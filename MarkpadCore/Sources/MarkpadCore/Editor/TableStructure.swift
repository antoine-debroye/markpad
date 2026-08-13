import Foundation

/// The shape of a Markdown table, expressed as ranges into the source.
///
/// The parser scans the table's own lines rather than relying on the AST for cell positions:
/// the editor needs the exact ranges of the delimiters themselves, not only the content, so
/// it can collapse them and align columns in their place.
public struct TableStructure: Sendable, Equatable {
    public enum Alignment: Sendable, Equatable {
        case left
        case center
        case right
    }

    public struct Cell: Sendable, Equatable {
        /// The cell's text, trimmed of the padding spaces around it.
        public var range: NSRange
        public var column: Int

        public init(range: NSRange, column: Int) {
            self.range = range
            self.column = column
        }
    }

    public struct Row: Sendable, Equatable {
        public var range: NSRange
        public var cells: [Cell]
        public var isHeader: Bool

        public init(range: NSRange, cells: [Cell], isHeader: Bool) {
            self.range = range
            self.cells = cells
            self.isHeader = isHeader
        }
    }

    public var range: NSRange
    public var rows: [Row]
    /// The `|---|---|` line, which is drawn as a rule rather than shown.
    public var separatorRange: NSRange?
    /// Every `|` in the table. Each one becomes the gap that starts the next column.
    public var delimiters: [NSRange]
    public var alignments: [Alignment]

    public var columnCount: Int { alignments.count }

    public func alignment(forColumn column: Int) -> Alignment {
        column < alignments.count ? alignments[column] : .left
    }
}

public enum TableParser {
    /// Reads the table occupying `range` of `source`.
    ///
    /// Returns nil when the text does not look like a table, so a malformed one simply
    /// renders as ordinary text instead of producing a broken grid.
    public static func parse(source: NSString, range: NSRange, index: SourceIndex) -> TableStructure? {
        var lineRanges: [NSRange] = []
        var offset = range.location
        let end = NSMaxRange(range)
        while offset < end, offset < source.length {
            let lineRange = index.lineRange(containing: offset)
            lineRanges.append(lineRange)
            let next = NSMaxRange(lineRange) + 1
            if next <= offset { break }
            offset = next
        }
        guard lineRanges.count >= 2 else { return nil }

        // The second line defines the columns and their alignment.
        let separatorRange = lineRanges[1]
        guard let alignments = parseAlignments(source.substring(with: separatorRange)) else { return nil }

        var rows: [TableStructure.Row] = []
        var delimiters: [NSRange] = []

        for (lineIndex, lineRange) in lineRanges.enumerated() {
            guard lineRange.length > 0 else { continue }
            let pipes = pipePositions(in: source, lineRange: lineRange)
            delimiters.append(contentsOf: pipes)
            guard lineIndex != 1 else { continue }

            let cells = cellRanges(in: source, lineRange: lineRange, pipes: pipes)
            rows.append(TableStructure.Row(
                range: lineRange,
                cells: cells.enumerated().map { TableStructure.Cell(range: $1, column: $0) },
                isHeader: lineIndex == 0
            ))
        }

        guard !rows.isEmpty else { return nil }
        return TableStructure(
            range: range,
            rows: rows,
            separatorRange: separatorRange,
            delimiters: delimiters,
            alignments: alignments
        )
    }

    /// Column alignments from a `| :--- | :---: | ---: |` line, or nil if it is not one.
    static func parseAlignments(_ line: String) -> [TableStructure.Alignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // Only pipes, dashes, colons and spaces may appear.
        guard trimmed.allSatisfy({ $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }) else { return nil }
        guard trimmed.contains("-") else { return nil }

        var body = Substring(trimmed)
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|") { body = body.dropLast() }

        let columns = body.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !columns.isEmpty, columns.allSatisfy({ !$0.isEmpty }) else { return nil }

        return columns.map { column in
            let leading = column.hasPrefix(":")
            let trailing = column.hasSuffix(":")
            if leading && trailing { return .center }
            if trailing { return .right }
            return .left
        }
    }

    /// Positions of the `|` characters that separate cells. A pipe escaped with a backslash
    /// is cell content, not a delimiter.
    static func pipePositions(in source: NSString, lineRange: NSRange) -> [NSRange] {
        var positions: [NSRange] = []
        var index = lineRange.location
        let end = NSMaxRange(lineRange)
        while index < end {
            if source.character(at: index) == UInt16(UnicodeScalar("|").value) {
                let isEscaped = index > lineRange.location
                    && source.character(at: index - 1) == UInt16(UnicodeScalar("\\").value)
                if !isEscaped {
                    positions.append(NSRange(location: index, length: 1))
                }
            }
            index += 1
        }
        return positions
    }

    /// Text between the pipes, trimmed of padding. Leading and trailing pipes are optional
    /// in Markdown, so the segments before the first and after the last are included only
    /// when they hold content.
    static func cellRanges(in source: NSString, lineRange: NSRange, pipes: [NSRange]) -> [NSRange] {
        var boundaries: [Int] = [lineRange.location]
        for pipe in pipes {
            boundaries.append(pipe.location)
            boundaries.append(NSMaxRange(pipe))
        }
        boundaries.append(NSMaxRange(lineRange))

        var cells: [NSRange] = []
        var index = 0
        while index + 1 < boundaries.count {
            let start = boundaries[index]
            let stop = boundaries[index + 1]
            index += 2
            guard stop >= start else { continue }
            let segment = NSRange(location: start, length: stop - start)
            let trimmed = trimming(source: source, range: segment)
            // Skip the empty segments an outer pipe creates at either end of the line.
            let isEdge = start == lineRange.location || stop == NSMaxRange(lineRange)
            if trimmed.length == 0 && isEdge { continue }
            cells.append(trimmed)
        }
        return cells
    }

    private static func trimming(source: NSString, range: NSRange) -> NSRange {
        var start = range.location
        var end = NSMaxRange(range)
        let space = UInt16(UnicodeScalar(" ").value)
        let tab = UInt16(UnicodeScalar("\t").value)
        while start < end, source.character(at: start) == space || source.character(at: start) == tab {
            start += 1
        }
        while end > start,
              source.character(at: end - 1) == space || source.character(at: end - 1) == tab {
            end -= 1
        }
        return NSRange(location: start, length: end - start)
    }
}
