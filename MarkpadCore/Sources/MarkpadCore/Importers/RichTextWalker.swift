import AppKit
import Foundation
import UniformTypeIdentifiers

/// Turns an attributed string read by AppKit into Markdown blocks.
///
/// Rich text has no notion of "heading" or, depending on the reader, even of "list": the RTF
/// reader keeps lists as `NSTextList`s, but the Word reader flattens them into literal
/// "\t•\titem" text. So structure is recovered from what survives in every reader —
/// paragraph styles, fonts and marker glyphs — and the rules are kept in one place here.
struct RichTextWalker {
    let attributed: NSAttributedString
    let assets: AssetCollector
    let reporter: ImportReporter

    /// A paragraph must be at least this much larger than body text to count as a heading.
    static let headingScale: CGFloat = 1.15
    static let maximumHeadingLevels = 3
    static let maximumHeadingLength = 120

    /// One paragraph as read, before it is classified.
    private struct Paragraph {
        var runs: [MarkdownRun] = []
        /// The paragraph's text with line breaks as "\n", for marker detection and code blocks.
        var text = ""
        var style: NSParagraphStyle?
        var cell: NSTextTableBlock?
        /// Smallest font size among its visible characters; nil when it has none.
        var minimumFontSize: CGFloat?
        var hasImage = false
        var hasLineBreak = false
        /// True when every visible character is in a monospaced font.
        var allMonospaced = true
    }

    /// Blocks before literal-marker list items get their levels.
    private enum Item {
        case block(MarkdownBlock)
        case literalListItem(indent: CGFloat, ordered: Bool, runs: [MarkdownRun])
    }

    func blocks() throws -> [MarkdownBlock] {
        let paragraphs = try readParagraphs()
        let ladder = headingLadder(for: paragraphs)

        var items: [Item] = []
        var table: TableBuilder?
        var codeLines: [String] = []

        func flushTable() {
            if let rows = table?.rows() { items.append(.block(.table(rows))) }
            table = nil
        }
        func flushCode() {
            if !codeLines.isEmpty { items.append(.block(.code(codeLines.joined(separator: "\n"), language: nil))) }
            codeLines = []
        }

        for (offset, paragraph) in paragraphs.enumerated() {
            if offset % 256 == 0 { try reporter.checkCancellation() }

            if let cell = paragraph.cell {
                flushCode()
                if let current = table, current.table !== cell.table { flushTable() }
                if table == nil { table = TableBuilder(table: cell.table) }
                table?.add(paragraph.runs, to: cell)
                continue
            }
            flushTable()

            let isBlank = paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !paragraph.hasImage
            let textLists = paragraph.style?.textLists ?? []

            if !textLists.isEmpty, !isBlank {
                flushCode()
                var runs = paragraph.runs
                if let marker = Self.literalMarker(in: paragraph.text, requireTab: true) {
                    runs = Self.dropping(marker.length, from: runs)
                }
                let ordered = Self.isOrdered(textLists.last!.markerFormat)
                items.append(.block(.listItem(level: textLists.count - 1, ordered: ordered, runs)))
                continue
            }

            if isBlank {
                // A blank line inside monospaced text is part of the code.
                if !codeLines.isEmpty, paragraph.allMonospaced, paragraph.minimumFontSize == nil {
                    codeLines.append("")
                } else {
                    flushCode()
                }
                continue
            }

            if let marker = Self.literalMarker(in: paragraph.text, requireTab: false) {
                flushCode()
                let indent = paragraph.style.map { max($0.headIndent, $0.firstLineHeadIndent) } ?? 0
                items.append(.literalListItem(
                    indent: indent,
                    ordered: marker.ordered,
                    runs: Self.dropping(marker.length, from: paragraph.runs)
                ))
                continue
            }

            if paragraph.allMonospaced, !paragraph.hasImage {
                codeLines.append(paragraph.text)
                continue
            }
            flushCode()

            if let size = paragraph.minimumFontSize,
               let level = ladder.firstIndex(of: Self.rounded(size)),
               !paragraph.hasLineBreak, !paragraph.hasImage,
               paragraph.text.trimmingCharacters(in: .whitespaces).count < Self.maximumHeadingLength {
                // The size already says "heading"; bold on top of it would be noise.
                let runs = paragraph.runs.map { run -> MarkdownRun in
                    var run = run
                    run.bold = false
                    return run
                }
                items.append(.block(.heading(level: level + 1, runs)))
                continue
            }
            items.append(.block(.paragraph(paragraph.runs)))
        }
        flushTable()
        flushCode()
        return Self.resolveLiteralLists(items)
    }

