"""Inert fixtures for build-policy checks and notice provenance."""
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


surface = load("surface_tests", "check-backend-surface.py")
notices = load("notice_tests", "collect-backend-notices.py")
UPSTREAM = "a" * 40


class SurfaceTests(unittest.TestCase):
    def policy(self):
        return dict(policy=1, upstream=UPSTREAM, storage_namespace="keybase-minimalist",
                    media=False, unfurls=False, payments=False, commands=False)

    def test_exact_build_policy(self):
        self.assertEqual(surface.check_build_info(json.dumps(self.policy()).encode(), UPSTREAM), self.policy())

    def test_policy_rejects_wrong_types_or_extra_fields(self):
        cases = [dict(policy=True), dict(media=0), dict(upstream="b" * 40), dict(storage_namespace="keybase"), dict(extra=False)]
        for mutation in cases:
            with self.subTest(mutation=mutation), self.assertRaises(surface.SurfaceError):
                surface.check_build_info(json.dumps(self.policy() | mutation).encode(), UPSTREAM)

    def test_invalid_build_json(self):
        for data in (b"[]", b"null", b"garbage", b"\xff"):
            with self.subTest(data=data), self.assertRaises(surface.SurfaceError):
                surface.check_build_info(data, UPSTREAM)

    def library_output(self, path):
        return f"/tmp/helper:\n\t{path} (compatibility version 1.0.0, current version 1.0.0)\n".encode()

    def test_direct_core_library_is_allowed(self):
        path = "/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation"
        self.assertEqual(surface.check_direct_libraries(self.library_output(path)), [path])

    def test_forbidden_frameworks_and_swift_overlays(self):
        for name in surface.FORBIDDEN_FRAMEWORKS:
            for path in (f"/System/Library/Frameworks/{name}.framework/{name}", f"/usr/lib/swift/libswift{name}.dylib"):
                with self.subTest(path=path), self.assertRaises(surface.SurfaceError):
                    surface.check_direct_libraries(self.library_output(path))

    def test_malformed_link_metadata_rejected(self):
        for data in (b"/tmp/helper:\n", b"unexpected text", b"\t/lib.dylib\n", b"\xff"):
            with self.subTest(data=data), self.assertRaises(surface.SurfaceError):
                surface.check_direct_libraries(data)

    def test_module_replacement_metadata(self):
        data = (b"/tmp/helper: go1.27.1\n\tpath\tgithub.com/keybase/client/go/keybase\n"
                b"\tmod\tgithub.com/keybase/client/go\t(devel)\t\n"
                b"\tdep\texample.org/original\tv1.0.0\n"
                b"\t=>\texample.org/replacement\tv1.1.0\th1:abc=\n"
                b"\tbuild\tGOOS=darwin\n")
        parsed = surface.parse_go_metadata(data)
        self.assertEqual(parsed["modules"][0]["replacement"], dict(path="example.org/replacement", version="v1.1.0", checksum="h1:abc="))
        self.assertEqual(parsed["buildSettings"]["GOOS"], "darwin")

    def test_missing_go_provenance_rejected(self):
        for data in (b"", b"/tmp/helper: go1.27.1\n", b"/tmp/helper: unknown\n"):
            with self.subTest(data=data), self.assertRaises(surface.SurfaceError):
                surface.parse_go_metadata(data)

    def run_inert(self, code, **limits):
        return surface.bounded_run([sys.executable, "-c", code], environment={"PATH": "/usr/bin:/bin"},
                                   label="Inert fixture", **limits)

    def test_output_flood_stops_at_limit(self):
        before = time.monotonic()
        with self.assertRaisesRegex(surface.SurfaceError, "output limit"):
            self.run_inert("import os\nwhile True: os.write(1, b'x' * 4096)", timeout=3, output_limit=8192)
        self.assertLess(time.monotonic() - before, 3)

    def test_stderr_is_bounded_too(self):
        with self.assertRaisesRegex(surface.SurfaceError, "output limit"):
            self.run_inert("import os\nos.write(2, b'x' * 16384)", timeout=3, output_limit=8192)

    def test_timeout_for_silent_child(self):
        before = time.monotonic()
        with self.assertRaisesRegex(surface.SurfaceError, "second limit"):
            self.run_inert("import time\ntime.sleep(30)", timeout=0.1, output_limit=8192)
        self.assertLess(time.monotonic() - before, 3)

    def test_failed_child_does_not_echo_stderr(self):
        with self.assertRaises(surface.SurfaceError) as failure:
            self.run_inert("import sys\nsys.stderr.write('PRIVATE FIXTURE')\nsys.exit(7)", timeout=3, output_limit=8192)
        self.assertNotIn("PRIVATE FIXTURE", str(failure.exception))
        self.assertIn("7", str(failure.exception))


