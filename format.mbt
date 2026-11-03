///|
/// Exact byte counts: unsigned decimal or hexadecimal and binary unit suffixes.
pub fn parse_size(text : String) -> UInt64 raise QcowError {
  let mut digits = text
  let mut multiplier = 1UL
  let suffixes = [
    ("KiB", 1024UL),
    ("MiB", 1048576UL),
    ("GiB", 1073741824UL),
    ("TiB", 1099511627776UL),
  ]
  for (suffix, factor) in suffixes {
    if text.has_suffix(suffix) {
      digits = text[:text.length() - suffix.length()].to_owned()
      multiplier = factor
      break
    }
  }
  let bytes = @utf8.encode(digits)
  let hexadecimal = bytes.length() >= 2 &&
    bytes[0] == b'0' &&
    (bytes[1] == b'x' || bytes[1] == b'X')
  let start = if hexadecimal { 2 } else { 0 }
  let base = if hexadecimal { 16UL } else { 10UL }
  if bytes.length() == start {
    raise Invalid("empty byte count")
  }
  let mut value = 0UL
  for i = start; i < bytes.length(); i = i + 1 {
    let byte = bytes[i].to_int()
    let digit = if byte >= 48 && byte <= 57 {
      byte - 48
    } else if hexadecimal && byte >= 65 && byte <= 70 {
      byte - 65 + 10
    } else if hexadecimal && byte >= 97 && byte <= 102 {
      byte - 97 + 10
    } else {
      raise Invalid("invalid byte count digit")
    }
    if digit.to_uint64() >= base {
      raise Invalid("digit outside number base")
    }
    value = add(multiply(value, base), digit.to_uint64())
  }
  multiply(value, multiplier)
}

///|
fn hex_digit(value : Int32) -> String {
  "0123456789abcdef"[value:value + 1].to_owned()
}

///|
pub fn hex_offset(value : UInt64) -> String {
  let mut text = ""
  let mut remaining = value
  for _i = 0; _i < 16; _i = _i + 1 {
    text = hex_digit((remaining & 15UL).to_int()) + text
    remaining = remaining >> 4
  }
  text
}

///|
/// Bounded binary display. Arbitrary guest bytes are not decoded as UTF-8.
pub fn hexdump(
  data : BytesView,
  offset~ : UInt64 = 0UL,
) -> String raise QcowError {
  if data.length() > 65536 {
    raise LimitExceeded
  }
  ignore(add(offset, data.length().to_uint64()))
  let mut result = ""
  for start = 0; start < data.length(); start = start + 16 {
    result = result + hex_offset(offset + start.to_uint64()) + "  "
    let stop = if start + 16 < data.length() {
      start + 16
    } else {
      data.length()
    }
    for i = start; i < start + 16; i = i + 1 {
      if i < stop {
        let value = data[i].to_int()
        result = result + hex_digit(value >> 4) + hex_digit(value & 15) + " "
      } else {
        result = result + "   "
      }
      if i == start + 7 {
        result = result + " "
      }
    }
    result = result + " |"
    for i = start; i < stop; i = i + 1 {
      let value = data[i].to_int()
      if value >= 32 && value <= 126 {
        result = result + decode_text(Bytes::from_array([data[i]]))
      } else {
        result = result + "."
      }
    }
    result = result + "|\n"
  }
  result
}

///|
pub(all) struct ByteRange {
  offset : UInt64
  length : UInt64
}

///|
pub fn ByteRange::end(self : ByteRange) -> UInt64 raise QcowError {
  add(self.offset, self.length)
}

///|
pub fn ByteRange::intersection(
  self : ByteRange,
  other : ByteRange,
) -> ByteRange? raise QcowError {
  let start = if self.offset > other.offset {
    self.offset
  } else {
    other.offset
  }
  let stop = min64(self.end(), other.end())
  if start < stop {
    Some({ offset: start, length: stop - start, })
  } else {
    None
  }
}

///|
pub fn ByteRange::split(
  self : ByteRange,
  chunk_size : UInt64,
  max_chunks : Int32,
) -> Array[ByteRange] raise QcowError {
  let end = self.end()
  if chunk_size == 0UL || max_chunks <= 0 {
    raise Invalid("invalid range split limit")
  }
  if ceiling(self.length, chunk_size) > max_chunks.to_uint64() {
    raise LimitExceeded
  }
  let result : Array[ByteRange] = []
  let mut position = self.offset
  while position < end {
    let length = min64(end - position, chunk_size)
    result.push({ offset: position, length, })
    position = position + length
  }
  result
}
