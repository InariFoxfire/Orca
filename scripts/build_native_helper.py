#!/usr/bin/env python3
"""Build the fixed credential helper using the current platform's native SDK."""
from __future__ import annotations

import os
import platform
import shlex
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def helper_name() -> str:
    system = {"Linux": "linux", "Darwin": "macos", "Windows": "windows"}.get(platform.system())
    arch = {"x86_64": "x86_64", "amd64": "x86_64", "arm64": "arm64", "aarch64": "arm64"}.get(platform.machine().lower())
    if (system, arch) not in {("linux", "x86_64"), ("windows", "x86_64"), ("macos", "x86_64"), ("macos", "arm64")}:
        raise RuntimeError("This platform/architecture is outside the supported helper build matrix")
    return f"credential_helper_{system}.{arch}" + (".exe" if system == "windows" else "")


def build() -> Path:
    source = ROOT / "addons/orca/native/credential_helper.cpp"
    output = source.parent / helper_name()
    work = ROOT / ".ci/native-build"
    work.mkdir(parents=True, exist_ok=True)
    if platform.system() == "Windows":
        # Use the installed native MSVC SDK and a static CRT: no DLL bundle needed.
        vswhere = Path(os.environ["ProgramFiles(x86)"]) / "Microsoft Visual Studio/Installer/vswhere.exe"
        install = subprocess.check_output([str(vswhere), "-latest", "-products", "*", "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-property", "installationPath"], text=True).strip()
        vcvars = Path(install) / "VC/Auxiliary/Build/vcvars64.bat"
        if not install or not vcvars.is_file():
            raise RuntimeError("Visual Studio C++ tools were not found")
        # Pass the raw cmd command line: CRT list quoting does not match cmd's /s rules.
        setup = subprocess.check_output(f'cmd.exe /d /s /c "call "{vcvars}" >nul && set"', text=True)
        environment = {name.upper(): value for name, value in os.environ.items()}
        for line in setup.splitlines():
            name, separator, value = line.partition("=")
            if separator and name:
                environment[name.upper()] = value
        compiler = shutil.which("cl.exe", path=environment.get("PATH"))
        if not compiler:
            raise RuntimeError("MSVC compiler was not found in the native SDK environment")
        subprocess.run([compiler, "/nologo", "/std:c++17", "/EHsc", "/O2", "/W4", "/MT", "/Brepro", str(source), f"/Fe:{output}", "/link", "/Brepro", "Advapi32.lib"], cwd=work, env=environment, check=True)
    elif platform.system() == "Darwin":
        arch = "arm64" if output.name.endswith("arm64") else "x86_64"
        subprocess.run(["clang++", "-std=c++17", "-O2", "-Wall", "-Wextra", "-arch", arch, "-mmacosx-version-min=11.0", str(source), "-framework", "Security", "-framework", "CoreFoundation", "-o", str(output)], cwd=work, check=True)
        # Ad-hoc signing enables native execution, but is not Developer ID/notarization.
        subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(output)], check=True)
        subprocess.run(["codesign", "--verify", "--strict", str(output)], check=True)
    else:
        flags = shlex.split(subprocess.check_output(["pkg-config", "--cflags", "--libs", "libsecret-1"], text=True))
        subprocess.run(["g++", "-std=c++17", "-O2", "-Wall", "-Wextra", "-pthread", str(source), "-o", str(output), *flags], cwd=work, check=True)
    output.chmod(0o755)
    print(f"Built {output.name}")
    return output


if __name__ == "__main__":
    build()
