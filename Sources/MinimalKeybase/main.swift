import AppKit
import MinimalCore

if CommandLine.arguments.contains("--self-check") {
    _ = NSApplication.shared
    Task {
        do {
            guard ASCIIText.sanitize("\u{1F600}") == ":grinning:" else { throw CheckError.resources }
            guard ASCIIText.isKnownEmojiShortcode(":information_desk_person:") else { throw CheckError.resources }
            try await MainActor.run {
                let editor = PlainTextView()
                editor.configurePlainText(editable: true)
                editor.insertText("\u{1F600}", replacementRange: NSRange(location: 0, length: 0))
                guard editor.string == ":grinning:" else { throw CheckError.editor }
                editor.insertText("a\u{202E}", replacementRange: editor.selectedRange())
                guard editor.string == ":grinning:" else { throw CheckError.editor }
                editor.setMarkedText("\u{1F469}\u{1F3FD}\u{200D}\u{1F4BB}", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: 0, length: 0))
                guard editor.string.utf8.allSatisfy({ $0 < 128 }) else { throw CheckError.editor }
            }
            let executable = try KeybaseExecutable.locate()
            let output = try await ProcessRunner.run(executable: executable, arguments: ["--version"], timeout: 20, outputLimit: 4096)
            guard output.status == 0 else { throw CheckError.executable }
            let verification = KeybaseExecutable.isBundled(executable) ? "bundled backend signature and integrity" : "official Keybase signature"
            print("PASS: bundled emoji mapping; native editor ASCII boundary; \(verification); bounded process execution.")
            print(ASCIIText.sanitize(String(decoding: output.stdout, as: UTF8.self)))
            exit(0)
        } catch {
            print("FAIL: " + ASCIIText.sanitize(error.localizedDescription))
            exit(1)
        }
    }
    // AppKit requires the actual main thread, not just the main-actor executor.
    RunLoop.main.run()
} else { MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppController()
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
} }

private enum CheckError: Error { case resources, executable, editor }
