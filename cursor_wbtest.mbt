///|
test "copy cursor rejects reentrant writes and releases guard after failure" {
  let image = image_fixture()
  let cursor = image.copy_cursor(0UL, 512UL, chunk_size=128)
  assert_true(
    fails(() => {
      ignore(cursor.step(1, (_, _) => ignore(cursor.step(1, fn(_, _) { () }))))
    }),
  )
  assert_eq(cursor.progress().next_offset, 0UL)
  assert_eq(cursor.progress().written_bytes, 0UL)
  let result = cursor.step(4, fn(_, _) { () })
  assert_true(result.complete)
  assert_eq(result.written_bytes, 512UL)
}

///|
test "backup cursor rejects reentrant writes without double acknowledgment" {
  let image = image_fixture()
  let selected : Array[Difference] = [{ offset: 0UL, length: 512UL, }]
  let plan = BackupPlan::new(1024UL, selected[:])
  let cursor = image.backup_cursor(plan, chunk_size=128)
  assert_true(
    fails(() => {
      ignore(cursor.step(1, (_, _) => ignore(cursor.step(1, fn(_, _) { () }))))
    }),
  )
  assert_eq(cursor.progress().copied_bytes, 0UL)
  let result = cursor.step(4, fn(_, _) { () })
  assert_true(result.complete)
  assert_eq(result.copied_bytes, 512UL)
}
