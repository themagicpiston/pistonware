#!/usr/bin/env python3
"""Fetch the current Luau tools and validate the repository's Lua sources."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import zipfile


ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / ".cache" / "luau"
RELEASE_API = "https://api.github.com/repos/luau-lang/luau/releases/latest"
SMOKE_TEMPLATE = ROOT / "tests" / "roblox_smoke.lua"
SMOKE_SOURCES = (
    "main.lua",
    "NewMainScript.lua",
    "games/12011959048.lua",
    "games/6872265039.lua",
    "games/6872274481.lua",
    "libraries/drawing.lua",
    "libraries/entity.lua",
    "libraries/hash.lua",
    "libraries/prediction.lua",
    "libraries/vm.lua",
)
REQUIRED_BINARIES = ("luau", "luau-compile")
WARNING_DIAGNOSTIC = re.compile(r"(?:\(W\d+\)|\bwarning\b)", re.IGNORECASE)


def binary_name(stem: str) -> str:
    return stem + ".exe" if os.name == "nt" else stem


def request(url: str) -> urllib.request.Request:
    return urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "pistonware-luau-tests",
        },
    )


def latest_release() -> tuple[str, dict[str, object]]:
    with urllib.request.urlopen(request(RELEASE_API), timeout=30) as response:
        release = json.load(response)

    tag = release.get("tag_name")
    if not isinstance(tag, str) or not tag:
        raise RuntimeError("GitHub returned no Luau release tag")

    asset_name = {
        "darwin": "luau-macos.zip",
        "linux": "luau-ubuntu.zip",
        "win32": "luau-windows.zip",
    }.get(sys.platform)
    if asset_name is None:
        raise RuntimeError(f"unsupported host platform: {sys.platform}")

    assets = release.get("assets")
    if not isinstance(assets, list):
        raise RuntimeError("GitHub returned no Luau release assets")
    asset = next(
        (item for item in assets if isinstance(item, dict) and item.get("name") == asset_name),
        None,
    )
    if not isinstance(asset, dict):
        raise RuntimeError(f"Luau release {tag} has no {asset_name} asset")
    if not isinstance(asset.get("browser_download_url"), str):
        raise RuntimeError(f"Luau release {tag} has no download URL for {asset_name}")
    if not isinstance(asset.get("digest"), str) or not asset["digest"].startswith("sha256:"):
        raise RuntimeError(f"Luau release {tag} has no SHA-256 digest for {asset_name}")
    return tag, asset


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def download(url: str, destination: Path) -> None:
    partial = destination.with_suffix(destination.suffix + ".part")
    try:
        with urllib.request.urlopen(request(url), timeout=60) as response, partial.open("wb") as handle:
            while block := response.read(1024 * 1024):
                handle.write(block)
        os.replace(partial, destination)
    finally:
        partial.unlink(missing_ok=True)


def executable(path: Path) -> bool:
    return path.is_file() and (os.name == "nt" or os.access(path, os.X_OK))


def install_archive(tag: str, asset: dict[str, object]) -> Path:
    asset_name = str(asset["name"])
    digest = str(asset["digest"]).removeprefix("sha256:")
    url = str(asset["browser_download_url"])
    release_key = f"{tag}-{asset_name.removesuffix('.zip')}"
    release_dir = CACHE / release_key
    archive = CACHE / f"{release_key}.zip"
    metadata = release_dir / "metadata.json"

    ready = False
    if metadata.is_file() and all(executable(release_dir / binary_name(name)) for name in REQUIRED_BINARIES):
        try:
            saved = json.loads(metadata.read_text(encoding="utf-8"))
            ready = saved.get("digest") == digest and saved.get("asset") == asset_name
        except (OSError, ValueError):
            ready = False
    if ready:
        return release_dir

    CACHE.mkdir(parents=True, exist_ok=True)
    if not archive.is_file() or sha256(archive) != digest:
        print(f"Downloading Luau {tag} ({asset_name})...")
        download(url, archive)
    if sha256(archive) != digest:
        archive.unlink(missing_ok=True)
        raise RuntimeError(f"SHA-256 mismatch for {asset_name}")

    with tempfile.TemporaryDirectory(prefix="extract-", dir=CACHE) as temporary:
        staging = Path(temporary)
        with zipfile.ZipFile(archive) as bundle:
            members = {Path(member.filename).name: member for member in bundle.infolist()}
            for name in REQUIRED_BINARIES:
                filename = binary_name(name)
                member = members.get(filename)
                if member is None or member.is_dir():
                    raise RuntimeError(f"{asset_name} does not contain {filename}")
                (staging / filename).write_bytes(bundle.read(member))

        release_dir.mkdir(parents=True, exist_ok=True)
        for name in REQUIRED_BINARIES:
            filename = binary_name(name)
            binary = release_dir / filename
            os.replace(staging / filename, binary)
            if os.name != "nt":
                binary.chmod(binary.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        metadata.write_text(
            json.dumps(
                {
                    "asset": asset_name,
                    "digest": digest,
                    "size": asset.get("size"),
                    "tag": tag,
                    "url": url,
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
    return release_dir


def source_files() -> list[Path]:
    files = sorted(path for path in ROOT.rglob("*.lua") if ".cache" not in path.parts)
    extensionless = ROOT / "loadstring"
    if extensionless.is_file():
        files.append(extensionless)
    return files


def run_parser(compiler: Path, files: list[Path]) -> None:
    command = [str(compiler), "--only-parse", *(str(path.relative_to(ROOT)) for path in files)]
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    output = (result.stdout + result.stderr).strip()
    if result.returncode:
        raise RuntimeError(f"Luau parse check failed:\n{output}")
    warnings = [line for line in output.splitlines() if WARNING_DIAGNOSTIC.search(line)]
    if warnings:
        raise RuntimeError("Luau parse check emitted warnings:\n" + "\n".join(warnings))
    print(f"Parsed {len(files)} Lua sources with {compiler.parent.name}.")


def lua_quote(value: str) -> str:
    return json.dumps(value)


def lua_long_string(value: str) -> str:
    equals = ""
    while f"]{equals}]" in value:
        equals += "="
    return f"[{equals}[{value}]{equals}]"


def smoke_program() -> str:
    template = SMOKE_TEMPLATE.read_text(encoding="utf-8")
    marker = "--[[ PISTONWARE_SOURCES ]]"
    if template.count(marker) != 1:
        raise RuntimeError(f"{SMOKE_TEMPLATE} must contain one {marker} marker")

    assignments = []
    for relative in SMOKE_SOURCES:
        path = ROOT / relative
        if not path.is_file():
            raise RuntimeError(f"smoke source does not exist: {relative}")
        with path.open("r", encoding="utf-8", newline="") as handle:
            source = handle.read()
        assignments.append(f"sources[{lua_quote(relative)}] = {lua_long_string(source)}")
    return template.replace(marker, marker + "\n" + "\n".join(assignments), 1)


def run_smoke(runtime: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="pistonware-luau-smoke-") as temporary:
        script = Path(temporary) / "roblox_smoke.lua"
        script.write_text(smoke_program(), encoding="utf-8")
        result = subprocess.run([str(runtime), str(script)], cwd=ROOT, capture_output=True, text=True)
    output = (result.stdout + result.stderr).strip()
    if result.returncode:
        raise RuntimeError(f"Luau Roblox smoke test failed:\n{output}")
    warnings = [line for line in output.splitlines() if WARNING_DIAGNOSTIC.search(line)]
    if warnings:
        raise RuntimeError("Luau Roblox smoke test emitted warnings:\n" + "\n".join(warnings))
    print("Loaded guarded entrypoints and shared libraries with Roblox-shaped test data.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compile-only", action="store_true", help="skip the runtime smoke test")
    args = parser.parse_args()

    try:
        tag, asset = latest_release()
        tools = install_archive(tag, asset)
        files = source_files()
        run_parser(tools / binary_name("luau-compile"), files)
        if not args.compile_only:
            run_smoke(tools / binary_name("luau"))
        print(f"Luau {tag} checks passed.")
        return 0
    except (OSError, RuntimeError, urllib.error.URLError, zipfile.BadZipFile) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
