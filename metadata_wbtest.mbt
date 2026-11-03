///|
fn bitmap_fixture() -> Array[Byte] {
  let data = fixture()
  for _i = 0; _i < 3 * 512; _i = _i + 1 {
    data.push(b'\x00')
  }
  put(data, 88, 8, 1UL)
  put(data, 104, 4, 0x23852875UL)
  put(data, 108, 4, 24UL)
  put(data, 112, 4, 1UL)
  put(data, 120, 8, 32UL)
  put(data, 128, 8, 3072UL)
  put(data, 6 * 512, 8, 3584UL)
  put(data, 6 * 512 + 8, 4, 1UL)
  data[6 * 512 + 16] = b'\x01'
  data[6 * 512 + 17] = b'\x09'
  put(data, 6 * 512 + 18, 2, 1UL)
  data[6 * 512 + 24] = b'a'
  put(data, 7 * 512, 8, 4096UL)
  data[8 * 512] = b'\x02'
  for index = 6; index < 9; index = index + 1 {
    put(data, 2 * 512 + index * 2, 2, 1UL)
  }
  data
}

///|
test "persistent bitmap decodes bit order and validates metadata" {
  let image = open(Bytes::from_array(bitmap_fixture()))
  let bitmaps = image.bitmaps()
  assert_eq(bitmaps.length(), 1)
  assert_eq(bitmaps[0].name, "a")
  assert_true(bitmaps[0].consistent)
  assert_true(!image.bitmap_dirty("a", 0UL))
  assert_true(image.bitmap_dirty("a", 512UL))
  let validation = image.validate_bitmap("a")
  assert_eq(validation.granules, 2UL)
  assert_eq(validation.dirty_granules, 1UL)
  let plan = image.bitmap_plan("a")
  assert_eq(plan.total_bytes(), 512UL)
  assert_eq(plan.ranges()[0].offset, 512UL)
  assert_true(image.audit().ok())
  assert_true(image.bitmap_regions().length() >= 3)
  assert_true(fails(() => ignore(image.check_refcounts())))
}

///|
test "stale or in-use bitmap cannot silently drive a backup" {
  for (offset, width, value) in [(88, 8, 0UL), (6 * 512 + 12, 4, 1UL)] {
    let data = bitmap_fixture()
    put(data, offset, width, value)
    let image = open(Bytes::from_array(data))
    assert_true(!image.bitmaps()[0].consistent)
    assert_true(fails(() => ignore(image.bitmap_plan("a"))))
  }
}

///|
test "bitmap out-of-disk tail bits and pointers are rejected" {
  for
    (offset, width, value) in [
      (8 * 512, 1, 4UL),
      (7 * 512, 8, 1UL),
      (7 * 512, 8, 4097UL),
      (7 * 512, 8, 4098UL),
    ] {
    let data = bitmap_fixture()
    put(data, offset, width, value)
    let image = open(Bytes::from_array(data))
    assert_true(fails(() => ignore(image.bitmap_ranges("a"))))
  }
}

///|
test "bitmap directory length flags type and names validated" {
  for
    (offset, width, value) in [
      (120, 8, 24UL),
      (6 * 512 + 12, 4, 8UL),
      (6 * 512 + 16, 1, 2UL),
      (6 * 512 + 17, 1, 64UL),
      (6 * 512 + 18, 2, 0UL),
      (6 * 512, 8, 1UL),
    ] {
    let data = bitmap_fixture()
    put(data, offset, width, value)
    let image = open(Bytes::from_array(data))
    assert_true(fails(() => ignore(image.bitmaps())))
  }
}

///|
test "unknown extensions are skipped but duplicates and overruns fail" {
  let data = fixture()
  put(data, 104, 4, 42UL)
  put(data, 108, 4, 8UL)
  let source = Source::from_bytes(Bytes::from_array(data))
  assert_eq(header_extensions(source).length(), 1)
  put(data, 120, 4, 42UL)
  put(data, 124, 4, 0UL)
  assert_true(fails(() => ignore(open(Bytes::from_array(data)))))
  put(data, 108, 4, 0xffffffffUL)
  assert_true(fails(() => ignore(open(Bytes::from_array(data)))))
}

///|
test "snapshot read selection is independent of public descriptions" {
  let data = fixture()
  for _i = 0; _i < 512; _i = _i + 1 {
    data.push(b'\x00')
  }
  put(data, 60, 4, 1UL)
  put(data, 64, 8, 3072UL)
  put(data, 6 * 512, 8, 1536UL)
  put(data, 6 * 512 + 8, 4, 1UL)
  put(data, 6 * 512 + 12, 2, 1UL)
  put(data, 6 * 512 + 14, 2, 1UL)
  put(data, 6 * 512 + 36, 4, 16UL)
  put(data, 6 * 512 + 48, 8, 1024UL)
  data[6 * 512 + 56] = b'1'
  data[6 * 512 + 57] = b's'
  let image = open(Bytes::from_array(data))
  let descriptions = image.snapshots()
  assert_eq(descriptions[0].id, "1")
  descriptions.clear()
  assert_eq(image.open_snapshot("1").read_at(0UL, 512), image.read_at(0UL, 512))
  assert_true(fails(() => ignore(image.open_snapshot("missing"))))
  put(data, 6 * 512 + 20, 4, 1000000000UL)
  let bad_time = open(Bytes::from_array(data))
  assert_true(fails(() => ignore(bad_time.snapshots())))
}

