///|
/// Return the stored reference count for the host cluster containing offset.
/// This is an inspection operation, not a repair or a full consistency verdict.
pub fn Image::refcount_at(
  self : Image,
  offset : UInt64,
) -> UInt64 raise QcowError {
  if offset >= self.physical_size() {
    raise OutOfBounds
  }
  let cluster = self.cluster_size().to_uint64()
  let bits = 1 << self.header.refcount_order
  let entries_per_block = cluster * 8UL / bits.to_uint64()
  let host_cluster = offset / cluster
  let table_index = host_cluster / entries_per_block
  let table_entries = self.header.refcount_clusters * cluster / 8UL
  if table_index >= table_entries {
    return 0UL
  }
  let pointer = self.source.integer(
    self.header.refcount_offset + table_index * 8UL,
    8,
  )
  if pointer == 0UL {
    return 0UL
  }
  if pointer % cluster != 0UL || (pointer & 0x1ffUL) != 0UL {
    raise Invalid("unaligned refcount block")
  }
  let block = self.cache.read(self.source, pointer, self.cluster_size())
  let index = host_cluster % entries_per_block
  if bits < 8 {
    let bit_index = index * bits.to_uint64()
    let byte_index = (bit_index / 8UL).to_int()
    let shift = (bit_index % 8UL).to_int()
    let mask = (1UL << bits) - 1UL
    (block[byte_index].to_uint64() >> shift) & mask
  } else {
    let width = bits / 8
    integer(block, index.to_int() * width, width)
  }
}

///|
pub(all) struct RefcountRun {
  offset : UInt64
  length : UInt64
  count : UInt64
}

///|
/// Scan only existing host file clusters, bounded by max_scan_clusters.
pub fn Image::refcount_runs(self : Image) -> Array[RefcountRun] raise QcowError {
  let cluster = self.cluster_size().to_uint64()
  let clusters = ceiling(self.physical_size(), cluster)
  if clusters > self.limits.max_scan_clusters.to_uint64() {
    raise LimitExceeded
  }
  let result : Array[RefcountRun] = []
  for index = 0UL; index < clusters; index = index + 1UL {
    let offset = index * cluster
    let length = min64(cluster, self.physical_size() - offset)
    let count = self.refcount_at(offset)
    if !result.is_empty() {
      let previous = result[result.length() - 1]
      if previous.count == count {
        result[result.length() - 1] = {
          ..previous,
          length: previous.length + length,
        }
        continue
      }
    }
    if result.length() >= self.limits.max_map_entries {
      raise LimitExceeded
    }
    result.push({ offset, length, count, })
  }
  result
}

///|
pub(all) struct RefcountStats {
  host_clusters : UInt64
  unreferenced_clusters : UInt64
  exclusive_clusters : UInt64
  shared_clusters : UInt64
  max_refcount : UInt64
}

///|
pub fn Image::refcount_stats(self : Image) -> RefcountStats raise QcowError {
  let cluster = self.cluster_size().to_uint64()
  let mut zero = 0UL
  let mut one = 0UL
  let mut shared = 0UL
  let mut maximum = 0UL
  for run in self.refcount_runs() {
    let count = ceiling(run.length, cluster)
    if run.count == 0UL {
      zero = zero + count
    } else if run.count == 1UL {
      one = one + count
    } else {
      shared = shared + count
    }
    if run.count > maximum {
      maximum = run.count
    }
  }
  {
    host_clusters: ceiling(self.physical_size(), cluster),
    unreferenced_clusters: zero,
    exclusive_clusters: one,
    shared_clusters: shared,
    max_refcount: maximum,
  }
}

///|
pub(all) struct HostRegion {
  offset : UInt64
  length : UInt64
  role : String
}

///|
fn Image::add_region(
  self : Image,
  result : Array[HostRegion],
  offset : UInt64,
  length : UInt64,
  role : String,
) -> Unit raise QcowError {
  if length == 0UL {
    return
  }
  self.source.check_range(offset, length)
  if result.length() >= self.limits.max_map_entries {
    raise LimitExceeded
  }
  result.push({ offset, length, role, })
}

///|
fn Image::table_regions(
  self : Image,
  result : Array[HostRegion],
  l1_offset : UInt64,
  entries : UInt64,
  role : String,
) -> Unit raise QcowError {
  let cluster = self.cluster_size().to_uint64()
  self.add_region(result, l1_offset, entries * 8UL, role + "/l1")
  for index = 0UL; index < entries; index = index + 1UL {
    let entry = self.source.integer(l1_offset + index * 8UL, 8)
    if (entry & 0x7f000000000001ffUL) != 0UL {
      raise Invalid("reserved L1 bits in metadata scan")
    }
    let l2 = entry & 0x00fffffffffffe00UL
    if l2 != 0UL {
      if l2 % cluster != 0UL {
        raise Invalid("unaligned L2 in metadata scan")
      }
      self.add_region(result, l2, cluster, role + "/l2")
    } else if entry != 0UL {
      raise Invalid("copied flag on missing L2")
    }
  }
}

///|
/// Enumerate metadata ranges, including inactive snapshots and refcount blocks.
pub fn Image::metadata_regions(
  self : Image,
) -> Array[HostRegion] raise QcowError {
  let result : Array[HostRegion] = []
  let cluster = self.cluster_size().to_uint64()
  self.add_region(result, 0UL, cluster, "header")
  self.add_region(
    result,
    self.header.refcount_offset,
    self.header.refcount_clusters * cluster,
    "refcount-table",
  )
  let table_entries = self.header.refcount_clusters * cluster / 8UL
  if table_entries > self.limits.max_scan_clusters.to_uint64() {
    raise LimitExceeded
  }
  for i = 0UL; i < table_entries; i = i + 1UL {
    let pointer = self.source.integer(self.header.refcount_offset + i * 8UL, 8)
    if pointer != 0UL {
      if pointer % cluster != 0UL {
        raise Invalid("unaligned refcount block")
      }
      self.add_region(result, pointer, cluster, "refcount-block")
    }
  }
  for region in self.bitmap_regions() {
    if result.length() >= self.limits.max_map_entries {
      raise LimitExceeded
    }
    result.push(region)
  }
  self.table_regions(
    result,
    self.header.l1_offset,
    self.header.l1_entries,
    "active",
  )
  for snapshot in self.snapshots() {
    self.add_region(
      result,
      snapshot.entry_offset,
      snapshot.entry_length,
      "snapshot-table",
    )
    self.table_regions(
      result,
      snapshot.l1_offset,
      snapshot.l1_entries,
      "snapshot:" + snapshot.id,
    )
  }
  result
}

///|
/// Byte union of ranges; repeated references to a shared table count only once.
pub fn region_union_size(
  regions : ArrayView[HostRegion],
) -> UInt64 raise QcowError {
  let sorted : Array[HostRegion] = []
  for region in regions {
    ignore(add(region.offset, region.length))
    sorted.push(region)
  }
  sorted.sort_by(fn(a, b) {
    if a.offset < b.offset {
      -1
    } else if a.offset > b.offset {
      1
    } else {
      0
    }
  })
  let mut total = 0UL
  let mut end = 0UL
  for region in sorted {
    let stop = region.offset + region.length
    let start = if region.offset > end { region.offset } else { end }
    if stop > start {
      total = add(total, stop - start)
      end = stop
    }
  }
  total
}