    // MARK: - Reading

    private func readParagraphs() throws -> [Paragraph] {
        let string = attributed.string as NSString
        let length = string.length
        var paragraphs: [Paragraph] = []
        var start = 0
        var index = 0

        while index <= length {
            let character: unichar = index < length ? string.character(at: index) : 0x0A
            // LF, CR, CRLF, paragraph separator and form feed (Word's page break) end a paragraph.
            let isSeparator = character == 0x0A || character == 0x0D || character == 0x2029 || character == 0x0C
            if isSeparator {
                if index < length || start < length {
                    let range = NSRange(location: start, length: index - start)
                    let styleIndex = min(index, max(length - 1, 0))
                    try autoreleasepool {
                        if paragraphs.count % 256 == 0 { try reporter.checkCancellation() }
                        paragraphs.append(read(range, styleAt: styleIndex))
                    }
                }
                if character == 0x0D, index + 1 < length, string.character(at: index + 1) == 0x0A { index += 1 }
                start = index + 1
            }
            index += 1
        }
        return paragraphs
    }

    private func read(_ range: NSRange, styleAt styleIndex: Int) -> Paragraph {
        var paragraph = Paragraph()
        guard attributed.length > 0 else { return paragraph }
        let styleLocation = range.length > 0 ? range.location : styleIndex
        paragraph.style = attributed.attribute(.paragraphStyle, at: styleLocation, effectiveRange: nil) as? NSParagraphStyle
        paragraph.cell = paragraph.style?.textBlocks.lazy.compactMap { $0 as? NSTextTableBlock }.first
        guard range.length > 0 else { return paragraph }

        let string = attributed.string as NSString
        attributed.enumerateAttributes(in: range) { attributes, runRange, _ in
            let text = string.substring(with: runRange)
            let font = attributes[.font] as? NSFont
            let traits = font?.fontDescriptor.symbolicTraits ?? []
            let isMonospaced = font.map { traits.contains(.monoSpace) || $0.isFixedPitch } ?? false
            var style = MarkdownRun("")
            style.bold = traits.contains(.bold)
            style.italic = traits.contains(.italic)
            style.strikethrough = ((attributes[.strikethroughStyle] as? Int) ?? 0) != 0
            style.code = isMonospaced
            if let url = attributes[.link] as? URL {
                style.link = url.absoluteString
            } else if let link = attributes[.link] as? String, !link.isEmpty {
                style.link = link
            }

            var pending = ""
            func flush() {
                guard !pending.isEmpty else { return }
                var run = style
                run.text = pending
                paragraph.runs.append(run)
                paragraph.text += pending
                if pending.contains(where: { !$0.isWhitespace }) {
                    if let size = font?.pointSize {
                        paragraph.minimumFontSize = min(paragraph.minimumFontSize ?? size, size)
                    }
                    if !isMonospaced { paragraph.allMonospaced = false }
                }
                pending = ""
            }

            for character in text {
                switch character {
                case "\u{2028}", "\u{0B}":
                    flush()
                    paragraph.runs.append(.lineBreak)
                    paragraph.text += "\n"
                    paragraph.hasLineBreak = true
                case "\u{FFFC}":
                    flush()
                    if let attachment = attributes[.attachment] as? NSTextAttachment,
                       let image = picture(from: attachment) {
                        paragraph.runs.append(image)
                        paragraph.hasImage = true
                        paragraph.allMonospaced = false
                    }
                default:
                    pending.append(character)
                }
            }
            flush()
        }
        return paragraph
    }

