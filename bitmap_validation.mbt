///|
pub(all) struct BitmapValidation {
  name : String
  granules : UInt64
  dirty_granules : UInt64
  allocated_blocks : UInt64
}

///|
/// Validate stored tail bits as well as pointers; a dirty bitmap must not claim
/// changes beyond the virtual disk. Unused bitmap-table entries must be zero.
pub fn Image::validate_bitmap(
  self : Image,
  name : String,
) -> BitmapValidation raise QcowError {
  let bitmap = self.find_bitmap(name)
  let cluster = self.cluster_size().to_uint64()
  let granules = ceiling(self.virtual_size(), bitmap.granularity())
  if granules > self.limits.max_scan_clusters.to_uint64() {
    raise LimitExceeded
  }
  let bits_per_block = cluster * 8UL
  let needed_blocks = ceiling(granules, bits_per_block)
  let mut dirty = 0UL
  let mut allocated = 0UL
  let mut scanned_bytes = 0UL
  for index = 0UL; index < bitmap.table_entries; index = index + 1UL {
    let pointer = self.bitmap_pointer(bitmap, index)
    if index >= needed_blocks {
      if pointer != 0UL {
        raise Invalid("nonempty bitmap table entry past virtual EOF")
      }
      continue
    }
    if pointer == 0UL {
      continue
    }
    let valid = min64(bits_per_block, granules - index * bits_per_block)
    if pointer == 1UL {
      if valid != bits_per_block {
        raise Invalid("all-ones bitmap block has nonzero tail bits")
      }
      dirty = dirty + valid
      continue
    }
    allocated = allocated + 1UL
    scanned_bytes = scanned_bytes + cluster
    if scanned_bytes > self.limits.max_scan_clusters.to_uint64() {
      raise LimitExceeded
    }
    let block = self.cache.read(self.source, pointer, self.cluster_size())
    for byte_index = 0; byte_index < block.length(); byte_index = byte_index + 1 {
      let first_bit = byte_index.to_uint64() * 8UL
      let mut value = block[byte_index].to_int()
      if first_bit >= valid {
        if value != 0 {
          raise Invalid("nonzero bitmap padding byte")
        }
        continue
      }
      let count = min64(8UL, valid - first_bit).to_int()
      if count < 8 && value >> count != 0 {
        raise Invalid("nonzero bitmap tail bits")
      }
      while value != 0 {
        dirty = dirty + (value & 1).to_uint64()
        value = value >> 1
      }
    }
  }
  { name, granules, dirty_granules: dirty, allocated_blocks: allocated, }
}

///|
pub fn BitmapValidation::json(self : BitmapValidation) -> Json {
  {
    "name": self.name,
    "granules": self.granules.to_string(),
    "dirty_granules": self.dirty_granules.to_string(),
    "allocated_blocks": self.allocated_blocks.to_string(),
  }
}
