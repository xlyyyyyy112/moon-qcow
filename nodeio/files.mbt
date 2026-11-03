///|
#external
pub type FileState

///|
#external
priv type Stat

///|
#external
priv type ReadResult

///|
#module("node:fs")
extern "js" fn node_open(path : String, mode : String) -> Int32 = "openSync"

///|
#module("node:fs")
extern "js" fn node_stat(fd : Int32) -> Stat = "fstatSync"

///|
#module("node:fs")
extern "js" fn node_close(fd : Int32) -> Unit = "closeSync"

///|
#module("node:fs")
extern "js" fn node_realpath(path : String) -> String = "realpathSync"

///|
#module("node:fs")
extern "js" fn node_read(
  fd : Int32,
  buffer : Bytes,
  start : Int32,
  count : Int32,
  offset : UInt64,
) -> Int32 = "readSync"

///|
#module("node:fs")
extern "js" fn node_write(
  fd : Int32,
  buffer : Bytes,
  start : Int32,
  count : Int32,
  offset : Double,
) -> Int32 = "writeSync"

///|
#module("node:fs")
extern "js" fn node_truncate(fd : Int32, size : Double) -> Unit = "ftruncateSync"

///|
#module("node:fs")
extern "js" fn node_sync(fd : Int32) -> Unit = "fsyncSync"

///|
extern "js" fn checked_sync(
  state : FileState,
  sync_fn : (Int32) -> Unit,
) -> String =
  #| (state, sync) => {
  #|   try {
  #|     if (state.closed) throw new Error("file is closed");
  #|     sync(state.fd);
  #|     return "";
  #|   } catch(e) { return String(e.message); }
  #| }

///|
/// Flush file data; this does not promise directory durability or atomic rename.
pub fn FileState::sync(self : FileState) -> Unit raise @qcow.QcowError {
  let error = checked_sync(self, node_sync)
  if !error.is_empty() {
    raise @qcow.Io(error)
  }
}

///|
#module("node:path")
extern "js" fn path_dirname(path : String) -> String = "dirname"

///|
#module("node:path")
extern "js" fn path_resolve(base : String, path : String) -> String = "resolve"

///|
extern "js" fn checked_open(
  open_fn : (String, String) -> Int32,
  stat_fn : (Int32) -> Stat,
  close_fn : (Int32) -> Unit,
  real_fn : (String) -> String,
  path : String,
  mode : String,
) -> FileState =
  #| (open, stat, close, realpath, path, mode) => {
  #|   let fd = -1;
  #|   try {
  #|     fd = open(path, mode);
  #|     const info = stat(fd);
  #|     if (!info.isFile()) throw new Error("not a regular file");
  #|     if (!Number.isSafeInteger(info.size)) throw new Error("file size exceeds Node safe integer range");
  #|     return {fd, size:BigInt(info.size), path:realpath(path), closed:false, error:""};
  #|   } catch (e) {
  #|     if (fd >= 0) { try { close(fd); } catch (_) {} }
  #|     return {fd:-1, size:0n, path, closed:true, error:String(e.message)};
  #|   }
  #| }

///|
extern "js" fn state_error(state : FileState) -> String =
  #| state => state.error

///|
extern "js" fn state_size(state : FileState) -> UInt64 =
  #| state => state.size

///|
extern "js" fn state_path(state : FileState) -> String =
  #| state => state.path

///|
extern "js" fn checked_read(
  state : FileState,
  read_fn : (Int32, Bytes, Int32, Int32, UInt64) -> Int32,
  offset : UInt64,
  count : Int32,
) -> ReadResult =
  #| (state, read, offset, count) => {
  #|   try {
  #|     if (state.closed) throw new Error("file is closed");
  #|     const bytes = new Uint8Array(count);
  #|     let done = 0;
  #|     while (done < count) {
  #|       const n = read(state.fd, bytes, done, count-done, offset+BigInt(done));
  #|       if (n <= 0) throw new Error("short file read");
  #|       done += n;
  #|     }
  #|     return {bytes, error:""};
  #|   } catch(e) { return {bytes:new Uint8Array(0), error:String(e.message)}; }
  #| }

///|
extern "js" fn read_error(result : ReadResult) -> String =
  #| result => result.error

///|
extern "js" fn read_bytes(result : ReadResult) -> Bytes =
  #| result => result.bytes

///|
extern "js" fn checked_close(
  state : FileState,
  close_fn : (Int32) -> Unit,
) -> String =
  #| (state, close) => {
  #|   if (state.closed) return "";
  #|   try { close(state.fd); state.closed = true; return ""; }
  #|   catch(e) { return String(e.message); }
  #| }

///|
extern "js" fn checked_write(
  state : FileState,
  write_fn : (Int32, Bytes, Int32, Int32, Double) -> Int32,
  offset : UInt64,
  data : Bytes,
) -> String =
  #| (state, write, offset, data) => {
  #|   try {
  #|     if (state.closed) throw new Error("file is closed");
  #|     if (offset + BigInt(data.length) > 9007199254740991n)
  #|       throw new Error("write offset exceeds Node safe integer range");
  #|     let done = 0;
  #|     while (done < data.length) {
  #|       const n = write(state.fd, data, done, data.length-done, Number(offset)+done);
  #|       if (n <= 0) throw new Error("short file write");
  #|       done += n;
  #|     }
  #|     return "";
  #|   } catch(e) { return String(e.message); }
  #| }

