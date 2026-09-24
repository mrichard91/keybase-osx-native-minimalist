import XCTest
import Foundation
@testable import MinimalCore

final class AccountLifecycleTests: XCTestCase {
    func testCancellationKillsGroupBeforeExactlyOneCompletion() async throws {
        let fixture = try await ProcessFixture.make(.ignoresSignals)
        let complete = expectation(description: "Account cancellation completed once")
        complete.assertForOverFulfill = true
        let session = try AccountSession(executable: fixture.executable, action: .login,
            validator: { _ in }, registry: ChildProcessRegistry(), cancellationGrace: 0.08, timeout: 5,
            onOutput: { _ in }, onEcho: { _ in }, onFinish: { _, _ in complete.fulfill() })
        defer { session.shutdown() }
        let pid = try await fixture.recordedPID(), descendant = try await fixture.recordedPID("child")
        session.cancel(); session.cancel()
        session.send(AccountText.responseData("late response")!)
        await fulfillment(of: [complete], timeout: 2)
        session.shutdown()
        await ProcessFixture.assertGone(pid)
        await ProcessFixture.assertGone(descendant)
    }

    func testSynchronousShutdownReapsBeforeReturning() async throws {
        let fixture = try await ProcessFixture.make(.ignoresSignals)
        let complete = expectation(description: "Shutdown callback")
        let session = try AccountSession(executable: fixture.executable, action: .signup,
            validator: { _ in }, registry: ChildProcessRegistry(), cancellationGrace: 0.08, timeout: 30,
            onOutput: { _ in }, onEcho: { _ in }, onFinish: { _, _ in complete.fulfill() })
        let pid = try await fixture.recordedPID(), descendant = try await fixture.recordedPID("child")
        session.shutdown()
        XCTAssertEqual(kill(pid, 0), -1)
        await fulfillment(of: [complete], timeout: 1)
        await ProcessFixture.assertGone(descendant)
    }

    func testNaturalAccountExitCleansDescendants() async throws {
        let fixture = try await ProcessFixture.make(.exitsLeavingChild)
        let complete = expectation(description: "Natural account exit")
        let session = try AccountSession(executable: fixture.executable, action: .login,
            validator: { _ in }, registry: ChildProcessRegistry(), cancellationGrace: 0.05, timeout: 5,
            onOutput: { _ in }, onEcho: { _ in }, onFinish: { status, error in
                XCTAssertEqual(status, 0); XCTAssertNil(error); complete.fulfill()
            })
        defer { session.shutdown() }
        let pid = try await fixture.recordedPID(), descendant = try await fixture.recordedPID("child")
        await fulfillment(of: [complete], timeout: 2)
        await ProcessFixture.assertGone(pid)
        await ProcessFixture.assertGone(descendant)
    }

    func testShutdownLetsOfficialCancellationSignalComplete() async throws {
        let fixture = try await ProcessFixture.make(.graceful)
        let complete = expectation(description: "Graceful account shutdown")
        let session = try AccountSession(executable: fixture.executable, action: .login,
            validator: { _ in }, registry: ChildProcessRegistry(), cancellationGrace: 0.5, timeout: 5,
            onOutput: { _ in }, onEcho: { _ in }, onFinish: { _, _ in complete.fulfill() })
        let pid = try await fixture.recordedPID()
        session.shutdown()
        XCTAssertEqual(try String(contentsOfFile: fixture.executable.path + ".terminated", encoding: .utf8), "x")
        XCTAssertEqual(kill(pid, 0), -1)
        await fulfillment(of: [complete], timeout: 1)
    }

    @MainActor
    func testReturnSubmitsCanonicalRawEmptyAndSecretPrompts() async throws {
        let fixture = try await ProcessFixture.make(.terminalPrompts)
        let canonical = expectation(description: "Canonical prompt")
        let raw = expectation(description: "Raw prompt")
        let empty = expectation(description: "Empty response prompt")
        let secret = expectation(description: "Secret prompt")
        let complete = expectation(description: "All prompts completed")
        var output = ""
        var seen = Set<String>()
        let prompts = [("Canonical response:", canonical), ("Raw response:", raw),
                       ("Empty response:", empty), ("Secret response:", secret)]
        let session = try AccountSession(executable: fixture.executable, action: .login,
            validator: { _ in }, registry: ChildProcessRegistry(), cancellationGrace: 0.05, timeout: 10,
            onOutput: { text in
                output += text
                for (prompt, ready) in prompts where output.contains(prompt) && seen.insert(prompt).inserted {
                    ready.fulfill()
                }
            }, onEcho: { _ in }, onFinish: { status, error in
                XCTAssertEqual(status, 0); XCTAssertNil(error); complete.fulfill()
            })
        defer { session.shutdown() }
        for (ready, response) in [(canonical, "canonical-fixture"), (raw, "raw-fixture"),
                                  (empty, ""), (secret, "secret-fixture")] {
            await fulfillment(of: [ready], timeout: 2)
            session.send(AccountText.responseData(response)!)
        }
        await fulfillment(of: [complete], timeout: 2)
        XCTAssertTrue(output.contains("PROMPTS COMPLETED"))
        XCTAssertFalse(output.contains("secret-fixture"))
        XCTAssertFalse(output.contains("canonical-fixture"))
        XCTAssertFalse(output.contains("raw-fixture"))
    }
}
