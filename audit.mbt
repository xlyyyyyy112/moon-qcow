///|
pub(all) struct AuditIssue {
  severity : String
  code : String
  offset : UInt64
  message : String
}

///|
pub(all) struct AuditReport {
  issues : Array[AuditIssue]
  scanned_bytes : UInt64
  mappings : Int32
  complete : Bool
}

///|
pub fn AuditReport::ok(self : AuditReport) -> Bool {
  if !self.complete {
    return false
  }
  for issue in self.issues {
    if issue.severity == "error" {
      return false
    }
  }
  true
}

///|
fn overlaps(
  a : UInt64,
  a_length : UInt64,
  b : UInt64,
  b_length : UInt64,
) -> Bool {
  a < b + b_length && b < a + a_length
}

///|
/// Validated metadata union used for O(log n) data/metadata overlap queries.
fn merged_regions(
  regions : Array[HostRegion],
) -> Array[HostRegion] raise QcowError {
  let sorted = regions.copy()
  sorted.sort_by(fn(a, b) {
    if a.offset < b.offset {
      -1
    } else if a.offset > b.offset {
      1
    } else {
      0
    }
  })
  let result : Array[HostRegion] = []
  for region in sorted {
    ignore(add(region.offset, region.length))
    if region.length == 0UL {
      continue
    }
    if !result.is_empty() {
      let last = result[result.length() - 1]
      let end = last.offset + last.length
      if region.offset <= end {
        let next_end = region.offset + region.length
        if next_end > end {
          result[result.length() - 1] = {
            ..last,
            length: next_end - last.offset,
          }
        }
        continue
      }
    }
    result.push({ ..region, role: "metadata", })
  }
  result
}

///|
fn overlaps_metadata(
  regions : Array[HostRegion],
  offset : UInt64,
  length : UInt64,
) -> Bool {
  let mut low = 0
  let mut high = regions.length()
  while low < high {
    let middle = low + (high - low) / 2
    let region = regions[middle]
    if region.offset + region.length <= offset {
      low = middle + 1
    } else {
      high = middle
    }
  }
  low < regions.length() &&
  overlaps(offset, length, regions[low].offset, regions[low].length)
}

///|
/// Audit active guest mappings and metadata references without modifying bytes.
/// This checks referenced counts are nonzero, not exact global refcount equality:
/// VM-state and bitmap allocations are outside this audit's ownership model.
pub fn Image::audit(
  self : Image,
  verify_data~ : Bool = false,
  max_issues~ : Int32 = 1000,
) -> AuditReport raise QcowError {
  if max_issues <= 0 || max_issues > 1000000 {
    raise Invalid("invalid audit issue limit")
  }
  let issues = self.layout_issues(max_issues~)
  if issues.length() >= max_issues {
    return { issues, scanned_bytes: 0UL, mappings: 0, complete: false, }
  }
  let metadata = merged_regions(self.metadata_regions())
  let cluster = self.cluster_size().to_uint64()
  let counted : Map[UInt64, Bool] = Map([])
  let mut operations = 0
  for region in metadata {
    let first = region.offset / cluster
    let last = ceiling(region.offset + region.length, cluster)
    for index = first; index < last; index = index + 1UL {
      if operations >= self.limits.max_scan_clusters {
        return { issues, scanned_bytes: 0UL, mappings: 0, complete: false, }
      }
      operations = operations + 1
      let offset = index * cluster
      if self.refcount_at(offset) == 0UL {
        issues.push({
          severity: "error",
          code: "unreferenced-metadata",
          offset,
          message: "referenced metadata cluster has zero refcount",
        })
        if issues.length() >= max_issues {
          return { issues, scanned_bytes: 0UL, mappings: 0, complete: false, }
        }
      }
    }
  }
  let mut position = 0UL
  let mut mappings = 0
  while position < self.virtual_size() {
    if mappings >= self.limits.max_scan_clusters {
      return { issues, scanned_bytes: position, mappings, complete: false, }
    }
    let extent = self.extent_at(position)
    let host = match (extent.kind, extent.physical) {
      (Data, Some(value)) => Some((value, extent.length))
      (Compressed, Some(value)) =>
        Some((value, extent.stored_length.to_uint64()))
      _ => None
    }
    if host is Some((offset, length)) {
      if overlaps_metadata(metadata, offset, length) {
        issues.push({
          severity: "error",
          code: "data-overlaps-metadata",
          offset: position,
          message: "guest data points into image metadata",
        })
      }
      let first = offset / cluster
      let last = ceiling(offset + length, cluster)
      for index = first; index < last; index = index + 1UL {
        if !counted.contains(index) {
          counted[index] = true
          let count = self.refcount_at(index * cluster)
          if count == 0UL {
            issues.push({
              severity: "error",
              code: "unreferenced-data",
              offset: position,
              message: "referenced guest cluster has zero refcount",
            })
          }
          if counted.length() > self.limits.max_scan_clusters {
            return {
              issues,
              scanned_bytes: position,
              mappings,
              complete: false,
            }
          }
        }
      }
    }
    if verify_data {
      let mut verified = 0UL
      while verified < extent.length {
        let count = min64(
          extent.length - verified,
          self.limits.max_read.to_uint64(),
        ).to_int()
        ignore(self.read_at(position + verified, count))
        verified = verified + count.to_uint64()
      }
    }
    position = position + extent.length
    mappings = mappings + 1
    if issues.length() >= max_issues {
      return { issues, scanned_bytes: position, mappings, complete: false, }
    }
  }
  { issues, scanned_bytes: position, mappings, complete: true, }
}

///|
pub(all) struct Reference {
  guest_offset : UInt64
  guest_length : UInt64
  physical_offset : UInt64
  physical_length : UInt64
  compressed : Bool
}

///|
/// Reverse mapping of a host byte range to active local guest references.
/// Backing data is not included because its addresses belong to other files.
pub fn Image::references_to(
  self : Image,
  host_offset : UInt64,
  host_length : UInt64,
) -> Array[Reference] raise QcowError {
  self.source.check_range(host_offset, host_length)
  let result : Array[Reference] = []
  if host_length == 0UL {
    return result
  }
  ignore(
    self.visit_extents(0UL, self.virtual_size(), extent => {
      match extent.physical {
        Some(physical) => {
          let stored_length = if extent.kind is Compressed {
            extent.stored_length.to_uint64()
          } else {
            extent.length
          }
          if overlaps(host_offset, host_length, physical, stored_length) {
            result.push({
              guest_offset: extent.offset,
              guest_length: extent.length,
              physical_offset: physical,
              physical_length: stored_length,
              compressed: extent.kind is Compressed,
            })
            if result.length() >= self.limits.max_map_entries {
              raise LimitExceeded
            }
          }
        }
        None => ()
      }
      true
    }),
  )
  result
}

///|
/// Metadata role lookup for diagnostics at an exact host address.
pub fn Image::metadata_at(
  self : Image,
  offset : UInt64,
) -> Array[HostRegion] raise QcowError {
  if offset >= self.physical_size() {
    raise OutOfBounds
  }
  let result : Array[HostRegion] = []
  for region in self.metadata_regions() {
    if offset >= region.offset && offset - region.offset < region.length {
      result.push(region)
    }
  }
  result
}
