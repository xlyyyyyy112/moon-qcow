///|
/// Persistent dirty bitmap directory entry. Only consistent type-1 bitmaps can
/// be used to select backup ranges; stale metadata remains inspectable.
pub(all) struct DirtyBitmap {
  name : String
  table_offset : UInt64
  table_entries : UInt64
  flags : UInt64
  granularity_bits : Int32
  extra_length : Int32
  directory_offset : UInt64
  directory_length : UInt64
  consistent : Bool
}

///|
pub fn DirtyBitmap::granularity(self : DirtyBitmap) -> UInt64 {
  1UL << self.granularity_bits
}

///|
fn Image::bitmap_extension(self : Image) -> HeaderExtension? raise QcowError {
  let extensions = header_extensions(self.source, limits=self.limits)
  for extension in extensions {
    if extension.kind == 0x23852875UL {
      return Some(extension)
    }
  }
  if (self.header.autoclear & 1UL) != 0UL {
    raise Invalid("bitmap consistency flag without extension")
  }
  None
}

///|
pub fn Image::bitmaps(self : Image) -> Array[DirtyBitmap] raise QcowError {
  let result : Array[DirtyBitmap] = []
  let extension = match self.bitmap_extension() {
    Some(extension) => extension
    None => return result
  }
  if extension.data.length() != 24 {
    raise Invalid("bitmap extension must be 24 bytes")
  }
  let count = integer(extension.data, 0, 4)
  if count == 0UL ||
    count > 65535UL ||
    count > self.limits.max_map_entries.to_uint64() {
    raise LimitExceeded
  }
  if integer(extension.data, 4, 4) != 0UL {
    raise Invalid("reserved bitmap extension field")
  }
  let directory_size = integer(extension.data, 8, 8)
  let directory_offset = integer(extension.data, 16, 8)
  if directory_offset == 0UL ||
    directory_offset % self.cluster_size().to_uint64() != 0UL {
    raise Invalid("bitmap directory alignment")
  }
  self.source.check_range(directory_offset, directory_size)
  let end = directory_offset + directory_size
  let mut position = directory_offset
  let names : Map[String, Bool] = Map([])
  for _index = 0UL; _index < count; _index = _index + 1UL {
    if position > end || end - position < 24UL {
      raise Invalid("truncated bitmap directory entry")
    }
    let prefix = self.source.read_at(position, 24)
    let table_offset = integer(prefix, 0, 8)
    let table_entries = integer(prefix, 8, 4)
    let flags = integer(prefix, 12, 4)
    let kind = prefix[16].to_int()
    let granularity_bits = prefix[17].to_int()
    let name_length = integer(prefix, 18, 2)
    let extra_length = integer(prefix, 20, 4)
    if (flags & 0xfffffff8UL) != 0UL || kind != 1 || granularity_bits > 63 {
      raise Unsupported("unknown bitmap flags, type, or granularity")
    }
    if name_length == 0UL || name_length > 1023UL {
      raise Invalid("bitmap name length")
    }
    if extra_length > 1048576UL {
      raise LimitExceeded
    }
    let length = ceiling(24UL + extra_length + name_length, 8UL) * 8UL
    if length > end - position {
      raise Invalid("bitmap directory entry exceeds directory")
    }
    let name = decode_text(
      self.source.read_at(position + 24UL + extra_length, name_length.to_int()),
    )
    if name.contains("\u0000") || names.contains(name) {
      raise Invalid("NUL or duplicate bitmap name")
    }
    names[name] = true
    let cluster = self.cluster_size().to_uint64()
    if table_entries == 0UL ||
      table_offset == 0UL ||
      table_offset % cluster != 0UL {
      raise Invalid("bitmap table alignment or size")
    }
    if table_entries > self.limits.max_scan_clusters.to_uint64() {
      raise LimitExceeded
    }
    self.source.check_range(table_offset, table_entries * 8UL)
    let bits_needed = ceiling(self.virtual_size(), 1UL << granularity_bits)
    let bytes_needed = ceiling(bits_needed, 8UL)
    if table_entries < ceiling(bytes_needed, cluster) {
      raise Invalid("bitmap table cannot cover virtual disk")
    }
    let consistent = (self.header.autoclear & 1UL) != 0UL &&
      (flags & 1UL) == 0UL &&
      (extra_length == 0UL || (flags & 4UL) != 0UL)
    result.push({
      name,
      table_offset,
      table_entries,
      flags,
      granularity_bits,
      extra_length: extra_length.to_int(),
      directory_offset: position,
      directory_length: length,
      consistent,
    })
    position = position + length
  }
  if position != end {
    raise Invalid("unconsumed bitmap directory bytes")
  }
  result
}

///|
fn Image::find_bitmap(
  self : Image,
  name : String,
) -> DirtyBitmap raise QcowError {
  for bitmap in self.bitmaps() {
    if bitmap.name == name {
      if !bitmap.consistent {
        raise Invalid("dirty bitmap is inconsistent and cannot guide a backup")
      }
      return bitmap
    }
  }
  raise Invalid("bitmap name not found")
}

