///|
/// Counts physical I/O calls made through the wrapped source, without retaining
/// payloads or changing the source's error semantics.
pub struct SourceMetrics {
  mut reads : UInt64
  mut bytes : UInt64
  mut failed : UInt64
  mut largest : Int32
}

///|
pub fn SourceMetrics::new() -> SourceMetrics {
  { reads: 0UL, bytes: 0UL, failed: 0UL, largest: 0, }
}

///|
pub fn SourceMetrics::wrap(self : SourceMetrics, source : Source) -> Source {
  Source::new(source.size, (offset, length) => {
    self.reads = self.reads + 1UL
    if length > self.largest {
      self.largest = length
    }
    errdefer {
      self.failed = self.failed + 1UL
    }
    let bytes = source.read_at(offset, length)
    self.bytes = self.bytes + length.to_uint64()
    bytes
  })
}

///|
pub fn SourceMetrics::reset(self : SourceMetrics) -> Unit {
  self.reads = 0UL
  self.bytes = 0UL
  self.failed = 0UL
  self.largest = 0
}

///|
pub fn SourceMetrics::json(self : SourceMetrics) -> Json {
  {
    "reads": self.reads.to_string(),
    "bytes": self.bytes.to_string(),
    "failed_reads": self.failed.to_string(),
    "largest_read": self.largest,
  }
}
