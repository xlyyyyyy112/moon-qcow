///|
extern "js" fn exit_code(code : Int32) -> Unit =
  #| code => { process.exitCode = code; }

///|
extern "js" fn stderr(message : String) -> Unit =
  #| message => { console.error(message); }

///|
fn usage() -> String {
  "MoonQCOW — QCOW2 只读镜像工具\n" +
  "用法: moon run --target js cmd/main -- <命令> <镜像> [参数]\n" +
  "  info                          文件头信息\n" +
  "  chain                         已附加的 backing 链\n" +
  "  map [--resolved]              逻辑到物理映射\n" +
  "  stats                         活动镜像分配统计\n" +
  "  snapshots                     列出内部快照\n" +
  "  metadata                      元数据物理区域\n" +
  "  refcounts                     物理簇引用计数\n" +
  "  check-refcounts               受支持范围的精确引用检查\n" +
  "  bitmaps                       持久化脏位图目录\n" +
  "  dirty <位图名>                位图选出的增量备份区间\n" +
  "  audit [--verify-data]         活动映射与元数据检查\n" +
  "  read <偏移> <长度> <新文件>   导出逻辑区间\n" +
  "  export-raw <新文件> [--sparse] 导出完整 RAW 镜像\n" +
  "  compare <RAW文件>             逐字节对照\n" +
  "  hexdump <偏移> <长度>         十六进制查看（最多64KiB）\n" +
  "  refs <物理偏移> <长度>        查询活动镜像反向引用\n" +
  "通用选项: --allow-backing --snapshot <ID> --chunk-size <字节数>\n" +
  "支持十进制/0x十六进制，以及 KiB/MiB/GiB/TiB 后缀。\n" +
  "只处理稳定的离线镜像。输出文件必须不存在。\n" +
  "退出码: 0成功，1对照不同或审计有问题，2参数/格式/I/O错误。"
}

///|
struct Options {
  command : String
  path : String
  positional : Array[String]
  allow_backing : Bool
  snapshot : String?
  chunk_size : Int32
  sparse : Bool
  resolved : Bool
  verify_data : Bool
}

///|
fn parse_args(args : Array[String]) -> Options raise @qcow.QcowError {
  if args.length() < 3 {
    raise @qcow.Invalid("expected command and image path; use --help")
  }
  let positional : Array[String] = []
  let seen : Map[String, Bool] = Map([])
  let mut allow_backing = false
  let mut snapshot = None
  let mut chunk_size = 1048576
  let mut sparse = false
  let mut resolved = false
  let mut verify_data = false
  let mut index = 3
  let mut literal = false
  while index < args.length() {
    let arg = args[index]
    if literal || !arg.has_prefix("--") {
      positional.push(arg)
      index = index + 1
      continue
    }
    if arg == "--" {
      literal = true
      index = index + 1
      continue
    }
    if seen.contains(arg) {
      raise @qcow.Invalid("duplicate option: " + arg)
    }
    seen[arg] = true
    match arg {
      "--allow-backing" => allow_backing = true
      "--sparse" => sparse = true
      "--resolved" => resolved = true
      "--verify-data" => verify_data = true
      "--snapshot" | "--chunk-size" => {
        index = index + 1
        if index >= args.length() {
          raise @qcow.Invalid("missing option value: " + arg)
        }
        if arg == "--snapshot" {
          snapshot = Some(args[index])
        } else {
          let size = @qcow.parse_size(args[index])
          if size == 0UL || size > 16777216UL {
            raise @qcow.Invalid("chunk size outside 1..16MiB")
          }
          chunk_size = size.to_int()
        }
      }
      _ => raise @qcow.Invalid("unknown option: " + arg)
    }
    index = index + 1
  }
  if sparse && args[1] != "export-raw" {
    raise @qcow.Invalid("--sparse is only valid for export-raw")
  }
  if resolved && args[1] != "map" {
    raise @qcow.Invalid("--resolved is only valid for map")
  }
  if verify_data && args[1] != "audit" {
    raise @qcow.Invalid("--verify-data is only valid for audit")
  }
  {
    command: args[1],
    path: args[2],
    positional,
    allow_backing,
    snapshot,
    chunk_size,
    sparse,
    resolved,
    verify_data,
  }
}

///|
fn expect(options : Options, count : Int32) -> Unit raise @qcow.QcowError {
  if options.positional.length() != count {
    raise @qcow.Invalid("wrong argument count for " + options.command)
  }
}

///|
fn print_jsons(values : Array[Json]) -> Unit {
  println(Json::array(values).stringify())
}

