import AppKit
import MinimalCore

@MainActor
class ChatWindow: NSWindow, NSTableViewDataSource, NSTableViewDelegate {
    let sidebar = NSTableView()
    let transcript = PlainTextView()
    let composer = PlainTextView()
    let transcriptScroll = NSScrollView()
    let titleLabel = NSTextField(labelWithString: "A quieter place to talk.")
    let subtitleLabel = NSTextField(labelWithString: "Direct messages and groups. Just text.")
    let statusLabel = NSTextField(labelWithString: "Start service, set up your account, then connect.")
    let accountLabel = NSTextField(labelWithString: "KEYBASE / MINIMAL")
    let hintLabel = NSTextField(labelWithString: "Return to send  /  Shift-Return for a new line  /  ASCII only")
    let sendButton = NSButton(title: "Send", target: nil, action: nil)
    let olderButton = NSButton(title: "Earlier messages", target: nil, action: nil)
    let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    let newButton = NSButton(title: "+ Conversation", target: nil, action: nil)
    let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    let startButton = NSButton(title: "Start service", target: nil, action: nil)
    let loginButton = NSButton(title: "Account...", target: nil, action: nil)
    var conversations: [Conversation] = []
    var onSelection: ((Conversation) -> Void)?
    private var restoringSelection = false

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        title = "Keybase Minimal"
        minSize = NSSize(width: 840, height: 540)
        isReleasedWhenClosed = false
        titlebarAppearsTransparent = true
        center()
        let root = NSView()
        contentView = root
        let sidebarContainer = NSView()
        sidebarContainer.wantsLayer = true
        sidebarContainer.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let chatContainer = NSView()
        let rule = NSBox(); rule.boxType = .separator
        for v in [sidebarContainer, rule, chatContainer] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            sidebarContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor), sidebarContainer.topAnchor.constraint(equalTo: root.topAnchor),
            sidebarContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor), sidebarContainer.widthAnchor.constraint(equalToConstant: 248),
            rule.leadingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor), rule.widthAnchor.constraint(equalToConstant: 1),
            rule.topAnchor.constraint(equalTo: root.topAnchor), rule.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            chatContainer.leadingAnchor.constraint(equalTo: rule.trailingAnchor), chatContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            chatContainer.topAnchor.constraint(equalTo: root.topAnchor), chatContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        accountLabel.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        accountLabel.textColor = .secondaryLabelColor
        accountLabel.lineBreakMode = .byTruncatingMiddle
        sidebar.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("conversation")))
        sidebar.headerView = nil
        sidebar.delegate = self; sidebar.dataSource = self
        sidebar.rowHeight = 54
        sidebar.intercellSpacing = NSSize(width: 0, height: 2)
        sidebar.backgroundColor = .clear
        sidebar.style = .sourceList
        let sidebarScroll = NSScrollView()
        sidebarScroll.documentView = sidebar
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.drawsBackground = false
        let sidebarFooter = NSStackView(views: [connectButton, startButton, loginButton])
        sidebarFooter.orientation = .vertical
        sidebarFooter.alignment = .leading
        sidebarFooter.spacing = 8
        let sidebarStack = NSStackView(views: [accountLabel, newButton, sidebarScroll, sidebarFooter])
        sidebarStack.orientation = .vertical; sidebarStack.alignment = .leading; sidebarStack.spacing = 18
        install(sidebarStack, in: sidebarContainer, inset: 18)
        sidebarScroll.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor).isActive = true
        sidebarScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        titleLabel.font = .systemFont(ofSize: 23, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        let headings = NSStackView(views: [titleLabel, subtitleLabel]); headings.orientation = .vertical; headings.alignment = .leading; headings.spacing = 5
        let spacer = NSView()
        let header = NSStackView(views: [headings, spacer, refreshButton]); header.orientation = .horizontal
        transcript.configurePlainText(editable: false)
        transcript.backgroundColor = .textBackgroundColor
        transcriptScroll.documentView = transcript
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.borderType = .noBorder
        composer.configurePlainText(editable: true)
        composer.backgroundColor = .controlBackgroundColor
        let composerScroll = NSScrollView()
        composerScroll.documentView = composer; composerScroll.hasVerticalScroller = true; composerScroll.borderType = .bezelBorder
        composerScroll.heightAnchor.constraint(equalToConstant: 94).isActive = true
        hintLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular); hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail
        sendButton.bezelStyle = .rounded
        let composerFooter = NSStackView(views: [hintLabel, NSView(), sendButton]); composerFooter.orientation = .horizontal
        statusLabel.font = .systemFont(ofSize: 11); statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.lineBreakMode = .byTruncatingTail
        let topRule = NSBox(); topRule.boxType = .separator
        let chatStack = NSStackView(views: [header, topRule, olderButton, transcriptScroll, composerScroll, composerFooter, statusLabel])
        chatStack.orientation = .vertical; chatStack.alignment = .leading; chatStack.spacing = 12
        install(chatStack, in: chatContainer, inset: 24)
        for view in [header, topRule, transcriptScroll, composerScroll, composerFooter, statusLabel] { view.widthAnchor.constraint(equalTo: chatStack.widthAnchor).isActive = true }
        transcriptScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        sendButton.isEnabled = false; olderButton.isEnabled = false; newButton.isEnabled = false
        composer.isEditable = false
        setWelcomeText()
    }

    private func install(_ stack: NSStackView, in parent: NSView, inset: CGFloat) {
        stack.translatesAutoresizingMaskIntoConstraints = false; parent.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            stack.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            stack.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)])
    }

    func setWelcomeText(backend: BackendPresentation = .unselected) {
        transcript.string = "YOUR CONVERSATIONS, WITHOUT THE CLUTTER\n\n" + backend.setupSteps + "\n\nMessages are displayed as plain ASCII text. Emoji appear as :shortcodes:. Attachments and other non-text messages are replaced with notices.\n\nNo previews, media, or clickable links in this window."
    }

    func numberOfRows(in tableView: NSTableView) -> Int { conversations.count }

    func replaceConversations(_ items: [Conversation], selectedID: String?) {
        // Reloading a sorted inbox can move a selected row. Restore identity
        // without treating an intermediate row index as a user selection.
        restoringSelection = true
        defer { restoringSelection = false }
        conversations = items
        sidebar.reloadData()
        if let row = items.firstIndex(where: { $0.id == selectedID }) {
            sidebar.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else { sidebar.deselectAll(nil) }
    }

    var isTranscriptAtEnd: Bool {
        transcriptScroll.contentView.bounds.maxY >= transcript.bounds.maxY - 30
    }

    var hasReadingFocus: Bool { isVisible && isKeyWindow && NSApp.isActive }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard conversations.indices.contains(row) else { return nil }
        let conversation = conversations[row]
        let heading = NSTextField(labelWithString: (conversation.unread ? "* " : "") + conversation.displayName)
        heading.font = .systemFont(ofSize: 13, weight: conversation.unread ? .semibold : .medium)
        heading.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: conversation.isTeam ? "TEAM CHANNEL" : "DIRECT / GROUP")
        detail.font = .monospacedSystemFont(ofSize: 9, weight: .regular); detail.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [heading, detail]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 4
        return stack
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !restoringSelection, conversations.indices.contains(sidebar.selectedRow) else { return }
        onSelection?(conversations[sidebar.selectedRow])
    }

    func showMessages(_ messages: [Message], scrollToEnd: Bool) {
        let oldOrigin = transcriptScroll.contentView.bounds.origin
        let output = NSMutableAttributedString()
        let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4
        let dateFormatter = DateFormatter(); dateFormatter.locale = Locale(identifier: "en_US_POSIX"); dateFormatter.dateFormat = "MMM dd HH:mm"
        for message in messages {
            let date = message.timestamp.map { dateFormatter.string(from: $0) } ?? "--:--"
            let header = "\(date)  \(ASCIIText.sanitize(message.sender, limit: 120))\n"
            output.append(NSAttributedString(string: header, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]))
            output.append(NSAttributedString(string: ASCIIText.sanitize(message.body) + "\n\n", attributes: [.font: mono, .foregroundColor: message.isNotice ? NSColor.secondaryLabelColor : NSColor.labelColor, .paragraphStyle: paragraph]))
        }
        if messages.isEmpty { output.append(NSAttributedString(string: "No messages yet. Say hello.", attributes: [.font: mono, .foregroundColor: NSColor.secondaryLabelColor])) }
        transcript.textStorage?.setAttributedString(output)
        if scrollToEnd { transcript.scrollToEndOfDocument(nil) }
        else { transcriptScroll.contentView.scroll(to: oldOrigin); transcriptScroll.reflectScrolledClipView(transcriptScroll.contentView) }
    }
}
