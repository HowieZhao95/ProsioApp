#!/usr/bin/env python3
"""Read-only validation for a built macOS recording app bundle."""

from __future__ import annotations

import argparse
import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


class CheckError(Exception):
    pass


CLI_TIMEOUT_SECONDS = 30


def run(*args: str) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(
            args,
            text=True,
            capture_output=True,
            check=False,
            timeout=CLI_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired as exc:
        raise CheckError(f"{Path(args[0]).name} timed out after {CLI_TIMEOUT_SECONDS} seconds") from exc
    except OSError as exc:
        raise CheckError(f"could not run {args[0]}: {exc}") from exc
    if result.returncode:
        detail = (result.stderr or result.stdout).strip()
        raise CheckError(f"{Path(args[0]).name} failed: {detail or result.returncode}")
    return result


def _requirement(app: Path) -> str:
    # codesign prints the designated requirement to stderr.
    result = run("/usr/bin/codesign", "-dr", "-", str(app))
    text = result.stderr + "\n" + result.stdout
    match = re.search(r"designated\s*=>\s*(.+)", text)
    if not match:
        raise CheckError(f"could not read designated requirement for {app}")
    return match.group(1).strip()


def inspect_app(app_arg: str, same_identity_as: str | None = None) -> dict[str, Any]:
    app = Path(app_arg).expanduser().resolve()
    if not app.is_dir() or app.suffix != ".app":
        raise CheckError(f"app bundle does not exist or is not a .app directory: {app}")

    info_path = app / "Contents/Info.plist"
    try:
        with info_path.open("rb") as stream:
            info = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException) as exc:
        raise CheckError(f"could not read {info_path}: {exc}") from exc

    if not isinstance(info, dict):
        raise CheckError("Info.plist must contain a dictionary")

    bundle_id = info.get("CFBundleIdentifier")
    executable_name = info.get("CFBundleExecutable")
    if not isinstance(bundle_id, str) or not bundle_id.strip():
        raise CheckError("Info.plist CFBundleIdentifier must be a non-empty string")
    if not isinstance(executable_name, str) or not executable_name.strip():
        raise CheckError("Info.plist CFBundleExecutable must be a non-empty filename")
    if (
        executable_name in {".", ".."}
        or "/" in executable_name
        or "\\" in executable_name
        or Path(executable_name).is_absolute()
    ):
        raise CheckError("Info.plist CFBundleExecutable must be a single filename")

    macos_dir = app / "Contents/MacOS"
    executable = macos_dir / executable_name
    if not executable.is_file():
        raise CheckError(f"bundle executable is missing: {executable}")
    resolved_macos_dir = macos_dir.resolve()
    executable = executable.resolve()
    if not executable.is_relative_to(resolved_macos_dir):
        raise CheckError("bundle executable symlink resolves outside Contents/MacOS")

    for field in ("CFBundleShortVersionString", "CFBundleVersion"):
        value = info.get(field)
        if value is not None and not isinstance(value, str):
            raise CheckError(f"Info.plist {field} must be a string")

    architectures = run("/usr/bin/lipo", "-archs", str(executable)).stdout.split()
    if not architectures:
        raise CheckError(f"no Mach-O architectures found in {executable}")
    uuid_text = run("/usr/bin/dwarfdump", "--uuid", str(executable)).stdout
    uuid_by_arch = {
        arch: uuid
        for uuid, arch in re.findall(r"UUID:\s*([0-9A-Fa-f-]+)\s+\(([^)]+)\)", uuid_text)
    }

    arch_results = []
    for arch in architectures:
        uuid = uuid_by_arch.get(arch)
        if not uuid:
            raise CheckError(f"could not find Mach-O UUID for architecture {arch}")
        dependencies = run("/usr/bin/otool", "-arch", arch, "-L", str(executable)).stdout
        # Require the actual AVKit framework install name. _AVKit_SwiftUI is a
        # separate private framework and must not satisfy this check.
        linked_avkit = any(
            re.search(r"(?:^|/)AVKit\.framework/(?:Versions/[^/]+/)?AVKit(?:\s|$)", line.strip())
            for line in dependencies.splitlines()[1:]
        )
        if not linked_avkit:
            raise CheckError(f"architecture {arch} does not directly link AVKit.framework")
        arch_results.append({"architecture": arch, "uuid": uuid, "links_avkit": True})

    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))
    requirement = _requirement(app)

    identity_matches = None
    if same_identity_as:
        reference_app = Path(same_identity_as).expanduser().resolve()
        reference_requirement = _requirement(reference_app)
        identity_matches = requirement == reference_requirement
        if not identity_matches:
            raise CheckError("designated requirement differs from the reference app")

    return {
        "ok": True,
        "bundle_id": bundle_id,
        "version": info.get("CFBundleShortVersionString"),
        "build": info.get("CFBundleVersion"),
        "executable": executable_name,
        "architectures": arch_results,
        "codesign_verified": True,
        "identity_matches_reference": identity_matches,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", help="built .app bundle to inspect")
    parser.add_argument(
        "--same-identity-as",
        metavar="INSTALLED_APP",
        help="require the same designated requirement as this installed .app",
    )
    args = parser.parse_args()
    try:
        result = inspect_app(args.app, args.same_identity_as)
        print(json.dumps(result, separators=(",", ":")))
        return 0
    except CheckError as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, separators=(",", ":")))
        return 1


if __name__ == "__main__":
    sys.exit(main())
