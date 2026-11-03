///|
fn can_merge(left : Extent, right : Extent) -> Bool {
  if left.offset + left.length != right.offset {
    return false
  }
  match (left.kind, right.kind) {
    (Data, Data) =>
      match (left.physical, right.physical) {
        (Some(a), Some(b)) => a + left.length == b
        _ => false
      }
    (Zero, Zero) | (Unallocated, Unallocated) => true
    _ => false
  }
}

///|
fn push_extent(result : Array[Extent], extent : Extent) -> Unit {
  if !result.is_empty() {
    let last = result[result.length() - 1]
    if can_merge(last, extent) {
      result[result.length() - 1] = {
        ..last,
        length: last.length + extent.length,
      }
      return
    }
  }
  result.push(extent)
}

///|
/// Streaming local map. The callback returns false to stop early.
/// Compressed records retain their original compressed location and are not merged.
pub fn Image::visit_extents(
  self : Image,
  offset : UInt64,
  length : UInt64,
  visit : (Extent) -> Bool raise QcowError,
) -> Bool raise QcowError {
  self.check_virtual(offset, length)
  let end = offset + length
  let mut position = offset
  let mut count = 0
  while position < end {
    if count >= self.limits.max_scan_clusters {
      raise LimitExceeded
    }
    let current = self.extent_at(position)
    let extent = { ..current, length: min64(current.length, end - position), }
    if !visit(extent) {
      return false
    }
    position = position + extent.length
    count = count + 1
  }
  true
}

///|
/// Collected, coalesced local map with a hard record limit.
pub fn Image::map_range(
  self : Image,
  offset : UInt64,
  length : UInt64,
) -> Array[Extent] raise QcowError {
  let result : Array[Extent] = []
  ignore(
    self.visit_extents(offset, length, extent => {
      push_extent(result, extent)
      if result.length() > self.limits.max_map_entries {
        raise LimitExceeded
      }
      true
    }),
  )
  result
}

///|
pub(all) struct ResolvedExtent {
  offset : UInt64
  length : UInt64
  kind : ExtentKind
  physical : UInt64?
  stored_length : Int32
  depth : Int32
}

///|
/// Resolve backing fallthrough while preserving explicit zero overrides.
pub fn Image::resolve_at(
  self : Image,
  position : UInt64,
) -> ResolvedExtent raise QcowError {
  let mapping = self.extent_at(position)
  match mapping.kind {
    Unallocated =>
      match self.backing {
        Some(Qcow(image)) if position < image.virtual_size() => {
          let resolved = image.resolve_at(position)
          {
            ..resolved,
            length: min64(mapping.length, resolved.length),
            depth: resolved.depth + 1,
          }
        }
        Some(Raw(source)) if position < source.size =>
          {
            offset: position,
            length: min64(mapping.length, source.size - position),
            kind: Data,
            physical: Some(position),
            stored_length: 0,
            depth: 1,
          }
        _ =>
          {
            offset: position,
            length: mapping.length,
            kind: Zero,
            physical: None,
            stored_length: 0,
            depth: self.depth,
          }
      }
    _ =>
      {
        offset: position,
        length: mapping.length,
        kind: mapping.kind,
        physical: mapping.physical,
        stored_length: mapping.stored_length,
        depth: 0,
      }
  }
}

///|
fn push_resolved(
  result : Array[ResolvedExtent],
  extent : ResolvedExtent,
) -> Unit {
  if !result.is_empty() {
    let last = result[result.length() - 1]
    let a : Extent = {
      offset: last.offset,
      length: last.length,
      kind: last.kind,
      physical: last.physical,
      stored_length: last.stored_length,
    }
    let b : Extent = {
      offset: extent.offset,
      length: extent.length,
      kind: extent.kind,
      physical: extent.physical,
      stored_length: extent.stored_length,
    }
    if last.depth == extent.depth && can_merge(a, b) {
      result[result.length() - 1] = {
        ..last,
        length: last.length + extent.length,
      }
      return
    }
  }
  result.push(extent)
}

///|
pub fn Image::resolved_map(
  self : Image,
  offset : UInt64,
  length : UInt64,
) -> Array[ResolvedExtent] raise QcowError {
  self.check_virtual(offset, length)
  let result : Array[ResolvedExtent] = []
  let mut position = offset
  let end = offset + length
  let mut scanned = 0
  while position < end {
    if scanned >= self.limits.max_scan_clusters {
      raise LimitExceeded
    }
    let current = self.resolve_at(position)
    let extent = { ..current, length: min64(current.length, end - position), }
    push_resolved(result, extent)
    if result.length() > self.limits.max_map_entries {
      raise LimitExceeded
    }
    position = position + extent.length
    scanned = scanned + 1
  }
  result
}

///|
pub(all) struct AllocationStats {
  virtual_bytes : UInt64
  physical_bytes : UInt64
  local_data_bytes : UInt64
  explicit_zero_bytes : UInt64
  backing_or_hole_bytes : UInt64
  compressed_guest_bytes : UInt64
  compressed_storage_bytes : UInt64
  mapped_records : Int32
}

///|
/// Statistics refer to the active mapping, not to all allocated host clusters.
pub fn Image::allocation_stats(self : Image) -> AllocationStats raise QcowError {
  let mut data = 0UL
  let mut zero = 0UL
  let mut hole = 0UL
  let mut compressed = 0UL
  let mut stored = 0UL
  let mut records = 0
  let seen : Map[UInt64, Bool] = Map([])
  ignore(
    self.visit_extents(0UL, self.virtual_size(), fn(extent) {
      match extent.kind {
        Data => data = data + extent.length
        Zero => zero = zero + extent.length
        Unallocated => hole = hole + extent.length
        Compressed => {
          compressed = compressed + extent.length
          let address = extent.physical.unwrap()
          if !seen.contains(address) {
            seen[address] = true
            stored = stored + extent.stored_length.to_uint64()
          }
        }
      }
      records = records + 1
      true
    }),
  )
  {
    virtual_bytes: self.virtual_size(),
    physical_bytes: self.physical_size(),
    local_data_bytes: data,
    explicit_zero_bytes: zero,
    backing_or_hole_bytes: hole,
    compressed_guest_bytes: compressed,
    compressed_storage_bytes: stored,
    mapped_records: records,
  }
}

///|
/// Intersect logical mappings with a caller-specified window.
pub fn clip_extents(
  extents : ArrayView[Extent],
  offset : UInt64,
  length : UInt64,
) -> Array[Extent] raise QcowError {
  let end = add(offset, length)
  let result : Array[Extent] = []
  let mut previous_end = 0UL
  for extent in extents {
    let extent_end = add(extent.offset, extent.length)
    if extent.length == 0UL || extent.offset < previous_end {
      raise Invalid("empty, overlapping, or unsorted input extent")
    }
    previous_end = extent_end
    let start = if extent.offset > offset { extent.offset } else { offset }
    let stop = min64(extent_end, end)
    if start < stop {
      let physical = match (extent.kind, extent.physical) {
        (Data, Some(value)) => Some(add(value, start - extent.offset))
        _ => extent.physical
      }
      result.push({ ..extent, offset: start, length: stop - start, physical, })
    }
  }
  result
}
