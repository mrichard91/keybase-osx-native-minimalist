import Foundation
import Darwin
import CKeybaseProcess

public enum AccountAction: Int32 {
    case login = 0
    case signup = 1
    case logout = 2
}

public final class AccountSession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "minimalist.keybase.account", qos: .userInitiated)
    private var child: OwnedChildProcess?
    private var fd: Int32 = -1
    private var timer: DispatchSourceTimer?
    private var pending = Data()
    private var outputCount = 0
    private let filter = TerminalTextFilter()
    private var lastEcho: Bool?
    private var stoppingAt: DispatchTime?
    private let deadline: DispatchTime
    private let cancellationGrace: TimeInterval
    private let onOutput: @MainActor (String) -> Void
    private let onEcho: @MainActor (Bool) -> Void
    private let onFinish: @MainActor (Int32?, String?) -> Void

    public convenience init(executable: URL, action: AccountAction,
                onOutput: @escaping @MainActor (String) -> Void,
                onEcho: @escaping @MainActor (Bool) -> Void,
                onFinish: @escaping @MainActor (Int32?, String?) -> Void) throws {
        try self.init(executable: executable, action: action,
                      validator: KeybaseExecutable.validate, registry: .shared,
                      cancellationGrace: 6, timeout: 1800,
                      onOutput: onOutput, onEcho: onEcho, onFinish: onFinish)
    }

    init(executable: URL, action: AccountAction, validator: (URL) throws -> Void,
         registry: ChildProcessRegistry, cancellationGrace: TimeInterval, timeout: TimeInterval,
         onOutput: @escaping @MainActor (String) -> Void,
         onEcho: @escaping @MainActor (Bool) -> Void,
         onFinish: @escaping @MainActor (Int32?, String?) -> Void) throws {
        self.onOutput = onOutput
        self.onEcho = onEcho
        self.onFinish = onFinish
        self.cancellationGrace = max(0, min(cancellationGrace, 10))
        self.deadline = .now() + max(0.05, min(timeout, 1800))
        try validator(executable)
        child = try registry.launch {
            var pid: pid_t = 0
            let result = withCStringArray(ProcessRunner.environment.map { "\($0.key)=\($0.value)" }) { env in
                executable.path.withCString { kb_spawn_account($0, action.rawValue, env, &pid, &fd) }
            }
            guard result == 0 else { throw ProcessRunnerError.launchFailed }
            return OwnedChildProcess(pid: pid)
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // The timer owns this session until finish() cancels it and breaks the
        // cycle. Closing a window therefore still waits for CLI cancellation.
        timer.setEventHandler { self.tick() }
        timer.schedule(deadline: .now(), repeating: .milliseconds(30))
        self.timer = timer
        timer.resume()
    }

    public func send(_ data: Data) {
        guard data.count <= 1001, data.last == 13,
              data.dropLast().allSatisfy({ $0 >= 32 && $0 <= 126 }) else { return }
        queue.async {
            guard self.child != nil, self.stoppingAt == nil else { return }
            guard self.pending.count + data.count <= 4096 else {
                self.finish(status: nil, error: "Too much pending account input.")
                return
            }
            self.pending.append(data)
            self.flushInput()
        }
    }

    public func cancel() {
        queue.async {
            guard self.child != nil, self.stoppingAt == nil else { return }
            self.pending.resetBytes(in: self.pending.startIndex..<self.pending.endIndex)
            self.pending.removeAll(keepingCapacity: false)
            // SIGINT allows the official CLI to cancel its RPC on the service.
            self.child?.interrupt()
            self.stoppingAt = .now() + self.cancellationGrace
        }
    }

    public func shutdown() {
        queue.sync {
            // The official CLI uses SIGINT to cancel its provisioning RPC and
            // waits up to five seconds for the cancellation to reach the service.
            // Finish that bounded handshake before forced cleanup on app quit.
            let remaining: TimeInterval
            if let deadline = self.stoppingAt {
                let now = DispatchTime.now().uptimeNanoseconds
                remaining = deadline.uptimeNanoseconds > now ?
                    Double(deadline.uptimeNanoseconds - now) / 1_000_000_000 : 0
            } else { remaining = self.cancellationGrace }
            self.child?.stop(signal: self.stoppingAt == nil ? SIGINT : 0, grace: remaining)
            self.finish(status: nil, error: nil)
        }
    }

    private func flushInput() {
        guard !pending.isEmpty else { return }
        guard kb_terminal_disable_echo(fd) == 0 else {
            finish(status: nil, error: "Keybase account input could not be kept private.")
            return
        }
        let count = pending.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
        if count > 0 {
            pending.resetBytes(in: pending.startIndex..<(pending.startIndex + count))
            pending.removeFirst(count)
        } else if count < 0 && errno != EINTR && errno != EAGAIN {
            finish(status: nil, error: "The Keybase account input closed.")
        }
    }

    private func tick() {
        guard child != nil else { return }
        if DispatchTime.now() >= deadline {
            finish(status: nil, error: "The account flow expired after 30 minutes. Open it again to continue.")
            return
        }
        if let stoppingAt, DispatchTime.now() >= stoppingAt {
            finish(status: nil, error: "Account flow cancelled.")
            return
        }
        var buffer = [UInt8](repeating: 0, count: 8192)
        for _ in 0..<16 {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            outputCount += count
            guard outputCount <= 512 * 1024 else {
                finish(status: nil, error: "The account flow exceeded the output safety limit.")
                return
            }
            let safe = filter.consume(Data(buffer.prefix(count)))
            DispatchQueue.main.async { self.onOutput(safe) }
        }
        let echo = kb_terminal_echo_enabled(fd) != 0
        if echo != lastEcho {
            lastEcho = echo
            DispatchQueue.main.async { self.onEcho(echo) }
        }
        flushInput()
        guard child != nil else { return }
        var status: Int32 = 0
        guard let child else { return }
        let state: Int
        switch child.observe() {
        case .running: return
        case .exited(let exitStatus): status = exitStatus; state = 1
        case .stopped: state = -1
        }
        if state != 0 {
            // Read the final prompt bytes after exit; no EOF dependency on a
            // child or service accidentally inheriting a terminal descriptor.
            for _ in 0..<16 {
                let count = read(fd, &buffer, buffer.count)
                guard count > 0 else { break }
                outputCount += count
                guard outputCount <= 512 * 1024 else { break }
                let safe = filter.consume(Data(buffer.prefix(count)))
                DispatchQueue.main.async { self.onOutput(safe) }
            }
            finish(status: state > 0 ? status : nil,
                   error: state < 0 ? "The Keybase account process ended unexpectedly." : nil)
        }
    }

    private func finish(status: Int32?, error: String?) {
        guard child != nil else { return }
        // The PID remains reserved until cleanup, even after natural exit.
        child?.stop()
        child = nil
        close(fd); fd = -1
        pending.resetBytes(in: pending.startIndex..<pending.endIndex)
        pending.removeAll(keepingCapacity: false)
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        DispatchQueue.main.async { self.onFinish(status, error) }
    }
}
