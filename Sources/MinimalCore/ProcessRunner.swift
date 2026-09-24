import Foundation
import Darwin
import CKeybaseProcess

public struct ProcessOutput: Sendable {
    public let stdout: Data
    public let stderr: Data
    public let status: Int32

    public init(stdout: Data, stderr: Data, status: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.status = status
    }
}

public enum ProcessRunnerError: LocalizedError {
    case invalidParameters
    case launchFailed
    case timedOut
    case outputLimitExceeded
    case inputFailed

    public var errorDescription: String? {
        switch self {
        case .invalidParameters: return "The command request is outside the allowed size or time limits."
        case .launchFailed: return "The Keybase command could not be started."
        case .timedOut: return "Keybase took too long to respond. Try connecting again."
        case .outputLimitExceeded: return "Keybase returned more data than the safety limit allows."
        case .inputFailed: return "The connection to the Keybase command closed before the request was sent."
        }
    }
}

public enum ProcessRunner {
    /// Call during application termination after controllers request their own
    /// graceful shutdown. This synchronously stops all remaining owned commands
    /// and prevents queued work from starting another process afterward.
    public static func shutdownAll() { ChildProcessRegistry.shared.shutdown() }

    /// Construct, rather than filter, the environment. In particular no KEYBASE,
    /// DYLD, proxy, certificate-path, plugin, shell, or debug overrides propagate.
    public static var environment: [String: String] {
        ["HOME": NSHomeDirectory(), "USER": NSUserName(), "LOGNAME": NSUserName(),
         "TMPDIR": NSTemporaryDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
         "LANG": "C", "LC_ALL": "C", "TERM": "dumb", "NO_COLOR": "1", "CLICOLOR": "0"]
    }

    public static func run(executable: URL, arguments: [String], input: Data? = nil,
                           timeout: TimeInterval = 30,
                           outputLimit: Int = 8 * 1024 * 1024) async throws -> ProcessOutput {
        guard executable.isFileURL, timeout.isFinite, timeout > 0, timeout <= 600,
              outputLimit > 0, outputLimit <= 64 * 1024 * 1024,
              (input?.count ?? 0) <= 8 * 1024 * 1024,
              arguments.count <= 256,
              !executable.path.utf8.contains(0),
              arguments.allSatisfy({ !$0.utf8.contains(0) && $0.utf8.count <= 64 * 1024 })
        else { throw ProcessRunnerError.invalidParameters }
        let cancellation = ProcessCancellation()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let output = try execute(executable: executable, arguments: arguments,
                                                 input: input ?? Data(), timeout: timeout,
                                                 outputLimit: outputLimit, cancellation: cancellation)
                        continuation.resume(returning: output)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { cancellation.cancel() })
    }

    private static func execute(executable: URL, arguments: [String], input: Data,
                                timeout: TimeInterval, outputLimit: Int,
                                cancellation: ProcessCancellation) throws -> ProcessOutput {
        if cancellation.isCancelled { throw CancellationError() }
        var pid: pid_t = 0
        var inputFD: Int32 = -1, outputFD: Int32 = -1, errorFD: Int32 = -1
        let child = try ChildProcessRegistry.shared.launch {
            if cancellation.isCancelled { throw CancellationError() }
            let result = withCStringArray([executable.path] + arguments) { argv in
                withCStringArray(environment.map { "\($0.key)=\($0.value)" }) { env in
                    executable.path.withCString { path in
                        kb_spawn_piped(path, argv, env, &pid, &inputFD, &outputFD, &errorFD)
                    }
                }
            }
            guard result == 0 else { throw ProcessRunnerError.launchFailed }
            return OwnedChildProcess(pid: pid)
        }
        defer {
            if inputFD >= 0 { close(inputFD) }
            close(outputFD); close(errorFD)
            child.stop()
        }
        var stdout = Data(), stderr = Data(), written = 0
        var status: Int32 = 0
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        var buffer = [UInt8](repeating: 0, count: 16384)

        while true {
            if cancellation.isCancelled { throw CancellationError() }
            if DispatchTime.now().uptimeNanoseconds >= deadline { throw ProcessRunnerError.timedOut }
            // Read both streams each iteration so either one can fill its pipe.
            for stream in 0..<2 {
                let fd = stream == 0 ? outputFD : errorFD
                // A bounded number of reads ensures a busy producer cannot starve
                // timeout/cancellation checks or consumption of the other stream.
                for _ in 0..<8 {
                    let count = read(fd, &buffer, buffer.count)
                    if count > 0 {
                        guard stdout.count + stderr.count + count <= outputLimit else {
                            throw ProcessRunnerError.outputLimitExceeded
                        }
                        if stream == 0 { stdout.append(contentsOf: buffer.prefix(count)) }
                        else { stderr.append(contentsOf: buffer.prefix(count)) }
                    } else { break }
                }
            }
            if inputFD >= 0 {
                if written == input.count { close(inputFD); inputFD = -1 }
                else {
                    let count = input.withUnsafeBytes { bytes -> Int in
                        write(inputFD, bytes.baseAddress!.advanced(by: written), min(input.count - written, 16384))
                    }
                    if count > 0 { written += count }
                    else if count < 0 && errno != EAGAIN && errno != EINTR {
                        throw ProcessRunnerError.inputFailed
                    }
                }
            }
            // Keep the child unreaped until the pipe buffers have been drained.
            // Once it exits, poll returns immediately; a final full drain captures
            // the last bytes without waiting on inherited descriptors indefinitely.
            switch child.observe() {
            case .stopped: throw CancellationError()
            case .running: break
            case .exited(let exitStatus):
                status = exitStatus
                for stream in 0..<2 {
                    let fd = stream == 0 ? outputFD : errorFD
                    while true {
                        let count = read(fd, &buffer, buffer.count)
                        if count <= 0 { break }
                        guard stdout.count + stderr.count + count <= outputLimit else {
                            throw ProcessRunnerError.outputLimitExceeded
                        }
                        if stream == 0 { stdout.append(contentsOf: buffer.prefix(count)) }
                        else { stderr.append(contentsOf: buffer.prefix(count)) }
                        if cancellation.isCancelled { throw CancellationError() }
                        if DispatchTime.now().uptimeNanoseconds >= deadline { throw ProcessRunnerError.timedOut }
                    }
                }
                // The leader remains unreaped, reserving its PID while any
                // descendants holding our pipes are terminated as one group.
                child.stop()
                return ProcessOutput(stdout: stdout, stderr: stderr, status: status)
            }
            var descriptors = [pollfd(fd: outputFD, events: Int16(POLLIN), revents: 0),
                               pollfd(fd: errorFD, events: Int16(POLLIN), revents: 0)]
            if inputFD >= 0 { descriptors.append(pollfd(fd: inputFD, events: Int16(POLLOUT), revents: 0)) }
            _ = poll(&descriptors, nfds_t(descriptors.count), 25)
        }
    }
}

private final class ProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

/// Pointer storage stays alive across the complete C spawn call, including exec.
public func withCStringArray<T>(_ values: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) throws -> T) rethrows -> T {
    let strings = values.map { strdup($0) }
    defer { strings.forEach { free($0) } }
    return try (strings + [nil]).withUnsafeBufferPointer { try body($0.baseAddress!) }
}
