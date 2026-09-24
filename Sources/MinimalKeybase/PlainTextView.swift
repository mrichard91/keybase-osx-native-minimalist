import AppKit
import MinimalCore

/// Only NSString pasteboard data enters the editor. Rich text, files and drops are not accepted.
final class PlainTextView: NSTextView {
    var onSend: (() -> Void)?
    var onRejectedInput: ((String) -> Void)?

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard let edit = normalizedEdit(insertString, replacing: replacementRange) else { return }
        super.insertText(edit.text, replacementRange: edit.range)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        // Input methods must not temporarily render Unicode before committing it.
        guard let edit = normalizedEdit(string, replacing: replacementRange) else { return }
        let length = (edit.text as NSString).length
        let selection = NSRange(location: min(selectedRange.location, length),
                                length: min(selectedRange.length, max(0, length - min(selectedRange.location, length))))
        super.setMarkedText(edit.text, selectedRange: selection, replacementRange: edit.range)
    }

    private func normalizedEdit(_ input: Any, replacing range: NSRange) -> (text: String, range: NSRange)? {
        guard isEditable else { return nil }
        let raw: String
        if let value = input as? String { raw = value }
        else if let value = input as? NSAttributedString { raw = value.string }
        else { reject("Only plain ASCII text can be inserted."); return nil }
        do {
            let text = try ASCIIText.normalizeInput(raw)
            let current = string as NSString
            let target = range.location == NSNotFound ? (hasMarkedText() ? markedRange() : selectedRange()) : range
            guard target.location <= current.length, target.length <= current.length - target.location else { return nil }
            let next = current.replacingCharacters(in: target, with: text)
            guard next.utf8.count <= ASCIIText.maximumOutgoingBytes else { throw ASCIIText.ValidationError.tooLong }
            return (text, target)
        } catch { reject(error.localizedDescription); return nil }
    }

    private func reject(_ message: String) {
        NSSound.beep()
        onRejectedInput?(ASCIIText.sanitize(message, limit: 500))
    }

    override func paste(_ sender: Any?) {
        guard isEditable, let text = NSPasteboard.general.string(forType: .string) else { return }
        insertText(text, replacementRange: selectedRange())
    }

    override func pasteAsPlainText(_ sender: Any?) { paste(sender) }
    override func pasteAsRichText(_ sender: Any?) { paste(sender) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { false }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { [] }
    override func insertNewline(_ sender: Any?) { insertText("\n", replacementRange: selectedRange()) }
    override func insertTab(_ sender: Any?) { insertText("    ", replacementRange: selectedRange()) }

    // No lookup, browser, sharing, Services, or Quick Look route is exposed from
    // message text. Copy remains an explicit user action.
    override func quickLook(with event: NSEvent) {}
    override func quickLookPreviewItems(_ sender: Any?) {}
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? { nil }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        if isEditable { menu.addItem(withTitle: "Cut", action: #selector(cut(_:)), keyEquivalent: "") }
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        if isEditable { menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "") }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        for item in menu.items where !item.isSeparatorItem { item.target = self }
        return menu
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 && !event.modifierFlags.contains(.shift) {
            onSend?()
        } else { super.keyDown(with: event) }
    }

    func configurePlainText(editable: Bool) {
        isEditable = editable
        isSelectable = true
        isRichText = false
        importsGraphics = false
        allowsImageEditing = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextCompletionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        usesRuler = false
        usesFontPanel = false
        allowsUndo = editable
        unregisterDraggedTypes()
        font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textContainerInset = NSSize(width: 16, height: 14)
        isHorizontallyResizable = false
        isVerticallyResizable = true
        autoresizingMask = [.width]
        textContainer?.widthTracksTextView = true
    }
}
