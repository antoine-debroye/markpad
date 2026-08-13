import Foundation

/// Converts swift-markdown source locations into `NSTextStorage` offsets.
///
/// cmark reports positions as 1-based line numbers with 1-based **UTF-8 byte** columns,
/// while `NSTextStorage` addresses text in UTF-16 units. Any document containing an emoji,
/// an accent or CJK text puts the two out of step, so every conversion goes through here.
public struct SourceIndex: Sendable {
    /// UTF-16 offset where each line begins.
    private let lineStarts: [Int]
    /// Per line, a table mapping a UTF-8 byte offset to a UTF-16 offset within that line.
    /// `nil` for pure ASCII lines, where the two are identical.
    private let byteToUTF16: [[Int]?]
    public let length: Int

    public init(source: String) {
        let text = source as NSString
        let length = text.length
        var lineStarts: [Int] = []
        var maps: [[Int]?] = []

        var index = 0
        while true {
            let lineStart = index
            var lineEnd = index
            while lineEnd < length, text.character(at: lineEnd) != 0x0A { lineEnd += 1 }

            // A CRLF line ending is not part of the line's content.
            var contentEnd = lineEnd
            if contentEnd > lineStart, text.character(at: contentEnd - 1) == 0x0D { contentEnd -= 1 }

            lineStarts.append(lineStart)
            let content = text.substring(with: NSRange(location: lineStart, length: contentEnd - lineStart))
            maps.append(Self.map(for: content))

            if lineEnd >= length { break }
            index = lineEnd + 1
        }

        self.lineStarts = lineStarts
        self.byteToUTF16 = maps
        self.length = length
    }

    /// `nil` when the line is ASCII, where a byte offset is already a UTF-16 offset.
    private static func map(for line: String) -> [Int]? {
        let utf16Count = (line as NSString).length
        if line.utf8.count == utf16Count { return nil }

        var table: [Int] = []
        table.reserveCapacity(line.utf8.count + 1)
        var utf16Offset = 0
        for scalar in line.unicodeScalars {
            let byteCount = UTF8.width(scalar)
            let unitCount = UTF16.width(scalar)
            // Every byte of a multi-byte scalar maps to the scalar's own start.
            for _ in 0..<byteCount { table.append(utf16Offset) }
            utf16Offset += unitCount
        }
        table.append(utf16Offset)
        return table
    }

    /// UTF-16 offset for a 1-based line and 1-based UTF-8 byte column, clamped to the text.
    public func offset(line: Int, column: Int) -> Int {
        guard !lineStarts.isEmpty else { return 0 }
        let lineIndex = min(max(line - 1, 0), lineStarts.count - 1)
        let base = lineStarts[lineIndex]
        let byteOffset = max(column - 1, 0)

        let withinLine: Int
        if let table = byteToUTF16[lineIndex] {
            withinLine = table[min(byteOffset, table.count - 1)]
        } else {
            withinLine = byteOffset
        }
        return min(base + withinLine, length)
    }

    /// UTF-16 range between two source positions.
    public func range(from start: SourcePosition, to end: SourcePosition) -> NSRange? {
        let startOffset = offset(line: start.line, column: start.column)
        let endOffset = offset(line: end.line, column: end.column)
        guard endOffset >= startOffset else { return nil }
        return NSRange(location: startOffset, length: endOffset - startOffset)
    }

    /// Range of the line containing `offset`, excluding its terminator.
    public func lineRange(containing offset: Int) -> NSRange {
        guard !lineStarts.isEmpty else { return NSRange(location: 0, length: 0) }
        var low = 0
        var high = lineStarts.count - 1
        var found = 0
        while low <= high {
            let mid = (low + high) / 2
            if lineStarts[mid] <= offset {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        let start = lineStarts[found]
        let end = found + 1 < lineStarts.count ? lineStarts[found + 1] - 1 : length
        return NSRange(location: start, length: max(end - start, 0))
    }

    public var lineCount: Int { lineStarts.count }

    /// Range covering the whole of `line` (1-based), excluding its terminator.
    public func range(ofLine line: Int) -> NSRange {
        guard line >= 1, line <= lineStarts.count else { return NSRange(location: 0, length: 0) }
        return lineRange(containing: lineStarts[line - 1])
    }
}

/// The subset of a source location this package needs, kept free of the Markdown module so
/// `SourceIndex` can be tested on its own.
public struct SourcePosition: Sendable, Equatable {
    public var line: Int
    public var column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }
}
