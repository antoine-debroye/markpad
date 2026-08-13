import AppKit
import MarkpadCore

/// The editing surface.
///
/// The text storage always holds the raw Markdown source. Rendering is achieved by styling
/// and by collapsing syntax glyphs, never by rewriting text, so undo, find, copy and save
/// all operate on exactly what the user typed.
final class MarkdownTextView: NSTextView {
    var onCheckboxToggle: ((NSRange) -> Void)?
    var onLinkActivated: ((String) -> Void)?
    /// Markers the layout manager paints over, used for checkbox hit testing.
    var paintedMarkers: [Marker] = []

    override var acceptsFirstResponder: Bool { true }

    // MARK: Clicks

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = characterIndex(at: point) {
            if let range = checkboxRange(at: index) {
                onCheckboxToggle?(range)
                return
            }
            if event.modifierFlags.contains(.command),
               let destination = textStorage?.attribute(
                    MarkdownStyler.linkDestination,
                    at: index,
                    effectiveRange: nil
               ) as? String {
                onLinkActivated?(destination)
                return
            }
        }
        super.mouseDown(with: event)
    }

    private func characterIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let container = textContainer else { return nil }
        let origin = textContainerOrigin
        let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)

        // Reject points past the end of a line so clicking empty space does not activate
        // whatever character happens to be nearest.
        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(for: local, in: container, fractionOfDistanceThroughGlyph: &fraction)
        guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }
        let bounds = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: container)
        guard bounds.insetBy(dx: -2, dy: -2).contains(local) else { return nil }
        return layoutManager.characterIndexForGlyph(at: glyphIndex)
    }

    private func checkboxRange(at index: Int) -> NSRange? {
        paintedMarkers.first { marker in
            guard case .checkbox = marker.presentation else { return false }
            return NSLocationInRange(index, marker.range)
                || index == NSMaxRange(marker.range)
        }?.range
    }

    // MARK: Editing conveniences

    override func insertNewline(_ sender: Any?) {
        guard let storage = textStorage else { return super.insertNewline(sender) }
        let caret = selectedRange().location
        let lineRange = (storage.string as NSString).lineRange(
            for: NSRange(location: min(caret, storage.length), length: 0)
        )
        let line = (storage.string as NSString).substring(with: lineRange)

        guard let continuation = ListContinuation.next(after: line, caretAtLineOffset: caret - lineRange.location) else {
            return super.insertNewline(sender)
        }

        switch continuation {
        case .end(let markerRange):
            // Enter on an empty list item ends the list instead of adding another bullet.
            let absolute = NSRange(location: lineRange.location + markerRange.location, length: markerRange.length)
            if shouldChangeText(in: absolute, replacementString: "") {
                storage.replaceCharacters(in: absolute, with: "")
                didChangeText()
            }
        case .insert(let text):
            super.insertNewline(sender)
            insertText(text, replacementRange: selectedRange())
        }
    }

    override func insertTab(_ sender: Any?) {
        guard indentSelectedLines(by: 1) else { return super.insertTab(sender) }
    }

    override func insertBacktab(_ sender: Any?) {
        guard indentSelectedLines(by: -1) else { return super.insertBacktab(sender) }
    }

    /// Indents or outdents the lines touched by the selection when they are list items.
    @discardableResult
    private func indentSelectedLines(by delta: Int) -> Bool {
        guard let storage = textStorage else { return false }
        let text = storage.string as NSString
        let lineRange = text.lineRange(for: selectedRange())
        let lines = text.substring(with: lineRange).components(separatedBy: "\n")
        guard lines.contains(where: { ListContinuation.isListItem($0) }) else { return false }

        let indent = "  "
        let updated = lines.map { line -> String in
            guard ListContinuation.isListItem(line) else { return line }
            if delta > 0 { return indent + line }
            return line.hasPrefix(indent) ? String(line.dropFirst(indent.count)) : line
        }.joined(separator: "\n")

        guard shouldChangeText(in: lineRange, replacementString: updated) else { return false }
        storage.replaceCharacters(in: lineRange, with: updated)
        didChangeText()
        return true
    }

    /// Wraps the selection in `marker`, or unwraps it when it is already wrapped.
    func toggleWrap(_ marker: String) {
        guard let storage = textStorage else { return }
        let selection = selectedRange()
        let text = storage.string as NSString
        let markerLength = (marker as NSString).length

        let outer = NSRange(
            location: selection.location - markerLength,
            length: selection.length + markerLength * 2
        )
        if outer.location >= 0, NSMaxRange(outer) <= text.length,
           text.substring(with: outer).hasPrefix(marker),
           text.substring(with: outer).hasSuffix(marker) {
            let inner = text.substring(with: selection)
            guard shouldChangeText(in: outer, replacementString: inner) else { return }
            storage.replaceCharacters(in: outer, with: inner)
            didChangeText()
            setSelectedRange(NSRange(location: outer.location, length: (inner as NSString).length))
            return
        }

        let selected = text.substring(with: selection)
        let replacement = marker + selected + marker
        guard shouldChangeText(in: selection, replacementString: replacement) else { return }
        storage.replaceCharacters(in: selection, with: replacement)
        didChangeText()
        setSelectedRange(NSRange(
            location: selection.location + markerLength,
            length: (selected as NSString).length
        ))
    }

    /// Turns the selection into a link, using the pasteboard URL when there is one.
    func makeLink() {
        guard let storage = textStorage else { return }
        let selection = selectedRange()
        let text = (storage.string as NSString).substring(with: selection)
        let pasteboardURL = NSPasteboard.general.string(forType: .string).flatMap { candidate -> String? in
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") ? trimmed : nil
        }

        let replacement = "[\(text)](\(pasteboardURL ?? ""))"
        guard shouldChangeText(in: selection, replacementString: replacement) else { return }
        storage.replaceCharacters(in: selection, with: replacement)
        didChangeText()

        // Put the caret where the author still has work to do.
        let caret = pasteboardURL == nil
            ? selection.location + (text as NSString).length + 3
            : selection.location + (replacement as NSString).length
        setSelectedRange(NSRange(location: caret, length: 0))
    }
}

