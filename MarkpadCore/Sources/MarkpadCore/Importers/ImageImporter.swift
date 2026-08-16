import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Converts an image of text into Markdown using on-device text recognition.
///
/// Structure inference is deliberately conservative: OCR gives reliable text and line
/// geometry but unreliable type sizes, so output is paragraphs and lists rather than
/// invented heading levels.
public struct ImageImporter: Sendable {
    public struct Options: Sendable {
        public var languages: [String]
        public var usesLanguageCorrection: Bool

        public init(languages: [String] = ["en-US"], usesLanguageCorrection: Bool = true) {
            self.languages = languages
            self.usesLanguageCorrection = usesLanguageCorrection
        }
    }

    public init() {}

    public func convert(
        url: URL,
        options: Options = Options(),
        progress: ImportProgress.Handler? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ConversionError.unreadableFile(url)
        }
        let markdown = try convert(image: image, options: options, progress: progress, isCancelled: isCancelled)
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConversionError.noTextFound(url)
        }
        return markdown
    }

    public func convert(
        image: CGImage,
        options: Options = Options(),
        progress: ImportProgress.Handler? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> String {
        // One image is one unit of work, so there are no pages to count.
        let reporter = ImportReporter(totalUnits: 1, handler: progress, isCancelled: isCancelled)
        reporter.report(.recognizingText, index: 0)
        try reporter.checkCancellation()

        let lines = try recognizeLines(in: image, options: options)
        reporter.reportAssembling()

        let markdown = TextBlockAssembler.markdown(
            from: lines,
            options: .init(inferHeadings: false)
        )
        reporter.reportFinished()
        return markdown
    }

    /// Recognised text grouped into reading order, with blank lines inserted where the
    /// vertical gap suggests a paragraph break.
    func recognizeLines(in image: CGImage, options: Options) throws -> [TextBlockAssembler.Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = options.usesLanguageCorrection
        request.recognitionLanguages = options.languages

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        guard let observations = request.results, !observations.isEmpty else { return [] }

        struct Fragment {
            let text: String
            let box: CGRect
        }

        // Vision reports normalised coordinates with the origin at the bottom left.
        let fragments = observations.compactMap { observation -> Fragment? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return Fragment(text: candidate.string, box: observation.boundingBox)
        }.sorted { lhs, rhs in
            // Same visual row when the vertical centres overlap; then order left to right.
            if abs(lhs.box.midY - rhs.box.midY) < max(lhs.box.height, rhs.box.height) * 0.5 {
                return lhs.box.minX < rhs.box.minX
            }
            return lhs.box.midY > rhs.box.midY
        }

        // Merge fragments that share a row (multi-column recognition of one line).
        var rows: [[Fragment]] = []
        for fragment in fragments {
            if let last = rows.last?.last,
               abs(last.box.midY - fragment.box.midY) < max(last.box.height, fragment.box.height) * 0.5 {
                rows[rows.count - 1].append(fragment)
            } else {
                rows.append([fragment])
            }
        }

        let rowBoxes = rows.map { row in row.dropFirst().reduce(row[0].box) { $0.union($1.box) } }
        let heights = rowBoxes.map(\.height).sorted()
        let medianHeight = heights.isEmpty ? 0 : heights[heights.count / 2]

        var lines: [TextBlockAssembler.Line] = []
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let gap = rowBoxes[index - 1].minY - rowBoxes[index].maxY
                if medianHeight > 0, gap > medianHeight * 0.9 {
                    lines.append(TextBlockAssembler.Line(text: ""))
                }
            }
            lines.append(TextBlockAssembler.Line(text: row.map(\.text).joined(separator: " ")))
        }
        return lines
    }
}
