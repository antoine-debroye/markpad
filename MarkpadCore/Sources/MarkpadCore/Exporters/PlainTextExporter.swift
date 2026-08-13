import Foundation
import Markdown

/// Renders Markdown to readable plain text: syntax removed, structure preserved through
/// indentation, list markers and blank lines.
public struct PlainTextExporter: Sendable {
    public struct Options: Sendable {
        /// Underline headings with `=`/`-` rules instead of leaving them bare.
        public var underlineHeadings: Bool
        /// Render links as `text (url)` rather than dropping the destination.
        public var includeLinkURLs: Bool

        public init(underlineHeadings: Bool = true, includeLinkURLs: Bool = true) {
            self.underlineHeadings = underlineHeadings
            self.includeLinkURLs = includeLinkURLs
        }
    }

    public init() {}

    public func export(markdown: String, options: Options = Options()) -> String {
        var renderer = PlainTextRenderer(options: options)
        var text = renderer.visit(MarkdownParsing.document(markdown))

        // Trim blank lines at the edges only. A general whitespace trim would eat the
        // indentation of a document that opens with a code block.
        while text.hasPrefix("\n") { text.removeFirst() }
        while let last = text.last, last == "\n" || last == " " || last == "\t" { text.removeLast() }
        return text.isEmpty ? "" : text + "\n"
    }
}

private struct PlainTextRenderer: MarkupVisitor {
    typealias Result = String

    /// One nesting step. List markers are padded to this width so continuation lines
    /// align under the text they belong to.
    private static let indentUnit = "   "

    let options: PlainTextExporter.Options
    private var indentLevel = 0
    private var quoteDepth = 0
    /// Marker for the next block to be emitted; consumed by the first `prefixed` call
    /// inside a list item so the bullet lands on the item's first line.
    private var pendingMarker: String?

    init(options: PlainTextExporter.Options) {
        self.options = options
    }

