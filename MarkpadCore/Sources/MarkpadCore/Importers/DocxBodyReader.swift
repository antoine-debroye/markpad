import Foundation

/// Walks the body of a WordprocessingML document and turns it into Markdown blocks.
///
/// Reads the XML directly rather than going through `NSAttributedString`, whose Word reader
/// drops tables and hyperlinks and flattens lists into indented text.
final class DocxBodyReader {
    /// A paragraph's contribution. Source-code paragraphs stay separate lines until the end,
    /// when consecutive ones are joined into one fenced block.
    enum Item {
        case block(MarkdownBlock)
        case codeLine(String)
    }

    private enum ParagraphKind {
        case heading(Int)
        case list(level: Int, ordered: Bool)
        case quote
        case code
        case body
    }

    /// A complex field (`w:fldChar` begin … separate … end) currently open.
    private struct Field {
        var instruction = ""
        var inResult = false
        var link: String?
    }

    private struct InlineContext {
        /// Run properties the paragraph style gives its text.
        var base: DocxRunProperties
        var link: String?
    }

    private struct RunStyle {
        var bold: Bool
        var italic: Bool
        var strikethrough: Bool
        var code: Bool
        var hidden: Bool
        var font: String?
    }

    static let metafileNotice = "Some pictures are Windows metafiles (EMF/WMF), which may not display on a Mac."

    private let zip: ZipReader
    private let partPath: String
    private let relationships: [String: DocxPartRelationship]
    private let styles: DocxStyles
    private let numbering: DocxNumbering
    private let collector: AssetCollector
    private let reporter: ImportReporter
    private let totalParagraphs: Int

    private(set) var notices: [String] = []
    private var fields: [Field] = []
    private var paragraphsRead = 0
    private var notedMetafiles = false

    init(
        zip: ZipReader,
        partPath: String,
        relationships: [String: DocxPartRelationship],
        styles: DocxStyles,
        numbering: DocxNumbering,
        collector: AssetCollector,
        reporter: ImportReporter,
        totalParagraphs: Int
    ) {
        self.zip = zip
        self.partPath = partPath
        self.relationships = relationships
        self.styles = styles
        self.numbering = numbering
        self.collector = collector
        self.reporter = reporter
        self.totalParagraphs = totalParagraphs
    }

    func blocks(from body: DocxNode) throws -> [MarkdownBlock] {
        var items: [Item] = []
        try readBlocks(body.children, into: &items)
        return Self.assemble(items)
    }

