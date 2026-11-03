# 工具链记录

- 本地 MoonBit：`moonc v0.10.18+6c83a7f62`。
- 工作流固定安装 `0.10.18+6c83a7f62`，不依赖浮动 latest。
- 命令行：JavaScript 后端，Node.js 22+；本地使用 Node.js 24.18.0。
- 对照工具：QEMU 8.2.2（Ubuntu 24.04 qemu-utils）。
- 测试脚本：Python 3.12，标准库，不需要 pip 包。

本项目不会替换 Windows 全局 MoonBit 安装。开发时可以给单个终端设置
`MOON_HOME` 与 `PATH`，使用独立工具链。

```sh
moon info --target all
moon fmt
moon check --target all --deny-warn
moon test --target all --deny-warn
moon test --target all --release --deny-warn
moon run examples/basic
moon build --target js --release --deny-warn
python scripts/interop.py --report reports/interop-local.json
```

Windows 原生 C 后端构建需要 MSVC 开发环境；缺少 MSVC 时仍可执行 wasm、
wasm-gc、js 的构建与测试。CI 的 Windows 任务配置了 MSVC 环境初始化。
