///|
test "public source and plan interfaces are usable from a consumer package" {
  let source = @qcow.Source::new(3UL, fn(_, count) { Bytes::make(count, b'x') })
  assert_eq(source.read_at(0UL, 3), b"xxx")
  let ranges : Array[@qcow.Difference] = [{ offset: 0UL, length: 10UL, }]
  let plan = @qcow.BackupPlan::new(20UL, ranges[:])
  assert_eq(plan.total_bytes(), 10UL)
  assert_eq(plan.complement().total_bytes(), 10UL)
  assert_eq(@qcow.parse_size("4GiB"), 4294967296UL)
}

///|
test "public typed source failures propagate to the caller" {
  let source = @qcow.Source::new(3UL, (_, _) => {
    raise @qcow.Io("consumer failure")
  })
  let failed = try {
    ignore(source.read_at(0UL, 1))
    false
  } catch {
    @qcow.Io(text) => text == "consumer failure"
    _ => false
  }
  assert_true(failed)
}