    static func assemble(_ items: [Item]) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var code: [String] = []
        func flush() {
            while code.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { code.removeFirst() }
            while code.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { code.removeLast() }
            if !code.isEmpty { blocks.append(.code(code.joined(separator: "\n"), language: nil)) }
            code = []
        }
        for item in items {
            switch item {
            case .codeLine(let line): code.append(line)
            case .block(let block):
                flush()
                blocks.append(block)
            }
        }
        flush()
        return blocks
    }

    // MARK: - Blocks

    private func readBlocks(_ nodes: [DocxNode], into items: inout [Item]) throws {
        for node in nodes {
            switch node.name {
            case "w:p":
                try readParagraph(node, into: &items)
            case "w:tbl":
                if let table = try readTable(node) { items.append(.block(table)) }
            case "w:sdt":
                try readBlocks(node.child("w:sdtContent")?.children ?? [], into: &items)
            case "mc:AlternateContent":
                let before = items.count
                for option in Self.alternatives(node) {
                    try readBlocks(option.children, into: &items)
                    if items.count != before { break }
                }
            case "w:del", "w:moveFrom", "w:sectPr", "w:sdtPr", "w:sdtEndPr", "w:pPr", "w:rPr", "w:tblPr":
                continue
            default:
                try readBlocks(node.children, into: &items)
            }
        }
    }

    /// Markup-compatibility options in preference order: each Choice, then the Fallback.
    private static func alternatives(_ node: DocxNode) -> [DocxNode] {
        node.children("mc:Choice") + node.children("mc:Fallback")
    }

    private func tick() throws {
        paragraphsRead += 1
        if paragraphsRead % 50 == 0 {
            try reporter.checkCancellation()
            let share = Double(paragraphsRead) / Double(max(totalParagraphs, 1))
            reporter.report(.extractingText, fraction: min(0.05 + 0.9 * share, 0.95))
        }
    }

    private func readParagraph(_ paragraph: DocxNode, into items: inout [Item]) throws {
        try tick()
        let pPr = paragraph.child("w:pPr")
        let styleID = pPr?.child("w:pStyle")?.attr("val") ?? styles.defaultParagraphStyle
        let kind = classify(pPr: pPr, styleID: styleID)

        // Headings, quotes and code carry their look in the Markdown construct itself, so the
        // bold of a heading style or the italic of a quote style is not repeated as emphasis.
        let base: DocxRunProperties
        switch kind {
        case .list, .body: base = styles.runProperties(styleID)
        case .heading, .quote, .code: base = DocxRunProperties()
        }

        var runs: [MarkdownRun] = []
        var extras: [Item] = []
        try readInline(paragraph.children, context: InlineContext(base: base), runs: &runs, extras: &extras)

        if case .code = kind {
            items.append(.codeLine(Self.plainText(runs)))
            items += extras
            return
        }

        let hasContent = runs.contains {
            $0.imageDestination != nil || !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if hasContent {
            switch kind {
            case .heading(let level):
                items.append(.block(.heading(level: level, runs.map { run in
                    var run = run
                    run.bold = false
                    return run
                })))
            case .list(let level, let ordered):
                items.append(.block(.listItem(level: level, ordered: ordered, runs)))
            case .quote:
                items.append(.block(.quote(runs)))
            case .code:
                break
            case .body:
                if let (ordered, stripped) = Self.textualListMarker(runs) {
                    items.append(.block(.listItem(level: Self.indentLevel(pPr), ordered: ordered, stripped)))
                } else if Self.isAllCode(runs) {
                    items.append(.codeLine(Self.plainText(runs)))
                } else {
                    items.append(.block(.paragraph(runs)))
                }
            }
        }
        items += extras
    }

    private func classify(pPr: DocxNode?, styleID: String?) -> ParagraphKind {
        if let direct = pPr?.child("w:outlineLvl")?.attr("val").flatMap({ Int($0) }) {
            if (0...8).contains(direct) { return .heading(min(direct + 1, 6)) }
        } else if let level = styles.headingLevel(styleID) {
            return .heading(min(level, 6))
        }

        let numPr = pPr?.child("w:numPr")
        var numberingID = numPr?.child("w:numId")?.attr("val")
        var level = numPr?.child("w:ilvl")?.attr("val").flatMap { Int($0) }
        if numberingID == nil, let inherited = styles.numbering(styleID) {
            numberingID = inherited.id
            level = level ?? inherited.level
        }
        if let numberingID, numberingID != "0" {
            let clamped = min(max(level ?? 0, 0), 8)
            return .list(level: clamped, ordered: numbering.isOrdered(numberingID, level: clamped, styles: styles))
        }

        if styles.isCode(styleID) { return .code }
        if styles.isQuote(styleID) { return .quote }
        return .body
    }

    // MARK: - Inline content

    private func readInline(
        _ nodes: [DocxNode],
        context: InlineContext,
        runs: inout [MarkdownRun],
        extras: inout [Item]
    ) throws {
        for node in nodes {
            switch node.name {
            case "w:r":
                try readRun(node, context: context, runs: &runs, extras: &extras)
            case "w:hyperlink":
                var inner = context
                if let link = hyperlinkTarget(node) { inner.link = link }
                try readInline(node.children, context: inner, runs: &runs, extras: &extras)
            case "w:fldSimple":
                var inner = context
                if let link = node.attr("instr").flatMap(Self.hyperlinkTarget(instruction:)) { inner.link = link }
                try readInline(node.children, context: inner, runs: &runs, extras: &extras)
            case "w:sdt":
                try readInline(node.child("w:sdtContent")?.children ?? [], context: context, runs: &runs, extras: &extras)
            case "mc:AlternateContent":
                let before = runs.count + extras.count
                for option in Self.alternatives(node) {
                    try readInline(option.children, context: context, runs: &runs, extras: &extras)
                    if runs.count + extras.count != before { break }
                }
            case "m:t":
                if !suppressingFieldCode, !node.text.isEmpty {
                    runs.append(MarkdownRun(node.text, link: activeLink(context)))
                }
            case "w:del", "w:moveFrom", "w:pPr", "w:rPr", "w:sdtPr", "w:sdtEndPr", "w:customXmlPr", "m:rPr":
                continue
            default:
                try readInline(node.children, context: context, runs: &runs, extras: &extras)
            }
        }
    }

    private func readRun(_ run: DocxNode, context: InlineContext, runs: inout [MarkdownRun], extras: inout [Item]) throws {
        let rPr = run.child("w:rPr")
        let characterStyle = rPr?.child("w:rStyle")?.attr("val")
        let properties = context.base
            .overlaid(with: styles.runProperties(characterStyle))
            .overlaid(with: DocxRunProperties(rPr))
        let style = RunStyle(
            bold: properties.bold ?? false,
            italic: properties.italic ?? false,
            strikethrough: properties.strikethrough ?? false,
            code: properties.isMonospace || styles.isCodeCharacterStyle(characterStyle),
            hidden: properties.hidden ?? false,
            font: properties.font
        )
        try readRunContent(run.children, style: style, context: context, runs: &runs, extras: &extras)
    }

    private func readRunContent(
        _ nodes: [DocxNode],
        style: RunStyle,
        context: InlineContext,
        runs: inout [MarkdownRun],
        extras: inout [Item]
    ) throws {
        func append(_ text: String) {
            guard !text.isEmpty, !style.hidden, !suppressingFieldCode else { return }
            runs.append(MarkdownRun(
                text,
                bold: style.bold,
                italic: style.italic,
                strikethrough: style.strikethrough,
                code: style.code,
                link: activeLink(context)
            ))
        }

        for node in nodes {
            switch node.name {
            case "w:t":
                append(node.text.replacingOccurrences(of: "\u{AD}", with: ""))
            case "w:tab", "w:ptab":
                append("\t")
            case "w:br":
                // Page and column breaks are layout, not content.
                let type = node.attr("type")
                if type == nil || type == "textWrapping" { append("\n") }
            case "w:cr":
                append("\n")
            case "w:noBreakHyphen":
                append("-")
            case "w:sym":
                if let symbol = Self.symbol(node) { append(symbol) }
            case "w:fldChar":
                handleFieldCharacter(node)
            case "w:instrText":
                if let last = fields.indices.last, !fields[last].inResult {
                    fields[last].instruction += node.text
                }
            case "w:drawing":
                try readDrawing(node, context: context, runs: &runs, extras: &extras)
            case "w:pict", "w:object":
                try readLegacyPicture(node, context: context, runs: &runs, extras: &extras)
            case "mc:AlternateContent":
                let before = runs.count + extras.count
                for option in Self.alternatives(node) {
                    try readRunContent(option.children, style: style, context: context, runs: &runs, extras: &extras)
                    if runs.count + extras.count != before { break }
                }
            case "w:ruby":
                if let base = node.child("w:rubyBase") {
                    try readInline(base.children, context: context, runs: &runs, extras: &extras)
                }
            default:
                // w:delText, w:footnoteReference, w:commentReference, w:lastRenderedPageBreak…
                continue
            }
        }
    }

    // MARK: - Fields and links

    /// True between a field's begin and separate marks, where the text is its instruction.
    private var suppressingFieldCode: Bool { fields.contains { !$0.inResult } }

    private func activeLink(_ context: InlineContext) -> String? {
        fields.last { $0.inResult && $0.link != nil }?.link ?? context.link
    }

    private func handleFieldCharacter(_ node: DocxNode) {
        switch node.attr("fldCharType") {
        case "begin":
            if fields.count < 64 { fields.append(Field()) }
        case "separate":
            if let last = fields.indices.last {
                fields[last].inResult = true
                fields[last].link = Self.hyperlinkTarget(instruction: fields[last].instruction)
            }
        case "end":
            if !fields.isEmpty { fields.removeLast() }
        default:
            break
        }
    }

    /// Where a `w:hyperlink` points. One with only a `w:anchor` jumps within the document,
    /// which has no Markdown counterpart, so its text is kept unlinked.
    private func hyperlinkTarget(_ node: DocxNode) -> String? {
        guard let id = node.attr("r:id"), let relationship = relationships[id] else { return nil }
        let target = relationship.target.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        if let anchor = node.attr("anchor"), !anchor.isEmpty, !target.contains("#") {
            return target + "#" + anchor
        }
        return target
    }

    /// The destination of a `HYPERLINK "url" \l "anchor"` field instruction, or nil for any
    /// other field or a link to a bookmark in this document.
    static func hyperlinkTarget(instruction: String) -> String? {
        let tokens = fieldTokens(instruction)
        guard let first = tokens.first, !first.quoted, first.text.uppercased() == "HYPERLINK" else { return nil }
        var url: String?
        var anchor: String?
        var index = 1
        while index < tokens.count {
            let token = tokens[index]
            if !token.quoted, token.text.hasPrefix("\\") {
                let name = token.text.lowercased()
                if ["\\l", "\\o", "\\t"].contains(name) {
                    if name == "\\l", index + 1 < tokens.count { anchor = tokens[index + 1].text }
                    index += 2
                } else {
                    index += 1
                }
                continue
            }
            if url == nil { url = token.text }
            index += 1
        }
        guard let rawURL = url?.trimmingCharacters(in: .whitespaces), !rawURL.isEmpty else { return nil }
        // Field instructions double backslashes, as in "C:\\Reports\\q3.docx".
        let target = rawURL.replacingOccurrences(of: "\\\\", with: "\\")
        if let anchor, !anchor.isEmpty { return target + "#" + anchor }
        return target
    }

    private static func fieldTokens(_ instruction: String) -> [(text: String, quoted: Bool)] {
        var tokens: [(text: String, quoted: Bool)] = []
        var current = ""
        var inQuotes = false
        var hasToken = false
        for character in instruction {
            if character == "\"" || character == "\u{201C}" || character == "\u{201D}" {
                if inQuotes {
                    tokens.append((current, true))
                    inQuotes = false
                } else {
                    if hasToken { tokens.append((current, false)) }
                    inQuotes = true
                }
                current = ""
                hasToken = false
                continue
            }
            if !inQuotes, character.isWhitespace {
                if hasToken { tokens.append((current, false)) }
                current = ""
                hasToken = false
                continue
            }
            current.append(character)
            hasToken = true
        }
        if hasToken { tokens.append((current, inQuotes)) }
        return tokens
    }

    // MARK: - Pictures

    private func readDrawing(_ drawing: DocxNode, context: InlineContext, runs: inout [MarkdownRun], extras: inout [Item]) throws {
        let textBoxes: Set<String> = ["w:txbxContent"]
        let properties = drawing.firstDescendant("wp:docPr", skipping: textBoxes)
        let alt = Self.altText(properties?.attr("descr"), properties?.attr("title"))
        for blip in drawing.descendants("a:blip", skipping: textBoxes) {
            if let id = blip.attr("r:embed"), let run = picture(id, alt: alt, link: activeLink(context)) {
                runs.append(run)
            }
        }
        for box in drawing.descendants("w:txbxContent") {
            try readBlocks(box.children, into: &extras)
        }
    }

    private func readLegacyPicture(_ picture: DocxNode, context: InlineContext, runs: inout [MarkdownRun], extras: inout [Item]) throws {
        let textBoxes: Set<String> = ["w:txbxContent"]
        let shapeAlt = picture.firstDescendant("v:shape", skipping: textBoxes)?.attr("alt")
        for imageData in picture.descendants("v:imagedata", skipping: textBoxes) {
            guard let id = imageData.attr("r:id") ?? imageData.attr("r:pict") else { continue }
            let alt = Self.altText(shapeAlt, imageData.attr("title"))
            if let run = self.picture(id, alt: alt, link: activeLink(context)) { runs.append(run) }
        }
        for box in picture.descendants("w:txbxContent") {
            try readBlocks(box.children, into: &extras)
        }
    }

    private static func altText(_ description: String?, _ title: String?) -> String {
        for candidate in [description, title] {
            let text = (candidate ?? "").replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return ""
    }

    /// The run for the picture behind relationship `id`: an image when pictures are kept,
    /// otherwise its alt text, or nothing when it has none.
    private func picture(_ id: String, alt: String, link: String?) -> MarkdownRun? {
        let fallback = alt.isEmpty ? nil : MarkdownRun(alt, link: link)
        guard let relationship = relationships[id], !relationship.isExternal,
              let path = ZipReader.resolve(relationship.target, relativeTo: partPath),
              let data = try? zip.data(for: path), !data.isEmpty else {
            return fallback
        }
        let name = (path as NSString).lastPathComponent
        guard let destination = collector.add(data, suggestedName: name) else { return fallback }
        let fileExtension = (name as NSString).pathExtension.lowercased()
        if ["emf", "wmf", "emz", "wmz"].contains(fileExtension), !notedMetafiles {
            notedMetafiles = true
            notices.append(Self.metafileNotice)
        }
        return .image(alt: alt, destination: destination, link: link)
    }

    // MARK: - Tables

    private func readTable(_ table: DocxNode) throws -> MarkdownBlock? {
        var rows: [[[MarkdownRun]]] = []
        for row in Self.collect("w:tr", in: table.children) {
            let rowProperties = row.child("w:trPr")
            if rowProperties?.child("w:del") != nil { continue }
            var cells: [[MarkdownRun]] = []
            let skipped = rowProperties?.child("w:gridBefore")?.attr("val").flatMap { Int($0) } ?? 0
            cells += Array(repeating: [], count: min(max(skipped, 0), 64))
            for cell in Self.collect("w:tc", in: row.children) {
                let cellProperties = cell.child("w:tcPr")
                let span = min(max(cellProperties?.child("w:gridSpan")?.attr("val").flatMap { Int($0) } ?? 1, 1), 64)
                let merge = cellProperties?.child("w:vMerge")
                // A vertically merged cell repeats nothing below its first row.
                let continuation = merge != nil && (merge?.attr("val") ?? "continue") == "continue"
                cells.append(continuation ? [] : try cellRuns(cell.children))
                cells += Array(repeating: [], count: span - 1)
            }
            if !cells.isEmpty { rows.append(cells) }
        }
        guard rows.contains(where: { $0.contains { !$0.isEmpty } }) else { return nil }
        // Markdown already sets the header row in bold, so Word's bold there is not repeated.
        rows[0] = rows[0].map { cell in
            cell.map { run in
                var run = run
                run.bold = false
                return run
            }
        }
        return .table(rows)
    }

    /// Rows or cells, looking through the content controls and revision marks that wrap them.
    private static func collect(_ name: String, in nodes: [DocxNode]) -> [DocxNode] {
        var found: [DocxNode] = []
        for node in nodes {
            if node.name == name {
                found.append(node)
            } else if ["w:sdt", "w:sdtContent", "w:customXml", "w:ins", "w:moveTo"].contains(node.name) {
                found += collect(name, in: node.children)
            }
        }
        return found
    }

    /// A cell holds one line in Markdown: its paragraphs, and any table nested in it, are
    /// joined with spaces.
    private func cellRuns(_ nodes: [DocxNode]) throws -> [MarkdownRun] {
        var pieces: [[MarkdownRun]] = []
        try cellPieces(nodes, into: &pieces)
        var runs: [MarkdownRun] = []
        for piece in pieces where piece.contains(where: {
            $0.imageDestination != nil || !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            if !runs.isEmpty { runs.append(MarkdownRun(" ")) }
            runs += piece
        }
        return runs
    }

    private func cellPieces(_ nodes: [DocxNode], into pieces: inout [[MarkdownRun]]) throws {
        for node in nodes {
            switch node.name {
            case "w:p":
                var items: [Item] = []
                try readParagraph(node, into: &items)
                pieces += items.map(Self.runs(of:))
            case "w:tbl":
                for row in Self.collect("w:tr", in: node.children) {
                    for cell in Self.collect("w:tc", in: row.children) {
                        try cellPieces(cell.children, into: &pieces)
                    }
                }
            case "w:sdt":
                try cellPieces(node.child("w:sdtContent")?.children ?? [], into: &pieces)
            case "mc:AlternateContent":
                let before = pieces.count
                for option in Self.alternatives(node) {
                    try cellPieces(option.children, into: &pieces)
                    if pieces.count != before { break }
                }
            case "w:tcPr", "w:del", "w:moveFrom", "w:sdtPr", "w:sdtEndPr":
                continue
            default:
                try cellPieces(node.children, into: &pieces)
            }
        }
    }

    private static func runs(of item: Item) -> [MarkdownRun] {
        switch item {
        case .codeLine(let line):
            let text = line.replacingOccurrences(of: "\n", with: " ")
            return text.trimmingCharacters(in: .whitespaces).isEmpty ? [] : [MarkdownRun(text, code: true)]
        case .block(let block):
            switch block {
            case .heading(_, let runs), .paragraph(let runs), .listItem(_, _, let runs), .quote(let runs):
                return runs
            default:
                return []
            }
        }
    }

    // MARK: - Helpers

    private static func plainText(_ runs: [MarkdownRun]) -> String {
        runs.filter { $0.imageDestination == nil }.map(\.text).joined()
    }

    /// A paragraph written entirely in a monospaced font reads as source code.
    private static func isAllCode(_ runs: [MarkdownRun]) -> Bool {
        let visible = runs.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return !visible.isEmpty
            && visible.allSatisfy { $0.code && $0.link == nil }
            && runs.allSatisfy { $0.imageDestination == nil }
    }

    private static let listMarker = try! NSRegularExpression(
        pattern: "^\\t *([•◦▪▫‣∙·●○■□–*-]|[0-9]{1,3}[.)]?|[A-Za-z][.)]|[ivxlcIVXLC]{1,6}[.)]) *\\t"
    )

    /// A list written as literal text, the way Cocoa's Word writer (TextEdit, `textutil`)
    /// saves one: a tab, the bullet or number, another tab, then the item.
    private static func textualListMarker(_ runs: [MarkdownRun]) -> (ordered: Bool, runs: [MarkdownRun])? {
        let leading = runs.prefix { $0.imageDestination == nil }.map(\.text).joined()
        let head = String(leading.prefix(24))
        let range = NSRange(head.startIndex..., in: head)
        guard let match = listMarker.firstMatch(in: head, range: range),
              let whole = Range(match.range, in: head),
              let markerRange = Range(match.range(at: 1), in: head) else { return nil }
        let ordered = head[markerRange].first.map { $0.isNumber || $0.isLetter } ?? false

        var remaining = head[whole].count
        var stripped: [MarkdownRun] = []
        for run in runs {
            guard remaining > 0, run.imageDestination == nil else {
                stripped.append(run)
                continue
            }
            let drop = min(remaining, run.text.count)
            remaining -= drop
            var trimmed = run
            trimmed.text = String(run.text.dropFirst(drop))
            if !trimmed.text.isEmpty { stripped.append(trimmed) }
        }
        return (ordered, stripped)
    }

    /// Nesting of a textual list item, from its indent: Cocoa indents each level half an inch.
    private static func indentLevel(_ pPr: DocxNode?) -> Int {
        guard let indent = pPr?.child("w:ind"),
              let left = (indent.attr("left") ?? indent.attr("start")).flatMap({ Int($0) }) else { return 0 }
        return min(max(left / 720 - 1, 0), 8)
    }

    /// A `w:sym` character. Symbol-font codes sit in the private-use area at U+F0xx; the Greek
    /// letters and common operators are mapped, other dingbats (Wingdings) are dropped.
    static func symbol(_ node: DocxNode) -> String? {
        guard let raw = node.attr("char"), let code = UInt32(raw, radix: 16) else { return nil }
        guard (0xF000...0xF0FF).contains(code) else {
            return Unicode.Scalar(code).map { String(Character($0)) }
        }
        let font = (node.attr("font") ?? "").lowercased()
        guard font.contains("symbol") else { return nil }
        let byte = code - 0xF000
        let latin = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
        let greek = "ΑΒΧΔΕΦΓΗΙϑΚΛΜΝΟΠΘΡΣΤΥςΩΞΨΖαβχδεφγηιϕκλμνοπθρστυϖωξψζ"
        if let scalar = Unicode.Scalar(byte), let index = latin.firstIndex(of: Character(scalar)) {
            return String(greek[greek.index(greek.startIndex, offsetBy: latin.distance(from: latin.startIndex, to: index))])
        }
        let operators: [UInt32: String] = [
            0xA3: "≤", 0xA5: "∞", 0xAC: "←", 0xAD: "↑", 0xAE: "→", 0xAF: "↓", 0xB0: "°", 0xB1: "±",
            0xB3: "≥", 0xB4: "×", 0xB7: "•", 0xB8: "÷", 0xB9: "≠", 0xBA: "≡", 0xBB: "≈", 0xD6: "√",
            0xE5: "∑", 0xF2: "∫", 0xB6: "∂", 0xD1: "∇", 0xCE: "∈", 0xC7: "∩", 0xC8: "∪", 0xA2: "′"
        ]
        if let mapped = operators[byte] { return mapped }
        if (0x20...0x7E).contains(byte), let scalar = Unicode.Scalar(byte) { return String(Character(scalar)) }
        return nil
    }
}
