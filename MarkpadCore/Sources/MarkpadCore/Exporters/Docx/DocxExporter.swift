import CoreGraphics
import Foundation
import ImageIO
import Markdown

/// Converts Markdown into a Word `.docx` document.
///
/// The package is written directly as OOXML rather than shelling out to a converter, so the
/// app stays self-contained and notarisable.
public struct DocxExporter: Sendable {
    public struct Options: Sendable {
        /// Directory used to resolve relative image paths. Images are embedded when found.
        public var resourceDirectory: URL?
        public var theme: MarkdownTheme

        public init(resourceDirectory: URL? = nil, theme: MarkdownTheme = .default) {
            self.resourceDirectory = resourceDirectory
            self.theme = theme
        }
    }

    public init() {}

    public func export(markdown: String, options: Options = Options()) throws -> Data {
        var renderer = DocxRenderer(options: options)
        let body = renderer.render(document: MarkdownParsing.document(markdown))

        var package = DocxPackage()
        package.add("[Content_Types].xml", xml: DocxParts.contentTypes(imageExtensions: renderer.imageExtensions))
        package.add("_rels/.rels", xml: DocxParts.packageRelationships)
        package.add("word/document.xml", xml: """
        \(XML.declaration)
        <w:document \(DocxParts.mainNamespaces)><w:body>\(body)\(DocxParts.sectionProperties)</w:body></w:document>
        """)
        package.add("word/_rels/document.xml.rels", xml: DocxParts.documentRelationships(renderer.relationships))
        package.add("word/styles.xml", xml: DocxParts.styles(theme: options.theme))
        package.add("word/numbering.xml", xml: DocxParts.numbering(orderedListStarts: renderer.orderedListStarts))
        for media in renderer.media {
            package.add("word/media/\(media.name)", data: media.data)
        }
        return try package.archiveData()
    }

    public func export(markdown: String, to url: URL, options: Options = Options()) throws {
        var options = options
        if options.resourceDirectory == nil {
            options.resourceDirectory = url.deletingLastPathComponent()
        }
        try export(markdown: markdown, options: options).write(to: url, options: .atomic)
    }
}

// MARK: - Renderer

private struct DocxRenderer {
    struct Media {
        let name: String
        let data: Data
        let pixelSize: CGSize
    }

    private struct RunFormat: OptionSet {
        let rawValue: Int
        static let bold = RunFormat(rawValue: 1 << 0)
        static let italic = RunFormat(rawValue: 1 << 1)
        static let strikethrough = RunFormat(rawValue: 1 << 2)
        static let code = RunFormat(rawValue: 1 << 3)
    }

    private enum InlinePiece {
        case text(String, RunFormat, link: String?)
        case lineBreak
        case image(source: String, alt: String)
    }

    let options: DocxExporter.Options
    private(set) var relationships: [DocxRelationship] = [
        DocxRelationship(id: "rId1", kind: .styles, target: "styles.xml"),
        DocxRelationship(id: "rId2", kind: .numbering, target: "numbering.xml")
    ]
    private(set) var media: [Media] = []
    private(set) var orderedListStarts: [Int] = []
    /// Unique across the whole document — duplicate ids make Word offer to repair the file.
    private var nextDrawingID = 1
    private var nextRelationshipID = 3

    var imageExtensions: Set<String> {
        Set(media.map { URL(fileURLWithPath: $0.name).pathExtension.lowercased() })
    }

    init(options: DocxExporter.Options) {
        self.options = options
    }

    private mutating func addRelationship(kind: DocxRelationship.Kind, target: String) -> String {
        let id = "rId\(nextRelationshipID)"
        nextRelationshipID += 1
        relationships.append(DocxRelationship(id: id, kind: kind, target: target))
        return id
    }

    // MARK: Blocks

    mutating func render(document: Document) -> String {
        renderBlocks(Array(document.children))
    }

    private mutating func renderBlocks(_ blocks: [Markup], listContext: ListContext? = nil) -> String {
        blocks.reduce(into: "") { $0 += renderBlock($1, listContext: listContext) }
    }

    /// Numbering state threaded into list item content.
    private struct ListContext {
        let numberID: Int
        let level: Int
        let quoted: Bool
    }

