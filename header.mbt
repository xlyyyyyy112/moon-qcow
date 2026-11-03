///|
/// Header fields are untrusted until inspect_header succeeds.
pub(all) struct Header {
  version : Int32
  backing_offset : UInt64
  backing_name_length : Int32
  cluster_bits : Int32
  virtual_size : UInt64
  l1_entries : UInt64
  l1_offset : UInt64
  refcount_offset : UInt64
  refcount_clusters : UInt64
  snapshot_count : Int32
  snapshot_offset : UInt64
  incompatible : UInt64
  compatible : UInt64
  autoclear : UInt64
  refcount_order : Int32
  header_length : Int32
}

///|
pub fn Header::cluster_size(self : Header) -> Int32 {
  1 << self.cluster_bits
}

///|
pub fn Header::extended_l2(self : Header) -> Bool {
  (self.incompatible & 16UL) != 0UL
}

///|
pub fn Header::l2_entries(self : Header) -> UInt64 {
  self.cluster_size().to_uint64() /
  (if self.extended_l2() { 16UL } else { 8UL })
}

///|
pub fn Header::cluster_count(self : Header) -> UInt64 {
  ceiling(self.virtual_size, self.cluster_size().to_uint64())
}

///|
pub fn inspect_header(
  source : Source,
  limits~ : Limits = Limits::default(),
) -> Header raise QcowError {
  limits.validate()
  let first = source.read_at(0UL, 72)
  if integer(first, 0, 4) != 0x514649fbUL {
    raise Invalid("QCOW magic")
  }
  let version64 = integer(first, 4, 4)
  if version64 != 2UL && version64 != 3UL {
    raise Unsupported("only QCOW2 v2 and v3 are supported")
  }
  let version = version64.to_int()
  let bits = integer(first, 20, 4)
  if bits < 9UL || bits > 21UL {
    raise Invalid("cluster_bits outside 9..21")
  }
  let cluster_bits = bits.to_int()
  let cluster = 1UL << cluster_bits
  source.check_range(0UL, cluster)
  if integer(first, 32, 4) != 0UL {
    raise Unsupported("AES and LUKS encrypted images")
  }
  let mut incompatible = 0UL
  let mut compatible = 0UL
  let mut autoclear = 0UL
  let mut refcount_order = 4
  let mut header_length = 72
  if version == 3 {
    let rest = source.read_at(72UL, 32)
    incompatible = integer(rest, 0, 8)
    compatible = integer(rest, 8, 8)
    autoclear = integer(rest, 16, 8)
    let order = integer(rest, 24, 4)
    if order > 6UL {
      raise Invalid("refcount order exceeds 6")
    }
    refcount_order = order.to_int()
    let length = integer(rest, 28, 4)
    if length < 104UL || length > cluster || length % 8UL != 0UL {
      raise Invalid("invalid v3 header length")
    }
    header_length = length.to_int()
    if (incompatible & 0xffffffffffffffefUL) != 0UL {
      raise Unsupported(
        "dirty, corrupt, external-data, non-deflate, or unknown incompatible feature",
      )
    }
    if (incompatible & 16UL) != 0UL && cluster_bits < 14 {
      raise Invalid("extended L2 requires cluster_bits >= 14")
    }
    if length > 104UL && source.integer(104UL, 1) != 0UL {
      raise Unsupported("non-deflate compression")
    }
  }
  let l1_entries = integer(first, 36, 4)
  if l1_entries > limits.max_l1_entries.to_uint64() {
    raise LimitExceeded
  }
  let l1_offset = integer(first, 40, 8)
  if l1_offset % cluster != 0UL || (l1_entries > 0UL && l1_offset == 0UL) {
    raise Invalid("invalid L1 offset")
  }
  source.check_range(l1_offset, l1_entries * 8UL)
  let virtual_size = integer(first, 24, 8)
  let l2_entries = cluster /
    (if (incompatible & 16UL) != 0UL { 16UL } else { 8UL })
  if l1_entries < ceiling(virtual_size, cluster * l2_entries) {
    raise Invalid("L1 table does not cover virtual size")
  }
  let backing_offset = integer(first, 8, 8)
  let backing_length = integer(first, 16, 4)
  if backing_offset != 0UL {
    if backing_offset < header_length.to_uint64() ||
      backing_offset >= cluster ||
      backing_length == 0UL ||
      backing_length > 1023UL ||
      backing_length > cluster - backing_offset {
      raise Invalid("invalid backing filename location")
    }
  }
  let refcount_offset = integer(first, 48, 8)
  let refcount_clusters = integer(first, 56, 4)
  if refcount_clusters == 0UL ||
    refcount_offset == 0UL ||
    refcount_offset % cluster != 0UL {
    raise Invalid("invalid refcount table")
  }
  source.check_range(refcount_offset, refcount_clusters * cluster)
  let snapshot_count = integer(first, 60, 4)
  if snapshot_count > limits.max_snapshots.to_uint64() {
    raise LimitExceeded
  }
  let snapshot_offset = integer(first, 64, 8)
  if snapshot_count > 0UL {
    if snapshot_offset == 0UL || snapshot_offset % cluster != 0UL {
      raise Invalid("invalid snapshot table offset")
    }
    source.check_range(snapshot_offset, 40UL)
  }
  {
    version,
    backing_offset,
    backing_name_length: if backing_offset == 0UL {
      0
    } else {
      backing_length.to_int()
    },
    cluster_bits,
    virtual_size,
    l1_entries,
    l1_offset,
    refcount_offset,
    refcount_clusters,
    snapshot_count: snapshot_count.to_int(),
    snapshot_offset,
    incompatible,
    compatible,
    autoclear,
    refcount_order,
    header_length,
  }
}

