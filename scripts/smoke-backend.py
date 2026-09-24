#!/usr/bin/env python3
"""Exercise only a fresh, logged-out backend against a closed loopback port."""

import argparse
import json
import os
from pathlib import Path
import selectors
import shutil
import signal
import stat
import subprocess
import tempfile
import time


def stop(process):
    if process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            process.wait(timeout=3)
            return
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=3)


def run_probe(arguments, environment, request=None, timeout=8):
    process = subprocess.Popen(arguments, stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               env=environment, start_new_session=True)
    output = {"stdout": bytearray(), "stderr": bytearray()}
    try:
        if request is not None:
            process.stdin.write(request)
        process.stdin.close()
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ, "stdout")
            selector.register(process.stderr, selectors.EVENT_READ, "stderr")
            deadline = time.monotonic() + timeout
            while selector.get_map():
                if time.monotonic() >= deadline:
                    raise RuntimeError("A smoke probe exceeded its time limit")
                for key, _ in selector.select(timeout=0.1):
                    chunk = os.read(key.fileobj.fileno(), 4096)
                    if not chunk:
                        selector.unregister(key.fileobj)
                    else:
                        output[key.data].extend(chunk)
                        if sum(map(len, output.values())) > 65536:
                            raise RuntimeError("A smoke probe exceeded its output limit")
            process.wait(timeout=max(0.1, deadline - time.monotonic()))
        return dict(status=process.returncode,
                    stdout=bytes(output["stdout"]).decode("utf-8", "backslashreplace"),
                    stderr=bytes(output["stderr"]).decode("utf-8", "backslashreplace"))
    finally:
        stop(process)
        process.stdout.close()
        process.stderr.close()


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def main():
    project = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path,
                        default=project / "build/backend/keybase-minimalist")
    parser.add_argument("--keep-fixture", action="store_true")
    args = parser.parse_args()
    require(os.uname().sysname == "Darwin", "This smoke test requires macOS")
    require(args.binary.is_file() and not args.binary.is_symlink(),
            "The backend must be a regular executable file")
    binary = str(args.binary.resolve())
    upstream = json.loads((project / "backend/upstream.json").read_text())["commit"]
    fixture = Path(tempfile.mkdtemp(prefix="kbm-smoke-", dir="/tmp"))
    profile = fixture / "profile"
    profile.mkdir(mode=0o700)
    environment = dict(PATH="/usr/bin:/bin:/usr/sbin:/sbin", LANG="C", LC_ALL="C",
                       TMPDIR=str(fixture), HOME=str(profile), KEYBASE_SECRET_STORE_FILE="1")
    # Do not inherit account, server, proxy, config or socket environment values.
    # The fixed --home covers all config/cache paths. Force a file secret store
    # inside this fixture instead of querying the shared macOS Keychain namespace.
    # HOME is scoped to these child processes; no parent environment is changed.
    arguments = [binary, "--home", str(profile),
                 "--socket-file", str(fixture / "rpc.sock"),
                 "--pid-file", str(fixture / "service.pid"),
                 "--log-file", str(fixture / "service.log"),
                 "--server", "http://127.0.0.1:1", "--push-disabled",
                 "--no-auto-fork", "--no-debug", "--app-start-mode", "minimalist"]
    # macOS prioritizes the namespaced sandbox-cache socket over --socket-file.
    socket = profile / "Library/Caches/Keybase-minimalist/keybased.sock"
    service = None
    passed = False
    results = []
    report = dict(passed=False, fixture=str(fixture), probes=results)

    def log_files():
        return [fixture / "console.log", fixture / "service.log",
                *list((profile / "Library/Logs").glob("*.log"))]

    def check_service():
        require(service.poll() is None, "The isolated service exited unexpectedly")
        require(sum(path.stat().st_size for path in log_files() if path.exists()) < 5_000_000,
                "The isolated service exceeded its log limit")

    def probe(name, command, request=None):
        check_service()
        encoded = (json.dumps(request) + "\n").encode() if request is not None else None
        result = run_probe(arguments + command, environment, encoded)
        results.append(dict(name=name, **result))
        check_service()
        return result

    def no_tcp_listener():
        result = run_probe(["/usr/sbin/lsof", "-nP", "-a", "-p", str(service.pid),
                            "-iTCP", "-sTCP:LISTEN", "-Fn"], environment)
        require(result["status"] == 1 and not result["stdout"] and not result["stderr"],
                "The isolated service has a TCP listener, or listener inspection failed")

    try:
        info_result = run_probe([binary, "--minimalist-build-info"], environment)
        require(info_result["status"] == 0, "Backend policy diagnostic failed")
        info = json.loads(info_result["stdout"])
        require(type(info.get("policy")) is int and info == dict(
            policy=1, upstream=upstream, storage_namespace="keybase-minimalist",
            media=False, unfurls=False, payments=False, commands=False),
            "Refusing to start a backend without the fixed minimalist policy")
        with (fixture / "console.log").open("wb") as console:
            service = subprocess.Popen(arguments + ["service"], stdin=subprocess.DEVNULL,
                                       stdout=console, stderr=subprocess.STDOUT,
                                       env=environment, start_new_session=True)
            report["servicePID"] = service.pid
            deadline = time.monotonic() + 12
            while not socket.exists():
                check_service()
                require(time.monotonic() < deadline, "The isolated RPC socket did not appear")
                time.sleep(0.1)
            require(stat.S_ISSOCK(socket.stat().st_mode), "Expected a Unix RPC socket")
            no_tcp_listener()
            version = probe("version", ["version"])
            require(version["status"] == 0 and "Service:" in version["stdout"],
                    "The isolated CLI could not reach its service")
            status = probe("logged-out-status", ["whoami", "--json"])
            require(status["status"] == 0 and json.loads(status["stdout"])["loggedIn"] is False,
                    "The fixture must remain logged out")
            for name, request, expected in [
                ("unfurl-settings", {"method": "getunfurlsettings"}, "Login required"),
                ("empty-account-inbox", {"method": "list"}, "Login required"),
                ("denied-attachment", {"method": "attach", "params": {"options": {}}},
                 "method disabled in minimalist build"),
            ]:
                result = probe(name, ["chat", "api"], request)
                require(result["status"] == 0 and
                        json.loads(result["stdout"]).get("error", {}).get("message") == expected,
                        "Unexpected response for " + name)
            # Give background initialization a short interval before a second check.
            time.sleep(1)
            check_service()
            no_tcp_listener()
            stop(service)
            require(service.returncode == 0, "The isolated service did not exit cleanly")
            for path in log_files():
                if path.exists():
                    with path.open("rb") as stream:
                        content = stream.read(5_000_001).decode("utf-8", "backslashreplace")
                    require(len(content) <= 5_000_000, "A backend log exceeded its size limit")
                    require(not any(marker in content for marker in
                                    ["panic:", "invalid memory address", "fatal error:"]),
                            "A backend runtime failure was logged")
            report.update(passed=True, tcpListeners=False, cleanupServiceExit=service.returncode)
            passed = True
    except Exception as error:
        report["error"] = str(error)
    finally:
        if service is not None:
            stop(service)
            report["cleanupServiceExit"] = service.returncode
        report["fixtureRetained"] = args.keep_fixture or not passed
        if report["fixtureRetained"]:
            (fixture / "results.json").write_text(json.dumps(report, indent=2) + "\n")
        else:
            shutil.rmtree(fixture)
        print(json.dumps(report, indent=2))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
