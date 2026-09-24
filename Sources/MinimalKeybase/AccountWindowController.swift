import AppKit
import Darwin
import CKeybaseProcess
import MinimalCore

enum AccountAction: Int32 {
    case login = 0
    case signup = 1
    case logout = 2

    var title: String {
        switch self {
        case .login: return "Log in to Keybase"
        case .signup: return "Create a Keybase account"
        case .logout: return "Log out of Keybase"
        }
    }
}

/// A plain text view of the official CLI's account flow, backed by a real PTY.
/// No terminal emulator, link handler, shell, or password arguments are involved.
@MainActor
final class AccountWindowController: NSWindowController, NSWindowDelegate {
    private let executable: URL
    private let action: AccountAction
    private let onCompletion: () -> Void
    private let transcript = PlainTextView()
    private let response = NSSecureTextField()
    private let responseLabel = NSTextField(labelWithString: "Response (input is hidden)")
    private let statusLabel = NSTextField(labelWithString: "Starting official Keybase account flow...")
    private let submitButton = NSButton(title: "Send response", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var session: AccountTerminalSession?
    private var finished = false
    private var windowClosed = false
    private var completionSent = false
    var isActive: Bool { session != nil && !finished }

    init(executable: URL, action: AccountAction, onCompletion: @escaping () -> Void) {
        self.executable = executable
        self.action = action
        self.onCompletion = onCompletion
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 590),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = action.title
        window.minSize = NSSize(width: 560, height: 420)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildInterface()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        window?.makeFirstResponder(response)
        guard session == nil, !finished else { return }
        do {
            session = try AccountTerminalSession(executable: executable, action: action,
                onOutput: { [weak self] output in self?.append(output) },
                onEcho: { [weak self] enabled in
                    self?.responseLabel.stringValue = enabled ? "Response (input is hidden)" : "Secret response (input is hidden)"
                },
                onFinish: { [weak self] status, error in self?.complete(status: status, error: error) })
            statusLabel.stringValue = "Follow the official Keybase prompts below."
        } catch { complete(status: nil, error: error.localizedDescription) }
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        let explanation = NSTextField(wrappingLabelWithString:
            "Keybase handles your password, device approval, and paper key. Responses are hidden, have no history, and must contain printable ASCII. This window keeps no account transcript on disk.")
        explanation.textColor = .secondaryLabelColor
        explanation.font = .systemFont(ofSize: 12)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        transcript.configurePlainText(editable: false)
        transcript.isSelectable = true
        transcript.isRichText = false
        transcript.importsGraphics = false
        transcript.isAutomaticLinkDetectionEnabled = false
        transcript.isAutomaticDataDetectionEnabled = false
        transcript.isAutomaticTextReplacementEnabled = false
        transcript.isContinuousSpellCheckingEnabled = false
        transcript.isGrammarCheckingEnabled = false
        transcript.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        transcript.textContainerInset = NSSize(width: 12, height: 12)
        transcript.autoresizingMask = [.width]
        transcript.textContainer?.widthTracksTextView = true
        scroll.documentView = transcript
        response.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        response.placeholderString = "Type a response and press Return"
        response.target = self
        response.action = #selector(submit)
        responseLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        submitButton.target = self
        submitButton.action = #selector(submit)
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [statusLabel, NSView(), cancelButton, submitButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        let layout = NSStackView(views: [explanation, scroll, responseLabel, response, buttons])
        layout.orientation = .vertical
        layout.alignment = .leading
        layout.spacing = 12
        layout.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            layout.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            layout.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            layout.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            explanation.widthAnchor.constraint(equalTo: layout.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: layout.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            response.widthAnchor.constraint(equalTo: layout.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: layout.widthAnchor)
        ])
        explanation.setContentHuggingPriority(.required, for: .vertical)
        response.setContentHuggingPriority(.required, for: .vertical)
    }

    @objc private func submit() {
        guard !finished, let session else { return }
        let value = response.stringValue
        guard let data = AccountText.responseData(value) else {
            statusLabel.stringValue = "Use at most 1,000 printable ASCII characters, with no line breaks."
            NSSound.beep()
            return
        }
        response.stringValue = ""
        session.send(data)
        statusLabel.stringValue = "Response sent to Keybase."
        window?.makeFirstResponder(response)
    }

    @objc private func cancel() {
        if finished { close(); return }
        response.stringValue = ""
        response.isEnabled = false
        submitButton.isEnabled = false
        cancelButton.isEnabled = false
        statusLabel.stringValue = "Cancelling the Keybase account flow..."
        session?.cancel()
    }

