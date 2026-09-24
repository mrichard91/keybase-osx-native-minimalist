import AppKit
import XCTest
@testable import MinimalKeybase

@MainActor
final class PlainTextViewTests: XCTestCase {
    private func editor() -> (NSWindow, PlainTextView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = PlainTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.configurePlainText(editable: true)
        window.contentView = view
        window.makeFirstResponder(view)
        return (window, view)
    }

    private func key(_ code: UInt16 = 36, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                         isARepeat: false, keyCode: code)!
    }

    func testChangingRecipientClearsUndoAndMarkedDraft() {
        let (window, view) = editor()
        defer { window.close() }
        view.insertText("private previous draft", replacementRange: NSRange(location: 0, length: 0))
        view.breakUndoCoalescing()
        XCTAssertTrue(view.undoManager?.canUndo == true)
        view.setMarkedText("pending", selectedRange: NSRange(location: 7, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        view.replaceDraft("different recipient")
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertFalse(view.undoManager?.canUndo == true)
        XCTAssertFalse(view.undoManager?.canRedo == true)
        XCTAssertEqual(view.string, "different recipient")
        view.replaceDraft("")
        XCTAssertFalse(view.undoManager?.canUndo == true)
        XCTAssertEqual(view.string, "")
    }

    func testReturnConfirmsMarkedInputAndKeypadEnterSends() {
        let (window, view) = editor()
        defer { window.close() }
        var sends = 0
        view.onSend = { sends += 1 }
        view.setMarkedText("hello", selectedRange: NSRange(location: 5, length: 0),
                           replacementRange: NSRange(location: 0, length: 0))
        view.keyDown(with: key())
        XCTAssertEqual(sends, 0)
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(view.string, "hello")
        view.keyDown(with: key(76))
        XCTAssertEqual(sends, 1)
        view.keyDown(with: key(flags: .shift))
        view.keyDown(with: key(76, flags: .option))
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(view.string, "hello\n\n")
    }

    func testInputCannotBypassASCIIBoundaryOrEditorLimit() {
        let (window, view) = editor()
        defer { window.close() }
        view.insertText("😀", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(view.string, ":grinning:")
        var rejected = 0
        view.onRejectedInput = { _ in rejected += 1 }
        view.setMarkedText("\u{202E}", selectedRange: .init(location: 0, length: 0), replacementRange: view.selectedRange())
        view.insertText(NSAttributedString(string: "café"), replacementRange: view.selectedRange())
        XCTAssertEqual(rejected, 2)
        XCTAssertEqual(view.string, ":grinning:")
        view.replaceDraft(String(repeating: "x", count: 10_000))
        view.insertNewline(nil)
        XCTAssertEqual(view.string.utf8.count, 10_000)
        XCTAssertEqual(rejected, 3)
        view.setSelectedRange(NSRange(location: 0, length: 1))
        view.insertText("y", replacementRange: view.selectedRange())
        XCTAssertEqual(view.string.utf8.count, 10_000)
        XCTAssertTrue(view.string.hasPrefix("y"))
    }

    func testContextMenuHasNoExternalActions() {
        let (window, view) = editor()
        defer { window.close() }
        let event = key()
        XCTAssertEqual(view.menu(for: event)?.items.filter { !$0.isSeparatorItem }.map(\.title),
                       ["Cut", "Copy", "Paste", "Select All"])
        view.isEditable = false
        XCTAssertEqual(view.menu(for: event)?.items.filter { !$0.isSeparatorItem }.map(\.title), ["Copy", "Select All"])
        XCTAssertNil(view.validRequestor(forSendType: .string, returnType: .string))
        if #available(macOS 15.0, *) { XCTAssertEqual(view.writingToolsBehavior, .none) }
    }
}
