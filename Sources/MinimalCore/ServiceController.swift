import Foundation

/// Starts only the official foreground Go service. This controller never launches
/// the Electron app, KBFS, updater, or a command shell, and stops only its own PID.
public final class ServiceController {
    private let executable: URL
    private var process: Process?
    public var isRunning: Bool { process?.isRunning == true }

    public init(executable: URL) { self.executable = executable }

    /// Call after an explicit user request to start the service. A service which
    /// is already running owns its normal Keybase lock; a second start exits.
    public func start() throws {
        guard !isRunning else { return }
        try KeybaseExecutable.validate(executable)
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--no-auto-fork", "--no-debug", "--app-start-mode", "minimalist", "service"]
        process.environment = ProcessRunner.environment
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
    }

    public func stop() {
        guard let process, process.isRunning else { self.process = nil; return }
        // Process refers to the exact child we launched; never run keybase ctl stop
        // because that could terminate a service started by another application.
        process.terminate()
        self.process = nil
    }

    deinit { stop() }
}
