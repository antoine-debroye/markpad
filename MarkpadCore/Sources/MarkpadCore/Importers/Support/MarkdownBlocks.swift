import Foundation

/// A span of text with uniform formatting, as a structured importer reads it from a Word run,
/// an HTML element or an attributed-string range.
///
/// Importers describe *what* the document says; `MarkdownRenderer` alone decides how that is
/// spelled in Markdown, so escaping, emphasis and list layout are identical whichever format
/// the text came from.
struct MarkdownRun: Equatable, Sendable {
    var text: String
    var bold = false
    var italic = false
    var strikethrough = false
    var code = false
    /// Destination of the link this run belongs to. Adjacent runs sharing it form one link.
    var link: String?
    /// When set, the run is an image and `text` is its alt text.
    var imageDestination: String?

    init(
        _ text: String,
        bold: Bool = false,
        italic: Bool = false,
        strikethrough: Bool = false,
        code: Bool = false,
        link: String? = nil
    ) {
        self.text = text
        self.bold = bold
        self.italic = italic
        self.strikethrough = strikethrough
        self.code = code
        self.link = link
    }

    static func image(alt: String, destination: String, link: String? = nil) -> MarkdownRun {
        var run = MarkdownRun(alt, link: link)
        run.imageDestination = destination
        return run
    }

    /// A hard line break inside a paragraph.
    static let lineBreak = MarkdownRun("\n")

    fileprivate func sameStyle(as other: MarkdownRun) -> Bool {
        bold == other.bold && italic == other.italic && strikethrough == other.strikethrough
            && code == other.code && link == other.link
            && imageDestination == nil && other.imageDestination == nil
    }
}

/// A block of an imported document.
enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, [MarkdownRun])
    case paragraph([MarkdownRun])
    /// One list item. Consecutive items form a list; `level` is 0 for the outermost.
    case listItem(level: Int, ordered: Bool, [MarkdownRun])
    /// Rows of cells. The first row is the header, as GFM requires one.
    case table([[[MarkdownRun]]])
    case code(String, language: String?)
    case quote([MarkdownRun])
    case rule
    /// Already-formed Markdown, emitted as-is: a slide marker comment, a nested document.
    case raw(String)
}

