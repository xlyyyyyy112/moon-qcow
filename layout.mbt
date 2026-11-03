///|
fn shared_metadata_role(role : String) -> String {
  if role.has_suffix("/l1") {
    "l1"
  } else if role.has_suffix("/l2") {
    "l2"
  } else if role.has_prefix("bitmap-data:") {
    "bitmap-data"
  } else {
    role
  }
}

///|
/// Validate metadata aliasing. Shared identical L1/L2/bitmap data blocks are
/// allowed; overlap between unrelated structures is an error.
pub fn Image::layout_issues(
  self : Image,
  max_issues~ : Int32 = 1000,
) -> Array[AuditIssue] raise QcowError {
  if max_issues <= 0 {
    raise Invalid("invalid layout issue limit")
  }
  let regions = self.metadata_regions()
  regions.sort_by(fn(a, b) {
    if a.offset < b.offset {
      -1
    } else if a.offset > b.offset {
      1
    } else if a.length > b.length {
      -1
    } else if a.length < b.length {
      1
    } else {
      0
    }
  })
  let result : Array[AuditIssue] = []
  let mut previous : HostRegion? = None
  for region in regions {
    if region.length == 0UL {
      continue
    }
    match previous {
      Some(last) => {
        let same_range = region.offset == last.offset &&
          region.length == last.length
        let family = shared_metadata_role(region.role)
        let shared = same_range &&
          family == shared_metadata_role(last.role) &&
          (family == "l1" || family == "l2" || family == "bitmap-data")
        if shared {
          continue
        }
        if region.offset < last.offset + last.length {
          result.push({
            severity: "error",
            code: "metadata-overlap",
            offset: region.offset,
            message: region.role + " overlaps " + last.role,
          })
          if result.length() >= max_issues {
            return result
          }
          if region.offset + region.length <= last.offset + last.length {
            continue
          }
        }
      }
      None => ()
    }
    previous = Some(region)
  }
  result
}

///|
pub fn Image::metadata_size(self : Image) -> UInt64 raise QcowError {
  region_union_size(self.metadata_regions()[:])
}

///|
pub(all) struct ChainLayer {
  depth : Int32
  format : String
  virtual_size : UInt64
  physical_size : UInt64
  backing_filename : String?
  version : Int32
}

///|
/// Describe attached sources without opening any additional files.
pub fn Image::chain(self : Image) -> Array[ChainLayer] raise QcowError {
  let result : Array[ChainLayer] = []
  let mut image = self
  let mut depth = 0
  while true {
    result.push({
      depth,
      format: "qcow2",
      virtual_size: image.virtual_size(),
      physical_size: image.physical_size(),
      backing_filename: backing_filename(image.source, limits=image.limits),
      version: image.header.version,
    })
    match image.backing {
      Some(Qcow(base)) => {
        image = base
        depth = depth + 1
      }
      Some(Raw(source)) => {
        result.push({
          depth: depth + 1,
          format: "raw",
          virtual_size: source.size,
          physical_size: source.size,
          backing_filename: None,
          version: 0,
        })
        break
      }
      None => break
    }
  }
  result
}

///|
pub fn ChainLayer::json(self : ChainLayer) -> Json {
  let filename : Json = match self.backing_filename {
    Some(value) => Json::string(value)
    None => Json::null()
  }
  {
    "depth": self.depth,
    "format": self.format,
    "virtual_size": self.virtual_size.to_string(),
    "physical_size": self.physical_size.to_string(),
    "backing_filename": filename,
    "version": self.version,
  }
}

///|
/// Obtain the host source corresponding to a resolved extent's depth.
pub fn Image::source_at_depth(
  self : Image,
  depth : Int32,
) -> Source raise QcowError {
  if depth < 0 {
    raise Invalid("negative backing depth")
  }
  if depth == 0 {
    return self.source
  }
  match self.backing {
    Some(Qcow(image)) => image.source_at_depth(depth - 1)
    Some(Raw(source)) if depth == 1 => source
    _ => raise Invalid("backing depth does not exist")
  }
}

///|
/// Backup intervals outside the selected plan, clipped to virtual size.
pub fn BackupPlan::complement(self : BackupPlan) -> BackupPlan raise QcowError {
  let result : Array[Difference] = []
  let mut position = 0UL
  for range in self.ranges {
    if position < range.offset {
      result.push({ offset: position, length: range.offset - position, })
    }
    position = range.offset + range.length
  }
  if position < self.virtual_size {
    result.push({ offset: position, length: self.virtual_size - position, })
  }
  BackupPlan::new(self.virtual_size, result[:])
}

///|
pub fn BackupPlan::window(
  self : BackupPlan,
  offset : UInt64,
  length : UInt64,
) -> BackupPlan raise QcowError {
  let selection : Array[Difference] = [{ offset, length, }]
  let mask = BackupPlan::new(self.virtual_size, selection[:])
  self.intersection(mask)
}

///|
pub fn BackupPlan::chunk_count(
  self : BackupPlan,
  chunk_size : UInt64,
) -> UInt64 raise QcowError {
  if chunk_size == 0UL {
    raise Invalid("zero backup chunk size")
  }
  let mut count = 0UL
  for range in self.ranges {
    count = add(count, ceiling(range.length, chunk_size))
  }
  count
}
