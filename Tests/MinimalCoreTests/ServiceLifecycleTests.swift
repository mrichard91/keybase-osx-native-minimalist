import XCTest
import Foundation
@testable import MinimalCore

final class ServiceLifecycleTests: XCTestCase {
    func testStopKillsUncooperativeOwnedGroupAndIsIdempotent() async throws {
        let fixture = try await ProcessFixture.make(.ignoresSignals)
        let service = ServiceController(executable: fixture.executable, validator: { _ in }, grace: 0.08)
        defer { service.stop() }
        try service.start()
        let parent = try await fixture.recordedPID(), descendant = try await fixture.recordedPID("child")
        XCTAssertTrue(service.isRunning)
        let start = Date()
        service.stop()
        service.stop()
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertFalse(service.isRunning)
        await ProcessFixture.assertGone(parent)
        await ProcessFixture.assertGone(descendant)
    }

    func testStopAllowsGracefulExit() async throws {
        let fixture = try await ProcessFixture.make(.graceful)
        let service = ServiceController(executable: fixture.executable, validator: { _ in }, grace: 0.5)
        defer { service.stop() }
        try service.start()
        let pid = try await fixture.recordedPID()
        service.stop()
        XCTAssertEqual(try String(contentsOfFile: fixture.executable.path + ".terminated", encoding: .utf8), "x")
        await ProcessFixture.assertGone(pid)
    }

    func testDeinitializationStopsOwnedService() async throws {
        let fixture = try await ProcessFixture.make(.ignoresSignals)
        var service: ServiceController? = ServiceController(executable: fixture.executable, validator: { _ in }, grace: 0.02)
        try service?.start()
        let pid = try await fixture.recordedPID(), descendant = try await fixture.recordedPID("child")
        service = nil
        await ProcessFixture.assertGone(pid)
        await ProcessFixture.assertGone(descendant)
    }

    func testNaturallyExitedLeaderStillHasItsDescendantsCleanedUp() async throws {
        let fixture = try await ProcessFixture.make(.exitsLeavingChild)
        let service = ServiceController(executable: fixture.executable, validator: { _ in })
        defer { service.stop() }
        try service.start()
        let pid = try await fixture.recordedPID(), descendant = try await fixture.recordedPID("child")
        for _ in 0..<100 where service.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(service.isRunning)
        await ProcessFixture.assertGone(pid)
        await ProcessFixture.assertGone(descendant)
    }

    func testStoppingOneServiceDoesNotTouchAnother() async throws {
        let first = try await ProcessFixture.make(.ignoresSignals)
        let second = try await ProcessFixture.make(.ignoresSignals)
        let a = ServiceController(executable: first.executable, validator: { _ in }, grace: 0)
        let b = ServiceController(executable: second.executable, validator: { _ in }, grace: 0)
        defer { a.stop(); b.stop() }
        try a.start(); try b.start()
        _ = try await first.recordedPID(); _ = try await second.recordedPID()
        a.stop()
        XCTAssertTrue(b.isRunning)
    }

    func testRegistryShutdownCleansChildrenAndRejectsLateLaunch() async throws {
        let fixture = try await ProcessFixture.make(.ignoresSignals)
        let registry = ChildProcessRegistry()
        let service = ServiceController(executable: fixture.executable, validator: { _ in }, registry: registry)
        try service.start()
        let pid = try await fixture.recordedPID(), descendant = try await fixture.recordedPID("child")
        registry.shutdown()
        XCTAssertFalse(service.isRunning)
        XCTAssertThrowsError(try service.start()) { XCTAssertTrue($0 is CancellationError) }
        await ProcessFixture.assertGone(pid)
        await ProcessFixture.assertGone(descendant)
    }

    func testFailedExecutableLaunchIsReportedImmediately() {
        let service = ServiceController(executable: URL(fileURLWithPath: "/does/not/exist"), validator: { _ in })
        XCTAssertThrowsError(try service.start())
        XCTAssertFalse(service.isRunning)
    }

    func testConcurrentStopAndRegistryShutdownReapOnlyOnce() async throws {
        let fixture = try await ProcessFixture.make(.ignoresSignals)
        let registry = ChildProcessRegistry()
        let service = ServiceController(executable: fixture.executable, validator: { _ in }, registry: registry, grace: 0.03)
        try service.start()
        let pid = try await fixture.recordedPID(), descendant = try await fixture.recordedPID("child")
        DispatchQueue.concurrentPerform(iterations: 12) { index in
            if index.isMultiple(of: 2) { service.stop() } else { registry.shutdown() }
        }
        XCTAssertFalse(service.isRunning)
        await ProcessFixture.assertGone(pid)
        await ProcessFixture.assertGone(descendant)
    }
}
