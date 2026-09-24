#!/usr/bin/env python3
"""Bounded build regression checks; never starts Keybase's account or service flow."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import time


# These are direct-link regressions, not a claim about transitive dependencies,
# Go's retained standard-library parsers, or every package in a dependency module.
FORBIDDEN_FRAMEWORKS = frozenset({
    "AVFoundation", "AVFAudio", "AppKit", "CoreMedia", "ImageIO", "WebKit", "QuickLook",
})
FORBIDDEN_GO_IMAGE_PACKAGES = frozenset({
    "image/png", "image/gif", "golang.org/x/image/tiff", "github.com/nf/cr2",
    "github.com/rwcarlsen/goexif", "camlistore.org/pkg/images", "perkeep.org/pkg/images",
})
SCOPE = (
    "Checks fixed early-exit build information, direct Mach-O media/UI linkage, "
    "embedded Go module metadata, and named removed image-package symbols in the actual binary. "
    "JPEG is explicitly reported when retained. This is a bounded regression check, not an "
    "inventory of every parser, linked Go package, or transitive system-framework dependency."
)


class SurfaceError(Exception):
    pass


def bounded_run(arguments: list[str], *, environment: dict[str, str], label: str,
                timeout: float, output_limit: int, cwd: Path | None = None) -> bytes:
    """Drain both pipes concurrently and enforce limits while data is arriving."""
    process = subprocess.Popen(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, env=environment, cwd=cwd, start_new_session=True)
    deadline = time.monotonic() + timeout
    outputs = [bytearray(), bytearray()]
    selector = selectors.DefaultSelector()
    try:
        for number, stream in enumerate((process.stdout, process.stderr)):
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ, number)
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise SurfaceError(f"{label} exceeded its {timeout:g}-second limit")
            for key, _ in selector.select(min(remaining, 0.1)):
                try:
                    chunk = os.read(key.fileobj.fileno(), 16384)
                except BlockingIOError:
                    continue
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                if len(outputs[0]) + len(outputs[1]) + len(chunk) > output_limit:
                    raise SurfaceError(f"{label} exceeded its output limit")
                outputs[key.data].extend(chunk)
        try:
            status = process.wait(timeout=max(0.001, deadline - time.monotonic()))
        except subprocess.TimeoutExpired as error:
            raise SurfaceError(f"{label} exceeded its {timeout:g}-second limit") from error
        if status:
            # Never echo a failed helper's potentially sensitive stderr transcript.
            raise SurfaceError(f"{label} failed with exit status {status}")
        return bytes(outputs[0])
    finally:
        selector.close()
        if process.returncode is None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                raise SurfaceError(f"{label} did not exit after forced cleanup")
        for stream in (process.stdout, process.stderr):
            stream.close()


def check_build_info(data: bytes, upstream: str) -> dict:
    try:
        info = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SurfaceError("Backend build information is not valid JSON") from error
    expected = dict(policy=1, upstream=upstream, storage_namespace="keybase-minimalist",
                    media=False, unfurls=False, payments=False, commands=False)
    if not isinstance(info, dict) or type(info.get("policy")) is not int or info != expected:
        raise SurfaceError("Backend build information does not match the pinned minimalist policy")
    # Python compares False == 0, so every policy boolean needs an exact type check.
    if any(type(info[name]) is not bool for name in ("media", "unfurls", "payments", "commands")):
        raise SurfaceError("Backend policy flags must be JSON booleans")
    return info


def check_direct_libraries(data: bytes) -> list[str]:
    try:
        text = data.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise SurfaceError("otool produced invalid text") from error
    libraries = []
    for line in text.splitlines():
        if not line.strip() or (not line[0].isspace() and line.endswith(":")):
            continue
        match = re.fullmatch(r"\s+(.+) \(compatibility version [^,]+, current version [^)]+\)", line)
        if not match:
            raise SurfaceError("otool output has an unexpected dependency format")
        libraries.append(match.group(1))
    if not libraries:
        raise SurfaceError("No Mach-O dynamic-library metadata was found")
    forbidden = set()
    for library in libraries:
        names = set(re.findall(r"(?:^|/)([^/]+)\.framework(?:/|$)", library))
        overlay = re.fullmatch(r"libswift(.+)\.dylib", Path(library).name)
        if overlay:
            names.add(overlay.group(1))
        forbidden.update(names & FORBIDDEN_FRAMEWORKS)
    if forbidden:
        raise SurfaceError("Forbidden direct framework links: " + ", ".join(sorted(forbidden)))
    return sorted(set(libraries))


def parse_go_metadata(data: bytes) -> dict:
    try:
        lines = data.decode("utf-8", errors="strict").splitlines()
    except UnicodeDecodeError as error:
        raise SurfaceError("Go build metadata is not valid text") from error
    if not lines or ": " not in lines[0]:
        raise SurfaceError("Go build metadata is missing its version header")
    version = lines[0].rsplit(": ", 1)[1]
    if not re.fullmatch(r"go[0-9]+\.[0-9]+(?:\.[0-9]+)?(?:[a-zA-Z0-9.-]*)", version):
        raise SurfaceError("Go build metadata has an unexpected toolchain version")
    result = dict(goVersion=version, modules=[], buildSettings={})
    previous_module = None
    for line in lines[1:]:
        fields = line.lstrip("\t").split("\t")
        if not fields or not fields[0]:
            continue
        kind = fields[0]
        if kind == "path" and len(fields) == 2:
            result["commandPath"] = fields[1]
        elif kind in ("mod", "dep", "=>") and 3 <= len(fields) <= 4:
            module = dict(path=fields[1], version=fields[2])
            if len(fields) == 4 and fields[3]:
                module["checksum"] = fields[3]
            if kind == "mod":
                result["mainModule"] = module
            elif kind == "dep":
                result["modules"].append(module)
            elif previous_module is not None:
                previous_module["replacement"] = module
            else:
                raise SurfaceError("Go module replacement has no preceding module")
            if kind != "=>":
                previous_module = module
        elif kind == "build" and len(fields) == 2 and "=" in fields[1]:
            key, value = fields[1].split("=", 1)
            result["buildSettings"][key] = value
        else:
            raise SurfaceError("Go build metadata has an unexpected record")
    if not result.get("commandPath") or "mainModule" not in result:
        raise SurfaceError("Go command/module provenance is missing")
    result["modules"].sort(key=lambda module: module["path"])
    return result


def check_go_image_symbols(data: bytes) -> dict:
    """Inspect native symbol names, including init/data/type symbols, not strings."""
    try:
        lines = data.decode("utf-8", errors="strict").splitlines()
    except UnicodeDecodeError as error:
        raise SurfaceError("Native symbol metadata is not valid text") from error
    # A boundary admits Go type/interface wrappers such as type:.eq.<package>,
    # but prevents a similarly named package inside an unrelated import path
    # from matching. A period or slash must terminate the exact package prefix.
    packages = sorted(FORBIDDEN_GO_IMAGE_PACKAGES | {"image/jpeg"})
    package_pattern = re.compile(r"(?<![A-Za-z0-9_/-])(" + "|".join(re.escape(p) for p in packages) + r")(?=[./])")
    found, required = set(), set()
    count = 0
    for line in lines:
        if not line.strip():
            continue
        # /usr/bin/nm -P emits: name type hexadecimal-value hexadecimal-size.
        # Go generic/type symbols may contain spaces, so split from the right.
        fields = line.rsplit(None, 3)
        if (len(fields) != 4 or not re.fullmatch(r"[A-Za-z?]", fields[1]) or
                not all(re.fullmatch(r"[0-9A-Fa-f]+", field) for field in fields[2:])):
            raise SurfaceError("Native symbol metadata has an unexpected format")
        symbol = fields[0].removeprefix("_")
        count += 1
        if symbol in ("main.main", "runtime.main") and fields[1].lower() == "t":
            required.add(symbol)
        found.update(package_pattern.findall(symbol))
    if required != {"main.main", "runtime.main"}:
        raise SurfaceError("Backend Go symbols are missing or stripped; image-package inspection cannot proceed")
    forbidden = found & FORBIDDEN_GO_IMAGE_PACKAGES
    if forbidden:
        raise SurfaceError("Forbidden Go image package symbols: " + ", ".join(sorted(forbidden)))
    return dict(symbolCount=count, forbiddenPackagePrefixes=sorted(FORBIDDEN_GO_IMAGE_PACKAGES),
                retainedImagePackages=sorted(found),
                scope="Named symbol regression check; retained image/jpeg remains part of the backend's parser surface.")


def sha256(path: Path) -> str:
    if path.stat().st_size > 512 * 1024 * 1024:
        raise SurfaceError("Backend exceeds the 512 MiB inspection limit")
    digest = hashlib.sha256()
    total = 0
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            total += len(chunk)
            if total > 512 * 1024 * 1024:
                raise SurfaceError("Backend changed beyond the inspection size limit")
            digest.update(chunk)
    return digest.hexdigest()


def write_report(path: Path, report: dict) -> None:
    if path.is_symlink():
        raise SurfaceError("Surface report must not replace a symbolic link")
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                         prefix=".surface-report-", delete=False) as stream:
            temporary = Path(stream.name)
            json.dump(report, stream, indent=2, sort_keys=True, ensure_ascii=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def inspect(binary: Path, upstream: str) -> dict:
    if not re.fullmatch(r"[0-9a-f]{40}", upstream):
        raise SurfaceError("Expected upstream must be a full lowercase commit SHA")
    if binary.is_symlink() or not binary.is_file() or not os.access(binary, os.X_OK):
        raise SurfaceError("Backend must be a regular executable, not a symbolic link")
    binary = binary.resolve(strict=True)
    go_tool = shutil.which("go")
    if not go_tool:
        raise SurfaceError("Install Go to inspect the embedded module metadata")
    with tempfile.TemporaryDirectory(prefix="keybase-surface-check-") as temporary:
        home = Path(temporary) / "home"
        home.mkdir(mode=0o700)
        # This environment belongs only to these child commands. The calling
        # shell's HOME, Go configuration, and build cache remain untouched.
        environment = dict(PATH="/usr/bin:/bin:/usr/sbin:/sbin", LANG="C", LC_ALL="C",
                           HOME=str(home), TMPDIR=temporary, XDG_CONFIG_HOME=str(home / "config"),
                           XDG_CACHE_HOME=str(home / "cache"), XDG_DATA_HOME=str(home / "data"),
                           XDG_RUNTIME_DIR=str(home / "runtime"), GOTOOLCHAIN="local", GOWORK="off",
                           GOFLAGS="", GOPROXY="off", GOSUMDB="off", GOTELEMETRY="off")
        info = check_build_info(bounded_run([str(binary), "--minimalist-build-info"],
            environment=environment, label="Backend build-info diagnostic", timeout=10, output_limit=8192), upstream)
        libraries = check_direct_libraries(bounded_run(["/usr/bin/otool", "-L", str(binary)],
            environment=environment, label="Mach-O linkage inspection", timeout=10, output_limit=128 * 1024))
        go_metadata = parse_go_metadata(bounded_run([go_tool, "version", "-m", str(binary)],
            environment=environment, label="Go build metadata inspection", timeout=15, output_limit=2 * 1024 * 1024))
        go_symbols = check_go_image_symbols(bounded_run(["/usr/bin/nm", "-P", str(binary)],
            environment=environment, label="Native Go image-symbol inspection", timeout=15, output_limit=16 * 1024 * 1024))
    return dict(schemaVersion=1, policy=1, upstream=upstream, binarySHA256=sha256(binary),
                buildInfo=info, directLibraries=libraries,
                forbiddenDirectFrameworks=sorted(FORBIDDEN_FRAMEWORKS), goBuild=go_metadata,
                goSymbolInspection=go_symbols, scope=SCOPE)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--upstream", required=True)
    parser.add_argument("--report", type=Path)
    arguments = parser.parse_args()
    try:
        report = inspect(arguments.binary, arguments.upstream)
        if arguments.report is not None:
            write_report(arguments.report, report)
        print(f"Backend surface check passed: policy 1; {len(report['directLibraries'])} direct libraries; "
              f"{len(report['goBuild']['modules'])} retained Go modules; "
              f"{report['goSymbolInspection']['symbolCount']} symbols checked; "
              f"retained image packages: {', '.join(report['goSymbolInspection']['retainedImagePackages']) or 'none detected'}.")
        return 0
    except (SurfaceError, OSError, ValueError) as error:
        print(f"Backend surface check failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
