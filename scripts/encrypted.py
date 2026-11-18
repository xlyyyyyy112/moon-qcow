"""Read offline encrypted QCOW2 using an explicit secret file and QEMU."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

CLI = Path(__file__).resolve().parents[1] / "_build/js/release/build/cmd/main/main.js"


def qemu_path(path: Path) -> str:
    path = path.resolve()
    if os.name == "nt" and not shutil.which("qemu-img"):
        return "/mnt/" + path.drive[0].lower() + path.as_posix()[2:]
    return str(path)


def qemu_command(tool: str) -> list[str]:
    if shutil.which("qemu-img"):
        return [tool]
    if os.name == "nt" and shutil.which("wsl"):
        return ["wsl", "-d", "Ubuntu", "--", tool]
    raise RuntimeError("Install QEMU tools (qemu-img) first")


def secret_option(path: Path) -> str:
    return "secret,id=key,file=" + qemu_path(path).replace(",", ",,")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path)
    parser.add_argument("--key-file", type=Path, required=True)
    commands = parser.add_subparsers(dest="command", required=True)
    read = commands.add_parser("read")
    read.add_argument("offset")
    read.add_argument("length")
    read.add_argument("output", type=Path)
    export = commands.add_parser("export-raw")
    export.add_argument("output", type=Path)
    args = parser.parse_args()
    try:
        if args.output.exists() or args.output.is_symlink():
            raise ValueError("output already exists")
        with args.image.open("rb") as handle:
            header = handle.read(36)
        if (len(header) != 36 or header[:4] != b"QFI\xfb"
                or int.from_bytes(header[4:8], "big") not in (2, 3)):
            raise ValueError("expected a QCOW2 v2/v3 image")
        method = int.from_bytes(header[32:36], "big")
        if method not in (1, 2):
            raise ValueError("expected an AES or LUKS QCOW2 image")
        if int.from_bytes(header[8:16], "big"):
            raise ValueError("encrypted adapter requires a standalone image")
        if not CLI.is_file():
            raise ValueError("build CLI with moon build --target js --release")
        image = "json:" + json.dumps({
            "driver": "qcow2", "file": {
                "driver": "file", "filename": qemu_path(args.image)
            }, "encrypt": {"key-secret": "key"},
        }, ensure_ascii=True)
        with tempfile.TemporaryDirectory(prefix="moon-qcow-decrypted-") as tmp:
            plain = Path(tmp) / "plaintext.qcow2"
            subprocess.run(
                qemu_command("qemu-img") + ["convert", "--object",
                    secret_option(args.key_file), "-O", "qcow2", image,
                    qemu_path(plain)], check=True,
            )
            operands = [args.offset, args.length] if args.command == "read" else []
            subprocess.run(["node", CLI, args.command, plain, *operands,
                            args.output], check=True)
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        # Do not print subprocess argv, which can contain local paths.
        parser.exit(2, "encrypted QCOW2 operation failed: " +
                    ("subprocess failed" if isinstance(error, subprocess.CalledProcessError)
                     else str(error)) + "\n")


if __name__ == "__main__":
    main()
