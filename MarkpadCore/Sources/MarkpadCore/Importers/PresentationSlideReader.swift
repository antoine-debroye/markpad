import Foundation

/// Reads one slide (and its speaker notes) into Markdown blocks.
///
/// PresentationML stores a slide as a shape tree. Bullets are usually not written on the
/// slide at all but inherited from the layout and master; rather than resolve that chain, text
/// in a body or content placeholder is treated as bulleted (unless it says `a:buNone`), and text
/// anywhere else only when it carries its own bullet.
final class PresentationSlideReader {
    let zip: ZipReader
    let collector: AssetCollector
    /// Set when a chart or SmartArt diagram was skipped.
    private(set) var omittedGraphics = false

    init(zip: ZipReader, collector: AssetCollector) {
        self.zip = zip
        self.collector = collector
    }

    /// Placeholders that repeat on every slide and carry no content of their own.
    private static let chromePlaceholders: Set<String> = ["dt", "ftr", "sldNum", "hdr"]
    /// On a notes page, the slide thumbnail is also chrome.
    private static let notesChromePlaceholders: Set<String> = ["dt", "ftr", "sldNum", "hdr", "sldImg"]

    /// The blocks of the slide at `part`, or nil when the part is missing or damaged.
    func slide(at part: String) throws -> [MarkdownBlock]? {
        guard let data = try zip.data(for: part), let root = OfficeImportXML.parse(data),
              let tree = root.child("cSld")?.child("spTree") else { return nil }
        let relationships = try OfficeImportRelationships.load(for: part, in: zip)
        var context = Context(relationships: relationships, notes: false)

        var blocks: [MarkdownBlock] = []
        // The title leads the slide even when it is stacked above other shapes.
        if let title = firstShape(in: tree, where: { Self.isTitle(Self.placeholderType(of: $0)) }) {
            context.hoistedTitle = title
            blocks.append(.heading(level: 2, lines(of: title.child("txBody"), relationships: relationships)))
        }
        blocks += shapes(in: tree, context: context)

        if let notesRelationship = relationships.first(ofType: "notesSlide"),
           let notesPart = relationships.partPath(for: notesRelationship) {
            blocks += try notes(at: notesPart)
        }
        return blocks
    }

    static func hasContent(_ block: MarkdownBlock) -> Bool {
        switch block {
        case .heading(_, let runs), .paragraph(let runs), .listItem(_, _, let runs), .quote(let runs):
            return runs.contains { $0.imageDestination != nil || !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        case .table(let rows):
            return !rows.isEmpty
        case .code, .rule:
            return true
        case .raw:
            return false
        }
    }

    // MARK: - Shape tree

    private struct Context {
        let relationships: OfficeImportRelationships
        let notes: Bool
        var hoistedTitle: OfficeImportElement?
    }

    private func shapes(in tree: OfficeImportElement, context: Context) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        for element in tree.children {
            switch element.name {
            case "sp":
                if element === context.hoistedTitle { continue }
                blocks += shape(element, context: context)
            case "grpSp":
                blocks += shapes(in: element, context: context)
            case "graphicFrame":
                if !context.notes { blocks += graphicFrame(element, context: context) }
            case "pic":
                if !context.notes { blocks += picture(element, context: context) }
            case "AlternateContent":
                // Markup-compatibility wrapper: the fallback is what any reader can show.
                if let branch = element.child("Fallback") ?? element.child("Choice") {
                    blocks += shapes(in: branch, context: context)
                }
            default:
                continue
            }
        }
        return blocks
    }

    private func firstShape(in tree: OfficeImportElement, where matches: (OfficeImportElement) -> Bool) -> OfficeImportElement? {
        for element in tree.children {
            if element.name == "sp", matches(element) { return element }
            if element.name == "grpSp", let found = firstShape(in: element, where: matches) { return found }
        }
        return nil
    }

    /// The placeholder type of a shape: nil when it is not a placeholder, and `obj` — the
    /// schema default — when it is one without a type.
    private static func placeholderType(of shape: OfficeImportElement) -> String? {
        guard let placeholder = shape.child("nvSpPr")?.child("nvPr")?.child("ph") else { return nil }
        return placeholder.attribute("type") ?? "obj"
    }

    private static func isTitle(_ type: String?) -> Bool { type == "title" || type == "ctrTitle" }

