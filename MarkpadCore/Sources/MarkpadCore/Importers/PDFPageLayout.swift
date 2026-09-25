import AppKit
import CoreGraphics
import Foundation
import PDFKit

/// A PDF page's text laid out by position: words, rows and columns, rebuilt from where each
/// character sits on the page.
///
/// A PDF stores glyphs at coordinates, not paragraphs or tables. Reading its text in order
/// loses exactly what makes a document readable as Markdown — which lines sit side by side,
/// which line up in columns, where a gap separates one block from the next — so this works
/// from the geometry instead.
struct PDFPageLayout {
    struct Word {
        var text: String
        var frame: CGRect
        var fontSize: Double
        var boldCharacters: Int
    }

    /// Words sharing a baseline, left to right.
    struct Row {
        var words: [Word]

        var frame: CGRect { words.map(\.frame).reduce(CGRect.null) { $0.union($1) } }
        var text: String { words.map(\.text).joined(separator: " ") }

        /// The size covering the most characters; a drop cap or marker does not decide it.
        var fontSize: Double {
            var weights: [Double: Int] = [:]
            for word in words { weights[word.fontSize, default: 0] += word.text.count }
            return weights.max { $0.value < $1.value }?.key ?? 0
        }

        var isBold: Bool {
            let bold = words.reduce(0) { $0 + $1.boldCharacters }
            let total = words.reduce(0) { $0 + $1.text.count }
            return total > 0 && bold * 2 > total
        }

        /// Runs of words separated by a gap wider than normal word spacing: side-by-side text
        /// or table cells.
        var segments: [Row] {
            var result: [Row] = []
            for word in words {
                if let last = result.last?.words.last,
                   word.frame.minX - last.frame.maxX <= PDFPageLayout.columnGap(for: max(word.fontSize, last.fontSize)) {
                    result[result.count - 1].words.append(word)
                } else {
                    result.append(Row(words: [word]))
                }
            }
            return result
        }
    }

    let rows: [Row]
    let pageBounds: CGRect

    /// Horizontal gap above which two words belong to different blocks rather than one line.
    /// Word spacing, even in loosely justified text, stays well under this.
    static func columnGap(for fontSize: Double) -> Double { max(1.2 * fontSize, 10) }

    // MARK: - Reading a page

    init?(page: PDFPage) {
        guard let string = page.string as NSString?, string.length > 0,
              let attributed = page.attributedString, attributed.length == string.length else {
            return nil
        }
        pageBounds = page.bounds(for: .mediaBox)

        var words: [Word] = []
        var current: Word?
        func finish() {
            if let word = current, !word.text.isEmpty { words.append(word) }
            current = nil
        }

        for index in 0..<string.length {
            let character = string.substring(with: NSRange(location: index, length: 1))
            // Any whitespace, a no-break space included, ends a word.
            if character.rangeOfCharacter(from: .whitespacesAndNewlines) != nil || character == "\u{A0}" {
                finish()
                continue
            }
            // A one-character selection, not `characterBounds(at:)`: on some PDFs the latter is
            // offset from the string by a few characters, which scatters letters across words.
            let frame = page.selection(for: NSRange(location: index, length: 1))?.bounds(for: page) ?? .zero
            let font = attributed.attribute(.font, at: index, effectiveRange: nil) as? NSFont
            let size = Double(font?.pointSize ?? frame.height)
            let bold = font?.fontDescriptor.symbolicTraits.contains(.bold) == true

            if var word = current {
                let sameLine = abs(frame.midY - word.frame.midY) < max(frame.height, word.frame.height) * 0.5
                let gap = frame.minX - word.frame.maxX
                // A glyph with no extent (a combining mark, an invisible character) stays
                // with the word it belongs to, and so does one overlapping the word: the "i"
                // of an "fi" ligature shares the ligature's box.
                let withinWord = frame.minX >= word.frame.minX - size * 0.3
                if frame.isEmpty || (sameLine && withinWord && gap <= size * 0.25) {
                    word.text += character
                    if !frame.isEmpty { word.frame = word.frame.union(frame) }
                    if bold { word.boldCharacters += 1 }
                    current = word
                    continue
                }
                finish()
            }
            guard !frame.isEmpty else { continue }
            current = Word(text: character, frame: frame, fontSize: size, boldCharacters: bold ? 1 : 0)
        }
        finish()
        rows = Self.rows(from: words)
    }

