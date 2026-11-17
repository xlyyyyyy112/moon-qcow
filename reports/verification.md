# 本地验证记录

验证日期：2026-11-16

## 结果

- `moon check --target all --deny-warn`：通过。
- `moon test --target wasm,wasm-gc,js --deny-warn`：三个目标各 49 项通过。
- `moon test --target wasm,wasm-gc,js --release --deny-warn`：三个目标各 49 项通过。
- `moon build --target js --release --deny-warn`：通过。MoonBit 对 TypeScript 声明文件输出有一条非致命提示。
- `python scripts/interop.py --report reports/interop-local.json`：通过。QEMU 8.2.2 验证 13 类真实镜像，其中包含 DEFLATE、Zstandard、backing 链、快照、扩展 L2、位图和大于 4 GiB 的偏移；另有 7 项预期失败检查。导出镜像与 QEMU 生成的原始数据逐字节一致。

## 未覆盖项

本机没有可用的 MSVC，因此无法在 Windows 上执行 MoonBit native 目标的构建与测试。WSL 中未安装 MoonBit CLI。此次修改没有触发 GitHub Actions；本记录仅表示上述本地检查结果，不代表远端 CI 已通过。
