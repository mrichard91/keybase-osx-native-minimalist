import Foundation
import Security
import CryptoKit
import Darwin

public enum KeybaseExecutableError: LocalizedError {
    case notInstalled
    case signatureRejected
    case bundledBackendRejected

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "The Keybase backend is missing. Rebuild the app with its bundled backend, or install official Keybase for the compatibility build."
        case .signatureRejected:
            return "The installed Keybase command could not be verified as an unmodified official Keybase release. Reinstall Keybase from keybase.io."
        case .bundledBackendRejected:
            return "The bundled Keybase backend or its signed build record could not be verified. Rebuild or reinstall the complete Minimalist app."
        }
    }
}

public enum KeybaseExecutable {
    private static var bundleURL: URL { Bundle.main.bundleURL.standardizedFileURL }
    private static var bundledHelper: URL { bundleURL.appendingPathComponent("Contents/Helpers/keybase-minimalist") }

    /// Presence includes a dangling helper symlink or a manifest whose helper was
    /// deleted, so damaged bundled installations cannot silently downgrade.
    public static var usesBundledBackend: Bool {
        containsBundledBackend(bundleURL, required: Bundle.main.object(forInfoDictionaryKey: "KeybaseMinimalistBundledBackend") as? Bool == true)
    }

    public static func isBundled(_ executable: URL) -> Bool {
        executable.isFileURL && bundleURL.pathExtension.lowercased() == "app" &&
        executable.standardizedFileURL == bundledHelper
    }

    /// PATH, symlink launchers, and environment overrides are never trusted.
    public static func locate() throws -> URL {
        if usesBundledBackend {
            try validate(bundledHelper)
            return bundledHelper
        }
        let candidates = [
            URL(fileURLWithPath: "/Applications/Keybase.app/Contents/SharedSupport/bin/keybase"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications/Keybase.app/Contents/SharedSupport/bin/keybase")
        ]
        for candidate in candidates where entryExists(candidate) {
            try validate(candidate)
            return candidate
        }
        throw KeybaseExecutableError.notInstalled
    }

    /// Validate again immediately before each execution, including account flows.
    public static func validate(_ executable: URL) throws {
        if isBundled(executable) {
            guard let appExecutable = Bundle.main.executableURL else {
                throw KeybaseExecutableError.bundledBackendRejected
            }
            do {
                try validateBundled(executable, bundle: bundleURL, appExecutable: appExecutable,
                                    verifyApplication: verifyCurrentApplication,
                                    verifyHelper: { try checkSignature($0, nested: false) })
            } catch { throw KeybaseExecutableError.bundledBackendRejected }
            return
        }
        // A bundled application must never escape its backend policy by asking
        // the generic validator to accept the compatibility executable.
        guard !usesBundledBackend else { throw KeybaseExecutableError.bundledBackendRejected }
        let allowed = [
            "/Applications/Keybase.app/Contents/SharedSupport/bin/keybase",
            NSHomeDirectory() + "/Applications/Keybase.app/Contents/SharedSupport/bin/keybase"
        ]
        guard executable.isFileURL, allowed.contains(executable.standardizedFileURL.path),
              canonicalRegularExecutable(executable)
        else { throw KeybaseExecutableError.signatureRejected }
        let code = try staticCode(executable, failure: .signatureRejected)
        let expression = "anchor apple generic and identifier \"keybase\" and certificate leaf[subject.OU] = \"99229SGT5K\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              let requirement else { throw KeybaseExecutableError.signatureRejected }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw KeybaseExecutableError.signatureRejected
        }
    }

