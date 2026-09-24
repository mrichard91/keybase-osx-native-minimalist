import XCTest
import Foundation
import CKeybaseProcess
@testable import MinimalCore

final class AccountTextTests: XCTestCase {
    func testResponseIsOneBoundedASCIILine() {
        XCTAssertEqual(AccountText.responseData("paper key words 123"), Data("paper key words 123\r".utf8))
        XCTAssertEqual(AccountText.responseData(""), Data([13]))
        for value in ["line\nbreak", "carriage\rreturn", "null\0byte", "tab\there", "é", "😀", String(repeating: "a", count: 1001)] {
            XCTAssertNil(AccountText.responseData(value))
        }
    }

    func testTerminalSequencesCannotReachAppKit() {
        let filter = TerminalTextFilter()
        XCTAssertEqual(filter.consume(Data("safe\u{1b}[31mred\u{1b}[0m\u{1b}]52;c;clipboard\u{7}end\r\n\t".utf8)),
                       "saferedend\n    ")
        XCTAssertEqual(filter.consume(Data("\u{1b}Pprivate payload\u{1b}\\visible".utf8)), "visible")
    }

    func testTerminalFilterHandlesSplitEscapeAndUnicode() {
        let filter = TerminalTextFilter()
        XCTAssertEqual(filter.consume(Data("begin\u{1b}]52;".utf8)), "begin")
        XCTAssertEqual(filter.consume(Data("clipboard\u{1b}".utf8)), "")
        XCTAssertEqual(filter.consume(Data("\\end".utf8)), "end")
        XCTAssertEqual(filter.consume(Data([0xf0, 0x9f])), "[non-ASCII]")
        XCTAssertEqual(filter.consume(Data([0x98, 0x80, 65])), "A")
    }

    func testPTYReadsPrivateResponseAndHasControllingTerminal() async throws {
        // Build an inert local fixture to exercise PTY behavior without touching
        // Keybase accounts, its service, or a network. It checks the fixed argv,
        // controlling terminal, and hidden canonical input before returning OK.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("account-fixture")
        let source = #"""
        #include <fcntl.h>
        #include <stdio.h>
        #include <string.h>
        #include <termios.h>
        #include <unistd.h>
        int main(int argc, char **argv) {
            if (argc != 6 || strcmp(argv[1], "--no-auto-fork") || strcmp(argv[2], "--no-debug") ||
                strcmp(argv[3], "--app-start-mode") || strcmp(argv[4], "minimalist") || strcmp(argv[5], "login")) return 1;
            int tty = open("/dev/tty", O_RDWR);
            if (tty < 0 || !isatty(0)) return 2;
            close(tty);
            struct termios mode;
            if (tcgetattr(0, &mode) || (mode.c_lflag & (ECHO | ECHONL))) return 3;
            printf("Response: "); fflush(stdout);
            char input[128];
            if (!fgets(input, sizeof(input), stdin) || strcmp(input, "sensitive-test-value\n")) return 4;
            puts("OK"); return 0;
        }
        """#
        let compilation = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/cc"),
            arguments: ["-x", "c", "-", "-o", executable.path], input: Data(source.utf8), timeout: 30)
        XCTAssertEqual(compilation.status, 0, String(decoding: compilation.stderr, as: UTF8.self))
        guard compilation.status == 0 else { return }
        var pid: pid_t = 0, terminal: Int32 = -1
        let result = withCStringArray(ProcessRunner.environment.map { "\($0.key)=\($0.value)" }) { env in
            executable.path.withCString { kb_spawn_account($0, 0, env, &pid, &terminal) }
        }
        XCTAssertEqual(result, 0)
        guard result == 0 else { return }
        var reaped = false
        defer {
            if !reaped { kb_process_kill(pid); kb_process_reap(pid) }
            close(terminal)
        }
        XCTAssertEqual(kb_terminal_echo_enabled(terminal), 0)
        XCTAssertEqual(kb_terminal_disable_echo(terminal), 0)
        let response = AccountText.responseData("sensitive-test-value")!
        XCTAssertEqual(response.withUnsafeBytes { write(terminal, $0.baseAddress!, $0.count) }, response.count)
        var output = Data(), buffer = [UInt8](repeating: 0, count: 1024)
        var exitStatus: Int32 = -1
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let count = read(terminal, &buffer, buffer.count)
            if count > 0 { output.append(contentsOf: buffer.prefix(count)) }
            if kb_process_poll(pid, &exitStatus) == 1 { reaped = true; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        while true {
            let count = read(terminal, &buffer, buffer.count)
            if count <= 0 { break }
            output.append(contentsOf: buffer.prefix(count))
        }
        XCTAssertTrue(reaped)
        XCTAssertEqual(exitStatus, 0)
        XCTAssertEqual(TerminalTextFilter().consume(output), "Response: OK\n")
    }
}