    private mutating func renderBlock(_ block: Markup, listContext: ListContext?) -> String {
        switch block {
        case let heading as Heading:
            return paragraph(
                style: "Heading\(min(heading.level, 6))",
                content: runsXML(for: inlinePieces(of: heading)),
                listContext: listContext
            )

        case let paragraphNode as Paragraph:
            return paragraph(
                style: listContext == nil ? nil : "ListParagraph",
                content: runsXML(for: inlinePieces(of: paragraphNode)),
                listContext: listContext
            )

        case let codeBlock as CodeBlock:
            var code = codeBlock.code
            if code.hasSuffix("\n") { code.removeLast() }
            let lines = code.isEmpty ? [""] : code.components(separatedBy: "\n")
            return lines.reduce(into: "") { result, line in
                let run = "<w:r><w:t xml:space=\"preserve\">\(XML.escape(line))</w:t></w:r>"
                result += paragraph(style: "SourceCode", content: run, listContext: nil)
            }

        case let quote as BlockQuote:
            // Word has no nested-quote element; the Quote style carries the visual treatment.
            return quote.children.reduce(into: "") { result, child in
                if let paragraphNode = child as? Paragraph {
                    result += paragraph(
                        style: "Quote",
                        content: runsXML(for: inlinePieces(of: paragraphNode)),
                        listContext: nil
                    )
                } else {
                    result += renderBlock(child, listContext: listContext)
                }
            }

        case is ThematicBreak:
            return """
            <w:p><w:pPr><w:pBdr><w:bottom w:val="single" w:sz="6" w:space="1" w:color="D2D2D7"/></w:pBdr>\
            <w:spacing w:before="240" w:after="240"/></w:pPr></w:p>
            """

        case let list as UnorderedList:
            return renderList(items: Array(list.listItems), numberID: 1, level: (listContext?.level ?? -1) + 1)

        case let list as OrderedList:
            orderedListStarts.append(Int(list.startIndex))
            let numberID = orderedListStarts.count + 1
            return renderList(items: Array(list.listItems), numberID: numberID, level: (listContext?.level ?? -1) + 1)

        case let table as Markdown.Table:
            return renderTable(table)

        case let html as HTMLBlock:
            _ = html
            return ""

        default:
            return renderBlocks(Array(block.children), listContext: listContext)
        }
    }

    private mutating func renderList(items: [ListItem], numberID: Int, level: Int) -> String {
        items.reduce(into: "") { result, item in
            let context = ListContext(numberID: numberID, level: min(level, 8), quoted: false)
            var isFirstBlock = true
            for child in item.children {
                if child is UnorderedList || child is OrderedList {
                    result += renderBlock(child, listContext: context)
                } else {
                    // Only the item's first block carries the bullet; later blocks indent under it.
                    let checkboxPrefix = isFirstBlock ? checkboxText(for: item) : ""
                    result += renderListItemBlock(child, context: context, prefix: checkboxPrefix)
                }
                isFirstBlock = false
            }
        }
    }

    private func checkboxText(for item: ListItem) -> String {
        guard let checkbox = item.checkbox else { return "" }
        return checkbox == .checked ? "☑ " : "☐ "
    }

    private mutating func renderListItemBlock(_ block: Markup, context: ListContext, prefix: String) -> String {
        guard let paragraphNode = block as? Paragraph else {
            return renderBlock(block, listContext: context)
        }
        var content = runsXML(for: inlinePieces(of: paragraphNode))
        if !prefix.isEmpty {
            content = "<w:r><w:t xml:space=\"preserve\">\(XML.escape(prefix))</w:t></w:r>" + content
        }
        return paragraph(style: "ListParagraph", content: content, listContext: context)
    }

    private func paragraph(style: String?, content: String, listContext: ListContext?) -> String {
        var properties = ""
        if let style { properties += "<w:pStyle w:val=\"\(style)\"/>" }
        if let listContext {
            properties += "<w:numPr><w:ilvl w:val=\"\(listContext.level)\"/>" +
                "<w:numId w:val=\"\(listContext.numberID)\"/></w:numPr>"
        }
        let propertyBlock = properties.isEmpty ? "" : "<w:pPr>\(properties)</w:pPr>"
        return "<w:p>\(propertyBlock)\(content)</w:p>"
    }

