import AppKit
import XCTest
import MinimalCore
@testable import MinimalKeybase

@MainActor
final class ChatWindowTests: XCTestCase {
    private func messages(_ range: ClosedRange<Int>) -> [Message] {
        range.map { id in
            Message(id: String(id), sender: "demo", body: "Message \(id): " + String(repeating: "plain text wraps across the window. ", count: 5),
                    timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(id)), isNotice: false)
        }
    }

    private func settleLayout(_ window: ChatWindow) async throws {
        window.contentView?.layoutSubtreeIfNeeded()
        if let container = window.transcript.textContainer {
            window.transcript.layoutManager?.ensureLayout(for: container)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func testSendingAndRefreshingLongThreadKeepLatestMessagesVisible() async throws {
        _ = NSApplication.shared
        let window = ChatWindow()
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        window.makeFirstResponder(window.composer)
        window.showMessages(messages(1...100), scrollToEnd: true)
        try await settleLayout(window)
        XCTAssertGreaterThan(window.transcript.bounds.height, window.transcriptScroll.contentView.bounds.height * 2)
        XCTAssertTrue(window.isTranscriptAtEnd, "Opening a long thread should reveal its latest message")
        for lastID in 101...104 {
            window.showMessages(messages((lastID - 99)...lastID), scrollToEnd: true)
            try await settleLayout(window)
            XCTAssertTrue(window.isTranscriptAtEnd, "The sent message should stay visible after layout and a rolling page update")
            let endOrigin = window.transcriptScroll.contentView.bounds.origin
            window.showMessages(messages((lastID - 99)...lastID), scrollToEnd: false)
            try await settleLayout(window)
            XCTAssertEqual(window.transcriptScroll.contentView.bounds.origin.y, endOrigin.y, accuracy: 1)
            XCTAssertTrue(window.isTranscriptAtEnd)
        }
    }

    func testBackgroundRefreshPreservesPositionWhenReadingEarlierMessages() async throws {
        _ = NSApplication.shared
        let window = ChatWindow()
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        window.showMessages(messages(1...100), scrollToEnd: true)
        try await settleLayout(window)
        let clip = window.transcriptScroll.contentView
        clip.scroll(to: NSPoint(x: 0, y: window.transcript.bounds.height / 3))
        window.transcriptScroll.reflectScrolledClipView(clip)
        let origin = clip.bounds.origin
        XCTAssertGreaterThan(origin.y, 0)
        XCTAssertFalse(window.isTranscriptAtEnd)
        window.showMessages(messages(1...101), scrollToEnd: false)
        try await settleLayout(window)
        XCTAssertEqual(clip.bounds.origin.y, origin.y, accuracy: 1)
        XCTAssertFalse(window.isTranscriptAtEnd)
    }

    func testTailSurvivesLargeChangesInMessageHeightAndWindowLayout() async throws {
        _ = NSApplication.shared
        let window = ChatWindow()
        defer { window.close() }
        let longMessage = Message(id: "101", sender: "demo", body: String(repeating: "A long synthetic message line.\n", count: 300), timestamp: nil, isNotice: false)
        // Initial display can arrive before AppKit's first layout pass.
        window.showMessages(messages(1...100), scrollToEnd: true)
        try await settleLayout(window)
        XCTAssertTrue(window.isTranscriptAtEnd)
        window.showMessages(messages(2...100) + [longMessage], scrollToEnd: true)
        try await settleLayout(window)
        XCTAssertTrue(window.isTranscriptAtEnd)
        window.setContentSize(NSSize(width: 840, height: 540))
        window.showMessages(messages(3...102), scrollToEnd: true)
        try await settleLayout(window)
        XCTAssertTrue(window.isTranscriptAtEnd)
    }
}