///|
fn Image::bitmap_pointer(
  self : Image,
  bitmap : DirtyBitmap,
  index : UInt64,
) -> UInt64 raise QcowError {
  if index >= bitmap.table_entries {
    raise Invalid("bitmap table index")
  }
  let pointer = self.source.integer(bitmap.table_offset + index * 8UL, 8)
  if (pointer & 0xff000000000001feUL) != 0UL {
    raise Invalid("reserved bitmap table bits")
  }
  let address = pointer & 0x00fffffffffffe00UL
  if address != 0UL {
    if (pointer & 1UL) != 0UL ||
      address % self.cluster_size().to_uint64() != 0UL {
      raise Invalid("bitmap data alignment or flags")
    }
    self.source.check_range(address, self.cluster_size().to_uint64())
  }
  pointer
}

///|
/// Query whether the bitmap granule containing a guest offset was modified.
pub fn Image::bitmap_dirty(
  self : Image,
  name : String,
  offset : UInt64,
) -> Bool raise QcowError {
  self.check_virtual(offset, 1UL)
  let bitmap = self.find_bitmap(name)
  let bit = offset / bitmap.granularity()
  let byte_index = bit / 8UL
  let cluster = self.cluster_size().to_uint64()
  let pointer = self.bitmap_pointer(bitmap, byte_index / cluster)
  if pointer == 0UL {
    return false
  }
  if pointer == 1UL {
    return true
  }
  let block = self.cache.read(self.source, pointer, self.cluster_size())
  let value = block[(byte_index % cluster).to_int()].to_int()
  (value & (1 << (bit % 8UL).to_int())) != 0
}

///|
/// Coalesced modified guest ranges. A single bitmap cluster is scanned once.
pub fn Image::bitmap_ranges(
  self : Image,
  name : String,
) -> Array[Difference] raise QcowError {
  ignore(self.validate_bitmap(name))
  let bitmap = self.find_bitmap(name)
  let result : Array[Difference] = []
  let cluster = self.cluster_size().to_uint64()
  let granularity = bitmap.granularity()
  let total_bits = ceiling(self.virtual_size(), granularity)
  if total_bits > self.limits.max_scan_clusters.to_uint64() {
    raise LimitExceeded
  }
  let mut loaded_index = 0xffffffffffffffffUL
  let mut pointer = 0UL
  let mut block = b""
  for bit = 0UL; bit < total_bits; bit = bit + 1UL {
    let byte_index = bit / 8UL
    let table_index = byte_index / cluster
    if table_index != loaded_index {
      pointer = self.bitmap_pointer(bitmap, table_index)
      loaded_index = table_index
      if pointer > 1UL {
        block = self.cache.read(self.source, pointer, self.cluster_size())
      }
    }
    let dirty = if pointer <= 1UL {
      pointer == 1UL
    } else {
      (
        block[(byte_index % cluster).to_int()].to_int() &
        (1 << (bit % 8UL).to_int())
      ) !=
      0
    }
    if !dirty {
      continue
    }
    let offset = bit * granularity
    let length = min64(granularity, self.virtual_size() - offset)
    if !result.is_empty() {
      let last = result[result.length() - 1]
      if last.offset + last.length == offset {
        result[result.length() - 1] = { ..last, length: last.length + length, }
        continue
      }
    }
    if result.length() >= self.limits.max_map_entries {
      raise LimitExceeded
    }
    result.push({ offset, length, })
  }
  result
}

///|
pub fn DirtyBitmap::json(self : DirtyBitmap) -> Json {
  {
    "name": self.name,
    "table_offset": self.table_offset.to_string(),
    "table_entries": self.table_entries.to_string(),
    "flags": self.flags.to_string(),
    "granularity": self.granularity().to_string(),
    "consistent": self.consistent,
    "extra_length": self.extra_length,
  }
}

///|
/// Every allocated bitmap block, including unused entries, is metadata.
pub fn Image::bitmap_regions(self : Image) -> Array[HostRegion] raise QcowError {
  let result : Array[HostRegion] = []
  let extension = match self.bitmap_extension() {
    Some(value) => value
    None => return result
  }
  if extension.data.length() != 24 {
    raise Invalid("bitmap extension size")
  }
  let directory_length = integer(extension.data, 8, 8)
  let directory_offset = integer(extension.data, 16, 8)
  self.add_region(
    result, directory_offset, directory_length, "bitmap-directory",
  )
  let cluster = self.cluster_size().to_uint64()
  for bitmap in self.bitmaps() {
    self.add_region(
      result,
      bitmap.table_offset,
      bitmap.table_entries * 8UL,
      "bitmap-table:" + bitmap.name,
    )
    for index = 0UL; index < bitmap.table_entries; index = index + 1UL {
      let pointer = self.bitmap_pointer(bitmap, index)
      if pointer > 1UL {
        self.add_region(result, pointer, cluster, "bitmap-data:" + bitmap.name)
      }
    }
  }
  result
}