///|
test "chain limits count attached RAW sources and nested QCOW images" {
  let data = fixture()
  put(data, 8, 8, 200UL)
  put(data, 16, 4, 1UL)
  data[200] = b'b'
  let limits = { ..Limits::default(), max_chain: 1, }
  assert_true(
    fails(() => {
      ignore(
        open(
          Bytes::from_array(data),
          backing=Raw(Source::from_bytes(b"")),
          limits~,
        ),
      )
    }),
  )
  let base = image_fixture()
  let overlay = open(Bytes::from_array(data), backing=Qcow(base))
  assert_eq(overlay.chain_depth(), 2)
  assert_eq(overlay.chain().length(), 2)
  assert_eq(overlay.source_at_depth(1).size(), base.physical_size())
  assert_true(fails(() => ignore(overlay.source_at_depth(2))))
}

///|
test "backing reads honor a smaller child's read limit" {
  let base = open(Bytes::from_array(fixture()), limits={
    ..Limits::default(),
    max_read: 10,
  })
  let data = fixture()
  put(data, 8, 8, 200UL)
  put(data, 16, 4, 1UL)
  put(data, 3 * 512, 8, 0UL)
  let overlay = open(Bytes::from_array(data), backing=Qcow(base))
  assert_eq(overlay.read_at(0UL, 33).length(), 33)
}

///|
test "invalid limit configurations fail at the boundary" {
  for
    limits in [
      { ..Limits::default(), max_read: 0, },
      { ..Limits::default(), max_chain: 129, },
      { ..Limits::default(), max_l1_entries: 0, },
      { ..Limits::default(), max_extensions: 0, },
      { ..Limits::default(), max_snapshots: -1, },
      { ..Limits::default(), max_scan_clusters: 0, },
      { ..Limits::default(), max_map_entries: 0, },
      { ..Limits::default(), cache_bytes: -1, },
    ] {
    assert_true(
      fails(() => ignore(open(Bytes::from_array(fixture()), limits~))),
    )
  }
}

///|
test "backup set algebra compared to an independent boolean universe" {
  let mut state = 12345UL
  for _trial = 0; _trial < 100; _trial = _trial + 1 {
    let a_ranges : Array[Difference] = []
    let b_ranges : Array[Difference] = []
    let a_truth = Array::make(64, false)
    let b_truth = Array::make(64, false)
    for (ranges, truth) in [(a_ranges, a_truth), (b_ranges, b_truth)] {
      for _item = 0; _item < 8; _item = _item + 1 {
        state = state * 48271UL % 2147483647UL
        let start = (state % 64UL).to_int()
        state = state * 48271UL % 2147483647UL
        let count = (state % (65 - start).to_uint64()).to_int()
        ranges.push({ offset: start.to_uint64(), length: count.to_uint64(), })
        for i = start; i < start + count; i = i + 1 {
          truth[i] = true
        }
      }
    }
    let a = BackupPlan::new(64UL, a_ranges[:])
    let b = BackupPlan::new(64UL, b_ranges[:])
    let union = a.union(b)
    let intersection = a.intersection(b)
    let subtraction = a.subtract(b)
    let complement = a.complement()
    for i = 0; i < 64; i = i + 1 {
      assert_eq(union.contains(i.to_uint64()), a_truth[i] || b_truth[i])
      assert_eq(intersection.contains(i.to_uint64()), a_truth[i] && b_truth[i])
      assert_eq(subtraction.contains(i.to_uint64()), a_truth[i] && !b_truth[i])
      assert_eq(complement.contains(i.to_uint64()), !a_truth[i])
    }
  }
}

///|
test "random guest reads match independently assembled expected bytes" {
  let data = fixture()
  let image = open(Bytes::from_array(data))
  let expected : Array[Byte] = []
  for i = 5 * 512; i < 6 * 512; i = i + 1 {
    expected.push(data[i])
  }
  for _i = 0; _i < 512; _i = _i + 1 {
    expected.push(b'\x00')
  }
  let mut state = 723UL
  for _trial = 0; _trial < 1000; _trial = _trial + 1 {
    state = state * 48271UL % 2147483647UL
    let start = (state % 1025UL).to_int()
    state = state * 48271UL % 2147483647UL
    let count = (state % (1025 - start).to_uint64()).to_int()
    let actual = image.read_at(start.to_uint64(), count)
    assert_eq(actual.length(), count)
    for i = 0; i < count; i = i + 1 {
      assert_eq(actual[i], expected[start + i])
    }
  }
}

///|
test "bounded malformed header mutation never panics" {
  let original = fixture()
  let mut state = 19UL
  for _trial = 0; _trial < 2000; _trial = _trial + 1 {
    state = state * 48271UL % 2147483647UL
    let index = (state % 104UL).to_int()
    state = state * 48271UL % 2147483647UL
    let bytes = original.copy()
    bytes[index] = (state % 256UL).to_byte()
    // Either a parsed image or a typed error is valid; aborts are test failures.
    ignore(
      fails(() => {
        let image = open(Bytes::from_array(bytes))
        ignore(image.read_at(0UL, 1))
      }),
    )
  }
}

///|
test "cache FIFO queue compacts under sustained eviction" {
  let cache = BlockCache::new(2)
  let source = Source::from_bytes(b"abcd")
  for index = 0; index < 10000; index = index + 1 {
    ignore(cache.read(source, (index % 2 * 2).to_uint64(), 2))
  }
  assert_eq(cache.bytes, 2)
  assert_eq(cache.blocks.length(), 1)
  assert_true(cache.queue.length() < 2048)
}
