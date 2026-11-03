# 本地验证记录

日期：2026-11-03。项目：MoonQCOW 0.1.0（模块 `xlyyyyyy112/moon-qcow`）。

## 验证结果

| 项目 | 结果 |
|---|---|
| `moon check --target all --deny-warn` | 通过 |
| wasm / wasm-gc / js Debug 测试 | 各 47/47 通过 |
| wasm / wasm-gc / js Release 测试 | 各 47/47 通过 |
| Linux native Debug 测试 | 47/47 通过 |
| Linux native Release 测试 | 47/47 通过 |
| `moon run --target wasm examples/basic` | 通过 |
| Linux native 示例 | 通过 |
| Node.js CLI `--help` / `info` | 通过 |
| `moon info --target all` / `moon fmt --check` | 通过 |
| QEMU 8.2.2 独立联调 | 12 类场景通过 |
| 本地 `moon package` | 通过；无构建目录、依赖缓存、临时镜像混入 |

Windows 主机使用独立的 MoonBit 0.10.18 工具链。native 测试在 Ubuntu WSL
中使用相同版本和 GCC 执行，没有使用旧版全局 Windows 工具链冒充验证。

## 可复现证据

- `interop-local.json`：QEMU 版本、逐场景结果和导出 SHA-256。
- `lines.json`：自有代码统计，测试、示例单独列出。
- `scripts/interop.py`：临时生成 QCOW2 / RAW，执行独立逐字节比较。
- `reader_wbtest.mbt`、`metadata_wbtest.mbt`、`cursor_wbtest.mbt`：核心回归。
- `tests/public/api_test.mbt`：消费方包的公开 API 检查。

联调包含 v2、v3（512B/64KiB/2MiB 簇）、扩展 L2、DEFLATE、两层 backing、
显式零覆盖、backing 容量之外补零、RAW backing、内部快照、持久化脏位图、
4GiB 以上偏移；还验证拒绝覆盖输出、缺少 backing、比较差异和不支持的头部。

回归中包含 100 轮独立布尔集合对照、1000 次随机逻辑读取和 2000 次损坏头变异。
复制失败重试和回调重入都有专门断言。

## 状态边界

源码已推送至 [GitHub](https://github.com/xlyyyyyy112/moon-qcow)，默认分支为 `main`。
模块 `xlyyyyyy112/moon-qcow@0.1.0` 已于 2026-11-03 发布到 Mooncakes，
可用 `moon view xlyyyyyy112/moon-qcow` 回查，用 `moon add xlyyyyyy112/moon-qcow@0.1.0` 安装。
[提交 `9d4b94f` 的 CI](https://github.com/xlyyyyyy112/moon-qcow/actions/runs/41658068703)
在 Windows、macOS、Ubuntu 全部通过，包括检查、构建、Debug/Release 测试与示例；
Linux 同时执行 QEMU 互操作测试，结果可从该次运行的 `qemu-interop` 产物下载。
发布使用全局 MoonBit 0.10.19，打包和解包校验通过；该版本对 `derive(...)`
有弃用提示。项目保留该写法以兼容 CI 固定的 MoonBit 0.10.18。
本记录不是赛事组委会验收结论。

不支持的格式特性、审计范围、资源上限见 README。`audit` 不等同完整的 QEMU
一致性修复；`check-refcounts` 的所有权重建范围也有明确限制。
