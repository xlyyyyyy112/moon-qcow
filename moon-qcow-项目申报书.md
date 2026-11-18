# MoonQCOW 项目申报书

**基本信息**
- 项目名称：MoonQCOW：MoonBit QCOW2 只读解析与增量备份库
- 参赛者：xlyyyyyy112
- 联系方式：19257724755
- GitHub：https://github.com/xlyyyyyy112/moon-qcow
- 项目方向：MoonBit 系统工具与虚拟化存储基础设施
- 是否为移植项目：否，依据公开 QCOW2 格式规范独立实现

**项目简介**
MoonQCOW 提供 MoonBit QCOW2 只读解析库和 Node.js 命令行工具，用于读取虚拟磁盘逻辑数据、查看映射、导出 RAW 镜像，并依据脏位图选择增量备份范围。项目不修改源镜像；备份链管理和完整恢复由上层应用负责。

**核心功能与验收产物**
- 解析 QCOW2 v2/v3、标准及扩展 L2、零簇、raw/qcow2 backing 链、内部快照和持久化脏位图。
- 支持 DEFLATE 与 zstd 压缩簇；提供逻辑读取、映射审计、RAW 导出、镜像比较和增量范围复制。
- 交付 MoonBit 库、Node.js CLI、中文 README、示例、核心测试和 GitHub Actions；使用 QEMU 生成镜像并逐字节对照。

**只读兼容目标与边界**
- 最终目标是对所选 QCOW2 v2/v3 规范内合法、离线且一致的镜像提供完整的只读逻辑磁盘访问与 RAW 导出，包含加密、外部数据、压缩、基底链及规范允许的组合。写入和修复另属维护操作。
- 已完成外部数据文件的 MoonBit 直接读取，覆盖 `data_file_raw=on/off`。独立 AES/LUKS 镜像目前由 QEMU 解密到临时 QCOW2，再由 MoonBit 读取和导出。原镜像的快照、映射、位图及加密与其他特性的组合仍待补齐。
- 真实镜像的生成、读取及导出步骤见[只读兼容范围](docs/只读兼容范围.md)。测试对照非对齐片段及完整 RAW，并检查外置文件缺失和 LUKS 错误密钥，见[本地报告](reports/interop-local.json)。

**参考与许可说明**
依据 [QEMU QCOW2 格式规范](https://www.qemu.org/docs/master/interop/qcow2.html) 实现，不复制其 GPL 代码。DEFLATE 和 zstd 分别使用 `moonbit-community/flate`、`gaato/zstd`（Apache-2.0）；本项目采用 Apache-2.0。