    /// The image run for an attachment, or nil when it is not a picture or pictures are not kept.
    private func picture(from attachment: NSTextAttachment) -> MarkdownRun? {
        var data: Data?
        var name = "image"
        if let wrapper = attachment.fileWrapper, wrapper.isRegularFile {
            data = wrapper.regularFileContents
            name = wrapper.preferredFilename ?? wrapper.filename ?? name
        } else if let contents = attachment.contents {
            data = contents
            if let ext = attachment.fileType.flatMap({ UTType($0)?.preferredFilenameExtension }) {
                name += "." + ext
            }
        } else if let image = attachment.image,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff) {
            data = bitmap.representation(using: .png, properties: [:])
            name += ".png"
        }
        guard let data, !data.isEmpty else { return nil }

        let ext = (name as NSString).pathExtension
        let isImage = UTType(filenameExtension: ext)?.conforms(to: .image) == true
            || AssetCollector.sniffExtension(data) != "bin"
        guard isImage, let destination = assets.add(data, suggestedName: name) else { return nil }
        return .image(alt: "", destination: destination)
    }

    // MARK: - Headings

    /// Font sizes that make a paragraph a heading, largest first.
    ///
    /// Body size is the size covering the most characters, as in `TextBlockAssembler`: a
    /// document with many short headings would otherwise pick the wrong baseline.
    private func headingLadder(for paragraphs: [Paragraph]) -> [CGFloat] {
        var weight: [CGFloat: Int] = [:]
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            guard let font = value as? NSFont else { return }
            let text = (attributed.string as NSString).substring(with: range)
            let visible = text.filter { !$0.isWhitespace && $0 != "\u{FFFC}" }.count
            if visible > 0 { weight[Self.rounded(font.pointSize), default: 0] += visible }
        }
        guard let body = weight.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key else { return [] }

        var sizes = Set<CGFloat>()
        for paragraph in paragraphs where paragraph.cell == nil && (paragraph.style?.textLists ?? []).isEmpty {
            guard let size = paragraph.minimumFontSize, size >= body * Self.headingScale else { continue }
            sizes.insert(Self.rounded(size))
        }
        return Array(sizes.sorted(by: >).prefix(Self.maximumHeadingLevels))
    }

    private static func rounded(_ value: CGFloat) -> CGFloat {
        (value * 2).rounded() / 2
    }

    // MARK: - Lists

    private static let unorderedFormats: Set<NSTextList.MarkerFormat> = [
        .box, .check, .circle, .diamond, .disc, .hyphen, .square,
    ]

    static func isOrdered(_ format: NSTextList.MarkerFormat) -> Bool {
        !unorderedFormats.contains(format)
    }

    struct Marker {
        /// Characters to drop from the start of the paragraph.
        var length: Int
        var ordered: Bool
    }

    private static let bulletGlyphs = "•◦▪▫‣·○●■□➢➤✓–—*-"
    /// Glyphs that are list markers even without a tab after them; `-` and `*` are not,
    /// since "- 5 degrees" and "* see note" occur in prose.
    private static let unambiguousBulletGlyphs = "•◦▪▫‣○●■□➢➤"

    /// A list marker typed or written out as text at the start of a paragraph, as the Word
    /// reader produces: "\t•\tone", "\t1\tfirst", "a)\tstep".
    ///
    /// A tab must separate the marker from the text unless the marker is an unmistakable
    /// bullet glyph; otherwise "1990. A good year" would become a list.
    static func literalMarker(in text: String, requireTab: Bool) -> Marker? {
        let characters = Array(text)
        var index = 0
        var sawTab = false
        while index < characters.count, characters[index] == "\t" || characters[index] == " " {
            if characters[index] == "\t" { sawTab = true }
            index += 1
        }
        guard index < characters.count else { return nil }

        var ordered = false
        var unambiguous = false
        let first = characters[index]
        if bulletGlyphs.contains(first) {
            unambiguous = unambiguousBulletGlyphs.contains(first)
            index += 1
        } else {
            var cursor = index
            if characters[cursor] == "(" { cursor += 1 }
            let tokenStart = cursor
            while cursor < characters.count, characters[cursor].isASCII,
                  characters[cursor].isLetter || characters[cursor].isNumber {
                cursor += 1
            }
            let token = String(characters[tokenStart..<cursor])
            let isNumber = !token.isEmpty && token.count <= 4 && token.allSatisfy(\.isNumber)
            let isLetter = token.count == 1 && token.first!.isLetter
            let isRoman = !token.isEmpty && token.count <= 6
                && token.lowercased().allSatisfy { "ivxlcdm".contains($0) }
            guard isNumber || isLetter || isRoman else { return nil }
            if cursor < characters.count, characters[cursor] == "." || characters[cursor] == ")" {
                cursor += 1
            } else if !isNumber {
                return nil
            }
            ordered = true
            index = cursor
        }

        // The separator after the marker.
        guard index < characters.count, characters[index] == "\t" || characters[index] == " " else { return nil }
        var separatorHasTab = false
        while index < characters.count, characters[index] == "\t" || characters[index] == " " {
            if characters[index] == "\t" { separatorHasTab = true }
            index += 1
        }
        guard index < characters.count else { return nil }
        if requireTab || !unambiguous {
            // Numbers need a tab straight after them; "\t1 first" is not a list marker.
            guard separatorHasTab || (sawTab && !ordered) else { return nil }
        }
        return Marker(length: index, ordered: ordered)
    }

    /// Removes the first `count` characters from a run sequence.
    static func dropping(_ count: Int, from runs: [MarkdownRun]) -> [MarkdownRun] {
        var remaining = count
        var result: [MarkdownRun] = []
        for run in runs {
            if remaining == 0 || run.imageDestination != nil {
                result.append(run)
                continue
            }
            if run.text.count <= remaining {
                remaining -= run.text.count
                continue
            }
            var trimmed = run
            trimmed.text = String(run.text.dropFirst(remaining))
            remaining = 0
            result.append(trimmed)
        }
        return result
    }

    /// Gives literal-marker list items levels by ranking the indents within each list.
    private static func resolveLiteralLists(_ items: [Item]) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var group: [(indent: CGFloat, ordered: Bool, runs: [MarkdownRun])] = []

        func flush() {
            let indents = Array(Set(group.map { rounded($0.indent) })).sorted()
            for item in group {
                let level = indents.firstIndex(of: rounded(item.indent)) ?? 0
                blocks.append(.listItem(level: level, ordered: item.ordered, item.runs))
            }
            group = []
        }

        for item in items {
            switch item {
            case .literalListItem(let indent, let ordered, let runs):
                group.append((indent, ordered, runs))
            case .block(let block):
                flush()
                blocks.append(block)
            }
        }
        flush()
        return blocks
    }
}

