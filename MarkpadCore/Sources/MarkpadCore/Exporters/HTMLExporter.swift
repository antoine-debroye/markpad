import Foundation
import Markdown

/// Renders Markdown to HTML.
///
/// The same renderer backs standalone `.html` export and the Quick Look preview, so a document
/// looks identical wherever it is displayed.
public struct HTMLExporter: Sendable {
    public struct Options: Sendable {
        /// Emit a full `<html>` document with embedded CSS rather than a fragment.
        public var standalone: Bool
        /// Document title used for `<title>`; falls back to the first heading.
        public var title: String?
        public var theme: MarkdownTheme
        /// Maps a Markdown image source to the `src` used in the output. Returning `nil` keeps
        /// the original value. Used to inline local images as data URIs.
        public var imageResolver: (@Sendable (String) -> String?)?
        /// Pass embedded HTML through untouched.
        ///
        /// Markdown permits inline HTML, so this is on for documents the user chose to
        /// export. It must be off when rendering a file the user has merely selected — a
        /// Quick Look preview — where passing through markup would let an untrusted file run
        /// script in the preview.
        public var allowsRawHTML: Bool

        public init(
            standalone: Bool = true,
            title: String? = nil,
            theme: MarkdownTheme = .default,
            imageResolver: (@Sendable (String) -> String?)? = nil,
            allowsRawHTML: Bool = true
        ) {
            self.standalone = standalone
            self.title = title
            self.theme = theme
            self.imageResolver = imageResolver
            self.allowsRawHTML = allowsRawHTML
        }
    }

    public init() {}

