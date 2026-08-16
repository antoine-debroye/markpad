import Foundation
import Markdown

/// Turns Markdown source into a `MarkdownLayout`.
///
/// This is the whole of the editor's "what should this look like" logic, kept free of AppKit
/// so it can be tested directly. Syntax markers are found by subtracting a node's children
/// from the node itself, which avoids re-implementing the parser's delimiter rules.
public struct StyleEngine: Sendable {
    public init() {}

    public func layout(for source: String) -> MarkdownLayout {
        let index = SourceIndex(source: source)
        var builder = LayoutBuilder(source: source as NSString, index: index)
        builder.walk(MarkdownParsing.document(source))
        var layout = builder.layout
        layout.images = builder.images
        return layout
    }

    /// Images found in the source, with the range of the syntax that produced them.
    public func images(in source: String) -> [ImagePlacement] {
        layout(for: source).images
    }
}

private struct LayoutBuilder {
    let source: NSString
    let index: SourceIndex
    var layout = MarkdownLayout()
    var images: [ImagePlacement] = []

    private var quoteDepth = 0
    private var listDepth = 0
    private var pendingListItemStart = false

    init(source: NSString, index: SourceIndex) {
        self.source = source
        self.index = index
    }

    // MARK: Ranges

    private func range(of markup: Markup) -> NSRange? {
        guard let sourceRange = markup.range else { return nil }
        return index.range(
            from: SourcePosition(line: sourceRange.lowerBound.line, column: sourceRange.lowerBound.column),
            to: SourcePosition(line: sourceRange.upperBound.line, column: sourceRange.upperBound.column)
        )
    }

    /// The parts of `markup` that are syntax rather than content: everything its children
    /// do not cover at the leading and trailing edges.
    private func delimiterRanges(of markup: Markup) -> [NSRange] {
        guard let full = range(of: markup) else { return [] }
        let childRanges = markup.children.compactMap { range(of: $0) }
        guard let first = childRanges.first, let last = childRanges.last else { return [full] }

        var result: [NSRange] = []
        if first.location > full.location {
            result.append(NSRange(location: full.location, length: first.location - full.location))
        }
        let fullEnd = full.location + full.length
        let lastEnd = last.location + last.length
        if fullEnd > lastEnd {
            result.append(NSRange(location: lastEnd, length: fullEnd - lastEnd))
        }
        return result
    }

    private mutating func addMarkers(_ ranges: [NSRange], _ presentation: Marker.Presentation = .hidden) {
        for range in ranges where range.length > 0 {
            layout.markers.append(Marker(range: range, presentation: presentation))
        }
    }

    private mutating func addInline(_ range: NSRange?, traits: InlineTraits, link: String? = nil) {
        guard let range, range.length > 0 else { return }
        layout.inlines.append(InlineRun(range: range, traits: traits, link: link))
    }

    private mutating func addBlock(_ markup: Markup, kind: BlockRun.Kind) {
        guard let range = range(of: markup) else { return }
        layout.blocks.append(BlockRun(
            range: range,
            kind: kind,
            quoteDepth: quoteDepth,
            listDepth: listDepth,
            isListItemStart: pendingListItemStart
        ))
        pendingListItemStart = false
    }

    // MARK: Walking

    mutating func walk(_ markup: Markup) {
        for child in markup.children {
            visit(child)
        }
    }

    private mutating func visit(_ markup: Markup) {
        switch markup {
        case let heading as Heading:
            addBlock(heading, kind: .heading(level: heading.level))
            addMarkers(delimiterRanges(of: heading))
            visitInlines(of: heading, traits: [])

        case let paragraph as Paragraph:
            addBlock(paragraph, kind: .paragraph)
            visitInlines(of: paragraph, traits: [])

        case let codeBlock as CodeBlock:
            addBlock(codeBlock, kind: .codeBlock(language: codeBlock.language))
            let fences = fenceRanges(of: codeBlock)
            addMarkers(fences)

            if let language = codeBlock.language, DiagramLanguage.isDiagram(language),
               let range = range(of: codeBlock) {
                layout.diagrams.append(DiagramPlacement(
                    range: range,
                    source: codeBlock.code,
                    language: language.lowercased()
                ))
            } else {
                highlightCode(codeBlock, fences: fences)
            }

        case is ThematicBreak:
            addBlock(markup, kind: .thematicBreak)
            if let range = range(of: markup) { addMarkers([range]) }

        case let quote as BlockQuote:
            addMarkers(quotePrefixRanges(of: quote))
            quoteDepth += 1
            walk(quote)
            quoteDepth -= 1

        case is UnorderedList, is OrderedList:
            listDepth += 1
            walk(markup)
            listDepth -= 1

        case let item as ListItem:
            visitListItem(item)

        case let table as Markdown.Table:
            addBlock(table, kind: .table)
            visitTableCells(table)
            if let range = range(of: table),
               let structure = TableParser.parse(source: source, range: range, index: index) {
                layout.tables.append(structure)
                // The pipes are deliberately not marked as hidden syntax. They disappear
                // only when the editor can draw the table as a grid, so a table too wide to
                // draw keeps its delimiters and stays readable as source.
            }

        case is HTMLBlock:
            addBlock(markup, kind: .html)

        default:
            walk(markup)
        }
    }