class NoticeTests(unittest.TestCase):
    def test_concatenated_go_module_json(self):
        data = b'{"Path":"example.org/a","Version":"v1"}\n {"Path":"example.org/b"}\n'
        self.assertEqual(set(notices.parse_module_list(data)), {"example.org/a", "example.org/b"})

    def test_duplicate_or_malformed_module_list_rejected(self):
        for data in (b'{}', b'[]', b'{"Path":"x"}{"Path":"x"}', b'{"Path":3}', b'{'):
            with self.subTest(data=data), self.assertRaises(notices.NoticeError):
                notices.parse_module_list(data)

    def test_notice_scan_excludes_symlink_and_nested_unrelated_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "LICENSE.md").write_text("license")
            (root / "COPYING").write_text("copying")
            (root / "README.md").write_text("readme")
            (root / "NOTICE").symlink_to(root / "README.md")
            (root / "LICENSES").mkdir()
            (root / "LICENSES" / "MIT.txt").write_text("mit")
            (root / "LICENSES" / "nested").mkdir()
            files, omissions = notices.notice_paths(root)
            self.assertEqual({str(path.relative_to(root)) for path in files}, {"LICENSE.md", "COPYING", "LICENSES/MIT.txt"})
            self.assertEqual(len(omissions), 2)

    def test_module_checksum_and_replacement_match(self):
        with tempfile.TemporaryDirectory() as temporary:
            cache = Path(temporary).resolve()
            module = dict(path="example.org/old", version="v1", replacement=dict(path="example.org/new", version="v2", checksum="h1:test="))
            record = dict(Path="example.org/old", Version="v1", Replace=dict(Path="example.org/new", Version="v2", Sum="h1:test=", Dir=str(cache)))
            self.assertEqual(notices.resolve_module(module, {module["path"]: record}, cache), (cache, None))
            record["Replace"]["Sum"] = "h1:changed="
            directory, missing = notices.resolve_module(module, {module["path"]: record}, cache)
            self.assertIsNone(directory)
            self.assertIn("checksum", missing)

    def test_module_outside_cache_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            cache = root / "cache"
            cache.mkdir()
            module = dict(path="example.org/a", version="v1", checksum="h1:test=")
            record = dict(Path="example.org/a", Version="v1", Sum="h1:test=", Dir=str(root))
            self.assertIn("outside", notices.resolve_module(module, {module["path"]: record}, cache)[1])

    def test_missing_and_binary_notices_are_explicit(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            report = notices.Report()
            report.add_directory(root, owner="fixture")
            (root / "LICENSE").write_bytes(b"binary\0")
            report.add_file(root / "LICENSE", owner="fixture", relative_to=root)
            self.assertEqual(len(report.missing), 2)
            self.assertEqual(report.files, 0)

    def test_atomic_output_refuses_symlink(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            actual = root / "actual"
            actual.write_text("original")
            link = root / "link"
            link.symlink_to(actual)
            report = notices.Report()
            report.append("new")
            with self.assertRaises(notices.NoticeError):
                notices.write_notices(link, report)
            self.assertEqual(actual.read_text(), "original")

    def test_packaged_go_notice_fallback_is_constrained(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            goroot = root / "libexec"
            (goroot / "bin").mkdir(parents=True)
            go = goroot / "bin" / "go"
            go.touch()
            (root / "LICENSE").write_text("go license")
            self.assertEqual(notices.runtime_notice(goroot, go, "LICENSE"), (root / "LICENSE", root))
            self.assertEqual(notices.runtime_notice(goroot, Path(sys.executable), "LICENSE"), (goroot / "LICENSE", goroot))


if __name__ == "__main__":
    unittest.main()
