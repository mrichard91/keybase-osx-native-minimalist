import AppKit
import XCTest
import MinimalCore
@testable import MinimalKeybase

@MainActor
private final class VisibleChatWindow: ChatWindow {
    var tailVisible = true
    var readingFocus = true
    override var hasReadingFocus: Bool { readingFocus }
    override var isTranscriptAtEnd: Bool { tailVisible }
}

private actor MemoryChat: ChatService {
    let first = Conversation(id: String(repeating: "a", count: 64), name: "alice,bob", topic: "", isTeam: false, unread: true)
    let second = Conversation(id: String(repeating: "b", count: 64), name: "alice,charlie", topic: "", isTeam: false, unread: true)
    var username = "alice"
    var inbox: [Conversation]
    var page = MessagePage(messages: [Message(id: "1", sender: "bob", body: "Verified message", timestamp: nil, isNotice: false)], next: nil, hasMore: false)
    var marks: [String] = []
    var receiptFails = false
    var prepareFails = false
    var accountFails = false
    var sent: [(conversationID: String, body: String)] = []
    var inboxAfterSend: [Conversation]?
    var inboxFailsAfterSend = false
    var inboxReads = 0
    var suspendNextInbox = false
    var inboxStarted: (@Sendable () -> Void)?
    var pendingInbox: CheckedContinuation<[Conversation], Error>?
    var capturedInbox: [Conversation] = []
    var suspendNext = false
    var readStarted: (@Sendable () -> Void)?
    var pendingRead: CheckedContinuation<MessagePage, Error>?

    init() { inbox = [first, second] }
    func account() throws -> String {
        if accountFails { throw KeybaseClientError.service("No account is signed in.") }
        return username
    }
    func prepareSecurity() throws { if prepareFails { throw KeybaseClientError.offline } }
    func conversations() async throws -> [Conversation] {
        inboxReads += 1
        if suspendNextInbox {
            suspendNextInbox = false
            capturedInbox = inbox
            return try await withCheckedThrowingContinuation { continuation in
                pendingInbox = continuation
                inboxStarted?()
            }
        }
        if !sent.isEmpty && inboxFailsAfterSend { throw KeybaseClientError.offline }
        return inbox
    }
    func read(conversationID: String, next: String?) async throws -> MessagePage {
        if suspendNext {
            suspendNext = false
            return try await withCheckedThrowingContinuation { continuation in
                pendingRead = continuation
                readStarted?()
            }
        }
        return page
    }
    func markRead(conversationID: String, messageID: String) throws {
        if receiptFails { throw KeybaseClientError.offline }
        marks.append(conversationID + ":" + messageID)
    }
    func send(conversationID: String, body: String) {
        sent.append((conversationID, body))
        if let inboxAfterSend { inbox = inboxAfterSend }
    }
    func openDirect(usernames: String) -> Conversation { first }
    func openTeam(name: String, channel: String) -> Conversation { first }
    func changeAccount(_ name: String) { username = name }
    func setInbox(_ value: [Conversation]) { inbox = value }
    func configureSendRefresh(inbox: [Conversation]? = nil, fails: Bool = false) {
        inboxAfterSend = inbox
        inboxFailsAfterSend = fails
    }
    func pauseInbox(_ notify: @escaping @Sendable () -> Void) { suspendNextInbox = true; inboxStarted = notify }
    func finishInbox(failing: Bool = false) {
        if failing { pendingInbox?.resume(throwing: KeybaseClientError.offline) }
        else { pendingInbox?.resume(returning: capturedInbox) }
        pendingInbox = nil
        capturedInbox = []
    }
    func setPage(_ value: MessagePage) { page = value }
    func failReceipts() { receiptFails = true }
    func setPrepareFailure(_ fails: Bool) { prepareFails = fails }
    func setAccountFailure(_ fails: Bool) { accountFails = fails }
    func pauseRead(_ notify: @escaping @Sendable () -> Void) { suspendNext = true; readStarted = notify }
    func finishRead() { pendingRead?.resume(returning: page); pendingRead = nil }
}

