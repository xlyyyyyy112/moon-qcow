///|
pub(all) struct Snapshot {
  index : Int32
  id : String
  name : String
  l1_offset : UInt64
  l1_entries : UInt64
  virtual_size : UInt64
  date_seconds : UInt64
  date_nanoseconds : UInt64
  vm_clock_nanoseconds : UInt64
  vm_state_size : UInt64
  entry_offset : UInt64
  entry_length : UInt64
}

///|
/// Snapshot enumeration is bounded and does not follow snapshot data mappings.
pub fn Image::snapshots(self : Image) -> Array[Snapshot] raise QcowError {
  let result : Array[Snapshot] = []
  let ids : Map[String, Bool] = Map([])
  let mut offset = self.header.snapshot_offset
  for index = 0; index < self.header.snapshot_count; index = index + 1 {
    let record = self.source.read_at(offset, 40)
    let l1_offset = integer(record, 0, 8)
    let l1_entries = integer(record, 8, 4)
    let id_length = integer(record, 12, 2)
    let name_length = integer(record, 14, 2)
    let date_seconds = integer(record, 16, 4)
    let date_nanoseconds = integer(record, 20, 4)
    let clock = integer(record, 24, 8)
    let mut state_size = integer(record, 32, 4)
    let extra_length = integer(record, 36, 4)
    if extra_length > 1024UL * 1024UL {
      raise LimitExceeded
    }
    if self.header.version == 3 && extra_length < 16UL {
      raise Invalid("v3 snapshot missing virtual size")
    }
    if date_nanoseconds >= 1000000000UL {
      raise Invalid("snapshot nanoseconds")
    }
    if l1_entries > self.limits.max_l1_entries.to_uint64() {
      raise LimitExceeded
    }
    let cluster = self.cluster_size().to_uint64()
    if l1_offset == 0UL || l1_offset % cluster != 0UL {
      raise Invalid("snapshot L1 alignment")
    }
    self.source.check_range(l1_offset, l1_entries * 8UL)
    let extra_offset = add(offset, 40UL)
    self.source.check_range(extra_offset, extra_length)
    if extra_length >= 8UL {
      state_size = self.source.integer(extra_offset, 8)
    }
    let virtual_size = if extra_length >= 16UL {
      self.source.integer(extra_offset + 8UL, 8)
    } else {
      self.virtual_size()
    }
    let coverage = cluster * self.header.l2_entries()
    if l1_entries < ceiling(virtual_size, coverage) {
      raise Invalid("snapshot L1 coverage")
    }
    let strings = add(extra_offset, extra_length)
    let id = decode_text(self.source.read_at(strings, id_length.to_int()))
    let name = decode_text(
      self.source.read_at(add(strings, id_length), name_length.to_int()),
    )
    if id.is_empty() || ids.contains(id) {
      raise Invalid("empty or duplicate snapshot ID")
    }
    ids[id] = true
    let next = add(strings, id_length + name_length)
    let padded = multiply(ceiling(next - offset, 8UL), 8UL)
    self.source.check_range(offset, padded)
    result.push({
      index,
      id,
      name,
      l1_offset,
      l1_entries,
      virtual_size,
      date_seconds,
      date_nanoseconds,
      vm_clock_nanoseconds: clock,
      vm_state_size: state_size,
      entry_offset: offset,
      entry_length: padded,
    })
    offset = add(offset, padded)
  }
  result
}

///|
/// Select a snapshot by exact ID. The active image and cache remain unchanged.
pub fn Image::open_snapshot(self : Image, id : String) -> Image raise QcowError {
  for snapshot in self.snapshots() {
    if snapshot.id == id {
      let header = {
        ..self.header,
        l1_offset: snapshot.l1_offset,
        l1_entries: snapshot.l1_entries,
        virtual_size: snapshot.virtual_size,
      }
      return {
        source: self.source,
        header,
        backing: self.backing,
        depth: self.depth,
        limits: self.limits,
        cache: BlockCache::new(self.limits.cache_bytes),
      }
    }
  }
  raise Invalid("snapshot ID not found")
}

///|
pub(all) struct FeatureName {
  feature_type : Int32
  bit : Int32
  name : String
}

///|
pub fn feature_names(source : Source) -> Array[FeatureName] raise QcowError {
  let result : Array[FeatureName] = []
  for extension in header_extensions(source) {
    if extension.kind != 0x6803f857UL {
      continue
    }
    if extension.data.length() % 48 != 0 {
      raise Invalid("feature table entry length")
    }
    let seen : Map[Int32, Bool] = Map([])
    for start = 0; start < extension.data.length(); start = start + 48 {
      let kind = extension.data[start].to_int()
      let bit = extension.data[start + 1].to_int()
      if kind > 2 || bit > 63 {
        raise Invalid("invalid feature name selector")
      }
      let key = kind * 64 + bit
      if seen.contains(key) {
        raise Invalid("duplicate feature name")
      }
      seen[key] = true
      let bytes : Array[Byte] = []
      let mut ended = false
      for i = start + 2; i < start + 48; i = i + 1 {
        let byte = extension.data[i]
        if byte == b'\x00' {
          ended = true
        } else if !ended {
          bytes.push(byte)
        }
      }
      result.push({
        feature_type: kind,
        bit,
        name: decode_text(Bytes::from_array(bytes)),
      })
    }
  }
  result
}