///|
fn export_range(
  image : @qcow.Image,
  path : String,
  offset : UInt64,
  length : UInt64,
  chunk_size : Int32,
  sparse : Bool,
) -> Unit raise @qcow.QcowError {
  let cursor = image.copy_cursor(offset, length, chunk_size~, sparse~)
  let output = @nodeio.create_file(path)
  defer (output.close() catch { _ => () })
  output.resize(length)
  while !cursor.progress().complete {
    ignore(
      cursor.step(1, (position, data) => {
        output.write_at(position - offset, data)
      }),
    )
  }
  output.sync()
  output.close()
  println(cursor.progress().json().stringify())
}

///|
fn execute(
  options : Options,
  image : @qcow.Image,
) -> Int32 raise @qcow.QcowError {
  match options.command {
    "chain" => {
      expect(options, 0)
      print_jsons(image.chain().map(fn(item) { item.json() }))
    }
    "info" => {
      expect(options, 0)
      println(image.header().json().stringify())
    }
    "map" => {
      expect(options, 0)
      if options.resolved {
        print_jsons(
          image
          .resolved_map(0UL, image.virtual_size())
          .map(fn(item) { item.json() }),
        )
      } else {
        print_jsons(
          image
          .map_range(0UL, image.virtual_size())
          .map(fn(item) { item.json() }),
        )
      }
    }
    "stats" => {
      expect(options, 0)
      println(image.allocation_stats().json().stringify())
    }
    "snapshots" => {
      expect(options, 0)
      print_jsons(image.snapshots().map(fn(item) { item.json() }))
    }
    "metadata" => {
      expect(options, 0)
      print_jsons(image.metadata_regions().map(fn(item) { item.json() }))
    }
    "refcounts" => {
      expect(options, 0)
      print_jsons(image.refcount_runs().map(fn(item) { item.json() }))
    }
    "check-refcounts" => {
      expect(options, 0)
      let check = image.check_refcounts()
      println(check.json().stringify())
      if !check.ok() {
        return 1
      }
    }
    "bitmaps" => {
      expect(options, 0)
      print_jsons(image.bitmaps().map(fn(item) { item.json() }))
    }
    "dirty" => {
      expect(options, 1)
      println(image.bitmap_plan(options.positional[0]).json().stringify())
    }
    "audit" => {
      expect(options, 0)
      let report = image.audit(verify_data=options.verify_data)
      println(report.json().stringify())
      if !report.ok() {
        return 1
      }
    }
    "read" => {
      expect(options, 3)
      let offset = @qcow.parse_size(options.positional[0])
      let length = @qcow.parse_size(options.positional[1])
      export_range(
        image,
        options.positional[2],
        offset,
        length,
        options.chunk_size,
        false,
      )
    }
    "export-raw" => {
      expect(options, 1)
      export_range(
        image,
        options.positional[0],
        0UL,
        image.virtual_size(),
        options.chunk_size,
        options.sparse,
      )
    }
    "compare" => {
      expect(options, 1)
      let raw = @nodeio.open_file(options.positional[0])
      defer (raw.close() catch { _ => () })
      let report = image.compare_raw(
        raw.source(),
        chunk_size=options.chunk_size,
      )
      println(report.json().stringify())
      if !report.complete || report.different_bytes != 0UL {
        return 1
      }
    }
    "hexdump" => {
      expect(options, 2)
      let offset = @qcow.parse_size(options.positional[0])
      let length = @qcow.parse_size(options.positional[1])
      if length > 65536UL {
        raise @qcow.LimitExceeded
      }
      println(@qcow.hexdump(image.read_at(offset, length.to_int())[:], offset~))
    }
    "refs" => {
      expect(options, 2)
      let offset = @qcow.parse_size(options.positional[0])
      let length = @qcow.parse_size(options.positional[1])
      print_jsons(
        image.references_to(offset, length).map(fn(item) { item.json() }),
      )
    }
    _ => raise @qcow.Invalid("unknown command: " + options.command)
  }
  0
}

///|
fn run(args : Array[String]) -> Int32 raise @qcow.QcowError {
  if args.length() == 1 || (args.length() == 2 && args[1] == "--help") {
    println(usage())
    return 0
  }
  let options = parse_args(args)
  let disk = @nodeio.open_disk(
    options.path,
    allow_backing=options.allow_backing,
  )
  defer (disk.close() catch { _ => () })
  let image = match options.snapshot {
    Some(id) => disk.image().open_snapshot(id)
    None => disk.image()
  }
  execute(options, image)
}

///|
fn main {
  let raw = @env.args()
  let args : Array[String] = []
  for index = 1; index < raw.length(); index = index + 1 {
    args.push(raw[index])
  }
  let code = run(args) catch {
    error => {
      stderr(error.message())
      2
    }
  }
  exit_code(code)
}
