import XCTest
import Foundation
@testable import MinimalCore

final class BackendTrustTests: XCTestCase {
    private final class BundleFixture {
        let directory: URL
        let bundle: URL
        let helper: URL
        let executable: URL
        let manifest: URL
        var sealedData = Data()

        init() throws {
            directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
            bundle = directory.appendingPathComponent("Fixture.app")
            helper = bundle.appendingPathComponent("Contents/Helpers/keybase-minimalist")
            executable = bundle.appendingPathComponent("Contents/MacOS/Fixture")
            manifest = bundle.appendingPathComponent("Contents/Resources/backend.json")
            for file in [helper, executable, manifest] {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            try Data("inert backend fixture".utf8).write(to: helper)
            try Data("inert app fixture".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            sealedData = try JSONSerialization.data(withJSONObject: [
                "policy": 1, "upstream": String(repeating: "a", count: 40),
                "binarySHA256": KeybaseExecutable.sha256(helper),
                "patchSHA256": String(repeating: "b", count: 64),
                "schemaVersion": 1, "repository": "https://github.com/keybase/client",
                "officialGoVersion": "go1.24.13", "goOS": "darwin", "goArch": "arm64"
            ])
            try sealedData.write(to: manifest)
        }

        func validate(helper override: URL? = nil) throws {
            try KeybaseExecutable.validateBundled(override ?? helper, bundle: bundle, appExecutable: executable,
                verifyApplication: { _, _ in
                    ApplicationTrust { data in
                        guard data == self.sealedData else { throw KeybaseExecutableError.bundledBackendRejected }
                    }
                }, verifyHelper: { _ in })
        }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    func testValidManifestAndHelperHash() throws {
        let fixture = try BundleFixture()
        XCTAssertNoThrow(try fixture.validate())
        XCTAssertTrue(KeybaseExecutable.containsBundledBackend(fixture.bundle))
    }

    func testHelperModificationFailsHashVerification() throws {
        let fixture = try BundleFixture()
        try Data("modified backend".utf8).write(to: fixture.helper)
        XCTAssertThrowsError(try fixture.validate())
    }

    func testManifestBytesMustMatchApplicationSeal() throws {
        let fixture = try BundleFixture()
        try Data(" ".utf8).write(to: fixture.manifest)
        XCTAssertThrowsError(try fixture.validate())
    }

    func testSymlinkedHelperAndManifestAreRejected() throws {
        let fixture = try BundleFixture()
        let moved = fixture.directory.appendingPathComponent("elsewhere")
        try FileManager.default.moveItem(at: fixture.helper, to: moved)
        try FileManager.default.createSymbolicLink(at: fixture.helper, withDestinationURL: moved)
        XCTAssertThrowsError(try fixture.validate())
        try FileManager.default.removeItem(at: fixture.helper)
        try FileManager.default.moveItem(at: moved, to: fixture.helper)
        try FileManager.default.moveItem(at: fixture.manifest, to: moved)
        try FileManager.default.createSymbolicLink(at: fixture.manifest, withDestinationURL: moved)
        XCTAssertThrowsError(try fixture.validate())
    }

    func testMissingHelperOrDanglingSymlinkStillSelectsBundledPolicy() throws {
        let fixture = try BundleFixture()
        try FileManager.default.removeItem(at: fixture.helper)
        XCTAssertTrue(KeybaseExecutable.containsBundledBackend(fixture.bundle))
        XCTAssertThrowsError(try fixture.validate())
        try FileManager.default.removeItem(at: fixture.manifest)
        XCTAssertTrue(KeybaseExecutable.containsBundledBackend(fixture.bundle, required: true))
        try FileManager.default.createSymbolicLink(atPath: fixture.helper.path, withDestinationPath: "/nonexistent-minimalist-fixture")
        XCTAssertTrue(KeybaseExecutable.containsBundledBackend(fixture.bundle))
        XCTAssertThrowsError(try fixture.validate())
    }

    func testAlternateHelperPathCannotBeSubstituted() throws {
        let fixture = try BundleFixture()
        XCTAssertThrowsError(try fixture.validate(helper: fixture.executable))
    }

    func testApplicationOrHelperSignatureFailureIsFatal() throws {
        let fixture = try BundleFixture()
        XCTAssertThrowsError(try KeybaseExecutable.validateBundled(fixture.helper, bundle: fixture.bundle,
            appExecutable: fixture.executable,
            verifyApplication: { _, _ in throw KeybaseExecutableError.bundledBackendRejected },
            verifyHelper: { _ in }))
        XCTAssertThrowsError(try KeybaseExecutable.validateBundled(fixture.helper, bundle: fixture.bundle,
            appExecutable: fixture.executable,
            verifyApplication: { _, _ in ApplicationTrust { _ in } },
            verifyHelper: { _ in throw KeybaseExecutableError.bundledBackendRejected }))
    }

    func testMalformedOrUnsupportedManifestFailsClosed() throws {
        let fixture = try BundleFixture()
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture.sealedData) as? [String: Any])
        let invalid: [(String, Any)] = [
            ("policy", 2), ("policy", true), ("upstream", ""), ("upstream", String(repeating: "g", count: 40)),
            ("binarySHA256", ""), ("binarySHA256", String(repeating: "A", count: 64)),
            ("patchSHA256", "short"), ("goOS", "linux"), ("schemaVersion", 2), ("unknownOverride", "anything")
        ]
        for (key, value) in invalid {
            var object = original; object[key] = value
            XCTAssertThrowsError(try BackendManifest.parse(JSONSerialization.data(withJSONObject: object)), key)
        }
        for data in [Data(), Data("[]".utf8), Data("{}".utf8), Data(repeating: 32, count: 4097)] {
            XCTAssertThrowsError(try BackendManifest.parse(data))
        }
    }
}