/// Turns importer output into Markdown text.
enum MarkdownRenderer {
    static func render(_ blocks: [MarkdownBlock]) -> String {
        var chunks: [String] = []
        var list: [String] = []
        // Per open list level: where its markers start, where its content starts, how many
        // items it has had, and whether it is numbered.
        var markerColumns: [Int] = []
        var contentColumns: [Int] = []
        var ordinals: [Int] = []
        var orderedLevels: [Bool] = []

        func flushList() {
            guard !list.isEmpty else { return }
            chunks.append(list.joined(separator: "\n"))
            list = []
            markerColumns = []
            contentColumns = []
            ordinals = []
            orderedLevels = []
        }

        for block in blocks {
            if case .listItem(let rawLevel, let ordered, let runs) = block {
                // A level can only go one deeper than the previous item, or the extra
                // indentation would read as a code block.
                let level = min(max(rawLevel, 0), markerColumns.count)
                if level < markerColumns.count {
                    let keep = level + 1
                    markerColumns.removeSubrange(keep...)
                    contentColumns.removeSubrange(keep...)
                    ordinals.removeSubrange(keep...)
                    orderedLevels.removeSubrange(keep...)
                    if orderedLevels[level] != ordered {
                        // A bullet list followed by a numbered one at the same depth starts over.
                        ordinals[level] = 0
                        orderedLevels[level] = ordered
                    }
                } else {
                    let column = level == 0 ? 0 : contentColumns[level - 1]
                    markerColumns.append(column)
                    contentColumns.append(column)
                    ordinals.append(0)
                    orderedLevels.append(ordered)
                }
                ordinals[level] += 1
                let marker = ordered ? "\(ordinals[level])." : "-"
                contentColumns[level] = markerColumns[level] + marker.count + 1
                let indent = String(repeating: " ", count: markerColumns[level])
                let continuation = String(repeating: " ", count: contentColumns[level])
                let body = inline(runs, lineStartEscaping: true)
                    .replacingOccurrences(of: "\n", with: "\n" + continuation)
                list.append(indent + marker + " " + body)
                continue
            }
            flushList()

            switch block {
            case .heading(let level, let runs):
                let text = singleLine(inline(runs, lineStartEscaping: false))
                guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                chunks.append(String(repeating: "#", count: min(max(level, 1), 6)) + " " + text)
            case .paragraph(let runs):
                let text = inline(runs, lineStartEscaping: true)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                chunks.append(text)
            case .quote(let runs):
                let text = inline(runs, lineStartEscaping: true)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                chunks.append(text.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "> " + $0 }.joined(separator: "\n"))
            case .table(let rows):
                if let table = MarkdownText.table(rows.map { $0.map { singleLine(inline($0, lineStartEscaping: false)) } }) {
                    chunks.append(table)
                }
            case .code(let text, let language):
                chunks.append(MarkdownText.fenced(text, language: language))
            case .rule:
                chunks.append("---")
            case .raw(let text):
                let trimmed = text.trimmingCharacters(in: .newlines)
                if !trimmed.isEmpty { chunks.append(trimmed) }
            case .listItem:
                break
            }
        }
        flushList()
        return chunks.isEmpty ? "" : chunks.joined(separator: "\n\n") + "\n"
    }

    /// Headings and table cells hold a single line, so hard breaks become spaces.
    private static func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\\\n", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    /// Renders runs as inline Markdown.
    ///
    /// Emphasis is opened and closed only where it changes, so `**a** **b**` does not become
    /// `**a****b**`. Whitespace at a boundary is moved outside the delimiters, because
    /// `** bold**` is not emphasis in CommonMark.
    static func inline(_ runs: [MarkdownRun], lineStartEscaping: Bool) -> String {
        let merged = merge(runs)
        var output = ""
        var index = 0
        while index < merged.count {
            let run = merged[index]
            if let link = run.link {
                var group: [MarkdownRun] = []
                while index < merged.count, merged[index].link == link {
                    var inner = merged[index]
                    inner.link = nil
                    group.append(inner)
                    index += 1
                }
                let label = styled(group)
                let trimmed = label.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    output += label
                } else {
                    let leading = String(label.prefix { $0 == " " })
                    let trailing = String(label.reversed().prefix { $0 == " " })
                    output += leading + "[" + trimmed + "](" + MarkdownText.destination(link) + ")" + trailing
                }
            } else {
                var group: [MarkdownRun] = []
                while index < merged.count, merged[index].link == nil {
                    group.append(merged[index])
                    index += 1
                }
                output += styled(group)
            }
        }
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let cleaned = lines.enumerated().map { offset, line -> String in
            let body = offset == lines.count - 1 ? line : line.replacingOccurrences(
                of: "\\s+$", with: "", options: .regularExpression)
            return lineStartEscaping ? MarkdownText.escapeLineStart(body) : body
        }
        // A hard break is a trailing backslash; a break at the very end is dropped.
        return cleaned.joined(separator: "\\\n").trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "(\\\\\\n)+$", with: "", options: .regularExpression)
    }

    private static func merge(_ runs: [MarkdownRun]) -> [MarkdownRun] {
        var merged: [MarkdownRun] = []
        for run in runs where !run.text.isEmpty || run.imageDestination != nil {
            if let last = merged.last, last.sameStyle(as: run), run.imageDestination == nil {
                merged[merged.count - 1].text += run.text
            } else {
                merged.append(run)
            }
        }
        return merged
    }

    /// Emphasis, code and images for runs that share one link state.
    ///
    /// CommonMark only recognises a delimiter that "flanks" its text, which rules out three
    /// spellings that naive concatenation produces:
    /// - `*a****b**`: a closing and an opening delimiter touching merge into one run. The
    ///   opening one switches to `_` instead, when what follows allows it.
    /// - `a**(b)**`: an opening delimiter between a letter and punctuation. The leading
    ///   punctuation moves before the delimiter.
    /// - `**b.**c`: a closing delimiter between punctuation and a letter. The trailing
    ///   punctuation moves outside the same way.
    private static func styled(_ runs: [MarkdownRun]) -> String {
        var output = ""
        var open: [String] = []

        func isWordCharacter(_ character: Character?) -> Bool {
            guard let character else { return false }
            return character.isLetter || character.isNumber
        }
        func isPunctuation(_ character: Character) -> Bool {
            character.isPunctuation || character.isSymbol
        }

        /// Closes down to `depth`. Trailing spaces always move outside the delimiters; trailing
        /// punctuation does too when a word character follows.
        func close(to depth: Int, before next: Character?) {
            guard open.count > depth else { return }
            var moved = String(output.reversed().prefix { $0 == " " }.reversed())
            output.removeLast(moved.count)
            if isWordCharacter(next) {
                let punctuation = String(output.reversed().prefix(while: isPunctuation).reversed())
                // Only when a word character remains inside to anchor the delimiter.
                if !punctuation.isEmpty, output.count > punctuation.count,
                   isWordCharacter(output.dropLast(punctuation.count).last) {
                    output.removeLast(punctuation.count)
                    moved = punctuation + moved
                }
            }
            while open.count > depth { output += open.removeLast() }
            output += moved
        }

        for (index, run) in runs.enumerated() {
            let next = runs.dropFirst(index + 1).first { !$0.text.isEmpty || $0.imageDestination != nil }
            let nextCharacter: Character? = next.flatMap { $0.imageDestination == nil ? $0.text.first : "!" }

            if let destination = run.imageDestination {
                close(to: 0, before: "!")
                output += "![" + MarkdownText.escape(run.text) + "](" + MarkdownText.destination(destination) + ")"
                continue
            }
            if run.text.allSatisfy({ $0 == "\n" }) {
                close(to: 0, before: nil)
                output += run.text
                continue
            }
            // Whitespace-only runs carry no visible emphasis; emitting them bare avoids `** **`.
            if run.text.allSatisfy({ $0 == " " || $0 == "\t" }) {
                output += " "
                continue
            }

            var text = run.text.replacingOccurrences(of: "\t", with: " ")
            var wanted: [Character] = []   // "b" bold, "i" italic, "s" strikethrough, in nesting order
            if !run.code {
                // Emphasis on punctuation alone shows nothing and only risks mis-parsing.
                let hasWords = text.contains { $0.isLetter || $0.isNumber }
                if run.bold && hasWords { wanted.append("b") }
                if run.italic && hasWords { wanted.append("i") }
                if run.strikethrough && hasWords { wanted.append("s") }
            }

            // Keep the longest prefix of open delimiters that is still wanted, in order.
            let openKinds = open.map(kind(of:))
            var keep = 0
            while keep < open.count, keep < wanted.count, openKinds[keep] == wanted[keep] { keep += 1 }
            close(to: keep, before: text.first)

            // Opening delimiters must be left-flanking: leading spaces go before them, and so
            // does leading punctuation that follows a word character.
            let leading = String(text.prefix { $0 == " " })
            text.removeFirst(leading.count)
            output += leading
            // A delimiter just closed counts too: cmark-gfm does not open emphasis on
            // punctuation straight after a closing `~~`.
            if wanted.count > open.count, isWordCharacter(output.last) || output.last.map({ "*_~".contains($0) }) == true {
                let punctuation = String(text.prefix(while: isPunctuation))
                if punctuation.count < text.count {
                    text.removeFirst(punctuation.count)
                    output += run.code ? "" : MarkdownText.escape(punctuation)
                    if run.code { text = punctuation + text }
                }
            }

            if wanted.count > open.count {
                // Touching a delimiter just closed would merge with it, so switch characters —
                // `_` needs no word character right after its closing, which the lookahead
                // checks; otherwise the text stays plain rather than render as stray `*`s.
                let touching = output.last == "*" || output.last == "_"
                let underscoreSafe = !isWordCharacter(nextCharacter) && !isWordCharacter(output.last)
                for kind in wanted[open.count...] {
                    let delimiter: String
                    switch kind {
                    case "b": delimiter = touching ? (output.last == "*" && underscoreSafe ? "__" : "") : "**"
                    case "i": delimiter = touching ? (output.last == "*" && underscoreSafe ? "_" : "") : "*"
                    default: delimiter = touching ? "" : "~~"
                    }
                    guard !delimiter.isEmpty else { break }
                    output += delimiter
                    open.append(delimiter)
                }
            }
            output += run.code ? MarkdownText.codeSpan(text) : MarkdownText.escape(text)
        }
        close(to: 0, before: nil)
        return output
    }

    private static func kind(of delimiter: String) -> Character {
        switch delimiter {
        case "**", "__": return "b"
        case "*", "_": return "i"
        default: return "s"
        }
    }
}
