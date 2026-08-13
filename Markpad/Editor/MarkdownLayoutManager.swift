import AppKit
import MarkpadCore

/// Draws everything Markdown needs that text attributes cannot express — quote bars, code
/// block backgrounds, horizontal rules, list bullets and task checkboxes — and collapses
/// syntax markers to zero width.
///
/// Markers are hidden by suppressing their glyphs rather than by changing the text, so the
/// storage always holds the exact Markdown source and saving, undo, find and copy stay
/// trivially correct.
final class MarkdownLayoutManager: NSLayoutManager {
    var theme = EditorTheme()

    /// Ranges whose glyphs are collapsed. Kept sorted for binary search during layout.
    private(set) var concealedRanges: [NSRange] = []
    /// Markers painted over: bullets and checkboxes keep their width so the glyph beneath
    /// can be replaced by a symbol without disturbing layout.
    var paintedMarkers: [Marker] = []
    /// Decoration geometry, refreshed with the layout.
    var blocks: [BlockRun] = []

    func setConcealedRanges(_ ranges: [NSRange]) {
        concealedRanges = ranges.sorted { $0.location < $1.location }
    }

    func isConcealed(_ characterIndex: Int) -> Bool {
        var low = 0
        var high = concealedRanges.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = concealedRanges[mid]
            if characterIndex < range.location {
                high = mid - 1
            } else if characterIndex >= NSMaxRange(range) {
                low = mid + 1
            } else {
                return true
            }
        }
        return false
    }

    // MARK: Decoration drawing

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
            return
        }

        let characterRange = self.characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        context.saveGState()

        for block in blocks {
            guard NSIntersectionRange(block.range, characterRange).length > 0
                    || block.range.length == 0 else { continue }

            switch block.kind {
            case .codeBlock:
                drawCodeBackground(for: block, origin: origin, context: context)
            case .thematicBreak:
                drawThematicBreak(for: block, origin: origin, context: context)
            default:
                break
            }

            if block.quoteDepth > 0 {
                drawQuoteBars(for: block, origin: origin, context: context)
            }
        }

        context.restoreGState()
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    private func boundingRect(for range: NSRange, origin: NSPoint) -> NSRect? {
        guard let container = textContainers.first else { return nil }
        let clamped = clamp(range)
        guard clamped.length > 0 || clamped.location < numberOfGlyphs else { return nil }
        let glyphRange = self.glyphRange(forCharacterRange: clamped, actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return nil }
        var rect = boundingRect(forGlyphRange: glyphRange, in: container)
        rect.origin.x += origin.x
        rect.origin.y += origin.y
        return rect
    }

    private func clamp(_ range: NSRange) -> NSRange {
        let length = textStorage?.length ?? 0
        let location = min(max(range.location, 0), length)
        return NSRange(location: location, length: min(range.length, length - location))
    }

    private func drawCodeBackground(for block: BlockRun, origin: NSPoint, context: CGContext) {
        guard var rect = boundingRect(for: block.range, origin: origin) else { return }
        rect = rect.insetBy(dx: -8, dy: -4)
        rect.size.width = max(rect.width, (textContainers.first?.size.width ?? rect.width) - 16)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        context.setFillColor(theme.codeBackground.cgColor)
        path.fill()
    }

    private func drawThematicBreak(for block: BlockRun, origin: NSPoint, context: CGContext) {
        guard let rect = boundingRect(for: block.range, origin: origin) else { return }
        let y = rect.midY.rounded()
        let width = (textContainers.first?.size.width ?? rect.width) - 8
        context.setStrokeColor(theme.rule.cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: origin.x + 4, y: y))
        context.addLine(to: CGPoint(x: origin.x + width, y: y))
        context.strokePath()
    }

    private func drawQuoteBars(for block: BlockRun, origin: NSPoint, context: CGContext) {
        guard let rect = boundingRect(for: block.range, origin: origin) else { return }
        context.setFillColor(theme.quoteBar.cgColor)
        for depth in 0..<block.quoteDepth {
            let x = origin.x + 4 + CGFloat(depth) * 10
            let bar = CGRect(x: x, y: rect.minY - 2, width: 3, height: rect.height + 4)
            context.fill(bar)
        }
    }

    // MARK: Painted markers

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)

        guard !paintedMarkers.isEmpty else { return }
        let characterRange = self.characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        for marker in paintedMarkers {
            guard NSIntersectionRange(marker.range, characterRange).length > 0,
                  let rect = boundingRect(for: marker.range, origin: origin) else { continue }

            switch marker.presentation {
            case .bullet:
                drawBullet(in: rect)
            case .checkbox(let checked):
                drawCheckbox(in: rect, checked: checked)
            case .hidden, .dimmed:
                break
            }
        }
    }

    /// Marker glyphs are drawn with Core Graphics rather than SF Symbols so their size and
    /// baseline can be tuned to the surrounding text exactly.
    private func drawBullet(in rect: NSRect) {
        let diameter = max(theme.baseFontSize * 0.3, 4)
        // Sit on the text's optical centre, in the leading half of the marker's width.
        let center = CGPoint(
            x: rect.minX + min(rect.width, theme.baseFontSize) / 2,
            y: rect.midY + theme.baseFontSize * 0.06
        )
        let circle = NSRect(
            x: center.x - diameter / 2,
            y: center.y - diameter / 2,
            width: diameter,
            height: diameter
        )
        theme.secondaryText.setFill()
        NSBezierPath(ovalIn: circle).fill()
    }

    private func drawCheckbox(in rect: NSRect, checked: Bool) {
        let side = theme.baseFontSize * 0.82
        let box = NSRect(
            x: rect.minX + 1,
            y: rect.midY - side / 2 + theme.baseFontSize * 0.05,
            width: side,
            height: side
        )
        let path = NSBezierPath(roundedRect: box, xRadius: 3.5, yRadius: 3.5)

        if checked {
            theme.link.setFill()
            path.fill()

            let tick = NSBezierPath()
            tick.move(to: CGPoint(x: box.minX + side * 0.24, y: box.midY + side * 0.02))
            tick.line(to: CGPoint(x: box.minX + side * 0.43, y: box.minY + side * 0.26))
            tick.line(to: CGPoint(x: box.minX + side * 0.78, y: box.maxY - side * 0.26))
            tick.lineWidth = max(side * 0.14, 1.5)
            tick.lineCapStyle = .round
            tick.lineJoinStyle = .round
            NSColor.white.setStroke()
            tick.stroke()
        } else {
            theme.secondaryText.setStroke()
            path.lineWidth = 1.2
            path.stroke()
        }
    }
}

// MARK: - Glyph suppression

extension MarkdownLayoutManager: NSLayoutManagerDelegate {
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes: UnsafePointer<Int>,
        font: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        guard !concealedRanges.isEmpty else { return 0 }

        // Only intervene when this run actually contains concealed characters.
        var touched = false
        for offset in 0..<glyphRange.length where isConcealed(characterIndexes[offset]) {
            touched = true
            break
        }
        guard touched else { return 0 }

        var adjusted = Array(UnsafeBufferPointer(start: properties, count: glyphRange.length))
        for offset in 0..<glyphRange.length where isConcealed(characterIndexes[offset]) {
            // A null glyph occupies no space and is not drawn; the character stays in storage.
            adjusted[offset].insert(.null)
        }

        adjusted.withUnsafeBufferPointer { buffer in
            layoutManager.setGlyphs(
                glyphs,
                properties: buffer.baseAddress!,
                characterIndexes: characterIndexes,
                font: font,
                forGlyphRange: glyphRange
            )
        }
        return glyphRange.length
    }
}
