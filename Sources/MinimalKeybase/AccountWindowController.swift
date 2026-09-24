import AppKit
import Darwin
import CKeybaseProcess
import MinimalCore

private extension AccountAction {
    var title: String {
        switch self {
        case .login: return "Log in to Keybase"
        case .signup: return "Create a Keybase account"
        case .logout: return "Log out of Keybase"
        }
    }
}

/// A plain text view of Keybase's account flow, backed by a real PTY. The bundled
/// build uses official Keybase source with the project's minimalist patch.
/// No terminal emulator, link handler, shell, or password arguments are involved.
@MainActor
final class AccountWindowController: NSWindowController, NSWindowDelegate {
    private let executable: URL
    private let action: AccountAction
    private let onCompletion: () -> Void
    private let transcript = PlainTextView()
    private let response = NSSecureTextField()
    private let responseLabel = NSTextField(labelWithString: "Response (input is hidden)")
    private let statusLabel = NSTextField(labelWithString: "Starting Keybase account flow...")
    private let submitButton = NSButton(title: "Send response", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var session: AccountSession?
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
            session = try AccountSession(executable: executable, action: action,
                onOutput: { [weak self] output in self?.append(output) },
                // Raw terminal mode disables kernel echo for ordinary prompts
                // too, so it cannot identify whether a prompt requests a secret.
                onEcho: { _ in },
                onFinish: { [weak self] status, error in self?.complete(status: status, error: error) })
            statusLabel.stringValue = "Follow the Keybase prompts below."
        } catch { complete(status: nil, error: error.localizedDescription) }
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        let accountContext = KeybaseExecutable.isBundled(executable) ?
            "Use your existing Keybase account to provision this app as a new device. Its backend uses official Keybase source with a minimalist patch, separate account storage, and separate Keychain entries." :
            "The official Keybase command uses your existing local Keybase service and account. Keybase handles your password, device approval, and paper key."
        let explanation = NSTextField(wrappingLabelWithString: accountContext +
            " Responses are hidden and must contain printable ASCII. This window keeps no response history or transcript on disk.")
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
