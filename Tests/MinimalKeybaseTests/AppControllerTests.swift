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
    var suspendNext = false
    var readStarted: (@Sendable () -> Void)?
    var pendingRead: CheckedContinuation<MessagePage, Error>?

    init() { inbox = [first, second] }
    func account() throws -> String {
        if accountFails { throw KeybaseClientError.service("No account is signed in.") }
        return username
    }
    func prepareSecurity() throws { if prepareFails { throw KeybaseClientError.offline } }
    func conversations() -> [Conversation] { inbox }
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
    func send(conversationID: String, body: String) {}
    func openDirect(usernames: String) -> Conversation { first }
    func openTeam(name: String, channel: String) -> Conversation { first }
    func changeAccount(_ name: String) { username = name }
    func setInbox(_ value: [Conversation]) { inbox = value }
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
        let first = chat.first
        let second = chat.second
        var selections: [String] = []
        window.onSelection = { selections.append($0.id) }
        window.replaceConversations([first, second], selectedID: first.id)
        window.replaceConversations([second, first], selectedID: first.id)
        XCTAssertEqual(window.sidebar.selectedRow, 1)
        XCTAssertTrue(selections.isEmpty)
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
