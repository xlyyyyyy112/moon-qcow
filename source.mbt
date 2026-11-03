///|
pub(all) suberror QcowError {
  Invalid(String)
  Unsupported(String)
  OutOfBounds
  MissingBacking
  LimitExceeded
  Io(String)
} derive(Debug)

///|
#deprecated
pub extend QcowError with @debug.Debug::{to_repr}

///|
/// A stable, exact-length random access source. The caller owns its lifetime.
pub struct Source {
  size : UInt64
  read : (UInt64, Int32) -> Bytes raise QcowError
}

///|
/// A source callback must return exactly the requested number of bytes.
pub fn Source::new(
  size : UInt64,
  read : (UInt64, Int32) -> Bytes raise QcowError,
) -> Source {
  { size, read, }
}

///|
pub fn Source::from_bytes(data : Bytes) -> Source {
  Source::new(data.length().to_uint64(), fn(offset, count) {
    let result : Array[Byte] = []
    for i = 0; i < count; i = i + 1 {
      result.push(data[offset.to_int() + i])
    }
    Bytes::from_array(result)
  })
}

///|
pub fn Source::size(self : Source) -> UInt64 {
  self.size
}

///|
pub fn Source::check_range(
  self : Source,
  offset : UInt64,
  length : UInt64,
) -> Unit raise QcowError {
  if offset > self.size || length > self.size - offset {
    raise Invalid("physical range exceeds source")
  }
}

///|
pub fn Source::read_at(
  self : Source,
  offset : UInt64,
  count : Int32,
) -> Bytes raise QcowError {
  if count < 0 || count > 16 * 1024 * 1024 {
    raise LimitExceeded
  }
  self.check_range(offset, count.to_uint64())
  if count == 0 {
    return b""
  }
  let bytes = (self.read)(offset, count)
  if bytes.length() != count {
    raise Io("short source read")
  }
  bytes
}

///|
fn Source::integer(
  self : Source,
  offset : UInt64,
  width : Int32,
) -> UInt64 raise QcowError {
  let bytes = self.read_at(offset, width)
  integer(bytes, 0, width)
}

///|
fn integer(data : Bytes, offset : Int32, width : Int32) -> UInt64 {
  let mut value = 0UL
  for i = 0; i < width; i = i + 1 {
    value = (value << 8) | data[offset + i].to_uint64()
  }
  value
}

///|
fn add(a : UInt64, b : UInt64) -> UInt64 raise QcowError {
  if b > 0xffffffffffffffffUL - a {
    raise Invalid("unsigned offset overflow")
  }
  a + b
}

///|
fn multiply(a : UInt64, b : UInt64) -> UInt64 raise QcowError {
  if b != 0UL && a > 0xffffffffffffffffUL / b {
    raise Invalid("unsigned size overflow")
  }
  a * b
}

///|
fn ceiling(value : UInt64, divisor : UInt64) -> UInt64 {
  value / divisor + (if value % divisor == 0UL { 0UL } else { 1UL })
}

///|
fn min64(a : UInt64, b : UInt64) -> UInt64 {
  if a < b {
    a
  } else {
    b
  }
}

///|
fn decode_text(data : Bytes) -> String raise QcowError {
  @utf8.decode(data) catch {
    _ => raise Invalid("invalid UTF-8 metadata string")
  }
}

///|
pub(all) struct Limits {
  max_read : Int32
  max_chain : Int32
  max_l1_entries : Int32
  max_extensions : Int32
  max_snapshots : Int32
  max_map_entries : Int32
  max_scan_clusters : Int32
  cache_bytes : Int32
}

///|
pub fn Limits::default() -> Limits {
  {
    max_read: 16 * 1024 * 1024,
    max_chain: 32,
    max_l1_entries: 4 * 1024 * 1024,
    max_extensions: 256,
    max_snapshots: 1024,
    max_map_entries: 1000000,
    max_scan_clusters: 4000000,
    cache_bytes: 8 * 1024 * 1024,
  }
}

///|
fn Limits::validate(self : Limits) -> Unit raise QcowError {
  if self.max_read <= 0 || self.max_read > 16 * 1024 * 1024 {
    raise Invalid("max_read must be within 1..16777216")
  }
  if self.max_chain <= 0 || self.max_chain > 128 {
    raise Invalid("max_chain must be within 1..128")
  }
  if self.max_l1_entries <= 0 || self.max_l1_entries > 4194304 {
    raise Invalid("invalid L1 entry limit")
  }
  if self.max_extensions <= 0 || self.max_extensions > 65536 {
    raise Invalid("invalid header extension limit")
  }
  if self.max_snapshots < 0 || self.max_snapshots > 65536 {
    raise Invalid("invalid snapshot limit")
  }
  if self.max_map_entries <= 0 || self.max_scan_clusters <= 0 {
    raise Invalid("scan limits must be positive")
  }
  if self.cache_bytes < 0 || self.cache_bytes > 64 * 1024 * 1024 {
    raise Invalid("cache limit must be within 0..67108864")
  }
}
