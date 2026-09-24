import XCTest
import Foundation
@testable import MinimalCore

final class ProcessRunnerTests: XCTestCase {
    func testArgumentsArePassedLiterally() async throws {
        let payload = "$(touch /tmp/should-never-run); `whoami` ' \" ; & | >"
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/printf"),
                                                 arguments: ["%s", payload])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), payload)
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testConcurrentInputAndOutputWithoutPipeDeadlock() async throws {
        let bytes = Data(repeating: 65, count: 512 * 1024)
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/cat"),
                                                 arguments: [], input: bytes, timeout: 5)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, bytes)
    }

    func testBothOutputStreamsAreDrained() async throws {
        // The fixture uses awk directly, with a constant program and no shell.
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/awk"),
            arguments: ["BEGIN { for (i=0;i<20000;i++) { print \"out\"; print \"err\" > \"/dev/stderr\"; } }"], timeout: 5)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout.count, 80_000)
        XCTAssertEqual(result.stderr.count, 80_000)
    }

    func testOutputIsBounded() async throws {
        do {
            _ = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/yes"),
                                             arguments: [], timeout: 3, outputLimit: 4096)
            XCTFail("Expected an output limit failure")
        } catch ProcessRunnerError.outputLimitExceeded {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testTimeoutTerminatesChild() async throws {
        let started = Date()
        do {
            _ = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"),
                                             arguments: ["5"], timeout: 0.08)
            XCTFail("Expected a timeout")
        } catch ProcessRunnerError.timedOut {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testCancellationTerminatesChild() async throws {
        let task = Task {
            try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"),
                                        arguments: ["5"], timeout: 10)
        }
        try await Task.sleep(nanoseconds: 80_000_000)
        let started = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testEnvironmentIsAnAllowlist() async throws {
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: [])
        let variables = String(decoding: result.stdout, as: UTF8.self).split(separator: "\n")
        XCTAssertEqual(Set(variables.map { String($0.split(separator: "=", maxSplits: 1)[0]) }),
                       Set(ProcessRunner.environment.keys))
        XCTAssertEqual(ProcessRunner.environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertFalse(variables.contains(where: { $0.hasPrefix("KEYBASE_") || $0.hasPrefix("DYLD_") }))
    }

    func testEmbeddedNULArgumentsAreRejected() async throws {
        do {
            _ = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/printf"),
                                             arguments: ["hello\0world"])
            XCTFail("Expected invalid argument failure")
        } catch ProcessRunnerError.invalidParameters {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testExecutablePinRejectsOtherPrograms() {
        XCTAssertThrowsError(try KeybaseExecutable.validate(URL(fileURLWithPath: "/bin/echo")))
        XCTAssertThrowsError(try KeybaseExecutable.validate(URL(fileURLWithPath: "/usr/local/bin/keybase")))
    }
}
