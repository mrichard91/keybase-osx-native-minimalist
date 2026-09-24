import AppKit
import MinimalCore

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSTextViewDelegate {
    private var window: ChatWindow!
    private var client: KeybaseClient?
    private var executable: URL?
    private var service: ServiceController?
    private var accountWindow: AccountWindowController?
    private var pollTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var username: String?
    private var selected: Conversation?
    private var nextPage: String?
    private var pageCursor: String?
    private var generation = 0
    private var sending = false
    private var connecting = false
    private var accountActive = false
    private var conversationReady = false
    private var displayedMessages: [Message] = []
    private var lastMarked: String?
    private var drafts: [String: String] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeMenu()
        window = ChatWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        bind(window.connectButton, #selector(connectClicked))
        bind(window.startButton, #selector(startService))
        bind(window.loginButton, #selector(accountClicked))
        bind(window.newButton, #selector(newConversation))
        bind(window.refreshButton, #selector(refreshClicked))
        bind(window.sendButton, #selector(sendClicked))
        bind(window.olderButton, #selector(olderClicked))
        window.onSelection = { [weak self] in self?.select($0) }
        window.composer.onSend = { [weak self] in self?.sendClicked() }
        window.composer.delegate = self
        window.composer.onRejectedInput = { [weak self] reason in self?.status(reason) }
        if CommandLine.arguments.contains("--demo") { showDemo() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        pollTask?.cancel(); loadTask?.cancel(); accountWindow?.shutdown(); service?.stop()
        drafts.removeAll(); window.composer.string = ""; window.transcript.string = ""
    }

    private func bind(_ button: NSButton, _ action: Selector) { button.target = self; button.action = action }
    private func makeMenu() {
        let menu = NSMenu()
        let item = NSMenuItem(); menu.addItem(item)
        let app = NSMenu(); item.submenu = app
        app.addItem(withTitle: "About Keybase Minimal", action: #selector(about), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Keybase Minimal", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenuItem(); edit.title = "Edit"; menu.addItem(edit)
        let editMenu = NSMenu(title: "Edit"); edit.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = menu
    }

    @objc private func about() {
        let alert = NSAlert(); alert.messageText = "Keybase Minimal"
        alert.informativeText = "A native, text-only Keybase chat client.\n\nUses the official signed Keybase service for identity and encryption. This project is independent of Keybase and has not undergone a security audit.\n\nMessages and drafts stay in memory in this app. The official service manages its own storage."
        alert.runModal()
    }

    private func setupClient() throws -> KeybaseClient {
        let path = try KeybaseExecutable.locate()
        if executable != path || client == nil {
            executable = path
            client = KeybaseClient(executable: path)
            service = ServiceController(executable: path)
        }
        return client!
    }

    @objc private func connectClicked() { Task { await connect() } }
    private func connect() async {
        guard !connecting, !accountActive else { return }
        connecting = true; window.connectButton.isEnabled = false
        defer { connecting = false; window.connectButton.isEnabled = true }
        pollTask?.cancel(); loadTask?.cancel()
        clearSession()
        status("Connecting to the signed Keybase service...")
        do {
            let client = try setupClient()
            let account = try await client.account()
            try await client.prepareSecurity()
            username = account
            window.accountLabel.stringValue = "@" + ASCIIText.sanitize(account, limit: 80)
            window.newButton.isEnabled = true
            window.connectButton.title = "Reconnect"
            try await refreshInbox()
            status("Connected as @\(account). Link previews are disabled in the shared Keybase service.")
            startPolling()
        } catch { show(error) }
    }

    @objc private func startService() {
        guard !accountActive else { return }
        do {
            _ = try setupClient()
            try service?.start()
            status("Starting the official Keybase service. Connect when it is ready.")
            Task { try? await Task.sleep(nanoseconds: 2_000_000_000); await connect() }
        } catch { show(error) }
    }

    @objc private func accountClicked() {
        if accountActive { accountWindow?.showWindow(nil); return }
        guard !connecting, !sending else { return }
        let alert = NSAlert(); alert.messageText = "Your Keybase account"
        alert.informativeText = "Use the official Keybase login and provisioning flow in a native text window. Passwords and paper keys are entered directly into that process. Account changes affect the shared Keybase service."
        alert.addButton(withTitle: "Log in / provision")
        alert.addButton(withTitle: "Create account")
        alert.addButton(withTitle: "Sign out")
        alert.addButton(withTitle: "Cancel")
        let answer = alert.runModal()
        let action: AccountAction
        switch answer {
        case .alertFirstButtonReturn: action = .login
        case .alertSecondButtonReturn: action = .signup
        case .alertThirdButtonReturn: action = .logout
        default: return
        }
        do {
            _ = try setupClient()
            guard let executable else { return }
            pollTask?.cancel(); loadTask?.cancel(); clearSession()
            accountWindow?.close()
            accountActive = true
            window.connectButton.isEnabled = false
            window.startButton.isEnabled = false
            accountWindow = AccountWindowController(executable: executable, action: action) { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.accountActive = false
                    self.window.connectButton.isEnabled = true
                    self.window.startButton.isEnabled = true
                    await self.connect()
                }
            }
            accountWindow?.showWindow(nil)
        } catch { show(error) }
    }

    private func clearSession() {
        generation += 1
        username = nil; selected = nil; nextPage = nil; pageCursor = nil; drafts.removeAll()
        conversationReady = false; displayedMessages = []; lastMarked = nil
        window.conversations = []; window.sidebar.reloadData()
        window.composer.string = ""; window.composer.isEditable = false; window.sendButton.isEnabled = false
        window.newButton.isEnabled = false; window.olderButton.isEnabled = false
        window.titleLabel.stringValue = "A quieter place to talk."
        window.subtitleLabel.stringValue = "Direct messages and groups. Just text."
        window.accountLabel.stringValue = "KEYBASE / MINIMAL"
        window.setWelcomeText()
    }

    private func refreshInbox() async throws {
        guard let client, let currentAccount = username else { return }
        let account = try await client.account()
        guard account == currentAccount else {
            clearSession()
            throw UIError.accountChanged
        }
        let items = try await client.conversations()
        guard username == currentAccount else { return }
        let selectedID = selected?.id
        window.conversations = items
        window.sidebar.reloadData()
        if let row = items.firstIndex(where: { $0.id == selectedID }) {
            window.sidebar.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    private func startPolling() {
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                guard let self, !Task.isCancelled, self.username != nil else { return }
                guard self.window.isVisible, NSApp.isActive else { continue }
                do {
                    if tick % 3 == 0 { try await self.refreshInbox() }
                    if self.loadTask == nil { await self.loadPage(scrollToEnd: false) }
                    tick += 1
                } catch {
                    guard !Task.isCancelled else { return }
                    self.window.sendButton.isEnabled = false
                    self.show(error)
                }
            }
        }
    }

    private func select(_ conversation: Conversation) {
        guard selected?.id != conversation.id else { return }
        if let selected { drafts[selected.id] = window.composer.string }
        generation += 1; loadTask?.cancel()
        selected = conversation; pageCursor = nil; nextPage = nil
        conversationReady = false; displayedMessages = []
        window.composer.string = drafts[conversation.id] ?? ""
        window.composer.isEditable = true
        window.titleLabel.stringValue = conversation.displayName
        window.subtitleLabel.stringValue = "PRIVATE  /  " + (conversation.isTeam ? "TEAM CHANNEL" : "DIRECT / GROUP") + "  /  TEXT ONLY"
        window.transcript.string = "Loading messages..."
        updateSendState()
        requestPage(scrollToEnd: true)
        window.makeFirstResponder(window.composer)
    }

    private func loadPage(scrollToEnd: Bool) async {
        guard let selected, let client, let account = username else { return }
        let requestGeneration = generation
        let cursor = pageCursor
        do {
            guard try await client.account() == account else {
                clearSession(); throw UIError.accountChanged
            }
            let page = try await client.read(conversationID: selected.id, next: cursor)
            guard try await client.account() == account else {
                clearSession(); throw UIError.accountChanged
            }
            guard requestGeneration == generation, username == account, !Task.isCancelled else { return }
            nextPage = page.hasMore ? page.next : nil
            window.olderButton.isEnabled = nextPage != nil
            let atEnd = window.transcriptScroll.contentView.bounds.maxY >= window.transcript.bounds.maxY - 30
            if displayedMessages != page.messages || scrollToEnd {
                window.showMessages(page.messages, scrollToEnd: scrollToEnd || atEnd)
                displayedMessages = page.messages
            }
            conversationReady = true
            updateSendState()
            status(cursor == nil ? "Connected. Emoji are displayed and sent as :shortcodes:." : "Viewing earlier messages. Refresh returns to the latest page.")
            if cursor == nil, window.isKeyWindow, let last = page.messages.last(where: { UInt32($0.id) != nil }), lastMarked != selected.id + ":" + last.id {
                try await client.markRead(conversationID: selected.id, messageID: last.id)
                lastMarked = selected.id + ":" + last.id
            }
        } catch {
            guard requestGeneration == generation, !Task.isCancelled else { return }
            conversationReady = false
            displayedMessages = []
            window.transcript.string = "Messages are unavailable. Reconnect or refresh after resolving the error below."
            window.sendButton.isEnabled = false
            show(error)
        }
    }

    @objc private func refreshClicked() {
        guard username != nil else { connectClicked(); return }
        generation += 1; loadTask?.cancel(); pageCursor = nil
        let requestGeneration = generation
        loadTask = Task {
            do { try await refreshInbox(); await loadPage(scrollToEnd: true) } catch { show(error) }
            if generation == requestGeneration { loadTask = nil }
        }
    }

    @objc private func olderClicked() {
        guard let nextPage else { return }
        generation += 1; loadTask?.cancel(); pageCursor = nextPage
        requestPage(scrollToEnd: false)
    }

    private func requestPage(scrollToEnd: Bool) {
        let requestGeneration = generation
        loadTask = Task {
            await loadPage(scrollToEnd: scrollToEnd)
            if generation == requestGeneration { loadTask = nil }
        }
    }

    func textDidChange(_ notification: Notification) { updateSendState() }
    private func updateSendState() {
        window.sendButton.isEnabled = username != nil && selected != nil && conversationReady && !sending && (try? ASCIIText.validateOutgoing(window.composer.string)) != nil
    }

    @objc private func sendClicked() {
        guard let selected, let client, let account = username, conversationReady, !sending else { return }
        let original = window.composer.string
        let body: String
        do { body = try ASCIIText.validateOutgoing(original) } catch { show(error); return }
        sending = true; updateSendState(); status("Sending...")
        Task {
            defer { sending = false; updateSendState() }
            do {
                guard try await client.account() == account else { clearSession(); throw UIError.accountChanged }
                try await client.send(conversationID: selected.id, body: body)
                guard username == account else { return }
                if drafts[selected.id] == original { drafts[selected.id] = nil }
                if self.selected?.id == selected.id {
                    if window.composer.string == original { window.composer.string = "" }
                    generation += 1; loadTask?.cancel(); pageCursor = nil
                    await loadPage(scrollToEnd: true)
                }
                status("Sent.")
            } catch {
                status("Send was not confirmed. Check the conversation before retrying; your draft has been kept. " + error.localizedDescription)
            }
        }
    }

    @objc private func newConversation() {
        guard let client, let account = username else { return }
        let alert = NSAlert(); alert.messageText = "Open a conversation"
        alert.informativeText = "For a direct message or group, enter Keybase usernames separated by commas. For a team, enter its name and an existing channel. Team membership is required."
        let kind = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26)); kind.addItems(withTitles: ["Direct message / group", "Team channel"])
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24)); name.placeholderString = "alice,bob or team_name"
        let topic = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24)); topic.placeholderString = "Team channel (default: general)"
        let stack = NSStackView(views: [kind, name, topic]); stack.orientation = .vertical; stack.spacing = 12; stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 110)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Open"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let isTeam = kind.indexOfSelectedItem == 1
        let enteredName = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let enteredTopic = topic.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        status("Opening conversation...")
        Task {
            do {
                guard try await client.account() == account else { clearSession(); throw UIError.accountChanged }
                let conversation = try await (isTeam ? client.openTeam(name: enteredName, channel: enteredTopic.isEmpty ? "general" : enteredTopic) : client.openDirect(usernames: enteredName))
                guard username == account else { return }
                try await refreshInbox()
                if !window.conversations.contains(where: { $0.id == conversation.id }) { window.conversations.insert(conversation, at: 0); window.sidebar.reloadData() }
                if let index = window.conversations.firstIndex(where: { $0.id == conversation.id }) { window.sidebar.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
                select(conversation)
            } catch { show(error) }
        }
    }

    private func status(_ text: String) { window.statusLabel.stringValue = ASCIIText.sanitize(text, limit: 500) }
    private func show(_ error: Error) { status(error.localizedDescription) }

    private func showDemo() {
        window.conversations = [
            Conversation(id: String(repeating: "a", count: 64), name: "minimal", topic: "engineering", isTeam: true, unread: false),
            Conversation(id: String(repeating: "b", count: 64), name: "alex,sam", topic: "", isTeam: false, unread: true),
            Conversation(id: String(repeating: "c", count: 64), name: "minimal", topic: "general", isTeam: true, unread: false)
        ]
        window.sidebar.reloadData()
        window.onSelection = nil
        window.sidebar.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        window.titleLabel.stringValue = "# engineering"
        window.subtitleLabel.stringValue = "PRIVATE  /  TEAM CHANNEL  /  TEXT ONLY"
        window.accountLabel.stringValue = "@demo / OFFLINE PREVIEW"
        window.transcript.string = "Sep 24 09:41  alex\nThe smallest useful surface: direct messages, groups, and plain text.\n\nSep 24 09:42  sam\nKeep the familiar account. Leave the distractions behind. :+1:\n\nSep 24 09:43  alex\nhttps://keybase.io stays plain text here. No preview, no browser.\n\nSep 24 09:44  system\n[Attachment omitted]\n\nSep 24 09:46  sam\nLooks good. Back to the conversation. :coffee:\n"
        status("Offline design preview. No account or network access.")
        for button in [window.connectButton, window.startButton, window.loginButton, window.refreshButton] { button.isEnabled = false }
    }
}

private enum UIError: LocalizedError {
    case accountChanged
    var errorDescription: String? { "The active Keybase account changed. Reconnect to reload conversations safely." }
}
