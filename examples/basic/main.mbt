///|
/// No disk image required: show sources, interval plans and exact-size parsing.
fn main raise {
  let a = @qcow.Source::from_bytes(b"moon")
  let b = @qcow.Source::from_bytes(b"qcow")
  let source = @qcow.concatenate_sources([a, b][:])
  assert_eq(source.read_at(2UL, 4), b"onqc")
  let ranges : Array[@qcow.Difference] = [
    { offset: 65536UL, length: 4096UL, },
    { offset: 69632UL, length: 4096UL, },
  ]
  let plan = @qcow.BackupPlan::new(@qcow.parse_size("1MiB"), ranges[:])
  assert_eq(plan.ranges().length(), 1)
  assert_eq(plan.total_bytes(), 8192UL)
  println(plan.json().stringify())
}
