import AppKit
import MinimalCore

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSTextViewDelegate {
    private var window: ChatWindow!
    private var client: (any ChatService)?
    private var injectedClient: (any ChatService)?
    private var backend = BackendPresentation.unselected
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
    private var sessionRevision = 0
    private var sending = false
    private var connecting = false
    private var accountActive = false
    private var conversationReady = false
    private var displayedMessages: [Message] = []
    private var lastMarked: String?
    private var drafts: [String: String] = [:]
    private struct SavedDrafts {
        let account: String
        let drafts: [String: String]
        let selectedID: String?
    }
    private var disconnectedDrafts: SavedDrafts?

    override init() { super.init() }

    /// In-memory UI harness. Does not locate, start, or inspect a real service.
    init(window: ChatWindow, client: any ChatService, backend: BackendPresentation = .bundled) {
        self.window = window
        self.client = client
        self.injectedClient = client
        self.backend = backend
        super.init()
        bindWindow()
        window.setWelcomeText(backend: backend)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeMenu()
        window = ChatWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        bindWindow()
        if CommandLine.arguments.contains("--demo") { showDemo() }
        else {
            // Only locate and validate the binary here. Account and service
            // operations wait for the user's Connect/Start service/Account action.
            do {
                _ = try setupClient()
                window.setWelcomeText(backend: backend)
                window.accountLabel.stringValue = backend.accountHeading
            } catch { show(error) }
        }
    }

    private func bindWindow() {
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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        pollTask?.cancel(); loadTask?.cancel(); accountWindow?.shutdown(); service?.stop()
        ProcessRunner.shutdownAll()
        disconnectedDrafts = nil
        drafts.removeAll(); window.composer.replaceDraft(""); window.transcript.string = ""
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
        alert.informativeText = backend.aboutExplanation
        alert.runModal()
    }

    private func setupClient() throws -> any ChatService {
        if let injectedClient { return injectedClient }
        let path = try KeybaseExecutable.locate()
        backend = KeybaseExecutable.isBundled(path) ? .bundled : .compatibility
        if executable != path || client == nil {
            executable = path
            client = KeybaseClient(executable: path)
            service = ServiceController(executable: path)
        }
        return client!
    }

    @objc private func connectClicked() { Task { await connect() } }
    func connect() async {
        guard !connecting, !accountActive, !sending else { return }
        connecting = true; window.connectButton.isEnabled = false
        defer { connecting = false; window.connectButton.isEnabled = true }
        let recovery: SavedDrafts?
        if let username {
            var saved = drafts
            if let selected { saved[selected.id] = window.composer.string }
            recovery = SavedDrafts(account: username, drafts: saved, selectedID: selected?.id)
        } else { recovery = disconnectedDrafts }
        pollTask?.cancel(); loadTask?.cancel()
        clearSession()
        disconnectedDrafts = recovery
        let revision = sessionRevision
        var checkingAccount = false
        status(backend.connectionMessage)
        do {
            let client = try setupClient()
            window.setWelcomeText(backend: backend)
            window.accountLabel.stringValue = backend.accountHeading
            status(backend.connectionMessage)
            checkingAccount = true
            let account = try await client.account()
            guard revision == sessionRevision, !Task.isCancelled else { return }
            checkingAccount = false
            if recovery?.account != account { disconnectedDrafts = nil }
            try await client.prepareSecurity()
            guard revision == sessionRevision, !Task.isCancelled else { return }
            username = account
            if recovery?.account == account { drafts = recovery?.drafts ?? [:] }
            window.accountLabel.stringValue = "@" + ASCIIText.sanitize(account, limit: 80) + (backend == .compatibility ? " / COMPATIBILITY" : "")
            window.newButton.isEnabled = true
            window.connectButton.title = "Reconnect"
            try await refreshInbox()
            guard isCurrentSession(account, revision: revision) else { return }
            if recovery?.account == account, let selectedID = recovery?.selectedID,
               let conversation = window.conversations.first(where: { $0.id == selectedID }) {
                select(conversation)
            }
            disconnectedDrafts = nil
            status(backend.connectedMessage(account: account))
            startPolling()
        } catch {
            guard revision == sessionRevision, !Task.isCancelled else { return }
            let retained = disconnectedDrafts
            clearSession()
            disconnectedDrafts = retained
            if checkingAccount, backend != .unselected, !(error is KeybaseExecutableError) {
                window.titleLabel.stringValue = "Set up your Keybase account"
                status("Not connected. Start service if needed, then choose Account... to log in or provision. " + error.localizedDescription)
            } else { show(error) }
        }
    }

    @objc private func startService() {
        guard !accountActive else { return }
        do {
            _ = try setupClient()
            try service?.start()
            status(backend == .bundled
                   ? "Starting this app's minimal service. Choose Account... to provision your existing account, or Connect if already set up."
                   : "Starting the installed Keybase service. Connect when it is ready, or choose Account... to log in.")
            Task { try? await Task.sleep(nanoseconds: 2_000_000_000); await connect() }
        } catch { show(error) }
    }

    @objc private func accountClicked() {
        if accountActive { accountWindow?.showWindow(nil); return }
        guard !connecting, !sending else { return }
        let accountExecutable: URL
        do {
            _ = try setupClient()
            guard let executable else { return }
            accountExecutable = executable
        } catch { show(error); return }
        let alert = NSAlert(); alert.messageText = "Your Keybase account"
        alert.informativeText = backend.accountExplanation
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
            // Keep the storage/trust mode described in the dialog. A changed
            // installation must fail validation, never switch account backends.
            try KeybaseExecutable.validate(accountExecutable)
            pollTask?.cancel(); loadTask?.cancel(); clearSession()
            accountWindow?.close()
            accountActive = true
            window.connectButton.isEnabled = false
            window.startButton.isEnabled = false
            accountWindow = AccountWindowController(executable: accountExecutable, action: action) { [weak self] in
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

    func clearSession() {
        pollTask?.cancel(); loadTask?.cancel(); pollTask = nil; loadTask = nil
        sessionRevision += 1
        generation += 1
        disconnectedDrafts = nil
        username = nil; selected = nil; nextPage = nil; pageCursor = nil; drafts.removeAll()
        conversationReady = false; displayedMessages = []; lastMarked = nil
        window.replaceConversations([], selectedID: nil)
        window.composer.replaceDraft(""); window.composer.isEditable = false; window.sendButton.isEnabled = false
        window.newButton.isEnabled = false; window.olderButton.isEnabled = false
        window.titleLabel.stringValue = "A quieter place to talk."
        window.subtitleLabel.stringValue = "Direct messages and groups. Just text."
        window.accountLabel.stringValue = backend.accountHeading
        window.setWelcomeText(backend: backend)
    }

    private func isCurrentSession(_ account: String, revision: Int) -> Bool {
        revision == sessionRevision && username == account && !Task.isCancelled
    }

    func refreshInbox() async throws {
        guard let client, let currentAccount = username else { return }
        let revision = sessionRevision
        let account = try await client.account()
        guard isCurrentSession(currentAccount, revision: revision) else { return }
        guard account == currentAccount else {
            clearSession()
            show(UIError.accountChanged)
            throw UIError.accountChanged
        }
        let items = try await client.conversations()
        guard isCurrentSession(currentAccount, revision: revision) else { return }
        let after = try await client.account()
        guard isCurrentSession(currentAccount, revision: revision) else { return }
        guard after == currentAccount else {
            clearSession()
            show(UIError.accountChanged)
            throw UIError.accountChanged
        }
        let selectedID = selected?.id
        window.replaceConversations(items, selectedID: selectedID)
        if let selectedID {
            if let current = items.first(where: { $0.id == selectedID }) {
                selected = current
                window.titleLabel.stringValue = current.displayName
            } else {
                clearConversation()
                status("The selected conversation is no longer available. Its draft is kept until you disconnect.")
            }
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

    func select(_ conversation: Conversation, load: Bool = true) {
        guard selected?.id != conversation.id else { return }
        if let selected { drafts[selected.id] = window.composer.string }
        generation += 1; loadTask?.cancel()
        selected = conversation; pageCursor = nil; nextPage = nil
        conversationReady = false; displayedMessages = []
        window.composer.replaceDraft(drafts[conversation.id] ?? "")
        window.composer.isEditable = true
        window.titleLabel.stringValue = conversation.displayName
        window.subtitleLabel.stringValue = "PRIVATE  /  " + (conversation.isTeam ? "TEAM CHANNEL" : "DIRECT / GROUP") + "  /  TEXT ONLY"
        window.transcript.string = "Loading messages..."
        updateSendState()
        if load { requestPage(scrollToEnd: true) }
        window.makeFirstResponder(window.composer)
    }

    private func clearConversation() {
        if let selected { drafts[selected.id] = window.composer.string }
        generation += 1; loadTask?.cancel(); loadTask = nil
        selected = nil; pageCursor = nil; nextPage = nil
        conversationReady = false; displayedMessages = []; lastMarked = nil
        window.composer.replaceDraft(""); window.composer.isEditable = false
        window.sendButton.isEnabled = false; window.olderButton.isEnabled = false
        window.titleLabel.stringValue = "Choose a conversation"
        window.subtitleLabel.stringValue = "Direct messages and groups. Just text."
        window.transcript.string = "Choose an available conversation from the sidebar."
    }

    func loadPage(scrollToEnd: Bool) async {
        guard let selected, let client, let account = username else { return }
        let requestGeneration = generation
        let revision = sessionRevision
        let cursor = pageCursor
        do {
            let before = try await client.account()
            guard isCurrentSession(account, revision: revision), requestGeneration == generation else { return }
            guard before == account else {
                clearSession(); show(UIError.accountChanged); return
            }
            let page = try await client.read(conversationID: selected.id, next: cursor)
            guard isCurrentSession(account, revision: revision), requestGeneration == generation else { return }
            let after = try await client.account()
            guard isCurrentSession(account, revision: revision), requestGeneration == generation else { return }
            guard after == account else {
                clearSession(); show(UIError.accountChanged); return
            }
            nextPage = page.hasMore ? page.next : nil
            window.olderButton.isEnabled = nextPage != nil
            let atEnd = window.isTranscriptAtEnd
            if displayedMessages != page.messages || scrollToEnd {
                window.showMessages(page.messages, scrollToEnd: scrollToEnd || atEnd)
                displayedMessages = page.messages
            }
            conversationReady = true
            updateSendState()
            status(cursor == nil ? "Connected. Emoji are displayed and sent as :shortcodes:." : "Viewing earlier messages. Refresh returns to the latest page.")
            if cursor == nil, window.hasReadingFocus, scrollToEnd || atEnd,
               let last = page.messages.last(where: { UInt32($0.id) != nil }), lastMarked != selected.id + ":" + last.id {
                do {
                    try await client.markRead(conversationID: selected.id, messageID: last.id)
                    guard isCurrentSession(account, revision: revision), requestGeneration == generation else { return }
                    lastMarked = selected.id + ":" + last.id
                } catch {
                    guard isCurrentSession(account, revision: revision), requestGeneration == generation else { return }
                    // A receipt failure cannot make already verified text unreadable.
                    conversationReady = false; updateSendState()
                    status("Messages loaded, but the read receipt was not confirmed. Refresh before sending. " + error.localizedDescription)
                }
            }
        } catch {
            guard isCurrentSession(account, revision: revision), requestGeneration == generation else { return }
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
            do {
                try await refreshInbox()
                guard generation == requestGeneration, !Task.isCancelled else { return }
                await loadPage(scrollToEnd: true)
            } catch {
                if generation == requestGeneration, !Task.isCancelled { show(error) }
            }
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
        window.connectButton.isEnabled = !connecting && !accountActive && !sending
    }

    @objc func sendClicked() {
        guard let selected, let client, let account = username, conversationReady, !sending else { return }
        let original = window.composer.string
        let revision = sessionRevision
        let body: String
        do { body = try ASCIIText.validateOutgoing(original) } catch { show(error); return }
        sending = true; updateSendState(); status("Sending...")
        Task {
            defer { sending = false; updateSendState() }
            do {
                let active = try await client.account()
                guard isCurrentSession(account, revision: revision) else { return }
                guard active == account else { clearSession(); show(UIError.accountChanged); return }
                try await client.send(conversationID: selected.id, body: body)
                guard isCurrentSession(account, revision: revision) else { return }
                if drafts[selected.id] == original { drafts[selected.id] = nil }
                if self.selected?.id == selected.id {
                    if window.composer.string == original { window.composer.replaceDraft("") }
                    generation += 1; loadTask?.cancel(); pageCursor = nil
                    await loadPage(scrollToEnd: true)
                }
                guard isCurrentSession(account, revision: revision) else { return }
                status("Sent to " + selected.displayName + ".")
            } catch {
                guard isCurrentSession(account, revision: revision) else { return }
                status("Send was not confirmed. Check the conversation before retrying; your draft has been kept. " + error.localizedDescription)
            }
        }
    }

    @objc private func newConversation() {
        guard let client, let account = username else { return }
        let revision = sessionRevision
        let selectionGeneration = generation
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
                let active = try await client.account()
                guard isCurrentSession(account, revision: revision) else { return }
                guard active == account else { clearSession(); show(UIError.accountChanged); return }
                let conversation = try await (isTeam ? client.openTeam(name: enteredName, channel: enteredTopic.isEmpty ? "general" : enteredTopic) : client.openDirect(usernames: enteredName))
                guard isCurrentSession(account, revision: revision) else { return }
                try await refreshInbox()
                guard isCurrentSession(account, revision: revision), selectionGeneration == generation else { return }
                if !window.conversations.contains(where: { $0.id == conversation.id }) {
                    window.replaceConversations([conversation] + window.conversations, selectedID: self.selected?.id)
                }
                if let index = window.conversations.firstIndex(where: { $0.id == conversation.id }) { window.sidebar.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
                select(conversation)
            } catch {
                if isCurrentSession(account, revision: revision) { show(error) }
            }
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
        window.transcript.string = "2026-09-24 09:41  alex\nThe smallest useful surface: direct messages, groups, and plain text.\n\n2026-09-24 09:42  sam\nKeep the familiar account. Leave the distractions behind. :+1:\n\n2026-09-24 09:43  alex\nhttps://keybase.io stays plain text here. No preview, no browser.\n\n2026-09-24 09:44  system\n[Attachment omitted]\n\n2026-09-24 09:46  sam\nLooks good. Back to the conversation. :coffee:\n"
        status("Offline design preview. No account or network access.")
        for button in [window.connectButton, window.startButton, window.loginButton, window.refreshButton] { button.isEnabled = false }
    }
}

private enum UIError: LocalizedError {
    case accountChanged
    var errorDescription: String? { "The active Keybase account changed. Reconnect to reload conversations safely." }
}