    private func shape(_ shape: OfficeImportElement, context: Context) -> [MarkdownBlock] {
        guard let body = shape.child("txBody") else { return [] }
        let type = Self.placeholderType(of: shape)
        let relationships = context.relationships

        if context.notes {
            if let type, Self.notesChromePlaceholders.contains(type) { return [] }
            return body.children("p").map { .paragraph(runs(of: $0, relationships: relationships)) }
        }
        if let type, Self.chromePlaceholders.contains(type) { return [] }
        if Self.isTitle(type) {
            return [.heading(level: 2, lines(of: body, relationships: relationships))]
        }

        // Body and content placeholders inherit their bullets from the layout.
        let inheritsBullets = type == "body" || type == "obj"
        var blocks: [MarkdownBlock] = []
        for paragraph in body.children("p") {
            let content = runs(of: paragraph, relationships: relationships)
            guard content.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                continue
            }
            let properties = paragraph.child("pPr")
            let level = properties?.attribute("lvl").flatMap(Int.init) ?? 0
            let numbered = properties?.child("buAutoNum") != nil
            let explicitBullet = numbered || properties?.child("buChar") != nil || properties?.child("buBlip") != nil
            let suppressed = properties?.child("buNone") != nil
            if explicitBullet || (inheritsBullets && !suppressed) {
                blocks.append(.listItem(level: max(0, level), ordered: numbered, content))
            } else {
                blocks.append(.paragraph(content))
            }
        }
        return blocks
    }

    /// All paragraphs of a text body as one run list, separated by line breaks — for titles
    /// and table cells, which are single blocks.
    private func lines(of body: OfficeImportElement?, relationships: OfficeImportRelationships) -> [MarkdownRun] {
        guard let body else { return [] }
        var result: [MarkdownRun] = []
        for paragraph in body.children("p") {
            let content = runs(of: paragraph, relationships: relationships)
            guard content.contains(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }) else { continue }
            if !result.isEmpty { result.append(.lineBreak) }
            result += content
        }
        return result
    }

    private func runs(of paragraph: OfficeImportElement, relationships: OfficeImportRelationships) -> [MarkdownRun] {
        var result: [MarkdownRun] = []
        for element in paragraph.children {
            switch element.name {
            case "r", "fld":
                guard let text = element.child("t")?.text, !text.isEmpty else { continue }
                let properties = element.child("rPr")
                var run = MarkdownRun(
                    // A vertical tab is PowerPoint's soft line break inside a run.
                    text.replacingOccurrences(of: "\u{0B}", with: "\n"),
                    bold: properties?.flag("b") ?? false,
                    italic: properties?.flag("i") ?? false,
                    strikethrough: properties.map { ($0.attribute("strike") ?? "noStrike") != "noStrike" } ?? false
                )
                if let id = properties?.child("hlinkClick")?.relationshipAttribute("id"),
                   let relationship = relationships[id], relationship.isExternal, !relationship.target.isEmpty {
                    run.link = relationship.target
                }
                result.append(run)
            case "br":
                result.append(.lineBreak)
            default:
                continue
            }
        }
        return result
    }

    // MARK: - Tables, charts, pictures

    private func graphicFrame(_ frame: OfficeImportElement, context: Context) -> [MarkdownBlock] {
        guard let data = frame.child("graphic")?.child("graphicData") else { return [] }
        if let table = data.child("tbl") {
            let rows = table.children("tr").map { row in
                row.children("tc").map { cell -> [MarkdownRun] in
                    // Cells covered by a merge repeat nothing; the merged content stays in the
                    // cell that starts the span.
                    if cell.flag("hMerge") || cell.flag("vMerge") { return [] }
                    return lines(of: cell.child("txBody"), relationships: context.relationships)
                }
            }
            return rows.isEmpty ? [] : [.table(rows)]
        }
        let uri = data.attribute("uri") ?? ""
        if uri.contains("/chart") || uri.contains("/diagram")
            || data.children.contains(where: { $0.name == "chart" || $0.name == "relIds" }) {
            omittedGraphics = true
        }
        return []
    }

    private func picture(_ picture: OfficeImportElement, context: Context) -> [MarkdownBlock] {
        let alt = (picture.child("nvPicPr")?.child("cNvPr")?.attribute("descr") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var destination: String?
        if let id = picture.child("blipFill")?.child("blip")?.relationshipAttribute("embed"),
           let path = context.relationships.partPath(for: id),
           let data = try? zip.data(for: path) {
            destination = collector.add(data, suggestedName: (path as NSString).lastPathComponent)
        }
        if let destination {
            return [.paragraph([.image(alt: alt, destination: destination)])]
        }
        return alt.isEmpty ? [] : [.paragraph([MarkdownRun(alt)])]
    }

    // MARK: - Notes

    private func notes(at part: String) throws -> [MarkdownBlock] {
        guard let data = try zip.data(for: part), let root = OfficeImportXML.parse(data),
              let tree = root.child("cSld")?.child("spTree") else { return [] }
        let relationships = try OfficeImportRelationships.load(for: part, in: zip)
        let paragraphs = shapes(in: tree, context: Context(relationships: relationships, notes: true))
            .filter(Self.hasContent)
        guard !paragraphs.isEmpty else { return [] }
        return [.heading(level: 3, [MarkdownRun("Notes")])] + paragraphs
    }
}
