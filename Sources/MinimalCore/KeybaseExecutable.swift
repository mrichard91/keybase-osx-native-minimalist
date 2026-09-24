import Foundation
import Security

public enum KeybaseExecutableError: LocalizedError {
    case notInstalled
    case signatureRejected

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Install the official Keybase app in /Applications, then connect again."
        case .signatureRejected:
            return "The installed Keybase command could not be verified as an unmodified official Keybase release. Reinstall Keybase from keybase.io."
        }
    }
}

public enum KeybaseExecutable {
    /// PATH, symlink launchers, and environment overrides are never trusted.
    public static func locate() throws -> URL {
        let candidates = [
            URL(fileURLWithPath: "/Applications/Keybase.app/Contents/SharedSupport/bin/keybase"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications/Keybase.app/Contents/SharedSupport/bin/keybase")
        ]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            try validate(candidate)
            return candidate
        }
        throw KeybaseExecutableError.notInstalled
    }

    /// Validate again immediately before each execution, including account flows.
    public static func validate(_ executable: URL) throws {
        let allowed = [
            "/Applications/Keybase.app/Contents/SharedSupport/bin/keybase",
            NSHomeDirectory() + "/Applications/Keybase.app/Contents/SharedSupport/bin/keybase"
        ]
        guard executable.isFileURL, allowed.contains(executable.standardizedFileURL.path),
              executable.resolvingSymlinksInPath().path == executable.standardizedFileURL.path,
              FileManager.default.isExecutableFile(atPath: executable.path)
        else { throw KeybaseExecutableError.signatureRejected }

        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess,
              let code else { throw KeybaseExecutableError.signatureRejected }
        // Pin the executable identifier and Keybase's Developer ID team, with an
        // Apple-rooted Developer ID Application certificate requirement.
        let expression = "anchor apple generic and identifier \"keybase\" and certificate leaf[subject.OU] = \"99229SGT5K\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              let requirement else { throw KeybaseExecutableError.signatureRejected }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw KeybaseExecutableError.signatureRejected
        }
    }
}