    private mutating func visitListItem(_ item: ListItem) {
        // The list marker is the gap between the item's start and its first block's start.
        if let itemRange = range(of: item),
           let firstChild = item.children.first(where: { range(of: $0) != nil }),
           let childRange = range(of: firstChild),
           childRange.location > itemRange.location {
            // The gap before the item's content holds the list marker and, for task items,
            // the checkbox: "- [x] ".
            let gap = NSRange(
                location: itemRange.location,
                length: childRange.location - itemRange.location
            )

            if let checkbox = item.checkbox, let box = checkboxRange(within: gap) {
                let markerLength = box.location - gap.location
                let markerRange = NSRange(location: gap.location, length: markerLength)
                // Hidden, not painted: on a task item the checkbox *is* the marker, so drawing
                // a bullet as well would give every row a stray dot before its box.
                addMarkers([markerRange], .hidden)
                addMarkers([box], .checkbox(checked: checkbox == .checked))
            } else {
                addMarkers([gap], markerPresentation(for: gap))
            }
        }
        pendingListItemStart = true
        walk(item)
        pendingListItemStart = false
    }

    /// A bullet marker is painted over; an ordered marker keeps its number and is dimmed.
    private func markerPresentation(for range: NSRange) -> Marker.Presentation {
        guard range.length > 0 else { return .dimmed }
        let text = source.substring(with: range).trimmingCharacters(in: .whitespaces)
        return (text == "-" || text == "*" || text == "+") ? .bullet : .dimmed
    }

    /// Locates the `[x]` or `[ ]` inside a task list item's marker gap.
    private func checkboxRange(within gap: NSRange) -> NSRange? {
        guard gap.length >= 3, NSMaxRange(gap) <= source.length else { return nil }
        let text = source.substring(with: gap) as NSString
        let open = text.range(of: "[")
        guard open.location != NSNotFound else { return nil }
        let remainder = NSRange(location: open.location, length: text.length - open.location)
        let close = text.range(of: "]", options: [], range: remainder)
        guard close.location != NSNotFound else { return nil }
        return NSRange(
            location: gap.location + open.location,
            length: close.location - open.location + 1
        )
    }

    /// The ``` lines of a fenced code block.
    private func fenceRanges(of codeBlock: CodeBlock) -> [NSRange] {
        guard let full = range(of: codeBlock) else { return [] }
        var ranges: [NSRange] = []
        let firstLine = index.lineRange(containing: full.location)
        if isFence(firstLine) { ranges.append(firstLine) }

        let end = max(full.location + full.length - 1, full.location)
        let lastLine = index.lineRange(containing: end)
        if lastLine.location != firstLine.location, isFence(lastLine) { ranges.append(lastLine) }
        return ranges
    }

    /// Colours the body of a fenced block, excluding the fence lines themselves.
    private mutating func highlightCode(_ codeBlock: CodeBlock, fences: [NSRange]) {
        guard SyntaxHighlighter.supports(language: codeBlock.language),
              let full = range(of: codeBlock) else { return }

        // The body starts after the opening fence and ends before the closing one.
        var start = full.location
        var end = NSMaxRange(full)
        if let opening = fences.first(where: { $0.location == full.location }) {
            start = min(NSMaxRange(opening) + 1, end)
        }
        if let closing = fences.last, closing.location > start, NSMaxRange(closing) >= end - 1 {
            end = max(closing.location, start)
        }
        guard end > start, end <= source.length else { return }

        let body = source.substring(with: NSRange(location: start, length: end - start))
        layout.code += SyntaxHighlighter.spans(in: body, language: codeBlock.language, offset: start)
    }

