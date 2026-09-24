import Foundation
import Darwin
import CKeybaseProcess

/// Owns only the foreground Go service it starts. Never controls a shared service
/// through `keybase ctl stop` and never launches the Electron app, KBFS or updater.
public final class ServiceController: @unchecked Sendable {
    private let executable: URL
    private let validator: (URL) throws -> Void
    private let registry: ChildProcessRegistry
    private let grace: TimeInterval
    private let lock = NSLock()
    private var child: OwnedChildProcess?

    public convenience init(executable: URL) {
        self.init(executable: executable, validator: KeybaseExecutable.validate,
                  registry: .shared, grace: 2)
    }

    /// Internal seam uses inert fixtures without weakening production validation.
    init(executable: URL, validator: @escaping (URL) throws -> Void,
         registry: ChildProcessRegistry = ChildProcessRegistry(), grace: TimeInterval = 0.1) {
        self.executable = executable
        self.validator = validator
        self.registry = registry
        self.grace = grace
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let child else { return false }
        if case .running = child.observe() { return true }
        child.stop()
        self.child = nil
        return false
    }

    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        if let child {
            if case .running = child.observe() { return }
            child.stop()
            self.child = nil
        }
        try validator(executable)
        let arguments = [executable.path, "--no-auto-fork", "--no-debug", "--app-start-mode", "minimalist", "service"]
        child = try registry.launch {
            var pid: pid_t = 0
            let result = withCStringArray(arguments) { argv in
                withCStringArray(ProcessRunner.environment.map { "\($0.key)=\($0.value)" }) { env in
                    executable.path.withCString { path in
                        NSHomeDirectory().withCString { directory in
                            kb_spawn_quiet(path, argv, env, directory, &pid)
                        }
                    }
                }
            }
            guard result == 0 else { throw ProcessRunnerError.launchFailed }
            return OwnedChildProcess(pid: pid)
        }
    }

    /// Give the owned service up to two seconds to exit, then kill its process
    /// group and reap the leader before returning. This is safe to call repeatedly.
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        child?.stop(signal: SIGTERM, grace: grace)
        child = nil
    }

    deinit { stop() }
}
