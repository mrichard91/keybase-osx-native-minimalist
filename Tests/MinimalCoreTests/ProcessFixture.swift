import Foundation
import XCTest
import Darwin
@testable import MinimalCore

/// Inert compiled processes exercise lifetimes without opening Keybase accounts,
/// connecting to its service, using a shell, or contacting a network.
final class ProcessFixture {
    enum Mode: Int { case ignoresSignals = 1, exitsLeavingChild = 2, graceful = 3, terminalPrompts = 4 }
    let directory: URL
    let executable: URL

    private init(directory: URL) {
        self.directory = directory
        executable = directory.appendingPathComponent("fixture")
    }

    static func make(_ mode: Mode) async throws -> ProcessFixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = ProcessFixture(directory: folder)
        let source = "#define MODE \(mode.rawValue)\n" + #"""
        #include <fcntl.h>
        #include <signal.h>
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        #include <termios.h>
        #include <unistd.h>
        static int marker = -1;
        static void terminate(int signal) { write(marker, "x", 1); _exit(0); }
        static void record(const char *exe, const char *suffix, int pid) {
            char path[4096]; snprintf(path, sizeof(path), "%s.%s", exe, suffix);
            FILE *file = fopen(path, "w"); if (!file) _exit(99);
            fprintf(file, "%d\n", pid); fclose(file);
        }
        int main(int argc, char **argv) {
            if (MODE == 4) {
                // Exercise the same raw Enter convention as upstream's
                // go-crypto/ssh/terminal, with canonical/raw transitions too.
                char input[128];
                puts("Canonical response:"); fflush(stdout);
                if (!fgets(input, sizeof(input), stdin) || strcmp(input, "canonical-fixture\n")) return 81;
                struct termios original, raw;
                if (tcgetattr(0, &original)) return 82;
                raw = original; cfmakeraw(&raw);
                if (tcsetattr(0, TCSANOW, &raw)) return 83;
                const char *prompts[] = {"Raw response:", "Empty response:", "Secret response:"};
                const char *expected[] = {"raw-fixture", "", "secret-fixture"};
                for (int p = 0; p < 3; ++p) {
                    puts(prompts[p]); fflush(stdout);
                    size_t length = 0;
                    while (1) {
                        unsigned char ch;
                        if (read(0, &ch, 1) != 1) return 84;
                        if (ch == '\r') break;
                        if (ch == '\n') continue; // Upstream ignores LF in raw mode.
                        if (length + 1 >= sizeof(input)) return 85;
                        input[length++] = ch;
                    }
                    input[length] = 0;
                    if (strcmp(input, expected[p])) return 86 + p;
                }
                if (tcsetattr(0, TCSANOW, &original)) return 90;
                puts("PROMPTS COMPLETED"); fflush(stdout);
                return 0;
            }
            signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN);
            if (MODE == 3) {
                char path[4096]; snprintf(path, sizeof(path), "%s.terminated", argv[0]);
                marker = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0600);
                signal(SIGTERM, terminate);
                signal(SIGINT, terminate);
            } else {
                pid_t child = fork(); if (child < 0) return 98;
                if (child == 0) { while (1) pause(); }
                record(argv[0], "child", child);
            }
            record(argv[0], "pid", getpid());
            if (MODE == 2) return 0;
            while (1) pause();
        }
        """#
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/cc"),
            arguments: ["-x", "c", "-", "-o", fixture.executable.path], input: Data(source.utf8), timeout: 30)
        guard result.status == 0 else {
            throw NSError(domain: "FixtureCompilation", code: Int(result.status),
                          userInfo: [NSLocalizedDescriptionKey: String(decoding: result.stderr, as: UTF8.self)])
        }
        return fixture
    }

    func recordedPID(_ suffix: String = "pid") async throws -> pid_t {
        let path = executable.path + "." + suffix
        for _ in 0..<300 {
            if let content = try? String(contentsOfFile: path, encoding: .utf8),
               let pid = Int32(content.trimmingCharacters(in: .whitespacesAndNewlines)) { return pid }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "FixtureDidNotStart", code: 1)
    }

    static func assertGone(_ pid: pid_t, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<300 {
            if kill(pid, 0) == -1 && errno == ESRCH { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Fixture process \(pid) remained alive after cleanup", file: file, line: line)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}
