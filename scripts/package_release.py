#!/usr/bin/env python3
"""Build a bounded, deterministic addon-only Orca updater/Asset Library ZIP."""

from __future__ import annotations

import argparse
import configparser
import hashlib
import json
import re
import stat
import struct
import zipfile
from pathlib import Path

FORMAT = "orca-update-v1"
MAX_ARCHIVE = 32 * 1024 * 1024
MAX_TOTAL = 128 * 1024 * 1024
MAX_FILE = 8 * 1024 * 1024
MAX_FILES = 2048
MANIFEST = "update_manifest.json"
EXECUTABLES = {
    f"native/credential_helper_{platform}.{arch}{suffix}"
    for platform, suffix in [("linux", ""), ("macos", ""), ("windows", ".exe")]
    for arch in ("x86_64", "arm64")
}
REQUIRED_HELPERS = {
    "native/credential_helper_linux.x86_64",
    "native/credential_helper_windows.x86_64.exe",
    "native/credential_helper_macos.arm64",
    "native/credential_helper_macos.x86_64",
}
RESERVED = {"CON", "PRN", "AUX", "NUL"} | {
    f"{prefix}{number}" for prefix in ("COM", "LPT") for number in range(1, 10)
}


def stable_version(value: str) -> bool:
    return bool(re.fullmatch(r"(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})", value))


def safe_path(path: str) -> bool:
    return (
        0 < len(path) <= 240
        and bool(re.fullmatch(r"[A-Za-z0-9_\-. /]+", path))
        and all(
            part and not part.startswith(".") and not part.endswith((".", " "))
            and part.split(".", 1)[0].upper() not in RESERVED
            for part in path.split("/")
        )
    )


def validate_platform_helpers(files: dict[str, bytes]) -> None:
    """Catch missing/misnamed CI artifacts; native execution tests remain required."""
    missing = REQUIRED_HELPERS - files.keys()
    if missing:
        raise ValueError("Missing required platform helpers: " + ", ".join(sorted(missing)))
    for name in REQUIRED_HELPERS:
        data = files[name]
        valid = False
        if "linux" in name:
            valid = len(data) >= 64 and data[:6] == b"\x7fELF\x02\x01" and struct.unpack_from("<H", data, 18)[0] == 62 and struct.unpack_from("<H", data, 16)[0] in (2, 3)
        elif "windows" in name:
            if len(data) >= 64 and data[:2] == b"MZ":
                offset = struct.unpack_from("<I", data, 60)[0]
                valid = 64 <= offset <= len(data) - 24 and data[offset:offset + 4] == b"PE\0\0" and struct.unpack_from("<H", data, offset + 4)[0] == 0x8664
        else:
            cpu = 0x100000C if name.endswith("arm64") else 0x1000007
            valid = len(data) >= 32 and data[:4] == b"\xcf\xfa\xed\xfe" and struct.unpack_from("<I", data, 4)[0] == cpu and struct.unpack_from("<I", data, 12)[0] == 2
        if not valid:
            raise ValueError("Helper has the wrong native format/architecture: " + name)


def build(addon: Path, output: Path, version: str | None = None, min_godot: str = "4.7.2", *, require_platform_helpers: bool = False, write_manifest: bool = False) -> dict:
    if addon.is_symlink() or any(parent.is_symlink() for parent in addon.parents):
        raise ValueError("Addon paths must not traverse symlinks")
    if output.resolve().is_relative_to(addon.resolve()):
        raise ValueError("Release output must be outside the source addon")
    config = configparser.ConfigParser(interpolation=None)
    config.read(addon / "plugin.cfg", encoding="utf-8")
    actual = config["plugin"]["version"].strip('"')
    version = actual if version is None else version
    if version != actual or not stable_version(version) or not stable_version(min_godot):
        raise ValueError("Stable release version must match plugin.cfg")
    if config["plugin"]["name"].strip('"') != "Orca" or config["plugin"]["script"].strip('"') != "orca.gd":
        raise ValueError("Unexpected plugin identity")
    files, seen, total = [], set(), 0
    for source in sorted(addon.rglob("*")):
        if source.is_symlink():
            raise ValueError("Release symlinks are forbidden")
        relative = source.relative_to(addon).as_posix()
        if source.is_dir():
            if not safe_path(relative):
                raise ValueError(f"Unsupported release directory: {relative}")
            continue
        if not source.is_file():
            raise ValueError("Only regular release files are supported")
        if source.suffix == ".import" or relative == MANIFEST:
            continue
        if not safe_path(relative) or relative.lower() in seen:
            raise ValueError(f"Unsupported/duplicate release path: {relative}")
        if relative.startswith("native/credential_helper_") and relative not in EXECUTABLES:
            raise ValueError("Unknown credential helper filename: " + relative)
        size = source.stat().st_size
        total += size
        if size > MAX_FILE or total > MAX_TOTAL or len(files) >= MAX_FILES:
            raise ValueError("Release exceeds its bounded file/count/size contract")
        with source.open("rb") as stream:
            data = stream.read(MAX_FILE + 1)
        if len(data) != size:
            raise ValueError("A release source changed while packaging")
        files.append((relative, data))
        seen.add(relative.lower())
    if not {"plugin.cfg", "orca.gd"}.issubset(seen):
        raise ValueError("Required addon files are missing")
    if require_platform_helpers:
        validate_platform_helpers(dict(files))
    manifest = {
        "format": FORMAT, "version": version, "min_godot": min_godot,
        "files": [
            {"path": name, "size": len(data), "sha256": hashlib.sha256(data).hexdigest(), "executable": name in EXECUTABLES}
            for name, data in files
        ],
    }
    payload = json.dumps(manifest, separators=(",", ":"), ensure_ascii=True).encode()
    if len(payload) > 512 * 1024:
        raise ValueError("Release manifest exceeds its limit")
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        raise ValueError("Refusing to overwrite an existing release archive")
    with zipfile.ZipFile(output, "x", compression=zipfile.ZIP_DEFLATED, allowZip64=False) as archive:
        for name, data in files + [(MANIFEST, payload)]:
            info = zipfile.ZipInfo("addons/orca/" + name, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3
            info.external_attr = (stat.S_IFREG | (0o755 if name in EXECUTABLES else 0o644)) << 16
            archive.writestr(info, data)
    if output.stat().st_size > MAX_ARCHIVE:
        output.unlink()
        raise ValueError("Compressed release exceeds the archive limit")
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_suffix(output.suffix + ".sha256").write_text(f"{digest}  {output.name}\n", encoding="ascii")
    if write_manifest:
        # Explicit release preparation for commit-based Asset Library installs.
        (addon / MANIFEST).write_bytes(payload)
    return {"version": version, "size": output.stat().st_size, "sha256": digest, "files": len(files)}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--addon", type=Path, default=Path("addons/orca"))
    parser.add_argument("--version", help="Must match plugin.cfg; omit to use its version")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--require-platform-helpers", action="store_true", help="Require Linux/Windows x86_64 and macOS arm64/x86_64 native binaries")
    parser.add_argument("--write-manifest", action="store_true", help="Also write the generated manifest into the source addon for an Asset Library release commit")
    args = parser.parse_args()
    result = build(args.addon, args.output, args.version, require_platform_helpers=args.require_platform_helpers, write_manifest=args.write_manifest)
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
