///|
test "exact reconstruction rejects allocation ownership it cannot model" {
  let unknown_extension = fixture()
  put(unknown_extension, 104, 4, 42UL)
  put(unknown_extension, 108, 4, 8UL)
  let image = open(Bytes::from_array(unknown_extension))
  assert_eq(image.read_at(512UL, 1), b"\x00")
  assert_true(fails(() => ignore(image.check_refcounts())))
  let unknown_feature = fixture()
  put(unknown_feature, 80, 8, 2UL)
  let compatible = open(Bytes::from_array(unknown_feature))
  assert_true(fails(() => ignore(compatible.check_refcounts())))
}
