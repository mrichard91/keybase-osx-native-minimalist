import Foundation
import Darwin
import CKeybaseProcess

/// Serializes signaling and reaping. The PID stays reserved until its group is
/// stopped; subsequent callers never signal a stale numeric PID.
final class OwnedChildProcess: @unchecked Sendable {
    enum Observation { case running, exited(Int32), stopped }
    private let lock = NSLock()
    private var pid: pid_t
    let identifier: pid_t
    init(pid: pid_t) { self.pid = pid; identifier = pid }

    func observe() -> Observation {
        lock.lock(); defer { lock.unlock() }
        guard pid > 0 else { return .stopped }
        var status: Int32 = 0
        switch kb_process_peek(pid, &status) {
        case 0: return .running
        case 1: return .exited(status)
        default:
            // Ownership was lost: never signal a PID another component reaped.
            pid = 0
            return .stopped
        }
    }

    func interrupt() {
        lock.lock(); defer { lock.unlock() }
        guard pid > 0 else { return }
        kb_process_interrupt(pid)
    }

    func stop(signal: Int32 = SIGKILL, grace: TimeInterval = 0) {
        lock.lock(); defer { lock.unlock() }
        guard pid > 0 else { return }
        kb_process_stop(pid, signal, Int32(min(max(grace, 0), 10) * 1000))
        pid = 0
    }

    deinit { stop() }
}

/// A shared lock prevents queued operations from spawning after app shutdown.
/// Weak entries leave normal process lifetime with the command or controller.
final class ChildProcessRegistry: @unchecked Sendable {
    static let shared = ChildProcessRegistry()
    private final class WeakChild {
        weak var value: OwnedChildProcess?
        init(_ value: OwnedChildProcess) { self.value = value }
    }
    private let lock = NSLock()
    private var children: [WeakChild] = []
    private var shuttingDown = false

    func launch(_ spawn: () throws -> OwnedChildProcess) throws -> OwnedChildProcess {
        lock.lock(); defer { lock.unlock() }
        guard !shuttingDown else { throw CancellationError() }
        let child = try spawn()
        children.removeAll { $0.value == nil }
        children.append(WeakChild(child))
        return child
    }

    func shutdown() {
        lock.lock()
        shuttingDown = true
        let live = children.compactMap(\.value)
        children.removeAll()
        lock.unlock()
        live.forEach { $0.stop() }
    }
}
