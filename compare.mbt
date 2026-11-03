///|
pub(all) struct Difference {
  offset : UInt64
  length : UInt64
}

///|
pub(all) struct CompareReport {
  compared_bytes : UInt64
  different_bytes : UInt64
  ranges : Array[Difference]
  complete : Bool
}

///|
/// Compare a logical image against a RAW source, preserving exact byte ranges.
/// If max_ranges is reached, complete=false; absence of more reported ranges is
/// never interpreted as equality. Both inputs must remain stable.
pub fn Image::compare_raw(
  self : Image,
  expected : Source,
  chunk_size~ : Int32 = 1024 * 1024,
  max_ranges~ : Int32 = 10000,
) -> CompareReport raise QcowError {
  if expected.size != self.virtual_size() {
    raise Invalid("comparison sizes differ")
  }
  if chunk_size <= 0 || chunk_size > self.limits.max_read || max_ranges <= 0 {
    raise Invalid("invalid comparison limits")
  }
  let ranges : Array[Difference] = []
  let mut position = 0UL
  let mut different = 0UL
  while position < self.virtual_size() {
    let count = min64(self.virtual_size() - position, chunk_size.to_uint64()).to_int()
    let actual = self.read_at(position, count)
    let wanted = expected.read_at(position, count)
    for i = 0; i < count; i = i + 1 {
      if actual[i] != wanted[i] {
        let offset = position + i.to_uint64()
        different = different + 1UL
        if !ranges.is_empty() {
          let previous = ranges[ranges.length() - 1]
          if previous.offset + previous.length == offset {
            ranges[ranges.length() - 1] = {
              ..previous,
              length: previous.length + 1UL,
            }
            continue
          }
        }
        if ranges.length() >= max_ranges {
          return {
            compared_bytes: offset + 1UL,
            different_bytes: different,
            ranges,
            complete: false,
          }
        }
        ranges.push({ offset, length: 1UL, })
      }
    }
    position = position + count.to_uint64()
  }
  {
    compared_bytes: position,
    different_bytes: different,
    ranges,
    complete: true,
  }
}

///|
/// Compare two logical images, including their respective backing chains.
pub fn Image::compare_image(
  self : Image,
  other : Image,
  chunk_size~ : Int32 = 1024 * 1024,
  max_ranges~ : Int32 = 10000,
) -> CompareReport raise QcowError {
  let source = Source::new(other.virtual_size(), (offset, count) => {
    other.read_at(offset, count)
  })
  self.compare_raw(source, chunk_size~, max_ranges~)
}

///|
/// Merge adjacent or overlapping byte differences into minimal sorted ranges.
pub fn merge_differences(
  input : ArrayView[Difference],
) -> Array[Difference] raise QcowError {
  let sorted : Array[Difference] = []
  for range in input {
    ignore(add(range.offset, range.length))
    if range.length > 0UL {
      sorted.push(range)
    }
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
  let result : Array[Difference] = []
  for range in sorted {
    if !result.is_empty() {
      let previous = result[result.length() - 1]
      let stop = previous.offset + previous.length
      if range.offset <= stop {
        let next_stop = range.offset + range.length
        if next_stop > stop {
          result[result.length() - 1] = {
            ..previous,
            length: next_stop - previous.offset,
          }
        }
        continue
      }
    }
    result.push(range)
  }
  result
}

///|
/// Convert byte changes to aligned backup blocks, clipped to the virtual disk.
pub fn dirty_blocks(
  differences : ArrayView[Difference],
  block_size : UInt64,
  virtual_size : UInt64,
) -> Array[Difference] raise QcowError {
  if block_size == 0UL || (block_size & (block_size - 1UL)) != 0UL {
    raise Invalid("block size must be a power of two")
  }
  let blocks : Array[Difference] = []
  for difference in differences {
    if difference.offset > virtual_size ||
      difference.length > virtual_size - difference.offset {
      raise OutOfBounds
    }
    if difference.length == 0UL {
      continue
    }
    let start = difference.offset / block_size * block_size
    let end = difference.offset + difference.length
    let tail = end % block_size
    let stop = if tail == 0UL {
      end
    } else {
      end + min64(block_size - tail, virtual_size - end)
    }
    blocks.push({ offset: start, length: stop - start, })
  }
  merge_differences(blocks[:])
}