///|
pub(all) struct HeaderExtension {
  kind : UInt64
  offset : UInt64
  data : Bytes
}

///|
pub fn header_extensions(
  source : Source,
  limits~ : Limits = Limits::default(),
) -> Array[HeaderExtension] raise QcowError {
  let header = inspect_header(source, limits~)
  let end = if header.backing_offset != 0UL {
    header.backing_offset
  } else {
    header.cluster_size().to_uint64()
  }
  let result : Array[HeaderExtension] = []
  let seen : Map[UInt64, Bool] = Map([])
  let mut offset = header.header_length.to_uint64()
  while offset < end {
    if end - offset < 8UL {
      raise Invalid("truncated header extension")
    }
    let prefix = source.read_at(offset, 8)
    let kind = integer(prefix, 0, 4)
    let length = integer(prefix, 4, 4)
    if kind == 0UL {
      if length != 0UL {
        raise Invalid("nonzero end-marker length")
      }
      return result
    }
    if result.length() >= limits.max_extensions {
      raise LimitExceeded
    }
    if seen.contains(kind) {
      raise Invalid("duplicate header extension")
    }
    seen[kind] = true
    let padded = ceiling(length, 8UL) * 8UL
    let payload = offset + 8UL
    if padded > end - payload {
      raise Invalid("header extension overlaps backing name or cluster end")
    }
    let data = source.read_at(payload, length.to_int())
    result.push({ kind, offset, data, })
    offset = payload + padded
  }
  raise Invalid("missing header extension terminator")
}

///|
pub fn backing_filename(
  source : Source,
  limits~ : Limits = Limits::default(),
) -> String? raise QcowError {
  let header = inspect_header(source, limits~)
  if header.backing_offset == 0UL {
    None
  } else {
    let text = decode_text(
      source.read_at(header.backing_offset, header.backing_name_length),
    )
    if text.contains("\u0000") {
      raise Invalid("NUL in backing filename")
    }
    Some(text)
  }
}

///|
pub fn backing_format(
  source : Source,
  limits~ : Limits = Limits::default(),
) -> String? raise QcowError {
  for extension in header_extensions(source, limits~) {
    if extension.kind == 0xe2792acaUL {
      return Some(decode_text(extension.data))
    }
  }
  None
}