    public func export(markdown: String, options: Options = Options()) -> String {
        let document = MarkdownParsing.document(markdown)
        var renderer = HTMLRenderer(options: options)
        let body = renderer.visit(document)
        guard options.standalone else { return body }

        let title = options.title ?? renderer.firstHeadingText ?? "Untitled"
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(HTMLRenderer.escape(title))</title>
        <style>
        \(CSSGenerator.stylesheet(theme: options.theme))
        </style>
        </head>
        <body>
        <article class="markpad">
        \(body)</article>
        </body>
        </html>
        """
    }
}

struct HTMLRenderer: MarkupVisitor {
    typealias Result = String

    let options: HTMLExporter.Options
    private(set) var firstHeadingText: String?
    private var usedAnchors: Set<String> = []

    init(options: HTMLExporter.Options) {
        self.options = options
    }

    static func escape(_ string: String) -> String {
        var out = ""
        out.reserveCapacity(string.count)
        for character in string {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(character)
            }
        }
        return out
    }

    /// Escapes a value for use inside a double-quoted attribute.
    static func escapeAttribute(_ string: String) -> String {
        escape(string).replacingOccurrences(of: "'", with: "&#39;")
    }

    mutating func defaultVisit(_ markup: Markup) -> String {
        visitChildren(of: markup)
    }

    private mutating func visitChildren(of markup: Markup) -> String {
        var out = ""
        for child in markup.children {
            out += visit(child)
        }
        return out
    }

    mutating func visitDocument(_ document: Document) -> String {
        visitChildren(of: document)
    }

    mutating func visitHeading(_ heading: Heading) -> String {
        let content = visitChildren(of: heading)
        let plain = heading.plainText
        if firstHeadingText == nil { firstHeadingText = plain }
        let anchor = uniqueAnchor(for: plain)
        return "<h\(heading.level) id=\"\(Self.escapeAttribute(anchor))\">\(content)</h\(heading.level)>\n"
    }

    private mutating func uniqueAnchor(for text: String) -> String {
        let base = Self.slug(text)
        var candidate = base.isEmpty ? "section" : base
        var counter = 1
        while usedAnchors.contains(candidate) {
            counter += 1
            candidate = "\(base)-\(counter)"
        }
        usedAnchors.insert(candidate)
        return candidate
    }

    static func slug(_ text: String) -> String {
        let lowered = text.lowercased()
        var out = ""
        var lastWasDash = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash && !out.isEmpty {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> String {
        let content = visitChildren(of: paragraph)
        // Paragraphs inside tight list items are unwrapped by the list renderer.
        return "<p>\(content)</p>\n"
    }

    mutating func visitText(_ text: Markdown.Text) -> String {
        Self.escape(text.string)
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> String {
        "<em>\(visitChildren(of: emphasis))</em>"
    }

    mutating func visitStrong(_ strong: Strong) -> String {
        "<strong>\(visitChildren(of: strong))</strong>"
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> String {
        "<del>\(visitChildren(of: strikethrough))</del>"
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> String {
        "<code>\(Self.escape(inlineCode.code))</code>"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        let language = codeBlock.language.map { " class=\"language-\(Self.escapeAttribute($0))\"" } ?? ""
        var code = codeBlock.code
        if code.hasSuffix("\n") { code.removeLast() }
        return "<pre><code\(language)>\(Self.escape(code))</code></pre>\n"
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> String {
        "<blockquote>\n\(visitChildren(of: blockQuote))</blockquote>\n"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String {
        "<hr>\n"
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> String {
        "\n"
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) -> String {
        "<br>\n"
    }

    mutating func visitLink(_ link: Markdown.Link) -> String {
        let destination = link.destination ?? ""
        let title = link.title.map { " title=\"\(Self.escapeAttribute($0))\"" } ?? ""
        return "<a href=\"\(Self.escapeAttribute(destination))\"\(title)>\(visitChildren(of: link))</a>"
    }

    mutating func visitImage(_ image: Markdown.Image) -> String {
        let source = image.source ?? ""
        let resolved = options.imageResolver?(source) ?? source
        let title = image.title.map { " title=\"\(Self.escapeAttribute($0))\"" } ?? ""
        let alt = image.plainText
        return "<img src=\"\(Self.escapeAttribute(resolved))\" alt=\"\(Self.escapeAttribute(alt))\"\(title)>"
    }

    mutating func visitUnorderedList(_ list: UnorderedList) -> String {
        let isTaskList = list.listItems.contains { $0.checkbox != nil }
        let classAttribute = isTaskList ? " class=\"task-list\"" : ""
        return "<ul\(classAttribute)>\n\(visitChildren(of: list))</ul>\n"
    }

    mutating func visitOrderedList(_ list: OrderedList) -> String {
        let start = list.startIndex == 1 ? "" : " start=\"\(list.startIndex)\""
        return "<ol\(start)>\n\(visitChildren(of: list))</ol>\n"
    }

    mutating func visitListItem(_ listItem: ListItem) -> String {
        var content = visitChildren(of: listItem)
        // Tight lists: a single paragraph child renders inline for cleaner markup.
        if listItem.childCount == 1, listItem.child(at: 0) is Paragraph {
            content = content
                .replacingOccurrences(of: "<p>", with: "")
                .replacingOccurrences(of: "</p>\n", with: "")
        }
        if let checkbox = listItem.checkbox {
            let checked = checkbox == .checked ? " checked" : ""
            return "<li class=\"task-item\"><input type=\"checkbox\" disabled\(checked)> \(content)</li>\n"
        }
        return "<li>\(content)</li>\n"
    }

    mutating func visitTable(_ table: Markdown.Table) -> String {
        var out = "<table>\n"
        let alignments = table.columnAlignments
        for child in table.children {
            if let head = child as? Markdown.Table.Head {
                out += "<thead>\n<tr>\n"
                for (index, cell) in head.cells.enumerated() {
                    out += "<th\(Self.alignmentAttribute(alignments, index))>\(visitChildren(of: cell))</th>\n"
                }
                out += "</tr>\n</thead>\n"
            } else if let body = child as? Markdown.Table.Body {
                out += "<tbody>\n"
                for row in body.rows {
                    out += "<tr>\n"
                    for (index, cell) in row.cells.enumerated() {
                        out += "<td\(Self.alignmentAttribute(alignments, index))>\(visitChildren(of: cell))</td>\n"
                    }
                    out += "</tr>\n"
                }
                out += "</tbody>\n"
            }
        }
        out += "</table>\n"
        return out
    }

    private static func alignmentAttribute(
        _ alignments: [Markdown.Table.ColumnAlignment?],
        _ index: Int
    ) -> String {
        guard index < alignments.count, let alignment = alignments[index] else { return "" }
        switch alignment {
        case .left: return " style=\"text-align:left\""
        case .center: return " style=\"text-align:center\""
        case .right: return " style=\"text-align:right\""
        }
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) -> String {
        guard options.allowsRawHTML else {
            return "<p>\(Self.escape(html.rawHTML))</p>\n"
        }
        return html.rawHTML
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> String {
        options.allowsRawHTML ? inlineHTML.rawHTML : Self.escape(inlineHTML.rawHTML)
    }
}
