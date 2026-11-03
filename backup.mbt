///|
/// Validated, sorted, coalesced selection of logical ranges for partial backup.
/// It contains no destination identity or durability guarantee.
pub struct BackupPlan {
  virtual_size : UInt64
  ranges : Array[Difference]
  total_bytes : UInt64
}

///|
pub fn BackupPlan::new(
  virtual_size : UInt64,
  ranges : ArrayView[Difference],
) -> BackupPlan raise QcowError {
  let merged = merge_differences(ranges)
  let mut total = 0UL
  for range in merged {
    if range.offset > virtual_size || range.length > virtual_size - range.offset {
      raise OutOfBounds
    }
    total = add(total, range.length)
  }
  { virtual_size, ranges: merged, total_bytes: total, }
}

///|
pub fn Image::bitmap_plan(
  self : Image,
  name : String,
) -> BackupPlan raise QcowError {
  BackupPlan::new(self.virtual_size(), self.bitmap_ranges(name)[:])
}

///|
pub fn BackupPlan::total_bytes(self : BackupPlan) -> UInt64 {
  self.total_bytes
}

///|
pub fn BackupPlan::virtual_size(self : BackupPlan) -> UInt64 {
  self.virtual_size
}

///|
/// Returns a copy so callers cannot alter an already-validated plan.
pub fn BackupPlan::ranges(self : BackupPlan) -> Array[Difference] {
  self.ranges.copy()
}

///|
pub fn BackupPlan::contains(self : BackupPlan, offset : UInt64) -> Bool {
  let mut low = 0
  let mut high = self.ranges.length()
  while low < high {
    let middle = low + (high - low) / 2
    let range = self.ranges[middle]
    if offset < range.offset {
      high = middle
    } else if offset - range.offset >= range.length {
      low = middle + 1
    } else {
      return true
    }
  }
  false
}

///|
pub fn BackupPlan::union(
  self : BackupPlan,
  other : BackupPlan,
) -> BackupPlan raise QcowError {
  if self.virtual_size != other.virtual_size {
    raise Invalid("backup plan size mismatch")
  }
  let ranges = self.ranges.copy()
  for range in other.ranges {
    ranges.push(range)
  }
  BackupPlan::new(self.virtual_size, ranges[:])
}

///|
pub fn BackupPlan::intersection(
  self : BackupPlan,
  other : BackupPlan,
) -> BackupPlan raise QcowError {
  if self.virtual_size != other.virtual_size {
    raise Invalid("backup plan size mismatch")
  }
  let result : Array[Difference] = []
  let mut left = 0
  let mut right = 0
  while left < self.ranges.length() && right < other.ranges.length() {
    let a = self.ranges[left]
    let b = other.ranges[right]
    let start = if a.offset > b.offset { a.offset } else { b.offset }
    let end = min64(a.offset + a.length, b.offset + b.length)
    if start < end {
      result.push({ offset: start, length: end - start, })
    }
    if a.offset + a.length < b.offset + b.length {
      left = left + 1
    } else {
      right = right + 1
    }
  }
  BackupPlan::new(self.virtual_size, result[:])
}

///|
pub fn BackupPlan::subtract(
  self : BackupPlan,
  other : BackupPlan,
) -> BackupPlan raise QcowError {
  if self.virtual_size != other.virtual_size {
    raise Invalid("backup plan size mismatch")
  }
  let result : Array[Difference] = []
  let mut right = 0
  for range in self.ranges {
    let mut position = range.offset
    let end = range.offset + range.length
    while right < other.ranges.length() &&
          other.ranges[right].offset + other.ranges[right].length <= position {
      right = right + 1
    }
    let mut index = right
    while index < other.ranges.length() && other.ranges[index].offset < end {
      let removal = other.ranges[index]
      if removal.offset > position {
        result.push({ offset: position, length: removal.offset - position, })
      }
      let removal_end = removal.offset + removal.length
      if removal_end > position {
        position = min64(removal_end, end)
      }
      if position == end {
        break
      }
      index = index + 1
    }
    if position < end {
      result.push({ offset: position, length: end - position, })
    }
  }
  BackupPlan::new(self.virtual_size, result[:])
}

///|
pub fn BackupPlan::aligned(
  self : BackupPlan,
  block_size : UInt64,
) -> BackupPlan raise QcowError {
  BackupPlan::new(
    self.virtual_size,
    dirty_blocks(self.ranges[:], block_size, self.virtual_size)[:],
  )
}

///|
pub fn BackupPlan::json(self : BackupPlan) -> Json {
  let ranges = self.ranges.map(fn(range) { range.json() })
  {
    "virtual_size": self.virtual_size.to_string(),
    "total_bytes": self.total_bytes.to_string(),
    "ranges": ranges,
  }
}

///|
/// Progress includes only fully acknowledged chunks in the selected ranges.
pub(all) struct BackupProgress {
  range_index : Int32
  next_offset : UInt64
  copied_bytes : UInt64
  total_bytes : UInt64
  complete : Bool
}

///|
pub struct BackupCursor {
  image : Image
  plan : BackupPlan
  chunk_size : Int32
  mut range_index : Int32
  mut within : UInt64
  mut copied : UInt64
  mut busy : Bool
}

///|
pub fn Image::backup_cursor(
  self : Image,
  plan : BackupPlan,
  chunk_size~ : Int32 = 1048576,
) -> BackupCursor raise QcowError {
  if plan.virtual_size != self.virtual_size() {
    raise Invalid("backup plan virtual size mismatch")
  }
  if chunk_size <= 0 || chunk_size > self.limits.max_read {
    raise Invalid("backup chunk size")
  }
  {
    image: self,
    plan,
    chunk_size,
    range_index: 0,
    within: 0UL,
    copied: 0UL,
    busy: false,
  }
}

///|
pub fn BackupCursor::progress(self : BackupCursor) -> BackupProgress {
  let complete = self.range_index == self.plan.ranges.length()
  {
    range_index: self.range_index,
    next_offset: if complete {
      self.plan.virtual_size
    } else {
      self.plan.ranges[self.range_index].offset + self.within
    },
    copied_bytes: self.copied,
    total_bytes: self.plan.total_bytes,
    complete,
  }
}

///|
/// Sink positions are absolute guest offsets; unselected bytes are untouched.
pub fn BackupCursor::step(
  self : BackupCursor,
  max_chunks : Int32,
  sink : (UInt64, Bytes) -> Unit raise QcowError,
) -> BackupProgress raise QcowError {
  if self.busy {
    raise Invalid("backup cursor is already executing a sink callback")
  }
  if max_chunks <= 0 {
    raise Invalid("max_chunks must be positive")
  }
  self.busy = true
  defer {
    self.busy = false
  }
  let mut chunks = 0
  while self.range_index < self.plan.ranges.length() && chunks < max_chunks {
    let range = self.plan.ranges[self.range_index]
    let count = min64(range.length - self.within, self.chunk_size.to_uint64()).to_int()
    let offset = range.offset + self.within
    let bytes = self.image.read_at(offset, count)
    sink(offset, bytes)
    self.within = self.within + count.to_uint64()
    self.copied = self.copied + count.to_uint64()
    if self.within == range.length {
      self.range_index = self.range_index + 1
      self.within = 0UL
    }
    chunks = chunks + 1
  }
  self.progress()
}