@MainActor
final class AppControllerTests: XCTestCase {
    private func context(backend: BackendPresentation = .bundled) -> (VisibleChatWindow, MemoryChat, AppController) {
        _ = NSApplication.shared
        let window = VisibleChatWindow()
        let chat = MemoryChat()
        let controller = AppController(window: window, client: chat, backend: backend)
        return (window, chat, controller)
    }

    func testCancelledReadCannotClearNewAccountSession() async throws {
        let (window, chat, controller) = context()
        defer { controller.clearSession(); window.close() }
        await controller.connect()
        controller.select(chat.first, load: false)
        let started = expectation(description: "Old read is awaiting its reply")
        await chat.pauseRead { started.fulfill() }
        let stale = Task { await controller.loadPage(scrollToEnd: true) }
        await fulfillment(of: [started], timeout: 2)
        controller.clearSession()
        await chat.changeAccount("bob")
        await controller.connect()
        await chat.finishRead()
        await stale.value
        XCTAssertEqual(window.accountLabel.stringValue, "@bob")
        XCTAssertEqual(window.conversations.count, 2)
        XCTAssertFalse(window.composer.isEditable)
    }

    func testUnprovisionedBundledAccountLeavesSetupAvailableAndChatDisabled() async {
        let (window, chat, controller) = context()
        defer { controller.clearSession(); window.close() }
        await chat.setAccountFailure(true)
        await controller.connect()
        XCTAssertFalse(window.composer.isEditable)
        XCTAssertFalse(window.sendButton.isEnabled)
        XCTAssertTrue(window.startButton.isEnabled)
        XCTAssertTrue(window.loginButton.isEnabled)
        XCTAssertTrue(window.connectButton.isEnabled)
        XCTAssertTrue(window.transcript.string.contains("new device"))
        XCTAssertTrue(window.statusLabel.stringValue.contains("Account..."))
        XCTAssertEqual(window.accountLabel.stringValue, "KEYBASE / MINIMAL")
    }

    func testInstalledCompatibilityAccountIsVisiblyDistinguished() async {
        let (window, _, controller) = context(backend: .compatibility)
        defer { controller.clearSession(); window.close() }
        await controller.connect()
        XCTAssertEqual(window.accountLabel.stringValue, "@alice / COMPATIBILITY")
        XCTAssertTrue(window.statusLabel.stringValue.contains("shared installed Keybase service"))
        XCTAssertTrue(window.transcript.string.contains("broader feature set"))
    }

    func testUnavailableConversationClosesEditorAndKeepsItsDraft() async throws {
        let (window, chat, controller) = context()
        defer { controller.clearSession(); window.close() }
        await controller.connect()
        let first = chat.first
        let second = chat.second
        controller.select(first, load: false)
        window.composer.insertText("unsent private draft", replacementRange: NSRange(location: 0, length: 0))
        await chat.setInbox([second])
        try await controller.refreshInbox()
        XCTAssertFalse(window.composer.isEditable)
        XCTAssertFalse(window.sendButton.isEnabled)
        XCTAssertEqual(window.sidebar.selectedRow, -1)
        XCTAssertEqual(window.composer.string, "")
        await chat.setInbox([first, second])
        try await controller.refreshInbox()
        controller.select(first, load: false)
        XCTAssertEqual(window.composer.string, "unsent private draft")
        XCTAssertFalse(window.composer.undoManager?.canUndo == true)
    }

    func testReconnectKeepsDraftAcrossFailureOnlyForSameAccount() async throws {
        let (window, chat, controller) = context()
        defer { controller.clearSession(); window.close() }
        await controller.connect()
        controller.select(chat.first, load: false)
        window.composer.insertText("keep this draft", replacementRange: NSRange(location: 0, length: 0))
        await chat.setPrepareFailure(true)
        await controller.connect()
        XCTAssertFalse(window.composer.isEditable)
        XCTAssertEqual(window.composer.string, "")
        await chat.setPrepareFailure(false)
        await controller.connect()
        XCTAssertEqual(window.accountLabel.stringValue, "@alice")
        XCTAssertEqual(window.composer.string, "keep this draft")
        XCTAssertFalse(window.composer.undoManager?.canUndo == true)
        await chat.changeAccount("bob")
        await controller.connect()
        controller.select(chat.first, load: false)
        XCTAssertEqual(window.accountLabel.stringValue, "@bob")
        XCTAssertEqual(window.composer.string, "")
    }