    private func append(_ output: String) {
        guard !windowClosed, !output.isEmpty else { return }
        transcript.textStorage?.append(NSAttributedString(string: output, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ]))
        transcript.scrollToEndOfDocument(nil)
    }

    private func complete(status: Int32?, error: String?) {
        finished = true
        response.stringValue = ""
        response.isEnabled = false
        submitButton.isEnabled = false
        cancelButton.isEnabled = true
        cancelButton.title = "Close"
        if let error {
            let safe = TerminalTextFilter().consume(Data(error.utf8))
            append("\n" + safe + "\n")
            statusLabel.stringValue = "Account flow ended."
        } else if status == 0 {
            statusLabel.stringValue = "Keybase completed the account flow. You can close this window."
        } else {
            statusLabel.stringValue = "Keybase ended the account flow. Review the prompts above."
        }
        notifyCompletion()
    }

    private func notifyCompletion() {
        guard !completionSent else { return }
        completionSent = true
        onCompletion()
    }

    func windowWillClose(_ notification: Notification) {
        windowClosed = true
        response.stringValue = ""
        transcript.string = ""
        if !finished, let session { session.cancel() }
        else { notifyCompletion() }
    }

    /// App termination cannot wait for asynchronous RPC cancellation callbacks.
    func shutdown() {
        response.stringValue = ""
        transcript.string = ""
        windowClosed = true
        session?.shutdown()
    }
}

private final class AccountTerminalSession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "minimalist.keybase.account", qos: .userInitiated)
    private var pid: pid_t = 0
    private var fd: Int32 = -1
    private var timer: DispatchSourceTimer?
    private var pending = Data()
    private var outputCount = 0
    private let filter = TerminalTextFilter()
    private var lastEcho: Bool?
    private var stoppingAt: DispatchTime?
    private let deadline = DispatchTime.now() + 1800
    private let onOutput: @MainActor (String) -> Void
    private let onEcho: @MainActor (Bool) -> Void
    private let onFinish: @MainActor (Int32?, String?) -> Void

    init(executable: URL, action: AccountAction,
         onOutput: @escaping @MainActor (String) -> Void,
         onEcho: @escaping @MainActor (Bool) -> Void,
         onFinish: @escaping @MainActor (Int32?, String?) -> Void) throws {
        self.onOutput = onOutput
        self.onEcho = onEcho
        self.onFinish = onFinish
        try KeybaseExecutable.validate(executable)
        let result = withCStringArray(ProcessRunner.environment.map { "\($0.key)=\($0.value)" }) { env in
            executable.path.withCString { kb_spawn_account($0, action.rawValue, env, &pid, &fd) }
        }
        guard result == 0 else { throw ProcessRunnerError.launchFailed }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // The timer owns this session until finish() cancels it and breaks the
        // cycle. Closing a window therefore still waits for CLI cancellation.
        timer.setEventHandler { self.tick() }
        timer.schedule(deadline: .now(), repeating: .milliseconds(30))
        self.timer = timer
        timer.resume()
    }

    func send(_ data: Data) {
        queue.async {
            guard self.pid > 0, self.stoppingAt == nil else { return }
            guard self.pending.count + data.count <= 4096 else {
                self.finish(status: nil, error: "Too much pending account input.", kill: true)
                return
            }
            self.pending.append(data)
            self.flushInput()
        }
    }

    func cancel() {
        queue.async {
            guard self.pid > 0, self.stoppingAt == nil else { return }
            self.pending.resetBytes(in: self.pending.startIndex..<self.pending.endIndex)
            self.pending.removeAll(keepingCapacity: false)
            // SIGINT allows the official CLI to cancel its RPC on the service.
            kb_process_interrupt(self.pid)
            self.stoppingAt = .now() + 6
        }
    }

    func shutdown() {
        queue.sync {
            self.finish(status: nil, error: nil, kill: true)
        }
    }

    private func flushInput() {
        guard !pending.isEmpty else { return }
        guard kb_terminal_disable_echo(fd) == 0 else {
            finish(status: nil, error: "Keybase account input could not be kept private.", kill: true)
            return
        }
        let count = pending.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
        if count > 0 {
            pending.resetBytes(in: pending.startIndex..<(pending.startIndex + count))
            pending.removeFirst(count)
        } else if count < 0 && errno != EINTR && errno != EAGAIN {
            finish(status: nil, error: "The Keybase account input closed.", kill: true)
        }
    }

    private func tick() {
        guard pid > 0 else { return }
        if DispatchTime.now() >= deadline {
            finish(status: nil, error: "The account flow expired after 30 minutes. Open it again to continue.", kill: true)
            return
        }
        if let stoppingAt, DispatchTime.now() >= stoppingAt {
            finish(status: nil, error: "Account flow cancelled.", kill: true)
            return
        }
        var buffer = [UInt8](repeating: 0, count: 8192)
        for _ in 0..<16 {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            outputCount += count
            guard outputCount <= 512 * 1024 else {
                finish(status: nil, error: "The account flow exceeded the output safety limit.", kill: true)
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
        guard pid > 0 else { return }
        var status: Int32 = 0
        let state = kb_process_poll(pid, &status)
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
                   error: state < 0 ? "The Keybase account process ended unexpectedly." : nil, kill: false)
        }
    }

    private func finish(status: Int32?, error: String?, kill: Bool) {
        guard pid > 0 else { return }
        if kill { kb_process_kill(pid); kb_process_reap(pid) }
        pid = 0
        close(fd); fd = -1
        pending.resetBytes(in: pending.startIndex..<pending.endIndex)
        pending.removeAll(keepingCapacity: false)
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        DispatchQueue.main.async { self.onFinish(status, error) }
    }
}