///|
extern "js" fn checked_truncate(
  state : FileState,
  truncate_fn : (Int32, Double) -> Unit,
  size : UInt64,
) -> String =
  #| (state, truncate, size) => {
  #|   try {
  #|     if (state.closed) throw new Error("file is closed");
  #|     if (size > 9007199254740991n) throw new Error("output size exceeds Node safe integer range");
  #|     truncate(state.fd, Number(size));
  #|     state.size = size;
  #|     return "";
  #|   } catch(e) { return String(e.message); }
  #| }

///|
/// Read-only open. The descriptor is owned by the returned handle.
pub fn open_file(path : String) -> FileState raise @qcow.QcowError {
  let state = checked_open(
    node_open, node_stat, node_close, node_realpath, path, "r",
  )
  let error = state_error(state)
  if !error.is_empty() {
    raise @qcow.Io(error)
  }
  state
}

///|
/// Exclusive create, never truncates an existing destination.
pub fn create_file(path : String) -> FileState raise @qcow.QcowError {
  let state = checked_open(
    node_open, node_stat, node_close, node_realpath, path, "wx",
  )
  let error = state_error(state)
  if !error.is_empty() {
    raise @qcow.Io(error)
  }
  state
}

///|
pub fn FileState::close(self : FileState) -> Unit raise @qcow.QcowError {
  let error = checked_close(self, node_close)
  if !error.is_empty() {
    raise @qcow.Io(error)
  }
}

///|
pub fn FileState::path(self : FileState) -> String {
  state_path(self)
}

///|
pub fn FileState::source(self : FileState) -> @qcow.Source {
  @qcow.Source::new(state_size(self), (offset, count) => {
    let result = checked_read(self, node_read, offset, count)
    let error = read_error(result)
    if !error.is_empty() {
      raise @qcow.Io(error)
    }
    read_bytes(result)
  })
}

///|
pub fn FileState::write_at(
  self : FileState,
  offset : UInt64,
  data : Bytes,
) -> Unit raise @qcow.QcowError {
  let error = checked_write(self, node_write, offset, data)
  if !error.is_empty() {
    raise @qcow.Io(error)
  }
}

///|
pub fn FileState::resize(
  self : FileState,
  size : UInt64,
) -> Unit raise @qcow.QcowError {
  let error = checked_truncate(self, node_truncate, size)
  if !error.is_empty() {
    raise @qcow.Io(error)
  }
}

///|
/// Bundle lifetimes of the image and all explicitly authorized backing files.
pub struct Disk {
  image : @qcow.Image
  files : Array[FileState]
}

///|
fn open_chain(
  path : String,
  files : Array[FileState],
  visited : Map[String, Bool],
  allow_backing : Bool,
  limits : @qcow.Limits,
) -> @qcow.Image raise @qcow.QcowError {
  if files.length() >= limits.max_chain {
    raise @qcow.LimitExceeded
  }
  let file = open_file(path)
  files.push(file)
  let canonical = file.path()
  if visited.contains(canonical) {
    raise @qcow.Invalid("backing chain cycle")
  }
  visited[canonical] = true
  let source = file.source()
  let filename = @qcow.backing_filename(source, limits~)
  match filename {
    None => @qcow.open_source(source, limits~)
    Some(name) => {
      if !allow_backing {
        raise @qcow.MissingBacking
      }
      let resolved = path_resolve(path_dirname(canonical), name)
      let format = @qcow.backing_format(source, limits~)
      let backing = match format {
        Some("raw") => {
          if files.length() >= limits.max_chain {
            raise @qcow.LimitExceeded
          }
          let base = open_file(resolved)
          files.push(base)
          if visited.contains(base.path()) {
            raise @qcow.Invalid("backing chain cycle")
          }
          @qcow.Raw(base.source())
        }
        Some("qcow2") =>
          @qcow.Qcow(
            open_chain(resolved, files, visited, allow_backing, limits),
          )
        _ =>
          raise @qcow.Unsupported(
            "automatic backing requires an explicit raw/qcow2 format extension",
          )
      }
      @qcow.open_source(source, backing~, limits~)
    }
  }
}

///|
/// Following paths embedded in an image requires explicit opt-in.
pub fn open_disk(
  path : String,
  allow_backing~ : Bool = false,
  limits~ : @qcow.Limits = @qcow.Limits::default(),
) -> Disk raise @qcow.QcowError {
  let files : Array[FileState] = []
  errdefer (for file in files {
    file.close() catch {
      _ => ()
    }
  })
  let image = open_chain(path, files, Map([]), allow_backing, limits)
  { image, files, }
}

///|
pub fn Disk::image(self : Disk) -> @qcow.Image {
  self.image
}

///|
/// Every descriptor is attempted even if an earlier close fails.
pub fn Disk::close(self : Disk) -> Unit raise @qcow.QcowError {
  let mut failed : @qcow.QcowError? = None
  for file in self.files {
    file.close() catch {
      error => failed = Some(error)
    }
  }
  match failed {
    Some(error) => raise error
    None => ()
  }
}