/// Collects the cells of one `NSTextTable` as its paragraphs arrive.
private struct TableBuilder {
    let table: NSTextTable
    private var cells: [Position: [MarkdownRun]] = [:]

    private struct Position: Hashable {
        var row: Int
        var column: Int
    }

    init(table: NSTextTable) {
        self.table = table
    }

    /// A cell holding several paragraphs keeps them apart with line breaks, which the
    /// renderer turns into spaces inside a table.
    mutating func add(_ runs: [MarkdownRun], to cell: NSTextTableBlock) {
        let position = Position(row: cell.startingRow, column: cell.startingColumn)
        if var existing = cells[position] {
            existing.append(.lineBreak)
            existing += runs
            cells[position] = existing
        } else {
            cells[position] = runs
        }
    }

    func rows() -> [[[MarkdownRun]]]? {
        guard !cells.isEmpty else { return nil }
        let rowCount = (cells.keys.map(\.row).max() ?? 0) + 1
        let columnCount = max((cells.keys.map(\.column).max() ?? 0) + 1, 1)
        var rows: [[[MarkdownRun]]] = Array(
            repeating: Array(repeating: [], count: columnCount), count: rowCount)
        for (position, runs) in cells where position.row >= 0 && position.column >= 0 {
            rows[position.row][position.column] = runs
        }
        // Drop rows that are empty throughout, such as the far side of a merged cell.
        rows = rows.filter { row in
            row.contains { $0.contains { $0.imageDestination != nil || !$0.text.allSatisfy(\.isWhitespace) } }
        }
        guard !rows.isEmpty else { return nil }
        // Header cells are usually bold; the header row already says so.
        let headerVisible = rows[0].flatMap { $0 }.filter { !$0.text.allSatisfy(\.isWhitespace) }
        if !headerVisible.isEmpty, headerVisible.allSatisfy(\.bold) {
            rows[0] = rows[0].map { $0.map { run in
                var run = run
                run.bold = false
                return run
            } }
        }
        return rows
    }
}
