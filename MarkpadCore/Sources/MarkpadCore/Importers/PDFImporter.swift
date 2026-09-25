import AppKit
import CoreGraphics
import Foundation
import PDFKit

/// Converts a PDF into Markdown.
///
/// Scope is deliberately bounded to single-column documents: multi-column reading order,
/// running headers and footnote reconstruction have no reliable general solution, and the
/// app presents this conversion as best effort.
public struct PDFImporter: Sendable {
    public struct Options: Sendable {
        /// Recognise text on pages that carry no text layer (scans).
        public var performOCRWhenNeeded: Bool
        /// Drop lines that repeat on most pages in the same position (running heads).
        public var stripRepeatingHeadersAndFooters: Bool
        public var inferHeadings: Bool

        public init(
            performOCRWhenNeeded: Bool = true,
            stripRepeatingHeadersAndFooters: Bool = true,
            inferHeadings: Bool = true
        ) {
            self.performOCRWhenNeeded = performOCRWhenNeeded
            self.stripRepeatingHeadersAndFooters = stripRepeatingHeadersAndFooters
            self.inferHeadings = inferHeadings
        }
    }

    public init() {}

    public func convert(
        url: URL,
        options: Options = Options(),
        progress: ImportProgress.Handler? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> String {
        guard let document = PDFDocument(url: url) else {
            throw ConversionError.unreadableFile(url)
        }

        let reporter = ImportReporter(
            totalUnits: max(document.pageCount, 1),
            handler: progress,
            isCancelled: isCancelled
        )
        reporter.report(.reading, index: 0)

        var pages: [PageContent] = []
        for index in 0..<document.pageCount {
            try reporter.checkCancellation()
            // Each page's attributed string and 2x rendering are autoreleased; without a pool
            // per page a long scan holds every one of them until the import returns, which in
            // a batch running several imports at once adds up to gigabytes.
            let content: PageContent? = try autoreleasepool {
                guard let page = document.page(at: index) else { return nil }
                // The text layer read by position, which is what finds tables, side-by-side
                // text and paragraph breaks. A page whose text and attributes disagree falls
                // back to reading the text in order.
                if let layout = PDFPageLayout(page: page), !layout.rows.isEmpty {
                    reporter.report(.extractingText, index: index)
                    return .layout(layout)
                }
                var lines = textLayerLines(of: page)
                let hasText = lines.contains { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
                // Reported before the slow step, so the label describes what is about to happen.
                reporter.report(hasText ? .extractingText : .recognizingText, index: index)

                if !hasText, options.performOCRWhenNeeded, let image = render(page: page) {
                    // Rasterising is itself slow, so this catches a cancel that arrived during it.
                    // The check must stay outside the `try?` below, which would swallow the error
                    // and leave the page silently blank.
                    try reporter.checkCancellation()
                    lines = (try? ImageImporter().recognizeLines(in: image, options: .init())) ?? []
                }
                return .lines(lines)
            }
            if let content { pages.append(content) }
        }

        try reporter.checkCancellation()
        reporter.reportAssembling()

        let repeating = options.stripRepeatingHeadersAndFooters ? runningHeads(in: pages) : []
        var allLines: [TextBlockAssembler.Line] = []
        for page in pages {
            switch page {
            case .layout(let layout):
                // No break at the page boundary: the next page's first line joins the
                // paragraph before it when the text runs on, and starts a new one when not.
                let kept = repeating.isEmpty ? layout : layout.removingSegments { repeating.contains(normalize($0)) }
                allLines += kept.lines()
            case .lines(let lines):
                let edges = edgeIndices(of: lines)
                for (index, line) in lines.enumerated() {
                    if edges.contains(index), repeating.contains(normalize(line.text)) { continue }
                    allLines.append(line)
                }
                // Recognised text has no geometry to say otherwise, so a page break ends a paragraph.
                allLines.append(TextBlockAssembler.Line(text: ""))
            }
        }
        while allLines.last?.text.isEmpty == true, allLines.last?.table == nil { allLines.removeLast() }

        let markdown = TextBlockAssembler.markdown(
            from: allLines,
            options: .init(inferHeadings: options.inferHeadings)
        )
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConversionError.noTextFound(url)
        }
        reporter.reportFinished()
        return markdown
    }

    /// Lines from the page's text layer, carrying the dominant font size and weight so the
    /// assembler can infer headings.
    private func textLayerLines(of page: PDFPage) -> [TextBlockAssembler.Line] {
        guard let attributed = page.attributedString, attributed.length > 0 else { return [] }
        let string = attributed.string as NSString

        var lines: [TextBlockAssembler.Line] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byLines) { substring, range, _, _ in
            let text = (substring ?? "").trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else {
                lines.append(TextBlockAssembler.Line(text: ""))
                return
            }

            // Use the size covering the most characters on the line; a leading drop cap or
            // footnote marker should not decide the whole line's level.
            var sizeWeights: [Double: Int] = [:]
            var boldWeight = 0
            var totalWeight = 0
            attributed.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
                guard let font = value as? NSFont else { return }
                sizeWeights[Double(font.pointSize), default: 0] += subrange.length
                if font.fontDescriptor.symbolicTraits.contains(.bold) { boldWeight += subrange.length }
                totalWeight += subrange.length
            }

            let size = sizeWeights.max(by: { $0.value < $1.value })?.key
            lines.append(TextBlockAssembler.Line(
                text: text,
                fontSize: size,
                isBold: totalWeight > 0 && boldWeight * 2 > totalWeight
            ))
        }
        return lines
    }

    private enum PageContent {
        /// A text layer read by position.
        case layout(PDFPageLayout)
        /// Lines without positions: recognised from a scan, or a text layer that could not be
        /// laid out.
        case lines([TextBlockAssembler.Line])
    }

    /// Text that repeats in the margins of many pages — running heads, footers, page numbers —
    /// which would otherwise interrupt the prose at every page break.
    ///
    /// Candidates are the pieces of text in each page's top and bottom margin, plus its first
    /// and last line. A footer and a page number side by side count separately. A document of
    /// six pages or more needs a candidate on three of them: a pack of several documents
    /// repeats each one's header only on its own pages. Shorter documents need most pages.
    private func runningHeads(in pages: [PageContent]) -> Set<String> {
        guard pages.count >= 3 else { return [] }
        let maximumRunningHeadLength = 80
        // Text in the margin band proper, and text that is merely a page's first or last line,
        // are counted apart: the band is where running heads live, so two repeats are enough
        // there — a three-page form within a pack repeats its header only twice.
        var bandCounts: [String: Int] = [:]
        var edgeCounts: [String: Int] = [:]
        for page in pages {
            var band: Set<String> = []
            var edges: Set<String> = []
            switch page {
            case .layout(let layout):
                let bandRows = layout.bandRowIndices
                for index in layout.marginRowIndices {
                    for segment in layout.rows[index].segments {
                        if bandRows.contains(index) { band.insert(normalize(segment.text)) } else { edges.insert(normalize(segment.text)) }
                    }
                }
            case .lines(let lines):
                for index in edgeIndices(of: lines) { edges.insert(normalize(lines[index].text)) }
            }
            for candidate in band where !candidate.isEmpty && candidate.count <= maximumRunningHeadLength {
                bandCounts[candidate, default: 0] += 1
            }
            for candidate in edges.subtracting(band) where !candidate.isEmpty && candidate.count <= maximumRunningHeadLength {
                edgeCounts[candidate, default: 0] += 1
            }
        }
        let edgeThreshold = pages.count >= 6 ? 3 : max(2, Int((Double(pages.count) * 0.6).rounded()))
        var repeating = Set(edgeCounts.filter { $0.value + (bandCounts[$0.key] ?? 0) >= edgeThreshold }.keys)
        repeating.formUnion(bandCounts.filter { $0.value >= 2 }.keys)
        return repeating
    }

    /// The first and last non-empty line: the only places a running head can be in text
    /// without positions.
    private func edgeIndices(of page: [TextBlockAssembler.Line]) -> Set<Int> {
        let filled = page.indices.filter { !page[$0].text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let first = filled.first, let last = filled.last, first != last else { return [] }
        return [first, last]
    }

    /// Collapses digits and whitespace so "Page 3" and "Page 4" compare equal.
    private func normalize(_ text: String) -> String {
        let collapsed = text
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression)
        return collapsed.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    /// Rasterises a page for OCR at twice its natural size, which measurably improves
    /// recognition of body text.
    private func render(page: PDFPage, scale: CGFloat = 2) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }
}
