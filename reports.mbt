///|
/// All byte offsets/counts are strings so JSON consumers preserve 64-bit values.
pub fn Header::json(self : Header) -> Json {
  {
    "version": self.version,
    "virtual_size": self.virtual_size.to_string(),
    "cluster_bits": self.cluster_bits,
    "cluster_size": self.cluster_size(),
    "l1_offset": self.l1_offset.to_string(),
    "l1_entries": self.l1_entries.to_string(),
    "refcount_offset": self.refcount_offset.to_string(),
    "refcount_clusters": self.refcount_clusters.to_string(),
    "refcount_order": self.refcount_order,
    "snapshot_count": self.snapshot_count,
    "snapshot_offset": self.snapshot_offset.to_string(),
    "backing_offset": self.backing_offset.to_string(),
    "backing_name_length": self.backing_name_length,
    "header_length": self.header_length,
    "incompatible_features": self.incompatible.to_string(),
    "compatible_features": self.compatible.to_string(),
    "autoclear_features": self.autoclear.to_string(),
    "extended_l2": self.extended_l2(),
  }
}

///|
pub fn ExtentKind::name(self : ExtentKind) -> String {
  match self {
    Data => "data"
    Zero => "zero"
    Unallocated => "unallocated"
    Compressed => "compressed"
  }
}

///|
fn optional_offset(offset : UInt64?) -> Json {
  match offset {
    Some(value) => Json::string(value.to_string())
    None => Json::null()
  }
}

///|
pub fn Extent::json(self : Extent) -> Json {
  {
    "offset": self.offset.to_string(),
    "length": self.length.to_string(),
    "kind": self.kind.name(),
    "physical": optional_offset(self.physical),
    "stored_length": self.stored_length,
  }
}

///|
pub fn ResolvedExtent::json(self : ResolvedExtent) -> Json {
  {
    "offset": self.offset.to_string(),
    "length": self.length.to_string(),
    "kind": self.kind.name(),
    "physical": optional_offset(self.physical),
    "stored_length": self.stored_length,
    "depth": self.depth,
  }
}

///|
pub fn Snapshot::json(self : Snapshot) -> Json {
  {
    "index": self.index,
    "id": self.id,
    "name": self.name,
    "l1_offset": self.l1_offset.to_string(),
    "l1_entries": self.l1_entries.to_string(),
    "virtual_size": self.virtual_size.to_string(),
    "date_seconds": self.date_seconds.to_string(),
    "date_nanoseconds": self.date_nanoseconds.to_string(),
    "vm_clock_nanoseconds": self.vm_clock_nanoseconds.to_string(),
    "vm_state_size": self.vm_state_size.to_string(),
  }
}

///|
pub fn AllocationStats::json(self : AllocationStats) -> Json {
  {
    "virtual_bytes": self.virtual_bytes.to_string(),
    "physical_bytes": self.physical_bytes.to_string(),
    "local_data_bytes": self.local_data_bytes.to_string(),
    "explicit_zero_bytes": self.explicit_zero_bytes.to_string(),
    "backing_or_hole_bytes": self.backing_or_hole_bytes.to_string(),
    "compressed_guest_bytes": self.compressed_guest_bytes.to_string(),
    "compressed_storage_bytes": self.compressed_storage_bytes.to_string(),
    "mapped_records": self.mapped_records,
  }
}

///|
pub fn CacheStats::json(self : CacheStats) -> Json {
  {
    "bytes": self.bytes,
    "blocks": self.blocks,
    "hits": self.hits.to_string(),
    "misses": self.misses.to_string(),
  }
}

///|
pub fn RefcountStats::json(self : RefcountStats) -> Json {
  {
    "host_clusters": self.host_clusters.to_string(),
    "unreferenced_clusters": self.unreferenced_clusters.to_string(),
    "exclusive_clusters": self.exclusive_clusters.to_string(),
    "shared_clusters": self.shared_clusters.to_string(),
    "max_refcount": self.max_refcount.to_string(),
  }
}

///|
pub fn RefcountRun::json(self : RefcountRun) -> Json {
  {
    "offset": self.offset.to_string(),
    "length": self.length.to_string(),
    "count": self.count.to_string(),
  }
}

///|
pub fn HostRegion::json(self : HostRegion) -> Json {
  {
    "offset": self.offset.to_string(),
    "length": self.length.to_string(),
    "role": self.role,
  }
}

///|
pub fn CopyProgress::json(self : CopyProgress) -> Json {
  {
    "start": self.start.to_string(),
    "next_offset": self.next_offset.to_string(),
    "end": self.end.to_string(),
    "written_bytes": self.written_bytes.to_string(),
    "skipped_zero_bytes": self.skipped_zero_bytes.to_string(),
    "complete": self.complete,
  }
}

///|
pub fn Difference::json(self : Difference) -> Json {
  { "offset": self.offset.to_string(), "length": self.length.to_string() }
}

///|
pub fn CompareReport::json(self : CompareReport) -> Json {
  let ranges = self.ranges.map(fn(range) { range.json() })
  {
    "compared_bytes": self.compared_bytes.to_string(),
    "different_bytes": self.different_bytes.to_string(),
    "ranges": ranges,
    "complete": self.complete,
  }
}

///|
pub fn AuditIssue::json(self : AuditIssue) -> Json {
  {
    "severity": self.severity,
    "code": self.code,
    "offset": self.offset.to_string(),
    "message": self.message,
  }
}

///|
pub fn AuditReport::json(self : AuditReport) -> Json {
  let issues = self.issues.map(fn(issue) { issue.json() })
  {
    "ok": self.ok(),
    "complete": self.complete,
    "scanned_bytes": self.scanned_bytes.to_string(),
    "mappings": self.mappings,
    "issues": issues,
    "scope": "active mappings, metadata overlap, nonzero referenced refcounts; not full repair/check",
  }
}

///|
pub fn Reference::json(self : Reference) -> Json {
  {
    "guest_offset": self.guest_offset.to_string(),
    "guest_length": self.guest_length.to_string(),
    "physical_offset": self.physical_offset.to_string(),
    "physical_length": self.physical_length.to_string(),
    "compressed": self.compressed,
  }
}

///|
pub fn FeatureName::json(self : FeatureName) -> Json {
  { "feature_type": self.feature_type, "bit": self.bit, "name": self.name }
}

///|
pub fn HeaderExtension::json(self : HeaderExtension) -> Json {
  {
    "kind": self.kind.to_string(),
    "offset": self.offset.to_string(),
    "length": self.data.length(),
  }
}

///|
pub fn QcowError::message(self : QcowError) -> String {
  match self {
    Invalid(message) => "invalid image: " + message
    Unsupported(message) => "unsupported feature: " + message
    OutOfBounds => "logical range exceeds virtual disk"
    MissingBacking =>
      "backing source required; following embedded paths requires explicit authorization"
    LimitExceeded => "configured resource limit exceeded"
    Io(message) => "I/O failure: " + message
  }
}