    func testSidebarRefreshKeepsIdentityWithoutSelectingIntermediateRow() async throws {
        let (window, chat, controller) = context()
        defer { controller.clearSession(); window.close() }
        let first = withRecency(chat.first, 20)
        let second = withRecency(chat.second, 10)
        var selections: [String] = []
        window.onSelection = { selections.append($0.id) }
        window.replaceConversations([first, second], selectedID: first.id)
        window.replaceConversations([withRecency(second, 30), first], selectedID: first.id)
        XCTAssertEqual(window.sidebar.selectedRow, 1)
        XCTAssertTrue(selections.isEmpty)
    }

    func testConfirmedSendRefreshesRecencyAndPreservesSelectionAndOtherDraft() async throws {
        let (window, chat, controller) = context()
        defer { controller.clearSession(); window.close() }
        let first = withRecency(chat.first, 10)
        let second = withRecency(chat.second, 20)
        await chat.setInbox([first, second])
        await chat.configureSendRefresh(inbox: [second, withRecency(first, 30)])
        await controller.connect()
        XCTAssertEqual(window.conversations.map(\.id), [second.id, first.id])
        controller.select(second, load: false)
        window.composer.replaceDraft("Other conversation's unsent draft")
        controller.select(first, load: false)
        await controller.loadPage(scrollToEnd: true)
        window.composer.replaceDraft("Inert outgoing fixture")
        controller.sendClicked()
        try await waitForSendCompletion(window)
        XCTAssertEqual(window.conversations.map(\.id), [first.id, second.id])
        XCTAssertEqual(window.sidebar.selectedRow, 0)
        XCTAssertEqual(window.titleLabel.stringValue, first.displayName)
        XCTAssertEqual(window.composer.string, "")
        XCTAssertEqual(window.statusLabel.stringValue, "Sent to " + first.displayName + ".")
        let sends = await chat.sent
        let inboxReads = await chat.inboxReads
        XCTAssertEqual(sends.count, 1)
        XCTAssertEqual(sends.first?.conversationID, first.id)
        XCTAssertEqual(inboxReads, 2)
        controller.select(second, load: false)
        XCTAssertEqual(window.composer.string, "Other conversation's unsent draft")
    }

    func testInboxRefreshFailureKeepsSendConfirmedAndClearsSentDraft() async throws {
        let (window, chat, controller) = context()
        defer { controller.clearSession(); window.close() }
        await controller.connect()
        controller.select(chat.first, load: false)
        await controller.loadPage(scrollToEnd: true)
        await chat.configureSendRefresh(fails: true)
        window.composer.replaceDraft("Confirmed inert fixture")
        controller.sendClicked()
        try await waitForSendCompletion(window)
        XCTAssertTrue(window.statusLabel.stringValue.hasPrefix("Sent to " + chat.first.displayName + "."))
        XCTAssertTrue(window.statusLabel.stringValue.contains("Inbox refresh failed"))
        XCTAssertFalse(window.statusLabel.stringValue.contains("Send was not confirmed"))
        XCTAssertFalse(window.statusLabel.stringValue.contains("draft has been kept"))
        XCTAssertEqual(window.composer.string, "")
        XCTAssertEqual(window.conversations.count, 2)
        let sends = await chat.sent
        let inboxReads = await chat.inboxReads
        XCTAssertEqual(sends.count, 1)
        XCTAssertEqual(inboxReads, 2)
        controller.select(chat.second, load: false)
        controller.select(chat.first, load: false)
        XCTAssertEqual(window.composer.string, "")
    }

