///|
/// Immutable index over a complete, ordered local extent map.
/// Intended for repeated range queries; building it still scans the image once.
pub struct MapIndex {
  virtual_size : UInt64
  records : Array[Extent]
}

///|
pub fn MapIndex::new(
  virtual_size : UInt64,
  records : ArrayView[Extent],
) -> MapIndex raise QcowError {
  let owned : Array[Extent] = []
  let mut next = 0UL
  for record in records {
    if record.offset != next || record.length == 0UL {
      raise Invalid("map must cover contiguous logical ranges")
    }
    if next > virtual_size || record.length > virtual_size - next {
      raise Invalid("map extends past virtual EOF")
    }
    match record.kind {
      Data => {
        match record.physical {
          Some(offset) => ignore(add(offset, record.length))
          None => raise Invalid("data extent lacks physical address")
        }
        if record.stored_length != 0 {
          raise Invalid("stored length on uncompressed data")
        }
      }
      Compressed =>
        match record.physical {
          Some(offset) => {
            if record.stored_length <= 0 {
              raise Invalid("compressed extent lacks stored length")
            }
            ignore(add(offset, record.stored_length.to_uint64()))
          }
          None => raise Invalid("compressed extent lacks physical address")
        }
      Zero | Unallocated =>
        if record.physical is Some(_) || record.stored_length != 0 {
          raise Invalid("zero or hole extent contains a physical address")
        }
    }
    owned.push(record)
    next = next + record.length
  }
  if next != virtual_size {
    raise Invalid("map does not reach virtual EOF")
  }
  { virtual_size, records: owned, }
}

///|
pub fn Image::map_index(self : Image) -> MapIndex raise QcowError {
  MapIndex::new(
    self.virtual_size(),
    self.map_range(0UL, self.virtual_size())[:],
  )
}

///|
pub fn MapIndex::record_count(self : MapIndex) -> Int32 {
  self.records.length()
}

///|
fn MapIndex::find(self : MapIndex, position : UInt64) -> Int32 {
  let mut low = 0
  let mut high = self.records.length()
  while low < high {
    let middle = low + (high - low) / 2
    let record = self.records[middle]
    if record.offset + record.length <= position {
      low = middle + 1
    } else {
      high = middle
    }
  }
  low
}

///|
pub fn MapIndex::lookup(
  self : MapIndex,
  position : UInt64,
) -> Extent raise QcowError {
  if position >= self.virtual_size {
    raise OutOfBounds
  }
  let record = self.records[self.find(position)]
  let delta = position - record.offset
  let physical = match (record.kind, record.physical) {
    (Data, Some(offset)) => Some(offset + delta)
    _ => record.physical
  }
  { ..record, offset: position, length: record.length - delta, physical, }
}

///|
pub fn MapIndex::query(
  self : MapIndex,
  offset : UInt64,
  length : UInt64,
) -> Array[Extent] raise QcowError {
  if offset > self.virtual_size || length > self.virtual_size - offset {
    raise OutOfBounds
  }
  let result : Array[Extent] = []
  if length == 0UL {
    return result
  }
  let mut index = self.find(offset)
  let end = offset + length
  while index < self.records.length() {
    let record = self.records[index]
    if record.offset >= end {
      break
    }
    let start = if record.offset > offset { record.offset } else { offset }
    let stop = min64(record.offset + record.length, end)
    let physical = match (record.kind, record.physical) {
      (Data, Some(value)) => Some(value + start - record.offset)
      _ => record.physical
    }
    result.push({ ..record, offset: start, length: stop - start, physical, })
    index = index + 1
  }
  result
}

///|
/// The full output is copied so callers cannot invalidate the index.
pub fn MapIndex::records(self : MapIndex) -> Array[Extent] {
  self.records.copy()
}

///|
/// Return holes in the local image, including ranges supplied by a backing file.
pub fn MapIndex::unallocated_plan(
  self : MapIndex,
) -> BackupPlan raise QcowError {
  let ranges : Array[Difference] = []
  for record in self.records {
    if record.kind is Unallocated {
      ranges.push({ offset: record.offset, length: record.length, })
    }
  }
  BackupPlan::new(self.virtual_size, ranges[:])
}

///|
/// Select guest ranges whose bytes are physically stored in this image.
pub fn MapIndex::stored_plan(self : MapIndex) -> BackupPlan raise QcowError {
  let ranges : Array[Difference] = []
  for record in self.records {
    if record.kind is Data || record.kind is Compressed {
      ranges.push({ offset: record.offset, length: record.length, })
    }
  }
  BackupPlan::new(self.virtual_size, ranges[:])
}

///|
pub fn MapIndex::json(self : MapIndex) -> Json {
  let records = self.records.map(fn(record) { record.json() })
  { "virtual_size": self.virtual_size.to_string(), "extents": records }
}