    init(rows: [Row], pageBounds: CGRect) {
        self.rows = rows
        self.pageBounds = pageBounds
    }

    /// Groups words into rows by vertical position, top of the page first.
    private static func rows(from words: [Word]) -> [Row] {
        let sorted = words.sorted { $0.frame.midY > $1.frame.midY }
        var rows: [Row] = []
        for word in sorted {
            if let last = rows.last {
                let reference = last.frame
                let tolerance = min(reference.height, word.frame.height) * 0.5
                if abs(word.frame.midY - reference.midY) <= tolerance {
                    rows[rows.count - 1].words.append(word)
                    continue
                }
            }
            rows.append(Row(words: [word]))
        }
        return rows.map { Row(words: $0.words.sorted { $0.frame.minX < $1.frame.minX }) }
    }

    // MARK: - Margins

    /// Share of the page height, at the top and at the bottom, where running heads live.
    static let marginBand = 0.08

    /// Rows that could be a running head or footer: in the top or bottom band of the page, or
    /// the first or last row of text.
    var marginRowIndices: Set<Int> {
        guard !rows.isEmpty else { return [] }
        var indices: Set<Int> = [0, rows.count - 1]
        let band = pageBounds.height * Self.marginBand
        for (index, row) in rows.enumerated()
        where row.frame.minY >= pageBounds.maxY - band || row.frame.maxY <= pageBounds.minY + band {
            indices.insert(index)
        }
        return indices
    }

    /// Rows inside the top or bottom margin band proper, as opposed to merely first or last.
    var bandRowIndices: Set<Int> {
        let band = pageBounds.height * Self.marginBand
        return Set(rows.indices.filter { index in
            rows[index].frame.minY >= pageBounds.maxY - band || rows[index].frame.maxY <= pageBounds.minY + band
        })
    }

    /// A copy without the given segments of margin rows.
    func removingSegments(where isRunningHead: (String) -> Bool) -> PDFPageLayout {
        let margins = marginRowIndices
        var kept: [Row] = []
        for (index, row) in rows.enumerated() {
            guard margins.contains(index) else { kept.append(row); continue }
            let remaining = row.segments.filter { !isRunningHead($0.text) }
            if !remaining.isEmpty { kept.append(Row(words: remaining.flatMap(\.words))) }
        }
        return PDFPageLayout(rows: kept, pageBounds: pageBounds)
    }

    // MARK: - Blocks

    /// The page as assembler lines: tables, side-by-side columns and paragraph breaks decided
    /// from geometry.
    func lines() -> [TextBlockAssembler.Line] {
        guard !rows.isEmpty else { return [] }
        let pitch = typicalLinePitch
        let bodySize = self.bodySize
        let textRight = rows.map(\.frame.maxX).max() ?? pageBounds.maxX
        let textLeft = rows.map(\.frame.minX).min() ?? pageBounds.minX
        let textWidth = max(textRight - textLeft, 1)

        var output: [TextBlockAssembler.Line] = []
        var previous: Row?
        var index = 0

        /// `previous` nil means the row follows a table or column block, or opens the page. A
        /// page's first line is left to the assembler, so a paragraph running over a page
        /// break stays one paragraph.
        func line(for row: Row, after previous: Row?, pageStart: Bool = false) -> TextBlockAssembler.Line {
            var line = TextBlockAssembler.Line(text: row.text, fontSize: row.fontSize, isBold: row.isBold)
            guard let previous else { line.startsBlock = !pageStart; return line }
            let spacing = previous.frame.minY - row.frame.minY
            // Larger type sits on a larger pitch; a wrapped heading is not a paragraph gap.
            let expected = max(pitch, row.fontSize * 1.25)
            let sizeChanged = abs(previous.fontSize - row.fontSize) > 0.75
            // The previous line stopped well short of the text's right edge: it ended its
            // paragraph, unless it broke a word with a hyphen. Headings are short by nature.
            let isBodySized = previous.fontSize <= bodySize * 1.1
            let endedShort = isBodySized && previous.frame.maxX < textRight - textWidth * 0.15
                && !previous.text.hasSuffix("-")
            line.startsBlock = spacing > expected * 1.35 || sizeChanged || endedShort
            return line
        }

        while index < rows.count {
            let row = rows[index]
            if row.segments.count >= 2, let table = table(startingAt: index, pitch: pitch) {
                switch table.kind {
                case .table(let cells):
                    var tableLine = TextBlockAssembler.Line(text: "")
                    tableLine.table = cells
                    tableLine.startsBlock = true
                    output.append(tableLine)
                case .columns(let columns):
                    // Side-by-side prose (signature blocks, two-column pages): each column in
                    // turn, laid out on its own so its line breaks are judged against its own
                    // width rather than the page's.
                    for column in columns where !column.isEmpty {
                        var columnLines = PDFPageLayout(rows: column, pageBounds: pageBounds).lines()
                        if !columnLines.isEmpty { columnLines[0].startsBlock = true }
                        output += columnLines
                    }
                case .separate(let segments):
                    for segment in segments {
                        var separate = line(for: segment, after: nil)
                        separate.startsBlock = true
                        output.append(separate)
                    }
                }
                previous = nil
                index = table.end
                continue
            }
            output.append(line(for: row, after: previous, pageStart: output.isEmpty))
            previous = row
            index += 1
        }
        return output
    }

