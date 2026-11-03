///|
pub(all) struct RefcountMismatch {
  offset : UInt64
  stored : UInt64
  expected : UInt64
}

///|
pub(all) struct RefcountCheck {
  checked_clusters : UInt64
  mismatches : Array[RefcountMismatch]
  complete : Bool
}

///|
pub fn RefcountCheck::ok(self : RefcountCheck) -> Bool {
  self.complete && self.mismatches.is_empty()
}

///|
fn Image::expect_cluster(
  self : Image,
  expected : Map[UInt64, UInt64],
  host : UInt64,
) -> Unit raise QcowError {
  if host >= self.physical_size() {
    raise Invalid("reference past host EOF")
  }
  let index = host / self.cluster_size().to_uint64()
  let count = expected.get(index).unwrap_or(0UL)
  expected[index] = add(count, 1UL)
  if expected.length() > self.limits.max_scan_clusters {
    raise LimitExceeded
  }
}

///|
/// Exact reference reconstruction for standalone allocation topology without
/// snapshots, persistent bitmaps or VM state. Unsupported ownership is rejected,
/// rather than claiming a complete check of allocations this model cannot count.
pub fn Image::check_refcounts(
  self : Image,
  max_mismatches~ : Int32 = 1000,
) -> RefcountCheck raise QcowError {
  if max_mismatches <= 0 {
    raise Invalid("invalid refcount mismatch limit")
  }
  if self.header.snapshot_count != 0 || self.bitmap_extension() is Some(_) {
    raise Unsupported(
      "exact refcount reconstruction with snapshots or persistent bitmaps",
    )
  }
  if (self.header.compatible & 0xfffffffffffffffeUL) != 0UL ||
    self.header.autoclear != 0UL {
    raise Unsupported(
      "exact refcount reconstruction with unknown compatible allocation features",
    )
  }
  for extension in header_extensions(self.source, limits=self.limits) {
    if extension.kind != 0xe2792acaUL && extension.kind != 0x6803f857UL {
      raise Unsupported(
        "exact refcount reconstruction with unmodeled metadata extension",
      )
    }
  }
  let cluster = self.cluster_size().to_uint64()
  let host_clusters = ceiling(self.physical_size(), cluster)
  if host_clusters > self.limits.max_scan_clusters.to_uint64() {
    raise LimitExceeded
  }
  let expected : Map[UInt64, UInt64] = Map([])
  let regions = self.metadata_regions()
  for region in regions {
    let first = region.offset / cluster
    let end = ceiling(region.offset + region.length, cluster)
    for index = first; index < end; index = index + 1UL {
      self.expect_cluster(expected, index * cluster)
    }
  }
  let unique_l2 : Map[UInt64, Bool] = Map([])
  let entries = self.header.l2_entries()
  let width = if self.header.extended_l2() { 16 } else { 8 }
  let mut scanned = 0
  for l1_index = 0UL
      l1_index < self.header.l1_entries
      l1_index = l1_index + 1UL {
    let pointer = self.source.integer(self.header.l1_offset + l1_index * 8UL, 8) &
      0x00fffffffffffe00UL
    if pointer == 0UL || unique_l2.contains(pointer) {
      continue
    }
    unique_l2[pointer] = true
    let table = self.cache.read(self.source, pointer, self.cluster_size())
    for index = 0UL; index < entries; index = index + 1UL {
      if scanned >= self.limits.max_scan_clusters {
        raise LimitExceeded
      }
      scanned = scanned + 1
      let entry = integer(table, index.to_int() * width, 8)
      if entry == 0UL {
        continue
      }
      let guest_cluster = l1_index * entries + index
      if guest_cluster >= self.header.cluster_count() {
        raise Unsupported("reference outside guest disk (possible VM state)")
      }
      let guest = guest_cluster * cluster
      // The normal mapping validator checks reserved bits and extended bitmaps.
      let extent = self.extent_at(guest)
      if extent.kind is Compressed {
        let host = extent.physical.unwrap()
        let first = host / cluster
        let end = ceiling(host + extent.stored_length.to_uint64(), cluster)
        for host_index = first; host_index < end; host_index = host_index + 1UL {
          self.expect_cluster(expected, host_index * cluster)
        }
      } else {
        let host = entry & 0x00fffffffffffe00UL
        if host != 0UL {
          self.source.check_range(host, cluster)
          self.expect_cluster(expected, host)
        }
      }
    }
  }
  let mismatches : Array[RefcountMismatch] = []
  for index = 0UL; index < host_clusters; index = index + 1UL {
    let offset = index * cluster
    let stored = self.refcount_at(offset)
    let wanted = expected.get(index).unwrap_or(0UL)
    if stored != wanted {
      mismatches.push({ offset, stored, expected: wanted, })
      if mismatches.length() >= max_mismatches {
        return { checked_clusters: index + 1UL, mismatches, complete: false, }
      }
    }
  }
  { checked_clusters: host_clusters, mismatches, complete: true, }
}

///|
pub fn RefcountMismatch::json(self : RefcountMismatch) -> Json {
  {
    "offset": self.offset.to_string(),
    "stored": self.stored.to_string(),
    "expected": self.expected.to_string(),
  }
}

///|
pub fn RefcountCheck::json(self : RefcountCheck) -> Json {
  let mismatches = self.mismatches.map(fn(item) { item.json() })
  {
    "ok": self.ok(),
    "complete": self.complete,
    "checked_clusters": self.checked_clusters.to_string(),
    "mismatches": mismatches,
    "scope": "active allocation topology without snapshots, bitmaps or VM state",
  }
}
