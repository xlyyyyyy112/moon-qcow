///|
/// Paths are never opened by the core; backing sources are explicit.
pub(all) enum Backing {
  Raw(Source)
  Qcow(Image)
}

///|
pub struct Image {
  source : Source
  header : Header
  backing : Backing?
  depth : Int32
  limits : Limits
  cache : BlockCache
}

///|
pub fn open(
  data : Bytes,
  backing? : Backing,
  limits~ : Limits = Limits::default(),
) -> Image raise QcowError {
  open_source(Source::from_bytes(data), backing?, limits~)
}

///|
pub fn open_source(
  source : Source,
  backing? : Backing,
  limits~ : Limits = Limits::default(),
) -> Image raise QcowError {
  let header = inspect_header(source, limits~)
  ignore(header_extensions(source, limits~))
  if header.backing_offset != 0UL && backing is None {
    raise MissingBacking
  }
  if header.backing_offset == 0UL && backing is Some(_) {
    raise Invalid("backing supplied for a standalone image")
  }
  let depth = match backing {
    Some(Qcow(image)) => image.depth + 1
    Some(Raw(_)) => 2
    _ => 1
  }
  if depth > limits.max_chain {
    raise LimitExceeded
  }
  let format = backing_format(source, limits~)
  match (format, backing) {
    (Some("raw"), Some(Raw(_))) => ()
    (Some("qcow2"), Some(Qcow(_))) => ()
    (None, _) => ()
    (Some(_), None) => ()
    _ => raise Invalid("backing format does not match supplied source")
  }
  {
    source,
    header,
    backing,
    depth,
    limits,
    cache: BlockCache::new(limits.cache_bytes),
  }
}

///|
pub fn Image::header(self : Image) -> Header {
  self.header
}

///|
pub fn Image::virtual_size(self : Image) -> UInt64 {
  self.header.virtual_size
}

///|
pub fn Image::physical_size(self : Image) -> UInt64 {
  self.source.size
}

///|
pub fn Image::cluster_size(self : Image) -> Int32 {
  self.header.cluster_size()
}

///|
pub fn Image::chain_depth(self : Image) -> Int32 {
  self.depth
}

///|
pub fn Image::cache_stats(self : Image) -> CacheStats {
  {
    bytes: self.cache.bytes,
    blocks: self.cache.blocks.length(),
    hits: self.cache.hits,
    misses: self.cache.misses,
  }
}

///|
pub fn Image::clear_cache(self : Image) -> Unit {
  self.cache.blocks.clear()
  self.cache.queue.clear()
  self.cache.head = 0
  self.cache.bytes = 0
  self.cache.hits = 0UL
  self.cache.misses = 0UL
}

///|
fn Image::check_virtual(
  self : Image,
  offset : UInt64,
  length : UInt64,
) -> Unit raise QcowError {
  if offset > self.header.virtual_size ||
    length > self.header.virtual_size - offset {
    raise OutOfBounds
  }
}

///|
pub(all) enum ExtentKind {
  Data
  Zero
  Unallocated
  Compressed
}

///|
/// Mapping is local to this image; backing resolution is a separate operation.
pub(all) struct Extent {
  offset : UInt64
  length : UInt64
  kind : ExtentKind
  physical : UInt64?
  stored_length : Int32
}

///|
fn Image::descriptor(
  self : Image,
  position : UInt64,
) -> (UInt64, UInt64) raise QcowError {
  let cluster = self.cluster_size().to_uint64()
  let guest_cluster = position / cluster
  let per_table = self.header.l2_entries()
  let l1_index = guest_cluster / per_table
  if l1_index >= self.header.l1_entries {
    raise Invalid("L1 index outside table")
  }
  let l1 = self.source.integer(self.header.l1_offset + l1_index * 8UL, 8)
  if (l1 & 0x7f000000000001ffUL) != 0UL {
    raise Invalid("reserved L1 bits")
  }
  let l2 = l1 & 0x00fffffffffffe00UL
  if l2 == 0UL {
    if l1 != 0UL {
      raise Invalid("copied flag on absent L2 table")
    }
    return (0UL, 0UL)
  }
  if l2 % cluster != 0UL {
    raise Invalid("unaligned L2 table")
  }
  let bytes = self.cache.read(self.source, l2, self.cluster_size())
  let width = if self.header.extended_l2() { 16 } else { 8 }
  let index = (guest_cluster % per_table).to_int() * width
  (
    integer(bytes, index, 8),
    if width == 16 {
      integer(bytes, index + 8, 8)
    } else {
      0UL
    },
  )
}

