import Foundation

/// Walks an XHTML tree and describes it as Markdown blocks.
///
/// Shared by the web page and EPUB importers, which differ only in where pictures come from and
/// which links still mean something once the page is Markdown; both are injected.
///
/// Whitespace follows HTML: runs of spaces, tabs and newlines read as one space, and space at
/// the edge of a block is dropped. Only `pre` keeps its text as written. A non-breaking space is
/// content, not whitespace, and is kept.
final class HTMLToMarkdown {
    /// Returns the Markdown destination for an `<img src>`, or nil to show the alt text instead.
    typealias ImageResolver = (_ source: String) -> String?
    /// Returns the destination to link to for an `href`, or nil to keep the text unlinked.
    typealias LinkResolver = (_ href: String) -> String?

    private let resolveImage: ImageResolver
    private let resolveLink: LinkResolver

    private(set) var blocks: [MarkdownBlock] = []
    /// The page's `<title>`, whitespace collapsed.
    private(set) var title: String?

    private var runs: [MarkdownRun] = []
    private var style = MarkdownRun("")
    /// Why inline text is currently being collected into one block, innermost last. While this
    /// is non-empty, block boundaries become line breaks rather than new blocks.
    private var flattening: [Flattening] = []

    private enum Flattening {
        case heading, quote, cell, listItem(level: Int, ordered: Bool)
    }

    /// Elements whose content is never shown.
    private static let skipped: Set<String> = [
        "head", "script", "style", "noscript", "template", "iframe", "frame", "frameset", "object",
        "embed", "applet", "input", "button", "select", "option", "optgroup", "textarea", "datalist",
        "canvas", "video", "audio", "map", "title", "meta", "link", "base",
    ]
    /// Elements that start and end a block. Their inline content becomes a paragraph.
    private static let blockContainers: Set<String> = [
        "p", "div", "section", "article", "main", "header", "footer", "aside", "nav", "address",
        "center", "form", "fieldset", "legend", "details", "summary", "hgroup", "dialog", "search",
        "body", "html", "li", "dd", "figcaption", "figure", "caption", "tr", "td", "th", "tbody",
        "thead", "tfoot", "dir", "menu",
    ]

    init(resolveImage: @escaping ImageResolver, resolveLink: @escaping LinkResolver) {
        self.resolveImage = resolveImage
        self.resolveLink = resolveLink
    }

