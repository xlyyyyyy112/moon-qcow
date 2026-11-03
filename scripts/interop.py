"""Independent QEMU oracle tests. Requires Node, qemu-img/qemu-io or Ubuntu WSL.

Run after `moon build --target js --release`. No third-party Python dependencies.
All generated images are created inside a private temporary directory.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "_build/js/release/build/cmd/main/main.js"


def run(args, expected=0):
    result = subprocess.run([str(a) for a in args], cwd=ROOT, text=True,
                            encoding="utf-8", errors="replace", capture_output=True,
                            timeout=120)
    if result.returncode != expected:
        raise AssertionError(f"command {args[0:4]} returned {result.returncode}, "
                             f"expected {expected}\n{result.stdout}\n{result.stderr}")
    return result.stdout.strip()


def qemu(tool, *args):
    if shutil.which(tool):
        return run([tool, *args])
    if os.name != "nt" or not shutil.which("wsl"):
        raise RuntimeError(f"Install {tool} (qemu-utils) first")
    converted = []
    for arg in args:
        if isinstance(arg, Path):
            absolute = arg.resolve()
            converted.append("/mnt/" + absolute.drive[0].lower() +
                             absolute.as_posix()[2:])
        else:
            converted.append(arg)
    return run(["wsl", "-d", "Ubuntu", "--", tool, *converted])


def cli(command, image, *args, expected=0, decode=True):
    output = run(["node", CLI, command, image, *args], expected)
    return json.loads(output) if decode else output


def test_image(directory, name, image, raw, *, backing=False, snapshot=None):
    flags = ["--allow-backing"] if backing else []
    if snapshot is not None:
        flags += ["--snapshot", snapshot]
    report = cli("compare", image, raw, "--chunk-size", "65521", *flags)
    assert report["complete"] and report["different_bytes"] == "0"
    output = directory / (name + ".export.raw")
    progress = cli("export-raw", image, output, "--sparse", "--chunk-size", "64KiB", *flags)
    assert progress["complete"]
    expected = raw.read_bytes()
    actual = output.read_bytes()
    assert actual == expected, name + " exported data mismatch"
    info = cli("info", image, *flags)
    assert int(info["virtual_size"]) == len(expected)
    mappings = cli("map", image, "--resolved", *flags)
    assert sum(int(x["length"]) for x in mappings) == len(expected)
    assert all(int(x["offset"]) == sum(int(p["length"]) for p in mappings[:i])
               for i, x in enumerate(mappings))
    audit = cli("audit", image, "--verify-data", *flags)
    assert audit["ok"] and audit["complete"], audit
    for offset, count in [(1, 517), (4093, 8199), (65523, 257), (len(expected)-17, 17)]:
        target = directory / f"{name}.{offset}.slice"
        cli("read", image, str(offset), str(count), target, *flags)
        assert target.read_bytes() == expected[offset:offset+count]
    return {"name": name, "bytes": len(expected),
            "sha256": hashlib.sha256(actual).hexdigest(),
            "compare": True, "sparse_export": True,
            "unaligned_reads": 4, "resolved_map": True, "audit": True}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    if not CLI.exists():
        raise RuntimeError("Build CLI first: moon build --target js --release")
    started = time.monotonic()
    cases = []
    with tempfile.TemporaryDirectory(prefix="moon-qcow-") as temporary:
        directory = Path(temporary)
        raw = directory / "source.raw"
        pattern = bytearray((bytes(range(251)) * 35000)[:8*1024*1024])
        pattern[65536:131072] = bytes(65536)
        pattern[2*1024*1024-13:2*1024*1024+257] = b"x" * 270
        raw.write_bytes(pattern)
        for name, options, compressed in [
            ("v2-4k", "compat=0.10,cluster_size=4096", False),
            ("v3-512", "compat=1.1,cluster_size=512", False),
            ("v3-64k", "compat=1.1,cluster_size=65536", False),
            ("v3-2m", "compat=1.1,cluster_size=2097152", False),
            ("extended-l2", "compat=1.1,extended_l2=on,cluster_size=16384", False),
            ("deflate", "compat=1.1,cluster_size=65536", True),
        ]:
            image = directory / (name + ".qcow2")
            compress = ["-c"] if compressed else []
            qemu("qemu-img", "convert", "-f", "raw", "-O", "qcow2", "-o", options,
                 *compress, raw, image)
            cases.append(test_image(directory, name, image, raw))
            checked = cli("check-refcounts", image)
            assert checked["ok"] and checked["complete"], checked
        base = directory / "v3-64k.qcow2"
        overlay = directory / "overlay.qcow2"
        qemu("qemu-img", "create", "-f", "qcow2", "-F", "qcow2", "-b", base.name, overlay, "10M")
        qemu("qemu-io", "-f", "qcow2", "-c", "write -P 124 4096 8192", overlay)
        qemu("qemu-io", "-f", "qcow2", "-c", "write -z 131072 65536", overlay)
        expected = directory / "overlay.raw"
        qemu("qemu-img", "convert", "-O", "raw", overlay, expected)
        cases.append(test_image(directory, "backing-zero-growth", overlay, expected, backing=True))
        cli("info", overlay, expected=2, decode=False)
        second = directory / "second.qcow2"
        qemu("qemu-img", "create", "-f", "qcow2", "-F", "qcow2", "-b", overlay.name, second)
        qemu("qemu-io", "-f", "qcow2", "-c", "write -P 19 524288 16384", second)
        second_raw = directory / "second.raw"
        qemu("qemu-img", "convert", "-O", "raw", second, second_raw)
        cases.append(test_image(directory, "two-layer-backing", second, second_raw, backing=True))
        raw_overlay = directory / "raw-overlay.qcow2"
        qemu("qemu-img", "create", "-f", "qcow2", "-F", "raw", "-b", raw.name, raw_overlay)
        cases.append(test_image(directory, "raw-backing", raw_overlay, raw, backing=True))
        bitmap_image = directory / "bitmap.qcow2"
        shutil.copyfile(base, bitmap_image)
        qemu("qemu-img", "bitmap", "--add", "-g", "65536", bitmap_image, "changed")
        qemu("qemu-io", "-f", "qcow2", "-c", "write -P 7 196608 4096", bitmap_image)
        bitmaps = cli("bitmaps", bitmap_image)
        assert len(bitmaps) == 1 and bitmaps[0]["consistent"], bitmaps
        dirty = cli("dirty", bitmap_image, "changed")
        assert dirty["ranges"] == [{"offset":"196608", "length":"65536"}], dirty
        bitmap_audit = cli("audit", bitmap_image)
        assert bitmap_audit["ok"], bitmap_audit
        cases.append({"name":"persistent-dirty-bitmap", "dirty_ranges":True, "audit":True})
        snapshot_image = directory / "snapshot.qcow2"
        shutil.copyfile(base, snapshot_image)
        qemu("qemu-img", "snapshot", "-c", "before", snapshot_image)
        qemu("qemu-io", "-f", "qcow2", "-c", "write -P 99 0 65536", snapshot_image)
        snapshots = cli("snapshots", snapshot_image)
        assert len(snapshots) == 1 and snapshots[0]["name"] == "before"
        cases.append(test_image(directory, "internal-snapshot", snapshot_image, raw,
                                snapshot=snapshots[0]["id"]))
        # Deliberate output collision must fail, leaving the original bytes intact.
        cli("export-raw", base, raw, expected=2, decode=False)
        assert raw.read_bytes() == bytes(pattern)
        changed = directory / "changed.raw"
        damaged = bytearray(pattern)
        damaged[31:35] = b"FAIL"
        changed.write_bytes(damaged)
        mismatch = cli("compare", base, changed, expected=1)
        assert mismatch["different_bytes"] == "4"
        # Corrupt a real image rather than testing only synthetic headers.
        for name, start, replacement in [
            ("bad-magic", 0, b"NOPE"),
            ("encrypted", 32, (2).to_bytes(4, "big")),
            ("unknown-feature", 72, (1 << 63).to_bytes(8, "big")),
        ]:
            image = directory / (name + ".qcow2")
            data = bytearray(base.read_bytes())
            data[start:start+len(replacement)] = replacement
            image.write_bytes(data)
            cli("info", image, expected=2, decode=False)
        # Large logical offsets must not wrap through a 32-bit conversion.
        large = directory / "large.qcow2"
        qemu("qemu-img", "create", "-f", "qcow2", large, "5G")
        qemu("qemu-io", "-f", "qcow2", "-c", "write -P 73 4294967296 4096", large)
        slice_path = directory / "large.slice"
        cli("read", large, "4294967296", "4096", slice_path)
        assert slice_path.read_bytes() == bytes([73])*4096
        cases.append({"name": "offset-above-4GiB", "read": True})
    report = {"qemu": qemu("qemu-img", "--version").splitlines()[0],
              "cases": cases, "image_cases": len(cases),
              "negative_checks": 6, "elapsed_seconds": round(time.monotonic()-started, 3)}
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2)+"\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
