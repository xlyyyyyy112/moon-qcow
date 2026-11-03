# MoonQCOW development

This project implements read-only QCOW2 access in MoonBit.

- Keep core code independent of OS I/O. Node-specific code belongs in `nodeio`.
- File sources must remain stable for an image's lifetime. Never follow embedded
  backing paths in the core parser or silently replace missing backing data.
- Preserve exact UInt64 offsets and bounded reads/scans. A partial operation must
  not report complete success. Do not suppress errors to produce synthetic zeros.
- Write a regression test for parser, mapping, ownership, and progress changes.
- Use `///|` blocks and `moon fmt`. Update public interfaces with `moon info`.
- Before completion run `moon info`, `moon fmt`, strict check and applicable tests.
- Run `scripts/interop.py` when image-reading/export behavior changes. It uses
  QEMU as an independent oracle; do not replace it with self-generated roundtrips.
- Count production `.mbt` separately from test files, generated `.mbti`, external
  dependencies, scripts, blank lines, and comments. Never add code just for LOC.
- Keep unsupported features and audit boundaries explicit in Chinese README.
