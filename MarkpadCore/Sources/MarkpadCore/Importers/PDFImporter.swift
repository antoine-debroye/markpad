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

    public func convert(url: URL, options: Options = Options()) throws -> String {
        guard let document = PDFDocument(url: url) else {
            throw ConversionError.unreadableFile(url)
        }

        var pages: [[TextBlockAssembler.Line]] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            var lines = textLayerLines(of: page)

            let hasText = lines.contains { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            if !hasText, options.performOCRWhenNeeded, let image = render(page: page) {
                lines = (try? ImageImporter().recognizeLines(in: image, options: .init())) ?? []
            }
            pages.append(lines)
        }

        var allLines = options.stripRepeatingHeadersAndFooters
            ? removingRunningHeads(from: pages)
            : pages.flatMap { $0 + [TextBlockAssembler.Line(text: "")] }

        // A page break always ends a paragraph.
        if allLines.last?.text.isEmpty == true { allLines.removeLast() }

        let markdown = TextBlockAssembler.markdown(
            from: allLines,
            options: .init(inferHeadings: options.inferHeadings)
        )
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConversionError.noTextFound(url)
        }
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

    /// Removes lines that appear on most pages — page numbers and running heads — which
    /// would otherwise interrupt the prose at every page boundary.
    private func removingRunningHeads(from pages: [[TextBlockAssembler.Line]]) -> [TextBlockAssembler.Line] {
        guard pages.count >= 3 else {
            return pages.flatMap { $0 + [TextBlockAssembler.Line(text: "")] }
        }

        // Only the topmost and bottommost non-empty line of each page can be a running head,
        // and only if it is short. Body text that happens to repeat must survive.
        func edgeIndices(of page: [TextBlockAssembler.Line]) -> Set<Int> {
            let filled = page.indices.filter { !page[$0].text.trimmingCharacters(in: .whitespaces).isEmpty }
            guard let first = filled.first, let last = filled.last, first != last else { return [] }
            return [first, last]
        }

        let maximumRunningHeadLength = 80
        var counts: [String: Int] = [:]
        for page in pages {
            let candidates = Set(edgeIndices(of: page).compactMap { index -> String? in
                let text = page[index].text.trimmingCharacters(in: .whitespaces)
                guard text.count <= maximumRunningHeadLength else { return nil }
                return normalize(text)
            })
            for candidate in candidates where !candidate.isEmpty {
                counts[candidate, default: 0] += 1
            }
        }
        let threshold = max(2, Int((Double(pages.count) * 0.6).rounded()))
        let repeating = Set(counts.filter { $0.value >= threshold }.keys)

        var result: [TextBlockAssembler.Line] = []
        for page in pages {
            let edges = edgeIndices(of: page)
            for (index, line) in page.enumerated() {
                if edges.contains(index), repeating.contains(normalize(line.text)) { continue }
                result.append(line)
            }
            result.append(TextBlockAssembler.Line(text: ""))
        }
        return result
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