/// Smart list behaviour for the Return key, kept separate so it can be reasoned about (and
/// tested) without a text view.
enum ListContinuation {
    enum Outcome: Equatable {
        /// Text to insert after the newline to continue the list.
        case insert(String)
        /// The item is empty: remove its marker and end the list.
        case end(markerRange: NSRange)
    }

    private static let pattern = #"^(\s*)(([-*+])|(\d{1,9})([.)]))(\s+)(\[[ xX]\]\s+)?"#

    static func isListItem(_ line: String) -> Bool {
        line.range(of: pattern, options: .regularExpression) != nil
    }

    static func next(after line: String, caretAtLineOffset offset: Int) -> Outcome? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsLine = line as NSString
        guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) else {
            return nil
        }

        let markerRange = match.range
        // Only continue when the caret is at or past the marker.
        guard offset >= markerRange.length else { return nil }

        let rest = nsLine.substring(from: markerRange.length).trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.isEmpty {
            return .end(markerRange: NSRange(location: 0, length: markerRange.length))
        }

        let indent = nsLine.substring(with: match.range(at: 1))
        let spacing = nsLine.substring(with: match.range(at: 6))
        let checkbox = match.range(at: 7).location != NSNotFound ? "[ ] " : ""

        if match.range(at: 3).location != NSNotFound {
            let bullet = nsLine.substring(with: match.range(at: 3))
            return .insert(indent + bullet + spacing + checkbox)
        }
        if match.range(at: 4).location != NSNotFound {
            let number = Int(nsLine.substring(with: match.range(at: 4))) ?? 1
            let delimiter = nsLine.substring(with: match.range(at: 5))
            return .insert("\(indent)\(number + 1)\(delimiter)\(spacing)\(checkbox)")
        }
        return nil
    }
}
