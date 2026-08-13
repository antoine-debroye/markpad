import AppKit
import MarkpadCore

/// Applies a `MarkdownLayout` to an `NSTextStorage` as text attributes.
///
/// Styling is derived state: it is written straight to the storage without registering undo,
/// and never changes a single character. Undo replays the text edit, which re-triggers
/// styling on its own.
struct MarkdownStyler {
    var theme: EditorTheme

    /// Attribute key marking a link destination, used for click handling.
    static let linkDestination = NSAttributedString.Key("markpad.link")

    /// Styles a table that is being drawn as a grid: header cells stand out and the
    /// `|---|---|` line collapses to a hairline where the header rule is drawn.
    func applyTable(_ structure: TableStructure, scale: CGFloat, to storage: NSTextStorage) {
        for row in structure.rows {
            let range = clamp(row.range, in: storage)
            guard range.length > 0 else { continue }

            let style = NSMutableParagraphStyle()
            style.lineHeightMultiple = 1.0
            style.paragraphSpacing = 0
            style.lineBreakMode = .byClipping
            storage.addAttribute(.paragraphStyle, value: style, range: range)

            let size = theme.baseFontSize * scale * 0.96
            let font = NSFont.systemFont(ofSize: size, weight: row.isHeader ? .semibold : .regular)
            storage.addAttributes([
                .font: font,
                .foregroundColor: theme.text
            ], range: range)
        }

        if let separator = structure.separatorRange {
            let range = clamp(separator, in: storage)
            guard range.length > 0 else { return }
            // The characters stay in the source but take almost no room; the rule between
            // header and body is drawn in the space they leave.
            let style = NSMutableParagraphStyle()
            style.lineHeightMultiple = 0.01
            style.paragraphSpacing = 0
            storage.addAttributes([
                .font: NSFont.systemFont(ofSize: 1),
                .foregroundColor: NSColor.clear,
                .paragraphStyle: style
            ], range: range)
        }
    }

    func apply(layout: MarkdownLayout, to storage: NSTextStorage, activeRanges: [NSRange]) {
        let fullRange = NSRange(location: 0, length: storage.length)
        guard fullRange.length > 0 else { return }

        storage.beginEditing()
        defer { storage.endEditing() }

        // Start from a clean baseline so removing syntax also removes its styling.
        storage.setAttributes([
            .font: theme.bodyFont,
            .foregroundColor: theme.text,
            .paragraphStyle: paragraphStyle(for: nil)
        ], range: fullRange)

        for block in layout.blocks {
            applyBlock(block, to: storage)
        }
        for inline in layout.inlines {
            applyInline(inline, to: storage)
        }
        for marker in layout.markers {
            let isActive = activeRanges.contains { NSIntersectionRange($0, marker.range).length > 0 }
            applyMarker(marker, to: storage, isActive: isActive)
        }
    }

    // MARK: Blocks

    private func applyBlock(_ block: BlockRun, to storage: NSTextStorage) {
        let range = clamp(block.range, in: storage)
        guard range.length > 0 else { return }

        storage.addAttribute(.paragraphStyle, value: paragraphStyle(for: block), range: range)

        switch block.kind {
        case .heading(let level):
            storage.addAttributes([
                .font: theme.headingFont(level: level),
                .foregroundColor: theme.heading
            ], range: range)

        case .codeBlock:
            storage.addAttributes([
                .font: theme.monospaceFont,
                .foregroundColor: theme.text
            ], range: range)

        case .thematicBreak:
            // The rule itself is drawn; the characters collapse to nothing.
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: range)

        case .table:
            storage.addAttributes([
                .font: theme.monospaceFont,
                .foregroundColor: theme.text
            ], range: range)

        case .html:
            storage.addAttributes([
                .font: theme.monospaceFont,
                .foregroundColor: theme.secondaryText
            ], range: range)

        case .paragraph:
            if block.quoteDepth > 0 {
                storage.addAttribute(.foregroundColor, value: theme.quoteText, range: range)
            }
        }
    }

    private func paragraphStyle(for block: BlockRun?) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = theme.lineHeightMultiple
        style.paragraphSpacing = theme.paragraphSpacing

        guard let block else { return style }

        let quoteInset = CGFloat(block.quoteDepth) * (theme.indentStep * 0.75)
        let listInset = CGFloat(block.listDepth) * theme.indentStep
        style.firstLineHeadIndent = quoteInset + listInset
        style.headIndent = quoteInset + listInset

        switch block.kind {
        case .heading(let level):
            style.paragraphSpacingBefore = level <= 2 ? theme.baseFontSize * 0.5 : theme.baseFontSize * 0.3
            style.paragraphSpacing = theme.baseFontSize * 0.2
        case .codeBlock:
            style.lineHeightMultiple = 1.05
            style.firstLineHeadIndent += 10
            style.headIndent += 10
            style.paragraphSpacing = 0
        case .thematicBreak:
            style.paragraphSpacing = theme.baseFontSize
            style.paragraphSpacingBefore = theme.baseFontSize
        default:
            break
        }

        if block.listDepth > 0 {
            // Wrapped list lines align under the item's text rather than its marker.
            style.headIndent += theme.indentStep * 0.9
            style.paragraphSpacing = theme.baseFontSize * 0.18
        }
        return style
    }

    // MARK: Inlines

    private func applyInline(_ inline: InlineRun, to storage: NSTextStorage) {
        let range = clamp(inline.range, in: storage)
        guard range.length > 0 else { return }

        // Compose with whatever the block already set so a bold word in a heading keeps the
        // heading's size.
        storage.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
            let current = (value as? NSFont) ?? theme.bodyFont
            let base = inline.traits.contains(.code) ? theme.monospaceFont : current
            storage.addAttribute(.font, value: theme.applying(traits: inline.traits, to: base), range: subrange)
        }

        if inline.traits.contains(.strikethrough) {
            storage.addAttributes([
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .strikethroughColor: theme.secondaryText
            ], range: range)
        }
        if inline.traits.contains(.code) {
            storage.addAttributes([
                .foregroundColor: theme.codeText,
                .backgroundColor: theme.codeBackground
            ], range: range)
        }
        if inline.traits.contains(.link), let destination = inline.link {
            storage.addAttributes([
                .foregroundColor: theme.link,
                Self.linkDestination: destination,
                .cursor: NSCursor.pointingHand
            ], range: range)
        }
    }

    // MARK: Markers

    private func applyMarker(_ marker: Marker, to storage: NSTextStorage, isActive: Bool) {
        let range = clamp(marker.range, in: storage)
        guard range.length > 0 else { return }

        switch marker.presentation {
        case .hidden:
            // When revealed, syntax is dimmed so it reads as scaffolding around the text.
            storage.addAttribute(.foregroundColor, value: theme.syntaxMarker, range: range)

        case .dimmed:
            storage.addAttribute(.foregroundColor, value: theme.secondaryText, range: range)

        case .bullet, .checkbox:
            // A symbol is painted over these characters, so the originals are made invisible
            // while keeping their width — except in the block being edited, where the raw
            // text must be visible to work with.
            storage.addAttribute(
                .foregroundColor,
                value: isActive ? theme.secondaryText : NSColor.clear,
                range: range
            )
        }
    }

    private func clamp(_ range: NSRange, in storage: NSTextStorage) -> NSRange {
        let location = min(max(range.location, 0), storage.length)
        return NSRange(location: location, length: min(range.length, storage.length - location))
    }
}
