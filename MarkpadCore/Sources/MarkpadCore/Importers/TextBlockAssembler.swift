import Foundation

/// Shared logic for turning a stream of recognised text lines into Markdown.
///
/// Both the PDF and image importers produce lines with a little typographic metadata; this
/// type owns the decisions that follow — list detection, paragraph joining, de-hyphenation
/// and escaping — so the two paths cannot drift apart.
public enum TextBlockAssembler {
    public struct Line: Sendable, Equatable {
        public var text: String
        /// Font size in points, when the source knows it.
        public var fontSize: Double?
        public var isBold: Bool

        public init(text: String, fontSize: Double? = nil, isBold: Bool = false) {
            self.text = text
            self.fontSize = fontSize
            self.isBold = isBold
        }
    }

    public struct Options: Sendable {
        /// Infer heading levels from relative font size. Off for OCR, where size estimates
        /// are unreliable enough to produce embarrassing output.
        public var inferHeadings: Bool
        /// Maximum heading depth when inference is on.
        public var maximumHeadingLevels: Int

        public init(inferHeadings: Bool = true, maximumHeadingLevels: Int = 2) {
            self.inferHeadings = inferHeadings
            self.maximumHeadingLevels = maximumHeadingLevels
        }
    }

    private enum Classification {
        case blank
        case heading(level: Int)
        case bullet(text: String)
        case ordered(number: Int, text: String)
        case body
    }

    public static func markdown(from lines: [Line], options: Options = Options()) -> String {
        let headingSizes = options.inferHeadings ? headingSizeLadder(for: lines, options: options) : []

        var blocks: [String] = []
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(paragraph.joined(separator: " "))
            paragraph.removeAll()
        }

        for line in lines {
            switch classify(line, headingSizes: headingSizes) {
            case .blank:
                flushParagraph()

            case .heading(let level):
                flushParagraph()
                blocks.append(String(repeating: "#", count: level) + " " + escapeInline(line.text))

            case .bullet(let text):
                flushParagraph()
                blocks.append("- " + escapeInline(text))

            case .ordered(let number, let text):
                flushParagraph()
                blocks.append("\(number). " + escapeInline(text))

            case .body:
                let text = escapeLine(line.text)
                if var previous = paragraph.last, previous.hasSuffix("-"), !previous.hasSuffix("--") {
                    // Re-join a word split across lines by hyphenation.
                    previous.removeLast()
                    paragraph[paragraph.count - 1] = previous + text
                } else if let previous = paragraph.last, continuesParagraph(previous: previous, next: text) {
                    paragraph.append(text)
                } else {
                    flushParagraph()
                    paragraph.append(text)
                }
            }
        }
        flushParagraph()

        return blocks
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n") + "\n"
    }

    /// Font sizes that should be treated as headings, largest first.
    private static func headingSizeLadder(for lines: [Line], options: Options) -> [Double] {
        let sized = lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty && $0.fontSize != nil }
        guard sized.count >= 3 else { return [] }

        // Body size is the size covering the most characters, not the most lines: a document
        // with many short headings would otherwise pick the wrong baseline.
        var weight: [Double: Int] = [:]
        for line in sized {
            weight[rounded(line.fontSize!), default: 0] += line.text.count
        }
        guard let bodySize = weight.max(by: { $0.value < $1.value })?.key else { return [] }

        let larger = Set(sized.compactMap { line -> Double? in
            let size = rounded(line.fontSize!)
            return size > bodySize * 1.12 ? size : nil
        })
        return Array(larger.sorted(by: >).prefix(options.maximumHeadingLevels))
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 2).rounded() / 2
    }

    private static func classify(_ line: Line, headingSizes: [Double]) -> Classification {
        let trimmed = line.text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .blank }

        if let size = line.fontSize,
           let index = headingSizes.firstIndex(of: rounded(size)),
           trimmed.count < 120 {
            return .heading(level: index + 1)
        }

        if let bullet = bulletContent(of: trimmed) {
            return .bullet(text: bullet)
        }
        if let ordered = orderedContent(of: trimmed) {
            return .ordered(number: ordered.number, text: ordered.text)
        }
        return .body
    }

    private static func bulletContent(of line: String) -> String? {
        for marker in ["• ", "· ", "▪ ", "◦ ", "‣ ", "– ", "— ", "* ", "- "] {
            if line.hasPrefix(marker) {
                return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        // A lone bullet glyph with no space after it.
        if let first = line.first, "•·▪◦‣".contains(first) {
            return String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func orderedContent(of line: String) -> (number: Int, text: String)? {
        let pattern = #"^(\d{1,3})[.)]\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let numberRange = Range(match.range(at: 1), in: line),
              let textRange = Range(match.range(at: 2), in: line),
              let number = Int(line[numberRange]) else {
            return nil
        }
        return (number, String(line[textRange]))
    }

    /// Whether `next` reads as a continuation of `previous` rather than a new paragraph.
    private static func continuesParagraph(previous: String, next: String) -> Bool {
        guard let last = previous.trimmingCharacters(in: .whitespaces).last else { return false }
        if ".!?:;".contains(last) {
            // A sentence ended; only continue if the next line clearly runs on.
            return next.first.map { $0.isLowercase } ?? false
        }
        return true
    }

    /// Escapes characters that would otherwise create unintended block structure.
    private static func escapeLine(_ text: String) -> String {
        var escaped = escapeInline(text)
        let blockStarters = ["#", ">", "|"]
        for starter in blockStarters where escaped.hasPrefix(starter) {
            escaped = "\\" + escaped
            break
        }
        return escaped
    }

    /// Escapes inline emphasis characters so extracted prose renders literally.
    private static func escapeInline(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            if character == "*" || character == "_" || character == "`" || character == "\\" {
                out.append("\\")
            }
            out.append(character)
        }
        return out
    }
}