    /// The default link policy for a web page: `javascript:` links and in-page anchors are
    /// dropped, everything else is kept as written.
    static func keepMeaningfulLinks(_ href: String) -> String? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { return nil }
        if trimmed.lowercased().hasPrefix("javascript:") { return nil }
        return trimmed
    }

    /// Converts a whole document. The body is walked; the head only supplies the title.
    func convert(_ document: XMLDocument) {
        guard let root = document.rootElement() else { return }
        if let head = Self.children(of: root).first(where: { Self.name(of: $0) == "head" }),
           let titleElement = Self.children(of: head).first(where: { Self.name(of: $0) == "title" }) {
            let text = Self.collapse(titleElement.stringValue ?? "").trimmingCharacters(in: .whitespaces)
            title = text.isEmpty ? nil : text
        }
        if let body = Self.children(of: root).first(where: { Self.name(of: $0) == "body" }) {
            walkChildren(of: body)
        } else {
            walk(root)
        }
        flush()
    }

    /// True when the output has a top-level heading, so the title need not be added.
    var hasLevelOneHeading: Bool {
        blocks.contains { if case .heading(1, _) = $0 { return true } else { return false } }
    }

    // MARK: - Walking

    private func walkChildren(of node: XMLNode) {
        for child in node.children ?? [] { walk(child) }
    }

    private func walk(_ node: XMLNode) {
        switch node.kind {
        case .text:
            appendText(node.stringValue ?? "")
        case .element:
            guard let element = node as? XMLElement else { return }
            walkElement(element)
        default:
            // Comments, processing instructions, DTD nodes.
            break
        }
    }

    /// Elements currently open during the walk.
    private var depth = 0

    private func walkElement(_ element: XMLElement) {
        let name = Self.name(of: element)
        if Self.skipped.contains(name) { return }
        // Content nested deeper than any real page is left out rather than walked, which would
        // recurse once per level.
        guard depth < ImportLimits.maximumNestingDepth else { return }
        depth += 1
        defer { depth -= 1 }

        switch name {
        case "br":
            runs.append(.lineBreak)
        case "hr":
            if flattening.isEmpty {
                flush()
                blocks.append(.rule)
            } else {
                boundary()
            }
        case "h1", "h2", "h3", "h4", "h5", "h6":
            if flattening.isEmpty {
                flush()
                let level = Int(name.dropFirst()) ?? 1
                let content = collect(.heading) { walkChildren(of: element) }
                blocks.append(.heading(level: level, content))
            } else {
                boundary()
                walkChildren(of: element)
                boundary()
            }
        case "ul", "ol":
            if flattening.isEmpty {
                flush()
                walkList(element, level: 0)
            } else if case .listItem(let level, _)? = flattening.last {
                // A list nested in an item: finish the item so far, then list one level deeper.
                emitListItem()
                let saved = flattening
                flattening = []
                walkList(element, level: level + 1)
                flattening = saved
            } else {
                boundary()
                walkChildren(of: element)
                boundary()
            }
        case "blockquote":
            if flattening.isEmpty {
                flush()
                let content = collect(.quote) { walkChildren(of: element) }
                blocks.append(.quote(content))
            } else {
                boundary()
                walkChildren(of: element)
                boundary()
            }
        case "pre":
            walkPreformatted(element)
        case "table":
            if flattening.isEmpty {
                flush()
                walkTable(element)
            } else {
                walkTableFlattened(element)
            }
        case "dt":
            boundary()
            withStyle({ $0.bold = true }) { walkChildren(of: element) }
            boundary()
        case "img", "image":
            appendImage(element)
        case "svg":
            // EPUB covers wrap their picture in SVG; the drawing itself cannot be shown.
            for image in Self.descendants(of: element) where Self.name(of: image) == "image" {
                appendImage(image)
            }
        case "a":
            let href = element.attribute(forName: "href")?.stringValue
            let destination = href.flatMap(resolveLink)
            if let destination {
                withStyle({ $0.link = destination }) { walkChildren(of: element) }
            } else {
                walkChildren(of: element)
            }
        case "strong", "b":
            withStyle({ $0.bold = true }) { walkChildren(of: element) }
        case "em", "i", "cite", "dfn", "var":
            withStyle({ $0.italic = true }) { walkChildren(of: element) }
        case "s", "del", "strike":
            withStyle({ $0.strikethrough = true }) { walkChildren(of: element) }
        case "code", "kbd", "samp", "tt":
            withStyle({ $0.code = true }) { walkChildren(of: element) }
        default:
            if Self.blockContainers.contains(name) {
                boundary()
                walkChildren(of: element)
                boundary()
            } else {
                // Unknown and purely presentational inline elements are transparent.
                walkChildren(of: element)
            }
        }
    }

    // MARK: Lists

    private func walkList(_ list: XMLElement, level: Int) {
        let ordered = Self.name(of: list) == "ol"
        for child in list.children ?? [] {
            if let element = child as? XMLElement {
                let name = Self.name(of: element)
                if name == "li" {
                    walkListItem(element, level: level, ordered: ordered)
                } else if name == "ul" || name == "ol" {
                    // Invalid but common: a list directly inside a list, meaning a sublist.
                    walkList(element, level: level + 1)
                } else if !Self.skipped.contains(name) {
                    walkListItem(element, level: level, ordered: ordered)
                }
            } else if child.kind == .text,
                      !Self.collapse(child.stringValue ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                let item = XMLElement(name: "li")
                item.addChild(XMLNode.text(withStringValue: child.stringValue ?? "") as! XMLNode)
                walkListItem(item, level: level, ordered: ordered)
            }
        }
    }

    private func walkListItem(_ item: XMLElement, level: Int, ordered: Bool) {
        flattening.append(.listItem(level: level, ordered: ordered))
        walkChildren(of: item)
        emitListItem()
        flattening.removeLast()
    }

    /// Emits the runs collected for the innermost list item, if it has any.
    private func emitListItem() {
        guard case .listItem(let level, let ordered)? = flattening.last else { return }
        let content = Self.trimmed(runs)
        runs = []
        guard Self.hasContent(content) else { return }
        blocks.append(.listItem(level: level, ordered: ordered, content))
    }

    // MARK: Preformatted text

    private func walkPreformatted(_ element: XMLElement) {
        var text = element.stringValue ?? ""
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        // A newline straight after `<pre>` (or its `<code>`) is not content.
        if text.hasPrefix("\n") { text.removeFirst() }
        while text.hasSuffix("\n") { text.removeLast() }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        if flattening.isEmpty {
            flush()
            blocks.append(.code(text, language: Self.codeLanguage(of: element)))
        } else {
            boundary()
            let lines = text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                if index > 0 { runs.append(.lineBreak) }
                var run = style
                run.text = line
                run.code = true
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { runs.append(run) }
            }
            boundary()
        }
    }

    /// The language named by a `language-x` or `lang-x` class on the `pre` or its `code`.
    private static func codeLanguage(of pre: XMLElement) -> String? {
        var candidates = [pre]
        if let code = children(of: pre).first(where: { name(of: $0) == "code" }) { candidates.append(code) }
        for element in candidates {
            let classes = (element.attribute(forName: "class")?.stringValue ?? "")
                .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            for token in classes {
                for prefix in ["language-", "lang-"] where token.lowercased().hasPrefix(prefix) {
                    let language = token.dropFirst(prefix.count)
                    if !language.isEmpty, language.allSatisfy({ $0.isLetter || $0.isNumber || "+#-_.".contains($0) }) {
                        return String(language)
                    }
                }
            }
        }
        return nil
    }

    // MARK: Tables

    private func tableRows(_ table: XMLElement) -> [XMLElement] {
        var head: [XMLElement] = []
        var body: [XMLElement] = []
        var foot: [XMLElement] = []
        for child in Self.children(of: table) {
            switch Self.name(of: child) {
            case "thead": head += Self.children(of: child).filter { Self.name(of: $0) == "tr" }
            case "tfoot": foot += Self.children(of: child).filter { Self.name(of: $0) == "tr" }
            case "tbody": body += Self.children(of: child).filter { Self.name(of: $0) == "tr" }
            case "tr": body.append(child)
            default: break
            }
        }
        return head + body + foot
    }

    private func walkTable(_ table: XMLElement) {
        if let caption = Self.children(of: table).first(where: { Self.name(of: $0) == "caption" }) {
            let content = collect(.cell) { walkChildren(of: caption) }
            if Self.hasContent(content) { blocks.append(.paragraph(content)) }
        }
        var rows: [[[MarkdownRun]]] = []
        for row in tableRows(table) {
            var cells: [[MarkdownRun]] = []
            for cell in Self.children(of: row) {
                let name = Self.name(of: cell)
                guard name == "td" || name == "th" else { continue }
                let content = collect(.cell) { walkChildren(of: cell) }
                cells.append(content)
                let span = Int(cell.attribute(forName: "colspan")?.stringValue ?? "") ?? 1
                if span > 1 { cells += Array(repeating: [], count: min(span, 1000) - 1) }
            }
            if !cells.isEmpty { rows.append(cells) }
        }
        guard rows.contains(where: { $0.contains(where: Self.hasContent) }) else { return }
        blocks.append(.table(rows))
    }

    /// A table inside a quote, list item or cell: one line per row, cells separated by spaces.
    private func walkTableFlattened(_ table: XMLElement) {
        boundary()
        for row in tableRows(table) {
            for cell in Self.children(of: row) where ["td", "th"].contains(Self.name(of: cell)) {
                appendText(" ")
                walkChildren(of: cell)
                appendText(" ")
            }
            boundary()
        }
    }

    // MARK: Images

    private func appendImage(_ element: XMLElement) {
        let alt = Self.collapse(element.attribute(forName: "alt")?.stringValue ?? "")
            .trimmingCharacters(in: .whitespaces)
        let source = element.attribute(forName: "src")?.stringValue
            ?? element.attribute(forName: "href")?.stringValue
            ?? element.attribute(forName: "xlink:href")?.stringValue
            ?? element.attributes?.first(where: { $0.localName == "href" })?.stringValue
        if let source = source?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty,
           let destination = resolveImage(source) {
            runs.append(.image(alt: alt, destination: destination, link: style.link))
        } else if !alt.isEmpty {
            appendText(alt)
        }
    }

    // MARK: - Inline collection

    private func appendText(_ raw: String) {
        let text = Self.collapse(raw)
        guard !text.isEmpty else { return }
        var piece = text
        if piece.hasPrefix(" ") && endsWithSpaceOrBreak { piece.removeFirst() }
        guard !piece.isEmpty else { return }
        var run = style
        run.text = piece
        runs.append(run)
    }

    /// Whether a leading space in new text would be redundant.
    private var endsWithSpaceOrBreak: Bool {
        for run in runs.reversed() {
            if run.imageDestination != nil { return false }
            if run.text.isEmpty { continue }
            return run.text.hasSuffix(" ") || run.text.hasSuffix("\n")
        }
        return true
    }

    private func withStyle(_ change: (inout MarkdownRun) -> Void, _ body: () -> Void) {
        let saved = style
        change(&style)
        body()
        style = saved
    }

    /// Collects the inline content produced by `body` as one block's runs.
    private func collect(_ reason: Flattening, _ body: () -> Void) -> [MarkdownRun] {
        let savedRuns = runs
        let savedStyle = style
        runs = []
        flattening.append(reason)
        body()
        flattening.removeLast()
        let content = Self.trimmed(runs)
        runs = savedRuns
        style = savedStyle
        return content
    }

    /// The edge of a block: a new paragraph, or a new line inside a flattened block.
    private func boundary() {
        if flattening.isEmpty {
            flush()
        } else if let last = runs.last(where: { !$0.text.isEmpty || $0.imageDestination != nil }),
                  !(last.imageDestination == nil && last.text == "\n") {
            runs.append(.lineBreak)
        }
    }

    /// Ends the current paragraph.
    private func flush() {
        let content = Self.trimmed(runs)
        runs = []
        if Self.hasContent(content) { blocks.append(.paragraph(content)) }
    }

    // MARK: - Helpers

    /// Drops spaces at the start and end of the runs and around line breaks, and line breaks
    /// at either end.
    static func trimmed(_ input: [MarkdownRun]) -> [MarkdownRun] {
        var runs = input.filter { !$0.text.isEmpty || $0.imageDestination != nil }
        func isBreak(_ run: MarkdownRun) -> Bool { run.imageDestination == nil && run.text == "\n" }
        for index in runs.indices where runs[index].imageDestination == nil && !isBreak(runs[index]) {
            let atStart = index == 0 || isBreak(runs[index - 1])
            let atEnd = index == runs.count - 1 || isBreak(runs[index + 1])
            var text = runs[index].text
            if atStart { text = String(text.drop(while: { $0 == " " })) }
            if atEnd { while text.hasSuffix(" ") { text.removeLast() } }
            runs[index].text = text
        }
        runs = runs.filter { !$0.text.isEmpty || $0.imageDestination != nil }
        // Breaks at the edges, and more than one in a row, carry nothing.
        var result: [MarkdownRun] = []
        for run in runs {
            if isBreak(run), result.isEmpty || isBreak(result[result.count - 1]) { continue }
            result.append(run)
        }
        while let last = result.last, isBreak(last) { result.removeLast() }
        // A run that is now only spaces before a break or the end is harmless; the renderer
        // trims line ends.
        return result
    }

    static func hasContent(_ runs: [MarkdownRun]) -> Bool {
        runs.contains { $0.imageDestination != nil || !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Collapses HTML whitespace (not non-breaking spaces) to single spaces.
    static func collapse(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        var inSpace = false
        for scalar in text.unicodeScalars {
            switch scalar {
            case " ", "\t", "\n", "\r", "\u{0C}":
                if !inSpace { output.append(" ") }
                inSpace = true
            default:
                output.unicodeScalars.append(scalar)
                inSpace = false
            }
        }
        return output
    }

    /// Lower-cased element name, using the original name of an element renamed for the tidier.
    static func name(of element: XMLElement) -> String {
        if let original = element.attribute(forName: HTMLDocumentLoader.originalTagAttribute)?.stringValue {
            return original.lowercased()
        }
        return (element.localName ?? element.name ?? "").lowercased()
    }

    static func children(of node: XMLNode) -> [XMLElement] {
        (node.children ?? []).compactMap { $0 as? XMLElement }
    }

    /// Every element below `node`, in document order. Iterative, so nesting depth cannot
    /// exhaust the stack.
    static func descendants(of node: XMLNode) -> [XMLElement] {
        var result: [XMLElement] = []
        var pending = Array(children(of: node).reversed())
        while let next = pending.popLast() {
            result.append(next)
            pending += children(of: next).reversed()
        }
        return result
    }
}
