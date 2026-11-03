# MoonQCOW 项目申报书

## 基本信息

- 项目名称：MoonQCOW：面向 QCOW2 虚拟磁盘的 MoonBit 只读解析与增量备份库
- 参赛者：xlyyyyyy112
- 联系方式：19257724755
- GitHub 仓库链接：https://github.com/xlyyyyyy112/moon-qcow
- 项目方向：MoonBit 系统工具与虚拟化存储基础设施
- 是否为移植项目：否；依据公开 QCOW2 格式规范独立实现
## 项目简介

QCOW2 是 QEMU/KVM 等虚拟化环境广泛使用的磁盘镜像格式。MoonBit 程序处理这类镜像时，往往需要调用外部工具或接入其他语言实现。MoonQCOW 提供一个以 MoonBit 实现的只读 QCOW2 解析库和 Node.js 命令行工具，使上层程序能够直接读取客户机逻辑字节、查看镜像映射，并基于脏位图选择增量备份范围。库提供变更范围选择与增量复制接口，备份链管理和完整恢复流程由上层应用实现。项目不修改原始镜像；对超出当前支持范围的加密、外部数据文件和损坏状态会明确拒绝。
## 核心功能与实现计划

- 解析 QCOW2 v2/v3 头部、L1/L2 表、扩展 L2 子簇、零簇和 backing 文件链，提供按偏移读取与逻辑映射查询；
- 支持 raw/qcow2 backing 链、DEFLATE 压缩簇、内部快照目录，以及按快照 ID 读取虚拟磁盘内容；
- 解析 1/2/4/8/16/32/64 位引用计数与持久化脏位图，提供元数据、映射、引用和位图的边界校验与审计报告；
- 提供范围集合、增量复制游标、RAW 导出、镜像比较、稀疏零块跳过和扇区读取适配器，供备份、迁移与诊断工具复用；
- 提供 `info`、`map`、`audit`、`read`、`export-raw`、`compare`、`snapshots`、`bitmaps` 与 `dirty` 等命令，Node.js 层仅负责受限文件 I/O；
- 使用 QEMU 生成独立测试镜像，并以逐字节读取、非对齐读取、backing 链、快照、脏位图和 4 GiB 以上偏移等场景进行对照验证。
## 预期验收产物

- 可通过 `moon add xlyyyyyy112/moon-qcow` 使用的 MoonBit 库，以及可复现的 Node.js 命令行示例；
- 覆盖核心读路径、异常边界和公共 API 的 MoonBit 测试，配套 Linux、macOS、Windows 三平台 CI；
- QEMU 对照测试脚本及结果报告，确保导出 RAW 内容和查询结果可复现；
- 发布到 Mooncakes，提供中文 README、最小运行示例和 Apache-2.0 许可证。
## 参考与开源说明

项目参考 QEMU 的 [QCOW2 互操作格式规范](https://www.qemu.org/docs/master/interop/qcow2.html) 与[持久化脏位图说明](https://www.qemu.org/docs/master/interop/bitmaps.html)，不复制 QEMU 的 GPL 实现代码。随机读取设计参考 [lima-vm/go-qcow2reader](https://github.com/lima-vm/go-qcow2reader)（Apache-2.0）；DEFLATE 解压依赖 `moonbit-community/flate`（Apache-2.0）。本项目采用 Apache-2.0 许可证。