    /// The size of most of the page's text.
    private var bodySize: Double {
        var weights: [Double: Int] = [:]
        for row in rows { weights[row.fontSize, default: 0] += row.text.count }
        return weights.max { $0.value < $1.value }?.key ?? 12
    }

    /// The usual distance from one baseline to the next within a paragraph.
    private var typicalLinePitch: Double {
        var distances: [Double] = []
        for (upper, lower) in zip(rows, rows.dropFirst()) {
            let distance = upper.frame.minY - lower.frame.minY
            if distance > 0, distance < upper.frame.height * 3 { distances.append(distance) }
        }
        guard !distances.isEmpty else { return (rows.first?.frame.height ?? 12) * 1.2 }
        return distances.sorted()[distances.count / 2]
    }

    private struct Region {
        enum Kind {
            case table([[String]])
            case columns([[Row]])
            case separate([Row])
        }
        let kind: Kind
        /// Index of the first row after the region.
        let end: Int
    }

    /// Reads rows from `start` that line up in the columns of `rows[start]`.
    ///
    /// Columns are taken from the first row's segments and later rows are cut at those
    /// columns, not at gaps, because cell text can run close to the next column. The region
    /// ends at a row whose text crosses a column boundary — ordinary prose resuming.
    private func table(startingAt start: Int, pitch: Double) -> Region? {
        let first = rows[start].segments
        let tolerance = 4.0
        // The first row's segments bound the region; the columns themselves are settled once
        // every row of it is known.
        var columnStarts = first.map(\.frame.minX)

        // Physical rows in the region.
        var physical: [(row: Row, cells: [[Word]])] = []
        var index = start
        while index < rows.count {
            let row = rows[index]
            if index > start {
                // A large gap below the table, or text that crosses a column boundary, ends it.
                let spacing = rows[index - 1].frame.minY - row.frame.minY
                if spacing > pitch * 3 { break }
                let crosses = row.segments.contains { segment in
                    columnStarts.dropFirst().contains { boundary in
                        segment.frame.minX < boundary - tolerance && segment.frame.maxX > boundary + tolerance
                    }
                }
                if crosses { break }
            }
            physical.append((row, []))
            index += 1
        }

        // Columns start wherever a cell starts in two or more rows. Two close columns — say
        // "Acknowledge" and "Initial Response" — can sit nearer than the gap that splits a
        // header row, but their cells below still start at the same places.
        var clusters: [(x: Double, rows: Int)] = []
        for entry in physical {
            for segment in entry.row.segments {
                let x = segment.frame.minX
                if let match = clusters.firstIndex(where: { abs($0.x - x) <= tolerance }) {
                    clusters[match].rows += 1
                } else {
                    clusters.append((x, 1))
                }
            }
        }
        // A boundary that falls on an ordinary word space in any row is not a column: text
        // after a checkbox, say, can start at the same place in two rows by coincidence.
        func isColumnBoundary(_ x: Double) -> Bool {
            for entry in physical {
                let words = entry.row.words
                for (left, right) in zip(words, words.dropFirst())
                where left.frame.minX < x - tolerance && right.frame.minX >= x - tolerance && right.frame.minX <= x + tolerance {
                    // Only a word space disqualifies it; close columns still have a clear gap.
                    if right.frame.minX - left.frame.maxX < max(left.fontSize, right.fontSize) * 0.5 { return false }
                }
                if words.contains(where: { $0.frame.minX < x - tolerance && $0.frame.maxX > x + tolerance }) { return false }
            }
            return true
        }
        for cluster in clusters where cluster.rows >= 2
            && !columnStarts.contains(where: { abs($0 - cluster.x) <= tolerance })
            && isColumnBoundary(cluster.x) {
            columnStarts.append(cluster.x)
        }
        columnStarts.sort()

        func column(of word: Word) -> Int {
            columnStarts.lastIndex { $0 <= word.frame.minX + tolerance } ?? 0
        }
        for position in physical.indices {
            var cells = Array(repeating: [Word](), count: columnStarts.count)
            for word in physical[position].row.words { cells[column(of: word)].append(word) }
            physical[position].cells = cells
        }

        // One row of side-by-side text is not a table: a footer beside a page number, say.
        guard physical.count >= 2 else {
            return Region(kind: .separate(first), end: start + 1)
        }

        // Two wide columns of running text — many rows, lines filling their column — are a
        // two-column page layout, not a table. A short two-column table (a list of targets,
        // a signature block) stays a table.
        let widths = zip(columnStarts, columnStarts.dropFirst().map { $0 } + [rows.map(\.frame.maxX).max() ?? pageBounds.maxX])
            .map { $1 - $0 }
        let textWidth = (rows.map(\.frame.maxX).max() ?? pageBounds.maxX) - (rows.map(\.frame.minX).min() ?? pageBounds.minX)
        func fill(_ column: Int) -> Double {
            let spans = physical.compactMap { entry -> Double? in
                guard let first = entry.cells[column].first, let last = entry.cells[column].last else { return nil }
                return (last.frame.maxX - first.frame.minX) / max(widths[column], 1)
            }
            return spans.isEmpty ? 0 : spans.reduce(0, +) / Double(spans.count)
        }
        if columnStarts.count == 2, widths.allSatisfy({ $0 > textWidth * 0.35 }),
           physical.count >= 8, fill(0) > 0.7, fill(1) > 0.7 {
            let columns = (0..<2).map { column in
                physical.compactMap { entry -> Row? in
                    entry.cells[column].isEmpty ? nil : Row(words: entry.cells[column])
                }
            }
            return Region(kind: .columns(columns), end: index)
        }

        // Logical rows: a cell that wraps continues at the table's tightest line spacing; the
        // next row starts after extra space. Measured within the table, not the page — a
        // page of padded tables would otherwise make padding look normal. A table drawn with
        // no extra space keeps each line as its own row, which reads worse but loses nothing.
        // The tightest spacing in the table is a wrapped line — unless no cell wraps, when it
        // is the row spacing itself; capping it at an ordinary line height for the type size
        // tells the two apart.
        let distances = zip(physical, physical.dropFirst()).map { $0.row.frame.minY - $1.row.frame.minY }
        let sizes = physical.map(\.row.fontSize).sorted()
        let lineHeight = sizes[sizes.count / 2] * 1.3
        let cellPitch = min(distances.filter { $0 > 0 }.min() ?? pitch, lineHeight)
        var logical: [[String]] = []
        var previousRow: Row?
        for entry in physical {
            let startsRow: Bool
            if let previousRow {
                startsRow = previousRow.frame.minY - entry.row.frame.minY > cellPitch * 1.25
            } else {
                startsRow = true
            }
            let texts = entry.cells.map { $0.map(\.text).joined(separator: " ") }
            if startsRow || logical.isEmpty {
                logical.append(texts)
            } else {
                for (column, text) in texts.enumerated() where !text.isEmpty {
                    let existing = logical[logical.count - 1][column]
                    logical[logical.count - 1][column] = existing.isEmpty ? text : Self.join(existing, text)
                }
            }
            previousRow = entry.row
        }
        return Region(kind: .table(logical), end: index)
    }

    /// Joins a cell's wrapped lines, re-joining a word hyphenated across them.
    private static func join(_ first: String, _ second: String) -> String {
        if first.hasSuffix("-"), !first.hasSuffix("--"), let next = second.first, next.isLowercase {
            return String(first.dropLast()) + second
        }
        return first + " " + second
    }
}