///|
/// Return a mapping starting at position and ending at the next mapping boundary.
pub fn Image::extent_at(
  self : Image,
  position : UInt64,
) -> Extent raise QcowError {
  self.check_virtual(position, 1UL)
  let cluster = self.cluster_size().to_uint64()
  let inside = position % cluster
  let (entry, bitmap) = self.descriptor(position)
  let length = min64(cluster - inside, self.virtual_size() - position)
  if (entry & 0x4000000000000000UL) != 0UL {
    if bitmap != 0UL || (entry & 0x8000000000000000UL) != 0UL {
      raise Invalid("compressed cluster flags")
    }
    let shift = 62 - (self.header.cluster_bits - 8)
    let offset_mask = (1UL << shift) - 1UL
    let physical = entry & offset_mask
    if physical >= 1UL << 56 {
      raise Invalid("compressed offset exceeds 56 bits")
    }
    let sectors = (
        (entry >> shift) & ((1UL << (self.header.cluster_bits - 8)) - 1UL)
      ) +
      1UL
    let stored = sectors * 512UL - physical % 512UL
    self.source.check_range(physical, stored)
    return {
      offset: position,
      length,
      kind: Compressed,
      physical: Some(physical),
      stored_length: stored.to_int(),
    }
  }
  if (entry & 0x3f000000000001feUL) != 0UL {
    raise Invalid("reserved L2 bits")
  }
  let physical = entry & 0x00fffffffffffe00UL
  if physical % cluster != 0UL {
    raise Invalid("unaligned data cluster")
  }
  if physical == 0UL && (entry & 0x8000000000000000UL) != 0UL {
    raise Invalid("copied flag without data cluster")
  }
  let mut kind = if physical == 0UL { Unallocated } else { Data }
  let mut final_length = length
  if self.header.extended_l2() {
    if (entry & 1UL) != 0UL {
      raise Invalid("zero bit in extended L2 descriptor")
    }
    let allocated = bitmap & 0xffffffffUL
    let zero = bitmap >> 32
    if (allocated & zero) != 0UL {
      raise Invalid("subcluster both allocated and zero")
    }
    if allocated != 0UL && physical == 0UL {
      raise Invalid("subcluster allocation without host cluster")
    }
    let sub_size = cluster / 32UL
    let bit = 1UL << (inside / sub_size).to_int()
    kind = if (zero & bit) != 0UL {
      Zero
    } else if (allocated & bit) != 0UL {
      Data
    } else {
      Unallocated
    }
    final_length = min64(length, sub_size - inside % sub_size)
  } else if (entry & 1UL) != 0UL {
    if self.header.version == 2 {
      raise Invalid("zero bit in v2 image")
    }
    kind = Zero
  }
  let host = if kind is Data {
    self.source.check_range(physical, cluster)
    Some(physical + inside)
  } else {
    None
  }
  {
    offset: position,
    length: final_length,
    kind,
    physical: host,
    stored_length: 0,
  }
}

///|
fn Image::backing_size(self : Image) -> UInt64 {
  match self.backing {
    Some(Raw(source)) => source.size
    Some(Qcow(image)) => image.virtual_size()
    None => 0UL
  }
}

///|
fn Image::backing_read(
  self : Image,
  offset : UInt64,
  count : Int32,
) -> Bytes raise QcowError {
  match self.backing {
    Some(Raw(source)) => source.read_at(offset, count)
    Some(Qcow(image)) => {
      let result : Array[Byte] = []
      let mut done = 0
      while done < count {
        let remaining = count - done
        let length = if remaining < image.limits.max_read {
          remaining
        } else {
          image.limits.max_read
        }
        for byte in image.read_at(offset + done.to_uint64(), length) {
          result.push(byte)
        }
        done = done + length
      }
      Bytes::from_array(result)
    }
    None => raise MissingBacking
  }
}

///|
/// Exact-length guest read. No result is returned if any segment is invalid.
pub fn Image::read_at(
  self : Image,
  offset : UInt64,
  length : Int32,
) -> Bytes raise QcowError {
  if length < 0 || length > self.limits.max_read {
    raise LimitExceeded
  }
  self.check_virtual(offset, length.to_uint64())
  let result : Array[Byte] = []
  let mut done = 0
  while done < length {
    let position = offset + done.to_uint64()
    let extent = self.extent_at(position)
    let count = min64(extent.length, (length - done).to_uint64()).to_int()
    match extent.kind {
      Data => {
        let physical = extent.physical.unwrap()
        for byte in self.source.read_at(physical, count) {
          result.push(byte)
        }
      }
      Zero =>
        for _i = 0; _i < count; _i = _i + 1 {
          result.push(b'\x00')
        }
      Unallocated => {
        let backing_size = self.backing_size()
        let available = if position >= backing_size {
          0
        } else {
          min64(backing_size - position, count.to_uint64()).to_int()
        }
        if available > 0 {
          for byte in self.backing_read(position, available) {
            result.push(byte)
          }
        }
        for _i = available; _i < count; _i = _i + 1 {
          result.push(b'\x00')
        }
      }
      Compressed => {
        let compressed = self.source.read_at(
          extent.physical.unwrap(),
          extent.stored_length,
        )
        let inflated = inflate_cluster(compressed, self.cluster_size())
        let inside = (position % self.cluster_size().to_uint64()).to_int()
        for i = 0; i < count; i = i + 1 {
          result.push(inflated[inside + i])
        }
      }
    }
    done = done + count
  }
  Bytes::from_array(result)
}
