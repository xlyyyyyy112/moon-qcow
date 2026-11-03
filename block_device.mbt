///|
/// Sector-oriented adapter for filesystem and partition readers.
pub struct BlockDevice {
  image : Image
  sector_size : Int32
  sector_count : UInt64
}

///|
pub fn Image::block_device(
  self : Image,
  sector_size~ : Int32 = 512,
) -> BlockDevice raise QcowError {
  if sector_size < 512 ||
    sector_size > 65536 ||
    (sector_size & (sector_size - 1)) != 0 {
    raise Invalid("sector size must be a power of two in 512..65536")
  }
  if self.virtual_size() % sector_size.to_uint64() != 0UL {
    raise Invalid("virtual disk size is not sector-aligned")
  }
  {
    image: self,
    sector_size,
    sector_count: self.virtual_size() / sector_size.to_uint64(),
  }
}

///|
pub fn BlockDevice::sector_size(self : BlockDevice) -> Int32 {
  self.sector_size
}

///|
pub fn BlockDevice::sector_count(self : BlockDevice) -> UInt64 {
  self.sector_count
}

///|
pub fn BlockDevice::read_sectors(
  self : BlockDevice,
  lba : UInt64,
  count : Int32,
) -> Bytes raise QcowError {
  if count < 0 || count > self.image.limits.max_read / self.sector_size {
    raise LimitExceeded
  }
  if lba > self.sector_count || count.to_uint64() > self.sector_count - lba {
    raise OutOfBounds
  }
  self.image.read_at(
    lba * self.sector_size.to_uint64(),
    count * self.sector_size,
  )
}

///|
/// A bounded subdevice whose sector addresses start at zero.
pub struct BlockSlice {
  device : BlockDevice
  first_lba : UInt64
  sectors : UInt64
}

///|
pub fn BlockDevice::slice(
  self : BlockDevice,
  first_lba : UInt64,
  sectors : UInt64,
) -> BlockSlice raise QcowError {
  if first_lba > self.sector_count || sectors > self.sector_count - first_lba {
    raise OutOfBounds
  }
  { device: self, first_lba, sectors, }
}

///|
pub fn BlockSlice::sector_count(self : BlockSlice) -> UInt64 {
  self.sectors
}

///|
pub fn BlockSlice::read_sectors(
  self : BlockSlice,
  lba : UInt64,
  count : Int32,
) -> Bytes raise QcowError {
  if count < 0 {
    raise LimitExceeded
  }
  if lba > self.sectors || count.to_uint64() > self.sectors - lba {
    raise OutOfBounds
  }
  self.device.read_sectors(self.first_lba + lba, count)
}

///|
/// Batch reads validate all requests before touching the source. Returned data
/// preserves caller order; one failed read fails the whole batch result.
pub fn Image::read_many(
  self : Image,
  ranges : ArrayView[ByteRange],
  max_total~ : UInt64 = 16777216UL,
) -> Array[Bytes] raise QcowError {
  if max_total > 67108864UL || ranges.length() > self.limits.max_map_entries {
    raise LimitExceeded
  }
  let mut total = 0UL
  for range in ranges {
    self.check_virtual(range.offset, range.length)
    if range.length > self.limits.max_read.to_uint64() {
      raise LimitExceeded
    }
    total = add(total, range.length)
    if total > max_total {
      raise LimitExceeded
    }
  }
  let result : Array[Bytes] = []
  for range in ranges {
    result.push(self.read_at(range.offset, range.length.to_int()))
  }
  result
}

///|
/// Expose an image as a stable logical source for generic random-access clients.
pub fn Image::as_source(self : Image) -> Source {
  Source::new(self.virtual_size(), (offset, length) => {
    self.read_at(offset, length)
  })
}

///|
/// A zero-copy subsource adapter: only requested bytes are materialized.
pub fn Source::slice(
  self : Source,
  offset : UInt64,
  length : UInt64,
) -> Source raise QcowError {
  self.check_range(offset, length)
  Source::new(length, (position, count) => {
    self.read_at(offset + position, count)
  })
}

///|
/// Concatenate sources without joining their bytes in memory.
pub fn concatenate_sources(
  sources : ArrayView[Source],
  max_sources~ : Int32 = 1024,
) -> Source raise QcowError {
  if max_sources <= 0 || sources.length() > max_sources {
    raise LimitExceeded
  }
  let owned : Array[Source] = []
  let starts : Array[UInt64] = []
  let mut size = 0UL
  for source in sources {
    if source.size == 0UL {
      continue
    }
    starts.push(size)
    owned.push(source)
    size = add(size, source.size)
  }
  Source::new(size, (offset, count) => {
    let result : Array[Byte] = []
    let mut position = offset
    let end = offset + count.to_uint64()
    let mut low = 0
    let mut high = owned.length()
    while low < high {
      let middle = low + (high - low) / 2
      if starts[middle] + owned[middle].size <= position {
        low = middle + 1
      } else {
        high = middle
      }
    }
    let mut index = low
    while position < end {
      let source = owned[index]
      let inside = position - starts[index]
      let length = min64(source.size - inside, end - position).to_int()
      for byte in source.read_at(inside, length) {
        result.push(byte)
      }
      position = position + length.to_uint64()
      index = index + 1
    }
    Bytes::from_array(result)
  })
}
