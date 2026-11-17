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

///|
/// Decode one QCOW2 Zstandard frame. Sector padding or a following compressed
/// cluster may share the stored range, so stop after the first frame.
fn inflate_zstd_cluster(
  data : Bytes,
  expected : Int32,
  window_bits : Int32,
) -> Bytes raise QcowError {
  let decoder = @zstd.Decoder(
    max_window_bits=window_bits,
    until=@codec_bytes.EndOfMember,
  )
  let output = FixedArray::make(expected + 1, b'\x00')
  ignore(
    decoder.step_into(data[:], output, end=true) catch {
      _ => raise Invalid("invalid or oversized Zstandard cluster")
    },
  )
  if !decoder.is_finished() || decoder.last_produced() != expected {
    raise Invalid("Zstandard cluster expands to wrong length")
  }
  Bytes::from_array(output[:expected])
}
