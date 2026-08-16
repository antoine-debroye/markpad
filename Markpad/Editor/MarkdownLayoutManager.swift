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
    /// A picture drawn in place of the Markdown that produced it — a linked image or a
    /// rendered diagram. Both are laid out the same way, so they share one path.
    struct Artwork {
        /// The syntax the picture replaces.
        let range: NSRange
        let image: NSImage
        let size: CGSize
    }

    var artworks: [Artwork] = []
    /// Width available for drawing, used to fit pictures to the window.
    var contentWidth: CGFloat = 600

    /// The picture whose syntax starts at `characterIndex`.
    private func artwork(startingAt characterIndex: Int) -> Artwork? {
        artworks.first { $0.range.location == characterIndex }
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

        // Rows now carry their own padding, so the grid can sit exactly on the row rects
        // instead of the ±2 fudges that used to stand in for it.
        let frame = NSRect(
            x: origin.x,
            y: first.rect.minY,
            width: table.width,
            height: last.rect.maxY - first.rect.minY
        )

        let radius = MarkdownStyler.Table.cornerRadius
        let outline = NSRect(
            x: frame.minX + 0.5,
            y: frame.minY.rounded() + 0.5,
            width: table.width,
            height: frame.height
        )
        let clip = NSBezierPath(roundedRect: outline, xRadius: radius, yRadius: radius)

        // Header band, clipped to the rounded outline so its top corners follow it.
        if first.isHeader {
            // The dedicated token, not the code background it used to borrow.
            context.setFillColor(theme.tableHeaderBackground.cgColor)
            context.saveGState()
            clip.addClip()
            context.fill(NSRect(
                x: frame.minX,
                y: first.rect.minY,
                width: table.width,
                height: first.rect.height
            ))
            context.restoreGState()
        }

        context.setStrokeColor(theme.tableBorder.cgColor)
        context.setLineWidth(1)

        // Horizontal rules between rows, on the row boundary itself.
        for (index, entry) in rowRects.enumerated() where index > 0 {
            let y = entry.rect.minY.rounded() + 0.5
            context.move(to: CGPoint(x: frame.minX, y: y))
            context.addLine(to: CGPoint(x: frame.minX + table.width, y: y))
        }

        // Column separators — inner boundaries only. The first and last coincide with the
        // outer border, and drawing a square line there cut across the rounded corners and
        // left a nub of background trapped inside the arc.
        for boundary in table.boundaries.dropFirst().dropLast() {
            let x = (frame.minX + boundary).rounded() + 0.5
            context.move(to: CGPoint(x: x, y: frame.minY))
            context.addLine(to: CGPoint(x: x, y: frame.maxY))
        }

        // Rules and separators stroke first; the rounded outline is a separate path because a
        // rounded rect cannot share a path with the straight lines above without joining them.
        context.strokePath()

        context.setStrokeColor(theme.tableBorder.cgColor)
        context.setLineWidth(1)
        clip.stroke()
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

    /// Width decorations span: the text column, not the container.
    ///
    /// A table wider than the column widens the container to hold it. Sizing a code panel or a
    /// rule from the container would then make it stretch past the prose it belongs to.
    private var decorationWidth: CGFloat {
        let container = textContainers.first?.size.width ?? contentWidth
        return min(container, contentWidth)
    }

    private func drawCodeBackground(for block: BlockRun, origin: NSPoint, context: CGContext) {
        guard var rect = boundingRect(for: block.range, origin: origin) else { return }
        rect = rect.insetBy(dx: -8, dy: -4)
        // Assigned, not `max`ed with the measured rect: `boundingRect(forGlyphRange:)` reports
        // line *fragment* rects, which span the whole container. Taking the larger of the two
        // would let the panel stretch across a container that a wide table had widened, instead
        // of spanning the text column the code actually sits in.
        rect.size.width = decorationWidth - 16
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        context.setFillColor(theme.codeBackground.cgColor)
        path.fill()
    }

    private func drawThematicBreak(for block: BlockRun, origin: NSPoint, context: CGContext) {
        guard let rect = boundingRect(for: block.range, origin: origin) else { return }
        let y = rect.midY.rounded()
        let width = decorationWidth - 8
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
            // Each bar sits at the left edge of the indent its own level introduced, so the
            // text — indented by the same step in `MarkdownStyler` — clears it.
            let x = origin.x + CGFloat(depth) * MarkdownStyler.QuoteBar.indent
            let bar = CGRect(
                x: x,
                y: rect.minY - 2,
                width: MarkdownStyler.QuoteBar.width,
                height: rect.height + 4
            )
            let path = NSBezierPath(
                roundedRect: bar,
                xRadius: MarkdownStyler.QuoteBar.cornerRadius,
                yRadius: MarkdownStyler.QuoteBar.cornerRadius
            )
            path.fill()
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
        guard !artworks.isEmpty else { return }

        for artwork in artworks {
            guard NSIntersectionRange(artwork.range, characterRange).length > 0 else { continue }
            guard let anchor = boundingRect(
                for: NSRange(location: artwork.range.location, length: 1),
                origin: origin
            ) else { continue }

            let target = NSRect(
                x: anchor.minX,
                y: anchor.minY + 6,
                width: artwork.size.width,
                height: artwork.size.height
            )
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: target, xRadius: 5, yRadius: 5).addClip()
            // Text view coordinates are flipped, so the picture must be told to respect that
            // or it draws upside down.
            artwork.image.draw(
                in: target,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
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
        // The design draws a 16px box on a 16px body font, so the box matches the text size.
        let side = theme.baseFontSize
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

            // Text view coordinates are flipped, so the tick's low point has the larger y.
            let tick = NSBezierPath()
            tick.move(to: CGPoint(x: box.minX + side * 0.24, y: box.minY + side * 0.50))
            tick.line(to: CGPoint(x: box.minX + side * 0.44, y: box.minY + side * 0.70))
            tick.line(to: CGPoint(x: box.minX + side * 0.78, y: box.minY + side * 0.32))
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

    /// The first character of a picture's syntax, which stands in for the picture itself.
    func isImageAnchor(_ characterIndex: Int) -> Bool {
        artwork(startingAt: characterIndex) != nil
    }

    /// Grows the line that holds a picture, or pads a table row.
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer,
        forGlyphRange glyphRange: NSRange
    ) -> Bool {
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        if let artwork = artworks.first(where: {
            NSLocationInRange($0.range.location, characterRange)
        }) {
            let height = artwork.size.height + 14
            lineFragmentRect.pointee.size.height = height
            lineFragmentUsedRect.pointee.size.height = height
            // Sit the text baseline at the bottom of the picture.
            baselineOffset.pointee = height - 4
            return true
        }

        // Table rows are padded here rather than through paragraph attributes. This is the only
        // hook that grows the line *and* moves the baseline independently, so the text ends up
        // centred and the padding lands inside the line's bounding rect — which is what the
        // header band and the row rules are measured from. Paragraph spacing sits outside that
        // rect, so the band stopped short of the rule and left a seam.
        if isTableRow(characterRange) {
            let padding = MarkdownStyler.Table.verticalPadding
            lineFragmentRect.pointee.size.height += padding * 2
            lineFragmentUsedRect.pointee.size.height += padding * 2
            baselineOffset.pointee += padding
            return true
        }

        return false
    }

    /// Whether these characters belong to a row of a table currently drawn as a grid.
    private func isTableRow(_ characterRange: NSRange) -> Bool {
        tables.contains { table in
            table.structure.rows.contains { row in
                NSIntersectionRange(row.range, characterRange).length > 0
            }
        }
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
        if let artwork = artwork(startingAt: characterIndex) {
            // Only the width comes from here. The line's height is set in
            // shouldSetLineFragmentRect, which is the hook the typesetter honours; returning
            // an oversized control box instead stops the following lines being laid out.
            return NSRect(x: glyphPosition.x, y: 0, width: artwork.size.width, height: proposedRect.height)
        }
        if let table = table(containing: characterIndex) {
            let gap = table.gap(forDelimiterAt: characterIndex, penX: glyphPosition.x)
            return NSRect(x: glyphPosition.x, y: 0, width: gap, height: proposedRect.height)
        }
        return .zero
    }
}
