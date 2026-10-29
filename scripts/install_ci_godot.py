#!/usr/bin/env python3
"""Install the pinned CI Godot editor and export its path to subsequent steps."""
from __future__ import annotations

import os
import platform
import stat
import urllib.request
import zipfile
from pathlib import Path

VERSION = "4.7.2"
ROOT = Path(__file__).resolve().parents[1]


def install() -> Path:
    suffix, executable = {
        "Linux": ("linux.x86_64", f"Godot_v{VERSION}-stable_linux.x86_64"),
        "Darwin": ("macos.universal", "Godot.app/Contents/MacOS/Godot"),
        "Windows": ("win64.exe", f"Godot_v{VERSION}-stable_win64_console.exe"),
    }[platform.system()]
    destination = ROOT / ".ci"
    destination.mkdir(exist_ok=True)
    archive = destination / "godot.zip"
    url = f"https://github.com/godotengine/godot/releases/download/{VERSION}-stable/Godot_v{VERSION}-stable_{suffix}.zip"
    urllib.request.urlretrieve(url, archive)
    with zipfile.ZipFile(archive) as reader:
        reader.extractall(destination)
        if platform.system() != "Windows":
            for entry in reader.infolist():
                mode = entry.external_attr >> 16
                if mode & stat.S_IXUSR and not entry.is_dir():
                    (destination / entry.filename).chmod(mode & 0o777)
    binary = destination / executable
    if not binary.is_file():
        raise RuntimeError("Pinned Godot archive did not contain the expected executable")
    binary.chmod(0o755)
    if os.environ.get("GITHUB_ENV"):
        with Path(os.environ["GITHUB_ENV"]).open("a", encoding="utf-8") as stream:
            stream.write(f"GODOT_BIN={binary}\n")
    print(f"Installed Godot {VERSION} for {platform.system()}")
    return binary


if __name__ == "__main__":
    install()
