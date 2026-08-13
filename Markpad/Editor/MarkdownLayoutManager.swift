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
    /// Tables currently drawn as grids, with the column positions they were measured at.
    var tables: [TableGeometry] = []
    /// Images drawn in place of their Markdown syntax.
    var images: [ImagePlacement] = []
    var imageStore: ImageStore?
    /// Width available for drawing, used to fit images to the window.
    var contentWidth: CGFloat = 600

    /// The image whose syntax starts at `characterIndex`.
    private func image(startingAt characterIndex: Int) -> ImagePlacement? {
        images.first { $0.range.location == characterIndex }
    }

    private func image(containing characterIndex: Int) -> ImagePlacement? {
        images.first { NSLocationInRange(characterIndex, $0.range) }
    }

    /// Size an image occupies in the text, or nil while it is still loading.
    private func displaySize(for placement: ImagePlacement) -> CGSize? {
        imageStore?.entry(for: placement.source, availableWidth: contentWidth)?.displaySize
    }

    /// The table whose grid contains `characterIndex`, if any.
    private func table(containing characterIndex: Int) -> TableGeometry? {
        tables.first { NSLocationInRange(characterIndex, $0.structure.range) }
    }

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

        for table in tables where NSIntersectionRange(table.structure.range, characterRange).length > 0 {
            drawTable(table, origin: origin, context: context)
        }

        context.restoreGState()
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    /// Draws the grid: a header band, a rule under it, and lines between rows and columns.
    private func drawTable(_ table: TableGeometry, origin: NSPoint, context: CGContext) {
        var rowRects: [(rect: NSRect, isHeader: Bool)] = []
        for row in table.structure.rows {
            guard let rect = boundingRect(for: row.range, origin: origin) else { continue }
            rowRects.append((rect, row.isHeader))
        }
        guard let first = rowRects.first, let last = rowRects.last else { return }

        let left = origin.x + (first.rect.minX - first.rect.minX)
        let frame = NSRect(
            x: origin.x,
            y: first.rect.minY,
            width: table.width,
            height: last.rect.maxY - first.rect.minY
        ).insetBy(dx: 0, dy: -2)
        _ = left

        // Header band.
        if first.isHeader {
            context.setFillColor(theme.codeBackground.cgColor)
            let header = NSRect(
                x: frame.minX,
                y: first.rect.minY - 2,
                width: table.width,
                height: first.rect.height + 4
            )
            context.fill(header)
        }

        context.setStrokeColor(theme.tableBorder.cgColor)
        context.setLineWidth(1)

        // Horizontal rules between rows.
        for (index, entry) in rowRects.enumerated() where index > 0 {
            let y = (entry.rect.minY - 2).rounded() + 0.5
            context.move(to: CGPoint(x: frame.minX, y: y))
            context.addLine(to: CGPoint(x: frame.minX + table.width, y: y))
        }

        // Column separators.
        for boundary in table.boundaries {
            let x = (frame.minX + boundary).rounded() + 0.5
            context.move(to: CGPoint(x: x, y: frame.minY - 2))
            context.addLine(to: CGPoint(x: x, y: frame.maxY))
        }

        // The outer frame joins the same path: stroking a rect directly would discard the
        // rules accumulated above.
        context.addRect(NSRect(
            x: frame.minX + 0.5,
            y: (frame.minY - 2).rounded() + 0.5,
            width: table.width,
            height: frame.height
        ))
        context.strokePath()
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

        let visibleRange = self.characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        drawImages(in: visibleRange, origin: origin)

        guard !paintedMarkers.isEmpty else { return }
        let characterRange = visibleRange

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

    /// Draws each picture into the space its syntax reserved.
    private func drawImages(in characterRange: NSRange, origin: NSPoint) {
        guard !images.isEmpty, let store = imageStore else { return }

        for placement in images {
            guard NSIntersectionRange(placement.range, characterRange).length > 0 else { continue }
            guard let entry = store.entry(for: placement.source, availableWidth: contentWidth) else { continue }
            guard let anchor = boundingRect(
                for: NSRange(location: placement.range.location, length: 1),
                origin: origin
            ) else { continue }

            let target = NSRect(
                x: anchor.minX,
                y: anchor.minY + 6,
                width: entry.displaySize.width,
                height: entry.displaySize.height
            )
            NSGraphicsContext.saveGraphicsState()
            let path = NSBezierPath(roundedRect: target, xRadius: 5, yRadius: 5)
            path.addClip()
            entry.image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
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
        guard !concealedRanges.isEmpty || !tables.isEmpty else { return 0 }

        // Only intervene when this run actually contains characters that need adjusting.
        var touched = false
        for offset in 0..<glyphRange.length {
            let characterIndex = characterIndexes[offset]
            if isConcealed(characterIndex) || isColumnDelimiter(characterIndex) {
                touched = true
                break
            }
        }
        guard touched else { return 0 }

        var adjusted = Array(UnsafeBufferPointer(start: properties, count: glyphRange.length))
        for offset in 0..<glyphRange.length {
            let characterIndex = characterIndexes[offset]
            if isImageAnchor(characterIndex) {
                // The first character of the image's syntax becomes a box the size of the
                // picture; the rest of the syntax collapses. The text is never touched.
                adjusted[offset].insert(.controlCharacter)
            } else if isColumnDelimiter(characterIndex) {
                // A table's pipes become the gaps that start each column: they are laid out
                // as control characters so their width can be set per column boundary.
                adjusted[offset].insert(.controlCharacter)
            } else if isConcealed(characterIndex) {
                // A null glyph occupies no space and is not drawn; the character stays in
                // storage.
                adjusted[offset].insert(.null)
            }
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

    /// True for a `|` belonging to a table that is currently drawn as a grid.
    func isColumnDelimiter(_ characterIndex: Int) -> Bool {
        table(containing: characterIndex)?.target(forDelimiterAt: characterIndex) != nil
    }

    /// The first character of an image's syntax, which stands in for the picture.
    func isImageAnchor(_ characterIndex: Int) -> Bool {
        guard let placement = image(startingAt: characterIndex) else { return false }
        return displaySize(for: placement) != nil
    }

    /// Grows the line that holds a picture so the picture has room to be drawn.
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer,
        forGlyphRange glyphRange: NSRange
    ) -> Bool {
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard let placement = images.first(where: {
            NSLocationInRange($0.range.location, characterRange)
        }), let size = displaySize(for: placement) else { return false }

        let height = size.height + 14
        lineFragmentRect.pointee.size.height = height
        lineFragmentUsedRect.pointee.size.height = height
        // Sit the text baseline at the bottom of the picture.
        baselineOffset.pointee = height - 4
        return true
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldUse action: NSLayoutManager.ControlCharacterAction,
        forControlCharacterAt characterIndex: Int
    ) -> NSLayoutManager.ControlCharacterAction {
        if isImageAnchor(characterIndex) || isColumnDelimiter(characterIndex) { return .whitespace }
        return action
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        boundingBoxForControlGlyphAt glyphIndex: Int,
        for textContainer: NSTextContainer,
        proposedLineFragment proposedRect: NSRect,
        glyphPosition: NSPoint,
        characterIndex: Int
    ) -> NSRect {
        if let placement = image(startingAt: characterIndex), let size = displaySize(for: placement) {
            // Only the width comes from here. The line's height is set in
            // shouldSetLineFragmentRect, which is the hook the typesetter honours; returning
            // an oversized control box instead stops the following lines being laid out.
            return NSRect(x: glyphPosition.x, y: 0, width: size.width, height: proposedRect.height)
        }
        if let table = table(containing: characterIndex) {
            let gap = table.gap(forDelimiterAt: characterIndex, penX: glyphPosition.x)
            return NSRect(x: glyphPosition.x, y: 0, width: gap, height: proposedRect.height)
        }
        return .zero
    }
}
