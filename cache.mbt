///|
/// Byte-bounded FIFO with constant-time lookup. The entry cap also bounds
/// per-entry overhead when images use the smallest legal cluster size.
pub struct BlockCache {
  blocks : Map[(UInt64, Int32), Bytes]
  mut queue : Array[(UInt64, Int32)]
  mut head : Int32
  mut bytes : Int32
  budget : Int32
  mut hits : UInt64
  mut misses : UInt64
}

///|
fn BlockCache::new(budget : Int32) -> BlockCache {
  {
    blocks: Map([]),
    queue: [],
    head: 0,
    bytes: 0,
    budget,
    hits: 0UL,
    misses: 0UL,
  }
}

///|
fn BlockCache::compact(self : BlockCache) -> Unit {
  if self.head >= 1024 && self.head > self.queue.length() / 2 {
    let remaining : Array[(UInt64, Int32)] = []
    for index = self.head; index < self.queue.length(); index = index + 1 {
      remaining.push(self.queue[index])
    }
    self.queue = remaining
    self.head = 0
  }
}

///|
fn BlockCache::read(
  self : BlockCache,
  source : Source,
  offset : UInt64,
  length : Int32,
) -> Bytes raise QcowError {
  let key = (offset, length)
  if self.blocks.get(key) is Some(bytes) {
    self.hits = self.hits + 1UL
    return bytes
  }
  self.misses = self.misses + 1UL
  let bytes = source.read_at(offset, length)
  if length > self.budget {
    return bytes
  }
  while self.bytes > self.budget - length || self.blocks.length() >= 4096 {
    let removed = self.queue[self.head]
    self.head = self.head + 1
    self.blocks.remove(removed)
    self.bytes = self.bytes - removed.1
  }
  self.compact()
  self.blocks[key] = bytes
  self.queue.push(key)
  self.bytes = self.bytes + length
  bytes
}

///|
pub(all) struct CacheStats {
  bytes : Int32
  blocks : Int32
  hits : UInt64
  misses : UInt64
}