    // MARK: Tables

    private mutating func renderTable(_ table: Markdown.Table) -> String {
        var rows: [(cells: [Markdown.Table.Cell], isHeader: Bool)] = []
        for child in table.children {
            if let head = child as? Markdown.Table.Head {
                rows.append((Array(head.cells), true))
            } else if let body = child as? Markdown.Table.Body {
                for row in body.rows { rows.append((Array(row.cells), false)) }
            }
        }
        guard !rows.isEmpty else { return "" }

        let columnCount = rows.map(\.cells.count).max() ?? 1
        // Markdown tables have no column spans, so an even grid is always correct.
        let columnWidth = DocxParts.contentWidthTwips / max(columnCount, 1)
        let grid = (0..<columnCount).map { _ in "<w:gridCol w:w=\"\(columnWidth)\"/>" }.joined()

        var xml = """
        <w:tbl><w:tblPr><w:tblStyle w:val="TableGrid"/>\
        <w:tblW w:w="\(DocxParts.contentWidthTwips)" w:type="dxa"/><w:tblLayout w:type="fixed"/></w:tblPr>\
        <w:tblGrid>\(grid)</w:tblGrid>
        """

        for row in rows {
            let headerProperties = row.isHeader
                ? "<w:trPr><w:tblHeader/></w:trPr>"
                : ""
            xml += "<w:tr>\(headerProperties)"
            for index in 0..<columnCount {
                let shading = row.isHeader
                    ? "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F2F2F5\"/>"
                    : ""
                var content = "<w:r><w:t/></w:r>"
                if index < row.cells.count {
                    var pieces = inlinePieces(of: row.cells[index])
                    if row.isHeader {
                        pieces = pieces.map { piece in
                            if case let .text(text, format, link) = piece {
                                return .text(text, format.union(.bold), link: link)
                            }
                            return piece
                        }
                    }
                    let runs = runsXML(for: pieces)
                    if !runs.isEmpty { content = runs }
                }
                // Every cell must contain at least one paragraph or Word rejects the file.
                xml += """
                <w:tc><w:tcPr><w:tcW w:w="\(columnWidth)" w:type="dxa"/>\(shading)</w:tcPr>\
                <w:p><w:pPr><w:spacing w:after="0"/></w:pPr>\(content)</w:p></w:tc>
                """
            }
            xml += "</w:tr>"
        }
        return xml + "</w:tbl><w:p/>"
    }

    // MARK: Inlines

    private mutating func inlinePieces(
        of markup: Markup,
        format: RunFormat = [],
        link: String? = nil
    ) -> [InlinePiece] {
        var pieces: [InlinePiece] = []
        for child in markup.children {
            switch child {
            case let text as Markdown.Text:
                pieces.append(.text(text.string, format, link: link))
            case let code as InlineCode:
                pieces.append(.text(code.code, format.union(.code), link: link))
            case let strong as Strong:
                pieces += inlinePieces(of: strong, format: format.union(.bold), link: link)
            case let emphasis as Emphasis:
                pieces += inlinePieces(of: emphasis, format: format.union(.italic), link: link)
            case let strike as Strikethrough:
                pieces += inlinePieces(of: strike, format: format.union(.strikethrough), link: link)
            case let linkNode as Markdown.Link:
                pieces += inlinePieces(of: linkNode, format: format, link: linkNode.destination ?? link)
            case let image as Markdown.Image:
                pieces.append(.image(source: image.source ?? "", alt: image.plainText))
            case is SoftBreak:
                pieces.append(.text(" ", format, link: link))
            case is LineBreak:
                pieces.append(.lineBreak)
            case is InlineHTML:
                continue
            default:
                pieces += inlinePieces(of: child, format: format, link: link)
            }
        }
        return pieces
    }

