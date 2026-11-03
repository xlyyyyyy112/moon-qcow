# MoonQCOW

用 MoonBit 读取 QCOW2 虚拟磁盘，查询数据映射，并分块导出 RAW 镜像。

这个库适合离线镜像转换、备份数据读取，以及文件系统工具的底层数据接入。QCOW2 的簇映射、backing 链、快照、引用计数和脏位图处理由 MoonBit 完成；文件命令行使用 Node.js 的同步随机 I/O。读取已有镜像时不会调用 QEMU，QEMU 只在独立对照测试中使用。

源码仓库：[xlyyyyyy112/moon-qcow](https://github.com/xlyyyyyy112/moon-qcow)。模块名为 `xlyyyyyy112/moon-qcow`，尚未发布到 Mooncakes。

## 运行

验证使用 MoonBit `0.10.18+6c83a7f62`、Node.js 24。47 组测试已在 wasm、wasm-gc、JavaScript、Linux native 的 Debug/Release 模式通过。CI 配置使用相同 MoonBit 版本和 Node.js 22。Python 3.12 用于运行外部对照测试。

在项目目录执行：

```sh
moon check --target all --deny-warn
moon test --target wasm,wasm-gc,js --deny-warn
moon run examples/basic
moon build --target js --release --deny-warn
node _build/js/release/build/cmd/main/main.js --help
```

基础库不依赖文件系统，可以接入自定义 `Source`，面向 wasm、wasm-gc、JavaScript、native。`nodeio` 和命令行仅支持 JavaScript/Node.js。

## 使用镜像

```sh
moon run --target js cmd/main -- info disk.qcow2
moon run --target js cmd/main -- map disk.qcow2 --resolved
moon run --target js cmd/main -- audit disk.qcow2 --verify-data
moon run --target js cmd/main -- export-raw disk.qcow2 restored.raw --sparse
moon run --target js cmd/main -- compare disk.qcow2 reference.raw
moon run --target js cmd/main -- read disk.qcow2 65523 257 fragment.bin
moon run --target js cmd/main -- snapshots disk.qcow2
moon run --target js cmd/main -- export-raw disk.qcow2 snapshot.raw --snapshot 1
moon run --target js cmd/main -- bitmaps disk.qcow2
moon run --target js cmd/main -- dirty disk.qcow2 changed
```

带 backing 文件的镜像需要增加 `--allow-backing`。这会按镜像中保存的路径打开其他本地文件，只应对信任的离线镜像开启。相对路径按包含它的镜像所在目录解析，循环链和过深链会报错；自动解析要求镜像明确声明 backing 格式为 raw 或 qcow2。

输出文件必须不存在，避免覆盖镜像或已有数据。稀疏导出只对新建、预设长度的零文件跳过零块；导出失败可能留下不完整文件，命令会返回非零退出码。不会修改 QCOW2 源文件。

命令默认输出 JSON。偏移和容量使用十进制字符串，避免 JavaScript JSON 数字损失 64 位精度。`read` 等参数支持十进制、`0x` 十六进制和 `KiB/MiB/GiB/TiB` 后缀。退出码为：0 成功，1 比较不同或检查发现问题，2 参数、格式或 I/O 错误。

## 库接口

在调用方 `moon.pkg` 中导入 `"xlyyyyyy112/moon-qcow" @qcow`。源码工作区中可以使用以下方式：

```moonbit nocheck
let image = @qcow.open(image_bytes)
let bytes = image.read_at(65523UL, 257)
let extents = image.map_range(0UL, image.virtual_size())
let cursor = image.copy_cursor(0UL, image.virtual_size())
```

大镜像应使用 `open_source(Source::new(size, read_at))`，而不是把整个文件读入内存。Source 回调必须返回精确长度，源内容必须在 Image 生命周期内保持稳定。核心库不会自动打开文件。磁盘字节读取、区间操作、导出进度、错误处理等接口可查 `pkg.generated.mbti`。

`CopyCursor` 和 `BackupCursor` 只在写入回调成功后推进进度；失败的块可以对幂等的 write-at 目标重试。稀疏复制需要调用方保证目标原本为零。进度不是持久化事务，也不提供跨进程断点身份校验。

## 已实现范围

- QCOW2 v2/v3、512 字节至 2 MiB 簇、64 位逻辑偏移。
- 标准 L1/L2、扩展 L2 子簇分配、显式零簇和 backing EOF 补零。
- raw/qcow2 backing 链；DEFLATE 压缩簇的有界解压。
- 内部快照目录及按 ID 读取；活动映射和解析 backing 后的映射。
- 元数据区域、反向引用、分配统计、1/2/4/8/16/32/64 位引用计数。
- 持久化脏位图目录、有效性检查、变更区间和增量复制选择。
- 分块 RAW 导出、逻辑字节比较、区间索引、扇区读取适配。
- 配置化读缓冲、缓存、链深度和扫描上限，失败时返回类型化错误。

不支持镜像写入、修复、AES/LUKS 加密、zstd 压缩、外部数据文件；遇到相应特性明确报错。dirty/corrupt 标志也会被拒绝，不尝试恢复活动中或损坏镜像。

`audit` 检查活动映射、元数据重叠以及被引用簇的非零引用计数，**不等同于 `qemu-img check`**。`check-refcounts` 能重建无快照、无持久化位图、无 VM 状态分配的引用关系；不支持的所有权范围会拒绝检查，不会假报完整通过。内部快照的 VM 内存状态不属于导出的虚拟磁盘内容。

Node 文件适配层要求物理文件大小和输出偏移不超过 `2^53-1`；核心地址模型为 UInt64。默认单次读取最多 16 MiB，缓存最多 8 MiB/4096 项，链深度最多 32，扫描数量也有上限。大型镜像可按需求配置 Limits，达到限制会报错，不会返回截断后冒充完整的结果。

## 测试

MoonBit 测试包含读取边界、压缩/子簇、位图异常、快照、引用计数、复制失败重试、区间集合性质测试和固定种子的损坏头变异。

真实镜像测试需安装 `qemu-img` 和 `qemu-io`，Linux 可安装 `qemu-utils`；Windows 脚本也支持调用 Ubuntu WSL 中的 QEMU：

```sh
moon build --target js --release --deny-warn
python scripts/interop.py --report reports/interop-local.json
python scripts/count_lines.py
```

脚本用 QEMU 生成测试镜像，以 RAW 文件或 QEMU 导出结果为独立对照，执行逐字节比较、非对齐读取、稀疏导出、backing 链、快照、脏位图及 4 GiB 以上偏移测试。测试数据在临时目录生成，不需要下载第三方磁盘镜像。具体记录见 `reports/interop-local.json`。CI 工作流已经配置，远端运行状态需在推送后确认。

## 来源与许可证

本项目采用 Apache-2.0，独立依据 [QEMU QCOW2 格式规范](https://www.qemu.org/docs/master/interop/qcow2.html) 和 [持久化脏位图说明](https://www.qemu.org/docs/master/interop/bitmaps.html) 实现。未复制 QEMU 的 GPL 实现代码或文档正文。

设计参考 [lima-vm/go-qcow2reader](https://github.com/lima-vm/go-qcow2reader) 的随机读取定位（Apache-2.0），不宣称与其全部功能等价。DEFLATE 解压复用 [moonbit-community/flate](https://github.com/moonbit-community/flate) 0.10.0（Apache-2.0），不将依赖代码计入本项目实现行数。QEMU 8.2.2 作为外部测试工具使用，不随库分发。