    private func isFence(_ range: NSRange) -> Bool {
        guard range.length > 0, NSMaxRange(range) <= source.length else { return false }
        let text = source.substring(with: range).trimmingCharacters(in: .whitespaces)
        return text.hasPrefix("```") || text.hasPrefix("~~~")
    }

    /// The `>` prefix on each line of a block quote.
    private func quotePrefixRanges(of quote: BlockQuote) -> [NSRange] {
        guard let full = range(of: quote) else { return [] }
        var ranges: [NSRange] = []
        var offset = full.location
        let end = full.location + full.length

        while offset < end, offset < source.length {
            let lineRange = index.lineRange(containing: offset)
            let line = source.substring(with: lineRange)
            if let marker = line.range(of: #"^\s*>\s?"#, options: .regularExpression) {
                let length = line.distance(from: line.startIndex, to: marker.upperBound)
                let utf16Length = String(line[line.startIndex..<marker.upperBound]).utf16.count
                _ = length
                ranges.append(NSRange(location: lineRange.location, length: utf16Length))
            }
            let next = NSMaxRange(lineRange) + 1
            if next <= offset { break }
            offset = next
        }
        return ranges
    }

    private mutating func visitTableCells(_ table: Markdown.Table) {
        for child in table.children {
            if let head = child as? Markdown.Table.Head {
                for cell in head.cells { visitInlines(of: cell, traits: .bold) }
            } else if let body = child as? Markdown.Table.Body {
                for row in body.rows {
                    for cell in row.cells { visitInlines(of: cell, traits: []) }
                }
            }
        }
    }

    // MARK: Inlines

    private mutating func visitInlines(of markup: Markup, traits: InlineTraits, link: String? = nil) {
        for child in markup.children {
            switch child {
            case let strong as Strong:
                addInline(range(of: strong), traits: traits.union(.bold), link: link)
                addMarkers(delimiterRanges(of: strong))
                visitInlines(of: strong, traits: traits.union(.bold), link: link)

            case let emphasis as Emphasis:
                addInline(range(of: emphasis), traits: traits.union(.italic), link: link)
                addMarkers(delimiterRanges(of: emphasis))
                visitInlines(of: emphasis, traits: traits.union(.italic), link: link)

            case let strike as Strikethrough:
                addInline(range(of: strike), traits: traits.union(.strikethrough), link: link)
                addMarkers(delimiterRanges(of: strike))
                visitInlines(of: strike, traits: traits.union(.strikethrough), link: link)

            case let code as InlineCode:
                addInline(range(of: code), traits: traits.union(.code), link: link)
                addMarkers(backtickRanges(of: code))

            case let linkNode as Markdown.Link:
                let destination = linkNode.destination ?? link
                addInline(range(of: linkNode), traits: traits.union(.link), link: destination)
                addMarkers(delimiterRanges(of: linkNode))
                visitInlines(of: linkNode, traits: traits.union(.link), link: destination)

            case let image as Markdown.Image:
                if let range = range(of: image) {
                    images.append(ImagePlacement(
                        range: range,
                        source: image.source ?? "",
                        alt: image.plainText
                    ))
                    // The syntax is not marked as hidden here. It disappears only once the
                    // editor has a picture to put in its place, so a missing or still
                    // loading image shows its Markdown instead of a blank gap.
                    addInline(range, traits: .code)
                }

            default:
                if child.childCount > 0 {
                    visitInlines(of: child, traits: traits, link: link)
                }
            }
        }
    }

    /// Inline code has no children, so its backtick runs are measured from the source.
    private func backtickRanges(of code: InlineCode) -> [NSRange] {
        guard let full = range(of: code), full.length > 0, NSMaxRange(full) <= source.length else { return [] }
        let text = source.substring(with: full)
        let leading = text.prefix { $0 == "`" }.count
        guard leading > 0 else { return [] }
        let trailing = text.reversed().prefix { $0 == "`" }.count
        guard full.length > leading + trailing else { return [] }
        return [
            NSRange(location: full.location, length: leading),
            NSRange(location: NSMaxRange(full) - trailing, length: trailing)
        ]
    }
}