    /// Test seams replace only signature checks; path, manifest and content
    /// verification remain the production implementation. No runtime override is exposed.
    static func validateBundled(_ helper: URL, bundle: URL, appExecutable: URL,
                                verifyApplication: (URL, URL) throws -> ApplicationTrust,
                                verifyHelper: (URL) throws -> Void) throws {
        let expected = bundle.standardizedFileURL.appendingPathComponent("Contents/Helpers/keybase-minimalist")
        let manifestURL = bundle.standardizedFileURL.appendingPathComponent("Contents/Resources/backend.json")
        guard bundle.isFileURL, bundle.pathExtension.lowercased() == "app",
              helper.isFileURL, helper.standardizedFileURL == expected,
              canonicalRegularExecutable(helper),
              manifestURL.resolvingSymlinksInPath() == manifestURL,
              appExecutable.standardizedFileURL.deletingLastPathComponent() ==
                bundle.standardizedFileURL.appendingPathComponent("Contents/MacOS") else {
            throw KeybaseExecutableError.bundledBackendRejected
        }
        let applicationTrust = try verifyApplication(bundle, appExecutable)
        try verifyHelper(helper)
        let attributes = try FileManager.default.attributesOfItem(atPath: manifestURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= 4096 else {
            throw KeybaseExecutableError.bundledBackendRejected
        }
        let data = try Data(contentsOf: manifestURL, options: .uncached)
        try applicationTrust.verifyManifest(data)
        let manifest = try BackendManifest.parse(data)
        guard try sha256(helper) == manifest.binarySHA256 else {
            throw KeybaseExecutableError.bundledBackendRejected
        }
    }

    private static func verifyCurrentApplication(_ bundle: URL, _ executable: URL) throws -> ApplicationTrust {
        guard bundle.standardizedFileURL == bundleURL,
              executable.standardizedFileURL == Bundle.main.executableURL?.standardizedFileURL,
              canonicalRegularExecutable(executable) else { throw KeybaseExecutableError.bundledBackendRejected }
        try checkSignature(bundle, nested: true)
        var running: SecCode?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCheckValidity(running, [], nil) == errSecSuccess else {
            throw KeybaseExecutableError.bundledBackendRejected
        }
        // A valid newly re-signed directory must not replace the bundle around
        // an older running app. Bind the resource seal to this process's code.
        var runningInfo: CFDictionary?
        var runningStaticCode: SecStaticCode?
        let appCode = try staticCode(bundle, failure: .bundledBackendRejected)
        var appInfo: CFDictionary?
        guard SecCodeCopyStaticCode(running, [], &runningStaticCode) == errSecSuccess,
              let runningStaticCode,
              SecCodeCopySigningInformation(runningStaticCode, [], &runningInfo) == errSecSuccess,
              SecCodeCopySigningInformation(appCode, [], &appInfo) == errSecSuccess,
              let runningHash = (runningInfo as NSDictionary?)?[kSecCodeInfoUnique] as? Data,
              let appHash = (appInfo as NSDictionary?)?[kSecCodeInfoUnique] as? Data,
              runningHash == appHash else { throw KeybaseExecutableError.bundledBackendRejected }
        return ApplicationTrust { manifest in
            // Validate the exact bytes read, rather than relying on a resource
            // path checked earlier that could have changed between those reads.
            guard SecCodeValidateFileResource(appCode, "Resources/backend.json" as CFString,
                                              manifest as CFData, []) == errSecSuccess else {
                throw KeybaseExecutableError.bundledBackendRejected
            }
        }
    }

    private static func checkSignature(_ url: URL, nested: Bool) throws {
        let code = try staticCode(url, failure: .bundledBackendRejected)
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures |
                               (nested ? kSecCSCheckNestedCode : 0))
        guard SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else {
            throw KeybaseExecutableError.bundledBackendRejected
        }
    }

    private static func staticCode(_ url: URL, failure: KeybaseExecutableError) throws -> SecStaticCode {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code else { throw failure }
        return code
    }

    private static func entryExists(_ url: URL) -> Bool {
        var attributes = stat()
        return url.path.withCString { lstat($0, &attributes) == 0 }
    }

    static func containsBundledBackend(_ bundle: URL, required: Bool = false) -> Bool {
        bundle.pathExtension.lowercased() == "app" &&
        (required || entryExists(bundle.appendingPathComponent("Contents/Helpers/keybase-minimalist")) ||
         entryExists(bundle.appendingPathComponent("Contents/Resources/backend.json")))
    }

    private static func canonicalRegularExecutable(_ url: URL) -> Bool {
        guard url.resolvingSymlinksInPath() == url.standardizedFileURL,
              FileManager.default.isExecutableFile(atPath: url.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        return attributes[.type] as? FileAttributeType == .typeRegular
    }

    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256(), total = 0
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            total += data.count
            guard total <= 512 * 1024 * 1024 else { throw KeybaseExecutableError.bundledBackendRejected }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct ApplicationTrust {
    let verifyManifest: (Data) throws -> Void
}

struct BackendManifest: Decodable {
    let policy: Int
    let upstream: String
    let binarySHA256: String
    let patchSHA256: String
    let schemaVersion: Int?
    let officialGoVersion: String?
    let repository: String?
    let goOS: String?
    let goArch: String?

    static func parse(_ data: Data) throws -> BackendManifest {
        guard data.count <= 4096,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: Set(["policy", "upstream", "binarySHA256", "patchSHA256",
                                                "schemaVersion", "officialGoVersion", "repository", "goOS", "goArch"])),
              let manifest = try? JSONDecoder().decode(BackendManifest.self, from: data),
              manifest.policy == 1,
              manifest.schemaVersion == nil || manifest.schemaVersion == 1,
              manifest.repository == nil || ["https://github.com/keybase/client", "https://github.com/keybase/client.git"].contains(manifest.repository!),
              manifest.goOS == nil || manifest.goOS == "darwin",
              manifest.goArch == nil || ["arm64", "amd64"].contains(manifest.goArch!),
              manifest.officialGoVersion == nil ||
                (manifest.officialGoVersion!.hasPrefix("go") && manifest.officialGoVersion!.utf8.count <= 128 &&
                 manifest.officialGoVersion!.utf8.allSatisfy({ $0 >= 32 && $0 <= 126 })),
              isHex(manifest.upstream, length: 40),
              isHex(manifest.binarySHA256, length: 64),
              isHex(manifest.patchSHA256, length: 64) else {
            throw KeybaseExecutableError.bundledBackendRejected
        }
        return manifest
    }

    private static func isHex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
