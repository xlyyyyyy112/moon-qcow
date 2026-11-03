///|
/// QCOW2 stores a raw DEFLATE stream with possible sector-padding after it.
fn inflate_cluster(data : Bytes, expected : Int32) -> Bytes raise QcowError {
  let decoded = @flate.inflate_all(data[:], max_output=expected) catch {
    _ => raise Invalid("invalid or oversized compressed cluster")
  }
  if decoded.length() != expected {
    raise Invalid("compressed cluster expands to wrong length")
  }
  decoded
}