    /// Applies quote and indent prefixes to every line of a rendered block, giving the
    /// first line a pending list marker when one is waiting.
    private mutating func prefixed(_ text: String) -> String {
        let quote = String(repeating: "> ", count: quoteDepth)
        let indent = String(repeating: Self.indentUnit, count: indentLevel)
        var firstPrefix = quote + indent

        if let marker = pendingMarker {
            // The marker stands in for the innermost indent step.
            let outer = String(repeating: Self.indentUnit, count: max(indentLevel - 1, 0))
            let padded = marker.count < Self.indentUnit.count
                ? marker.padding(toLength: Self.indentUnit.count, withPad: " ", startingAt: 0)
                : marker
            firstPrefix = quote + outer + padded
            pendingMarker = nil
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.enumerated().map { index, line -> String in
            if line.isEmpty { return "" }
            return (index == 0 ? firstPrefix : quote + indent) + line
        }.joined(separator: "\n")
    }

    mutating func defaultVisit(_ markup: Markup) -> String {
        visitChildren(of: markup)
    }

    private mutating func visitChildren(of markup: Markup) -> String {
        markup.children.reduce(into: "") { $0 += visit($1) }
    }

    /// Renders inline children without block prefixes.
    private mutating func inlineText(of markup: Markup) -> String {
        markup.children.reduce(into: "") { $0 += visit($1) }
    }

    mutating func visitDocument(_ document: Document) -> String {
        visitChildren(of: document)
    }

    mutating func visitHeading(_ heading: Heading) -> String {
        let text = inlineText(of: heading)
        guard options.underlineHeadings, heading.level <= 2 else {
            return prefixed(text) + "\n\n"
        }
        let rule = String(repeating: heading.level == 1 ? "=" : "-", count: max(text.count, 3))
        return prefixed(text + "\n" + rule) + "\n\n"
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> String {
        prefixed(inlineText(of: paragraph)) + "\n\n"
    }

    mutating func visitText(_ text: Markdown.Text) -> String {
        text.string
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> String { "\n" }
    mutating func visitLineBreak(_ lineBreak: LineBreak) -> String { "\n" }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> String {
        inlineCode.code
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        var code = codeBlock.code
        if code.hasSuffix("\n") { code.removeLast() }
        let indented = code
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : "    " + $0 }
            .joined(separator: "\n")
        return prefixed(indented) + "\n\n"
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> String {
        quoteDepth += 1
        defer { quoteDepth -= 1 }
        return visitChildren(of: blockQuote)
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String {
        prefixed(String(repeating: "─", count: 40)) + "\n\n"
    }

    mutating func visitLink(_ link: Markdown.Link) -> String {
        let text = inlineText(of: link)
        guard options.includeLinkURLs, let destination = link.destination, !destination.isEmpty else {
            return text
        }
        return text == destination ? text : "\(text) (\(destination))"
    }

    mutating func visitImage(_ image: Markdown.Image) -> String {
        let alt = image.plainText
        let source = image.source ?? ""
        if alt.isEmpty { return source.isEmpty ? "" : "[image: \(source)]" }
        return source.isEmpty ? "[image: \(alt)]" : "[image: \(alt) — \(source)]"
    }

    mutating func visitUnorderedList(_ list: UnorderedList) -> String {
        renderList(Array(list.listItems)) { _ in "•  " }
    }

    mutating func visitOrderedList(_ list: OrderedList) -> String {
        let start = Int(list.startIndex)
        return renderList(Array(list.listItems)) { "\(start + $0). " }
    }

    private mutating func renderList(_ items: [ListItem], marker: (Int) -> String) -> String {
        var out = ""
        for (index, item) in items.enumerated() {
            // A task item's checkbox replaces the bullet — it reads better and still
            // communicates list membership.
            pendingMarker = item.checkbox.map { $0 == .checked ? "[x] " : "[ ] " } ?? marker(index)

            indentLevel += 1
            var body = visitChildren(of: item)
            indentLevel -= 1

            if let unused = pendingMarker {
                // Empty list item: keep the marker so the item isn't silently dropped.
                body = prefixedMarkerOnly(unused) + "\n\n"
                pendingMarker = nil
            }

            // Collapse the blank line between tight items; keep paragraph spacing inside.
            while body.hasSuffix("\n\n") { body.removeLast() }
            out += body + "\n"
        }
        return out + "\n"
    }

    private func prefixedMarkerOnly(_ marker: String) -> String {
        let quote = String(repeating: "> ", count: quoteDepth)
        let outer = String(repeating: Self.indentUnit, count: max(indentLevel, 0))
        return quote + outer + marker.trimmingCharacters(in: .whitespaces)
    }

    mutating func visitTable(_ table: Markdown.Table) -> String {
        var rows: [[String]] = []
        for child in table.children {
            if let head = child as? Markdown.Table.Head {
                rows.append(head.cells.map { inlineText(of: $0) })
            } else if let body = child as? Markdown.Table.Body {
                for row in body.rows {
                    rows.append(row.cells.map { inlineText(of: $0) })
                }
            }
        }
        guard !rows.isEmpty else { return "" }

        let columnCount = rows.map(\.count).max() ?? 0
        var widths = Array(repeating: 0, count: columnCount)
        for row in rows {
            for (index, cell) in row.enumerated() where index < columnCount {
                widths[index] = max(widths[index], cell.count)
            }
        }

        var lines: [String] = []
        for (rowIndex, row) in rows.enumerated() {
            let padded = (0..<columnCount).map { index -> String in
                let value = index < row.count ? row[index] : ""
                return value.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }
            var line = padded.joined(separator: "  ")
            while line.hasSuffix(" ") { line.removeLast() }
            lines.append(line)
            if rowIndex == 0 {
                lines.append(widths.map { String(repeating: "─", count: $0) }.joined(separator: "  "))
            }
        }
        return prefixed(lines.joined(separator: "\n")) + "\n\n"
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) -> String { "" }
    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> String { "" }
}
