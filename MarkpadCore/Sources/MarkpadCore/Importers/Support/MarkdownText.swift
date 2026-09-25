import Foundation

/// Spelling rules for literal text in generated Markdown.
///
/// Converted documents are prose, not Markdown, so any character that Markdown would read as
/// syntax has to be escaped — otherwise a Word paragraph that begins "1990. A good year" becomes
/// a numbered list and `*nix` starts emphasis.
enum MarkdownText {
    /// Characters that are syntax wherever they appear in a line.
    private static let inlineSpecials: Set<Character> = ["\\", "`", "*", "_", "[", "]", "<", "~"]

    /// Escapes inline syntax. Line-start syntax is `escapeLineStart`'s job.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            if inlineSpecials.contains(character) { out.append("\\") }
            out.append(character)
        }
        // `&amp;` in prose would otherwise display as `&`.
        return out.replacingOccurrences(
            of: "&(?=#?[A-Za-z0-9]+;)", with: "\\\\&", options: .regularExpression)
    }

    /// Escapes a line whose first characters would start a block: a heading, quote, list,
    /// table, rule or setext underline.
    static func escapeLineStart(_ line: String) -> String {
        guard let first = line.first else { return line }
        if "#>|+-=".contains(first) { return "\\" + line }
        // "1990. A good year" and "3) Next" would become ordered lists.
        if let match = line.range(of: "^[0-9]{1,9}[.)]", options: .regularExpression) {
            let digits = line[match].dropLast()
            let delimiter = line[match].last.map(String.init) ?? ""
            return digits + "\\" + delimiter + line[match.upperBound...]
        }
        return line
    }

    /// An inline code span, with enough backticks to contain any in the text.
    static func codeSpan(_ text: String) -> String {
        let fence = String(repeating: "`", count: longestRun(of: "`", in: text) + 1)
        let pad = text.hasPrefix("`") || text.hasSuffix("`") ? " " : ""
        return fence + pad + text + pad + fence
    }

    /// A fenced code block whose fence is longer than any backtick run in `text`, so content
    /// containing Markdown fences cannot close it early.
    static func fenced(_ text: String, language: String? = nil) -> String {
        let fence = String(repeating: "`", count: max(3, longestRun(of: "`", in: text) + 1))
        var body = text
        while body.hasSuffix("\n") { body.removeLast() }
        return fence + (language ?? "") + "\n" + body + "\n" + fence
    }

    /// A GFM table. The first row is the header; ragged rows are padded; returns nil when
    /// there is nothing to show.
    static func table(_ rows: [[String]]) -> String? {
        // A backstop for every importer: spans and ragged rows cannot make a table wider than
        // `ImportLimits.maximumTableColumns`. Importers that can say so add their own notice.
        let limit = ImportLimits.maximumTableColumns
        let width = min(rows.map(\.count).max() ?? 0, limit)
        guard width > 0 else { return nil }
        let padded = rows.map { row -> [String] in
            let cells = row.prefix(limit).map(escapeCell)
            return cells + Array(repeating: "", count: width - cells.count)
        }
        func line(_ cells: [String]) -> String {
            "| " + cells.joined(separator: " | ") + " |"
        }
        var lines = [line(padded[0]), line(Array(repeating: "---", count: width))]
        lines += padded.dropFirst().map(line)
        return lines.joined(separator: "\n")
    }

    /// A pipe inside a cell ends the cell, and a newline ends the table.
    static func escapeCell(_ text: String) -> String {
        var cell = text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        // Already-escaped pipes (from inline rendering) are left as they are.
        cell = cell.replacingOccurrences(of: "(?<!\\\\)\\|", with: "\\\\|", options: .regularExpression)
        return cell.trimmingCharacters(in: .whitespaces)
    }

    /// A link or image destination. Spaces and parentheses are not allowed bare, so such a
    /// destination is percent-encoded; the editor, HTML and Word exporters all decode it.
    static func destination(_ raw: String) -> String {
        var allowed = CharacterSet.urlFragmentAllowed
        allowed.insert(charactersIn: "#%")
        allowed.remove(charactersIn: "()<> ")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }

    private static func longestRun(of character: Character, in text: String) -> Int {
        var longest = 0
        var current = 0
        for scalar in text {
            if scalar == character {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }
}