    private mutating func runsXML(for pieces: [InlinePiece]) -> String {
        var xml = ""
        var index = 0
        while index < pieces.count {
            // Group consecutive pieces sharing a destination into one hyperlink element.
            if case let .text(_, _, link?) = pieces[index], !link.isEmpty {
                var group: [InlinePiece] = []
                while index < pieces.count, case let .text(text, format, current) = pieces[index], current == link {
                    group.append(.text(text, format, link: link))
                    index += 1
                }
                let relationshipID = addRelationship(kind: .hyperlink, target: link)
                let inner = group.reduce(into: "") { $0 += runXML(for: $1, hyperlink: true) }
                xml += "<w:hyperlink r:id=\"\(relationshipID)\">\(inner)</w:hyperlink>"
                continue
            }
            xml += runXML(for: pieces[index], hyperlink: false)
            index += 1
        }
        return xml
    }

    private mutating func runXML(for piece: InlinePiece, hyperlink: Bool) -> String {
        switch piece {
        case .lineBreak:
            return "<w:r><w:br/></w:r>"

        case let .text(text, format, _):
            guard !text.isEmpty else { return "" }
            var properties = ""
            if hyperlink { properties += "<w:rStyle w:val=\"Hyperlink\"/>" }
            if format.contains(.code) { properties += "<w:rStyle w:val=\"InlineCode\"/>" }
            if format.contains(.bold) { properties += "<w:b/>" }
            if format.contains(.italic) { properties += "<w:i/>" }
            if format.contains(.strikethrough) { properties += "<w:strike/>" }
            let propertyBlock = properties.isEmpty ? "" : "<w:rPr>\(properties)</w:rPr>"
            return "<w:r>\(propertyBlock)<w:t xml:space=\"preserve\">\(XML.escape(text))</w:t></w:r>"

        case let .image(source, alt):
            return imageXML(source: source, alt: alt)
        }
    }

    private mutating func imageXML(source: String, alt: String) -> String {
        guard let resolved = resolveImage(source), let loaded = loadImage(at: resolved) else {
            // Unresolvable image: keep the alt text so no content is silently lost.
            let text = alt.isEmpty ? source : alt
            return "<w:r><w:rPr><w:i/></w:rPr><w:t xml:space=\"preserve\">[\(XML.escape(text))]</w:t></w:r>"
        }

        let name = "image\(media.count + 1).\(resolved.pathExtension.lowercased())"
        media.append(Media(name: name, data: loaded.data, pixelSize: loaded.size))
        let relationshipID = addRelationship(kind: .image, target: "media/\(name)")

        // 914400 EMU per inch; images are treated as 96 DPI and clamped to the text column.
        let emuPerPixel = 9525.0
        let maxWidth = 5_943_600.0
        var width = Double(loaded.size.width) * emuPerPixel
        var height = Double(loaded.size.height) * emuPerPixel
        if width > maxWidth, width > 0 {
            height *= maxWidth / width
            width = maxWidth
        }
        let cx = Int(max(width.rounded(), 1))
        let cy = Int(max(height.rounded(), 1))

        let drawingID = nextDrawingID
        nextDrawingID += 1
        let description = XML.escape(alt)

        return """
        <w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">\
        <wp:extent cx="\(cx)" cy="\(cy)"/><wp:effectExtent l="0" t="0" r="0" b="0"/>\
        <wp:docPr id="\(drawingID)" name="Picture \(drawingID)" descr="\(description)"/>\
        <wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>\
        <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">\
        <pic:pic><pic:nvPicPr><pic:cNvPr id="\(drawingID)" name="\(XML.escape(name))" descr="\(description)"/>\
        <pic:cNvPicPr/></pic:nvPicPr>\
        <pic:blipFill><a:blip r:embed="\(relationshipID)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
        <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm>\
        <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>\
        </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>
        """
    }

    private func resolveImage(_ source: String) -> URL? {
        guard !source.isEmpty else { return nil }
        if let url = URL(string: source), url.scheme != nil {
            // Remote images aren't downloaded during export.
            return url.isFileURL ? url : nil
        }
        let decoded = source.removingPercentEncoding ?? source
        guard let directory = options.resourceDirectory else { return nil }
        let candidate = URL(fileURLWithPath: decoded, relativeTo: directory).standardizedFileURL
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    private func loadImage(at url: URL) -> (data: Data, size: CGSize)? {
        guard DocxParts.imageMIMEType(forExtension: url.pathExtension) != nil,
              let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double else {
            return nil
        }
        return (data, CGSize(width: width, height: height))
    }
}
