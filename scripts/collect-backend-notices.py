#!/usr/bin/env python3
"""Collect available notices for the exact backend and verified Go module cache."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import itertools
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile


_spec = importlib.util.spec_from_file_location("backend_surface", Path(__file__).with_name("check-backend-surface.py"))
surface = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(surface)
NoticeError = surface.SurfaceError
MAX_NOTICE_BYTES = 1024 * 1024
MAX_REPORT_BYTES = 32 * 1024 * 1024
NOTICE_NAME = re.compile(r"^(?:licen[cs]e|copying|copyright|notice|patents)(?:[._-].*)?$", re.IGNORECASE)


def parse_module_list(data: bytes) -> dict[str, dict]:
    try:
        text = data.decode("utf-8", errors="strict")
        decoder = json.JSONDecoder()
        result = {}
        offset = 0
        while offset < len(text):
            while offset < len(text) and text[offset].isspace():
                offset += 1
            if offset == len(text):
                break
            record, offset = decoder.raw_decode(text, offset)
            if not isinstance(record, dict) or not isinstance(record.get("Path"), str) or record["Path"] in result:
                raise NoticeError("Go module list contains an invalid or duplicate module")
            result[record["Path"]] = record
        return result
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise NoticeError("Go module list is not valid JSON") from error


def resolve_module(module: dict, available: dict[str, dict], cache: Path) -> tuple[Path | None, str | None]:
    record = available.get(module["path"])
    if record is None or record.get("Version") != module["version"]:
        return None, "Linked module/version is absent from the source module graph."
    expected = module.get("replacement", module)
    actual = record.get("Replace", record)
    if bool(module.get("replacement")) != bool(record.get("Replace")):
        return None, "Linked replacement differs from the source module graph."
    for expected_key, actual_key in (("path", "Path"), ("version", "Version"), ("checksum", "Sum")):
        if not expected.get(expected_key) or expected[expected_key] != actual.get(actual_key):
            return None, "Linked path, version, or checksum differs from verified module metadata."
    directory = actual.get("Dir")
    if not isinstance(directory, str):
        return None, "Verified module directory is unavailable."
    path = Path(directory)
    if path.is_symlink() or not path.is_dir():
        return None, "Module directory is missing or is a symbolic link."
    resolved = path.resolve(strict=True)
    if not resolved.is_relative_to(cache):
        return None, "Module directory is outside the verified module cache."
    return resolved, None


def notice_paths(directory: Path) -> tuple[list[Path], list[str]]:
    """Bounded root-level collection plus standard LICENSES/NOTICES directories."""
    paths, omissions = [], []
    entries = sorted(itertools.islice(directory.iterdir(), 10001), key=lambda path: path.name.casefold())
    if len(entries) > 10000:
        raise NoticeError("A dependency directory exceeds the notice scan entry limit")
    for path in entries:
        name_matches = NOTICE_NAME.fullmatch(path.name) is not None
        if path.is_symlink():
            if name_matches or path.name.casefold() in ("licenses", "notices"):
                omissions.append(f"Skipped symbolic link: {path.name}")
            continue
        if path.is_file() and name_matches:
            paths.append(path)
        elif path.is_dir() and path.name.casefold() in ("licenses", "notices"):
            children = sorted(itertools.islice(path.iterdir(), 1001), key=lambda child: child.name.casefold())
            if len(children) > 1000:
                omissions.append(f"Skipped directory beyond 1000-entry limit: {path.name}")
                continue
            for child in children:
                if child.is_file() and not child.is_symlink():
                    paths.append(child)
                else:
                    omissions.append(f"Skipped nested directory or symbolic link: {child.relative_to(directory)}")
    if len(paths) > 100:
        omissions.append("Notice file list limited to its first 100 entries.")
        paths = paths[:100]
    return paths, omissions


def runtime_notice(goroot: Path, go_tool: Path, name: str) -> tuple[Path, Path]:
    path = goroot / name
    # Homebrew moves LICENSE one level above its libexec GOROOT. Only accept
    # this layout when the selected Go executable is inside that same root.
    if not path.exists() and goroot.name == "libexec" and go_tool.resolve().is_relative_to(goroot.resolve()):
        candidate = goroot.parent / name
        if candidate.is_file() and not candidate.is_symlink():
            return candidate, goroot.parent
    return path, goroot


class Report:
    def __init__(self) -> None:
        self.parts = []
        self.byte_count = 0
        self.files = 0
        self.missing = []

    def append(self, text: str) -> None:
        self.byte_count += len(text.encode("utf-8"))
        if self.byte_count > MAX_REPORT_BYTES:
            raise NoticeError("Collected notices exceed the 32 MiB report limit")
        self.parts.append(text)

    def missing_notice(self, owner: str, reason: str) -> None:
        self.missing.append(f"{owner}: {reason}")
        self.append(f"MISSING OR INCOMPLETE: {reason}\n\n")

    def add_file(self, path: Path, *, owner: str, relative_to: Path) -> None:
        if path.is_symlink() or not path.is_file():
            self.missing_notice(owner, f"Required notice unavailable: {path.name}")
            return
        with path.open("rb") as stream:
            data = stream.read(MAX_NOTICE_BYTES + 1)
        if len(data) > MAX_NOTICE_BYTES or b"\0" in data:
            self.missing_notice(owner, f"Skipped binary or oversized notice: {path.relative_to(relative_to)}")
            return
        try:
            text = data.decode("utf-8", errors="strict")
            encoding = "UTF-8"
        except UnicodeDecodeError:
            text = data.decode("latin-1")
            encoding = "ISO-8859-1 fallback; original bytes identified by SHA-256"
        self.append(f"File: {path.relative_to(relative_to)}\nSHA-256: {hashlib.sha256(data).hexdigest()}\n"
                    f"Text encoding: {encoding}\n\n{text.rstrip()}\n\n")
        self.files += 1

    def add_directory(self, directory: Path, *, owner: str) -> None:
        paths, omissions = notice_paths(directory)
        if not paths:
            self.missing_notice(owner, "No root-level license/notice file or standard LICENSES/NOTICES file found.")
        for omission in omissions:
            self.missing_notice(owner, omission)
        for path in paths:
            self.add_file(path, owner=owner, relative_to=directory)


def write_notices(path: Path, report: Report) -> None:
    if path.is_symlink():
        raise NoticeError("Notices output must not replace a symbolic link")
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                         prefix=".backend-notices-", delete=False) as stream:
            temporary = Path(stream.name)
            stream.writelines(report.parts)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def collect(binary: Path, source: Path, cache: Path, upstream: str) -> tuple[Report, int]:
    if not re.fullmatch(r"[0-9a-f]{40}", upstream):
        raise NoticeError("Upstream must be a full lowercase commit SHA")
    if binary.is_symlink() or not binary.is_file():
        raise NoticeError("Backend must be a regular file, not a symbolic link")
    binary, source, cache = (path.resolve(strict=True) for path in (binary, source, cache))
    go_tool = shutil.which("go")
    if not go_tool:
        raise NoticeError("Go is required for verified module provenance")
    report = Report()
    with tempfile.TemporaryDirectory(prefix="keybase-notices-") as temporary:
        home = Path(temporary) / "home"
        home.mkdir(mode=0o700)
        # Child-only environment: no user's Keybase configuration or network
        # access is involved. These commands inspect source/module metadata.
        environment = dict(PATH="/usr/bin:/bin:/usr/sbin:/sbin", LANG="C", LC_ALL="C", HOME=str(home),
                           TMPDIR=temporary, GOENV="off", GOTOOLCHAIN="local", GOWORK="off", GOFLAGS="",
                           GOPROXY="off", GOSUMDB="off", GOTELEMETRY="off", GOMODCACHE=str(cache),
                           GOCACHE=str(Path(temporary) / "go-cache"), GIT_TERMINAL_PROMPT="0")
        def run(arguments: list[str], label: str, timeout: float = 30, limit: int = 8 * 1024 * 1024) -> bytes:
            return surface.bounded_run(arguments, environment=environment, cwd=source / "go",
                                       label=label, timeout=timeout, output_limit=limit)
        actual_commit = run(["/usr/bin/git", "-C", str(source), "rev-parse", "HEAD"], "Upstream revision check").decode().strip()
        if actual_commit != upstream:
            raise NoticeError("Source revision does not match the pinned upstream")
        run(["/usr/bin/git", "-C", str(source), "diff", "--quiet", "HEAD", "--", "LICENSE", "go/LICENSE"],
            "Official license integrity check")
        metadata = surface.parse_go_metadata(run([go_tool, "version", "-m", str(binary)], "Linked module inspection"))
        if metadata["mainModule"]["path"] != "github.com/keybase/client/go":
            raise NoticeError("Backend main module is not the official Keybase source module")
        run([go_tool, "mod", "verify"], "Go module cache checksum verification", timeout=120, limit=256 * 1024)
        # Query only modules actually retained by the binary. Asking for "all"
        # can fetch unused lazy graph nodes even after a successful Go build.
        module_paths = [module["path"] for module in metadata["modules"]]
        if len(module_paths) > 1000 or any(not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._~+/-]{0,1023}", path) for path in module_paths):
            raise NoticeError("Linked module paths exceed the inspection limits")
        available = parse_module_list(run([go_tool, "list", "-mod=readonly", "-m", "-json", *module_paths], "Go module graph inspection"))
        report.append("KEYBASE MINIMAL - BUNDLED BACKEND THIRD-PARTY NOTICES\n\n"
            f"Official source: https://github.com/keybase/client\nPinned upstream: {upstream}\n"
            f"Backend SHA-256: {surface.sha256(binary)}\nGo toolchain: {metadata['goVersion']}\n\n"
            "Scope: available root-level LICENSE, COPYING, COPYRIGHT, NOTICE and PATENTS files, plus\n"
            "files immediately within standard LICENSES/NOTICES directories, for modules named in\n"
            "the actual binary's Go build metadata. The module cache passed go mod verify and each\n"
            "collected module path/version/checksum is matched to that metadata. Replacement module\n"
            "notices apply where Go replaced an original module. This is not an exhaustive nested\n"
            "package inventory or legal determination. Missing or incomplete coverage is stated.\n"
            "The patched backend includes retained parsers/packages; notices are not a safety audit.\n\n"
            "================================================================================\n"
            "OFFICIAL KEYBASE SOURCE (local minimalist policy patch applied)\n\n")
        for relative in ("LICENSE", "go/LICENSE"):
            report.add_file(source / relative, owner="Official Keybase source", relative_to=source)
        goroot = Path(run([go_tool, "env", "GOROOT"], "Go runtime notice location", limit=8192).decode().strip())
        current_version = run([go_tool, "env", "GOVERSION"], "Go runtime version", limit=8192).decode().strip()
        report.append("================================================================================\nGO RUNTIME\n\n")
        if current_version != metadata["goVersion"]:
            report.missing_notice("Go runtime", "Current Go toolchain differs from the binary; its notices were not substituted.")
        else:
            for name in ("LICENSE", "PATENTS"):
                path, base = runtime_notice(goroot, Path(go_tool), name)
                report.add_file(path, owner="Go runtime", relative_to=base)
        for module in metadata["modules"]:
            owner = f"{module['path']} {module['version']}"
            report.append(f"================================================================================\nMODULE: {owner}\n")
            if "replacement" in module:
                effective = module["replacement"]
                report.append(f"Replaced by: {effective['path']} {effective['version']}\n")
            else:
                effective = module
            report.append(f"Go checksum: {effective.get('checksum', '(unavailable)')}\n\n")
            directory, reason = resolve_module(module, available, cache)
            if reason:
                report.missing_notice(owner, reason)
            else:
                report.add_directory(directory, owner=owner)
        report.append("================================================================================\nCOLLECTION SUMMARY\n\n"
                      f"Linked dependency modules: {len(metadata['modules'])}\nNotice files included: {report.files}\n"
                      f"Missing/incomplete entries: {len(report.missing)}\n")
        for missing in report.missing:
            report.append(f"- {missing}\n")
    return report, len(metadata["modules"])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--module-cache", type=Path, required=True)
    parser.add_argument("--upstream", required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    try:
        report, count = collect(arguments.binary, arguments.source, arguments.module_cache, arguments.upstream)
        write_notices(arguments.output, report)
        print(f"Backend notices collected: {count} linked modules; {report.files} notice files; "
              f"{len(report.missing)} explicitly listed missing/incomplete entries.")
        return 0
    except (NoticeError, OSError, ValueError) as error:
        print(f"Backend notice collection failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
