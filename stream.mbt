///|
/// Export progress is acknowledged only after the sink callback succeeds.
pub(all) struct CopyProgress {
  start : UInt64
  next_offset : UInt64
  end : UInt64
  written_bytes : UInt64
  skipped_zero_bytes : UInt64
  complete : Bool
}

///|
/// Incremental operation state. Caller supplies a stable image and destination.
pub struct CopyCursor {
  image : Image
  start : UInt64
  end : UInt64
  chunk_size : Int32
  sparse : Bool
  mut next : UInt64
  mut written : UInt64
  mut skipped : UInt64
  mut busy : Bool
}

///|
/// Sparse mode does not write zero chunks; destination must initially read zero
/// and be sized by the caller. Never use sparse mode against existing dirty data.
pub fn Image::copy_cursor(
  self : Image,
  offset : UInt64,
  length : UInt64,
  chunk_size~ : Int32 = 1024 * 1024,
  sparse~ : Bool = false,
) -> CopyCursor raise QcowError {
  self.check_virtual(offset, length)
  if chunk_size <= 0 || chunk_size > self.limits.max_read {
    raise Invalid("invalid copy chunk size")
  }
  {
    image: self,
    start: offset,
    end: offset + length,
    chunk_size,
    sparse,
    next: offset,
    written: 0UL,
    skipped: 0UL,
    busy: false,
  }
}

///|
pub fn CopyCursor::progress(self : CopyCursor) -> CopyProgress {
  {
    start: self.start,
    next_offset: self.next,
    end: self.end,
    written_bytes: self.written,
    skipped_zero_bytes: self.skipped,
    complete: self.next == self.end,
  }
}

///|
pub fn bytes_are_zero(data : BytesView) -> Bool {
  for byte in data {
    if byte != b'\x00' {
      return false
    }
  }
  true
}

///|
/// At most max_chunks are processed; sink offsets are absolute guest offsets.
/// A throwing sink leaves that chunk unacknowledged and safe to retry at the
/// same offset with an idempotent write-at sink.
pub fn CopyCursor::step(
  self : CopyCursor,
  max_chunks : Int32,
  sink : (UInt64, Bytes) -> Unit raise QcowError,
) -> CopyProgress raise QcowError {
  if self.busy {
    raise Invalid("copy cursor is already executing a sink callback")
  }
  if max_chunks <= 0 {
    raise Invalid("max_chunks must be positive")
  }
  self.busy = true
  defer {
    self.busy = false
  }
  let mut processed = 0
  while self.next < self.end && processed < max_chunks {
    let count = min64(self.end - self.next, self.chunk_size.to_uint64()).to_int()
    let data = self.image.read_at(self.next, count)
    let zero = self.sparse && bytes_are_zero(data[:])
    if zero {
      self.skipped = self.skipped + count.to_uint64()
    } else {
      sink(self.next, data)
      self.written = self.written + count.to_uint64()
    }
    self.next = self.next + count.to_uint64()
    processed = processed + 1
  }
  self.progress()
}

///|
/// Full bounded-memory export. Cancellation is checked before every chunk.
/// An interrupted export reports progress and must not be presented as complete.
pub fn Image::copy_to(
  self : Image,
  sink : (UInt64, Bytes) -> Unit raise QcowError,
  chunk_size~ : Int32 = 1024 * 1024,
  sparse~ : Bool = false,
  cancelled~ : () -> Bool = fn() { false },
) -> CopyProgress raise QcowError {
  let cursor = self.copy_cursor(0UL, self.virtual_size(), chunk_size~, sparse~)
  while !cursor.progress().complete {
    if cancelled() {
      return cursor.progress()
    }
    ignore(cursor.step(1, sink))
  }
  cursor.progress()
}

///|
/// A seekable bounded view, useful for stream consumers without a huge buffer.
pub struct Reader {
  image : Image
  start : UInt64
  length : UInt64
  mut position : UInt64
}

///|
pub fn Image::reader(
  self : Image,
  offset : UInt64,
  length : UInt64,
) -> Reader raise QcowError {
  self.check_virtual(offset, length)
  { image: self, start: offset, length, position: 0UL, }
}

///|
pub fn Reader::position(self : Reader) -> UInt64 {
  self.position
}

///|
pub fn Reader::remaining(self : Reader) -> UInt64 {
  self.length - self.position
}

///|
pub fn Reader::seek(self : Reader, offset : UInt64) -> Unit raise QcowError {
  if offset > self.length {
    raise OutOfBounds
  }
  self.position = offset
}

///|
/// Stream reads may return fewer bytes at EOF, unlike Image::read_at.
pub fn Reader::read(self : Reader, maximum : Int32) -> Bytes raise QcowError {
  if maximum < 0 || maximum > self.image.limits.max_read {
    raise LimitExceeded
  }
  let count = min64(self.remaining(), maximum.to_uint64()).to_int()
  let result = self.image.read_at(self.start + self.position, count)
  self.position = self.position + count.to_uint64()
  result
}