    func testOlderInboxCannotOverwriteConfirmedSendOrderOrNewDraft() async throws {
        let (window, chat, controller) = context()
        defer { controller.clearSession(); window.close() }
        let first = withRecency(chat.first, 10)
        let second = withRecency(chat.second, 20)
        await chat.setInbox([first, second])
        await controller.connect()
        controller.select(first, load: false)
        await controller.loadPage(scrollToEnd: true)
        let started = expectation(description: "Older inbox captured before send")
        await chat.pauseInbox { started.fulfill() }
        let stale = Task { try await controller.refreshInbox() }
        await fulfillment(of: [started], timeout: 2)
        await chat.configureSendRefresh(inbox: [second, withRecency(first, 30)])
        window.composer.replaceDraft("Inert outgoing fixture")
        controller.sendClicked()
        try await waitForSendCompletion(window)
        window.composer.replaceDraft("New unsent draft after confirmation")
        let confirmation = window.statusLabel.stringValue
        await chat.finishInbox()
        try await stale.value
        XCTAssertEqual(window.conversations.map(\.id), [first.id, second.id])
        XCTAssertEqual(window.conversations.first?.lastMessageAt, Date(timeIntervalSince1970: 30))
        XCTAssertEqual(window.sidebar.selectedRow, 0)
        XCTAssertEqual(window.titleLabel.stringValue, first.displayName)
        XCTAssertEqual(window.composer.string, "New unsent draft after confirmation")
        XCTAssertEqual(window.statusLabel.stringValue, confirmation)
        let sends = await chat.sent
        XCTAssertEqual(sends.count, 1)
    }

    func testSupersededInboxErrorIsDiscardedAfterNewerSuccess() async throws {
        let (window, chat, controller) = context()
        defer { controller.clearSession(); window.close() }
        await controller.connect()
        let started = expectation(description: "Older inbox suspended")
        await chat.pauseInbox { started.fulfill() }
        let stale = Task { try await controller.refreshInbox() }
        await fulfillment(of: [started], timeout: 2)
        try await controller.refreshInbox()
        await chat.finishInbox(failing: true)
        try await stale.value
        XCTAssertEqual(window.conversations.count, 2)
        XCTAssertEqual(window.accountLabel.stringValue, "@alice")
    }

    private func withRecency(_ conversation: Conversation, _ seconds: TimeInterval) -> Conversation {
        Conversation(id: conversation.id, name: conversation.name, topic: conversation.topic,
                     isTeam: conversation.isTeam, unread: conversation.unread,
                     lastMessageAt: Date(timeIntervalSince1970: seconds))
    }

    private func waitForSendCompletion(_ window: ChatWindow) async throws {
        for _ in 0..<200 {
            if window.statusLabel.stringValue.hasPrefix("Sent to ") && window.connectButton.isEnabled { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Fake-service send did not finish")
    }

    func testReadReceiptRequiresVisibleTailAndFailureKeepsVerifiedText() async throws {
        let (window, chat, controller) = context()
        defer { controller.clearSession(); window.close() }
        await controller.connect()
        controller.select(chat.first, load: false)
        window.tailVisible = false
        await controller.loadPage(scrollToEnd: false)
        let initiallyMarked = await chat.marks
        XCTAssertTrue(initiallyMarked.isEmpty)
        window.tailVisible = true
        window.readingFocus = false
        await controller.loadPage(scrollToEnd: false)
        let backgroundMarks = await chat.marks
        XCTAssertTrue(backgroundMarks.isEmpty)
        window.readingFocus = true
        await controller.loadPage(scrollToEnd: false)
        let visibleMarks = await chat.marks
        XCTAssertEqual(visibleMarks.count, 1)
        await chat.setPage(MessagePage(messages: [Message(id: "2", sender: "bob", body: "Still verified", timestamp: nil, isNotice: false)], next: nil, hasMore: false))
        await chat.failReceipts()
        await controller.loadPage(scrollToEnd: false)
        XCTAssertTrue(window.transcript.string.contains("Still verified"))
        XCTAssertTrue(window.statusLabel.stringValue.contains("read receipt"))
        XCTAssertFalse(window.sendButton.isEnabled)
    }
}
