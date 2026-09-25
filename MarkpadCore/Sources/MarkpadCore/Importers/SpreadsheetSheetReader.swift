import Foundation

/// Streams one worksheet part into rows of cell text.
///
/// Sheets can hold hundreds of thousands of rows, so the part is read with `XMLParser` rather
/// than built into a tree, and only the rows that will be shown are kept: once a value turns up
/// past the row limit the parse stops, since everything after it would be cut anyway.
final class SpreadsheetSheetReader: NSObject, XMLParserDelegate {
    struct Table: Equatable {
        /// The used range, header first; cells are "" where the sheet has nothing.
        var rows: [[String]]
        var truncated: Bool
        /// Columns beyond `ImportLimits.maximumTableColumns` were left out.
        var columnsTruncated = false
    }

    /// Excel's own limits. A row or column past them is not a real cell, and trusting the
    /// number would overflow the arithmetic below.
    static let maximumRows = 1_048_576
    static let maximumColumns = 16_384

    private let sharedStrings: [String]
    private let dateStyles: [Bool]
    private let uses1904: Bool
    private let maximumDataRows: Int
    private let isCancelled: @Sendable () -> Bool

    init(
        sharedStrings: [String],
        dateStyles: [Bool],
        uses1904: Bool,
        maximumDataRows: Int,
        isCancelled: @escaping @Sendable () -> Bool
    ) {
        self.sharedStrings = sharedStrings
        self.dateStyles = dateStyles
        self.uses1904 = uses1904
        self.maximumDataRows = maximumDataRows
        self.isCancelled = isCancelled
    }

    // Parse state. Rows and columns are 0-based.
    private var cells: [Int: [Int: String]] = [:]
    private var firstRow: Int?
    private var truncated = false
    private var cancelled = false
    private var inSheetData = false
    private var row = -1
    private var nextColumn = 0
    private var rowsSeen = 0
    private var cell: (column: Int, type: String, style: Int)?
    private var value = ""
    private var inlineText = ""
    private var inValue = false
    private var inInlineString = false
    private var inText = false
    private var phoneticDepth = 0
    private weak var parser: XMLParser?

    /// The sheet's used range, or nil when the part is not well-formed XML.
    /// Throws `ConversionError.cancelled` when cancelled mid-sheet.
    func read(_ data: Data) throws -> Table? {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        self.parser = parser
        let finished = parser.parse()
        if cancelled { throw ConversionError.cancelled }
        // Stopping early at the row limit reports as a failed parse; that is not damage.
        guard finished || truncated else { return nil }
        return table()
    }

    private func table() -> Table {
        guard let firstRow else { return Table(rows: [], truncated: truncated) }
        let kept = cells.filter { $0.key - firstRow <= maximumDataRows }
        if kept.count < cells.count { truncated = true }
        guard let lastRow = kept.keys.max() else { return Table(rows: [], truncated: truncated) }
        let used = Set(kept.values.flatMap(\.keys))
        guard let firstColumn = used.min(), let lastColumn = used.max() else {
            return Table(rows: [], truncated: truncated)
        }
        // The used range, gaps included — unless it is wider than a table can be, when only
        // columns holding something are kept, up to the limit.
        var columns = Array(firstColumn...lastColumn)
        var columnsTruncated = false
        if columns.count > ImportLimits.maximumTableColumns {
            columns = used.sorted()
            if columns.count > ImportLimits.maximumTableColumns {
                columns = Array(columns.prefix(ImportLimits.maximumTableColumns))
                columnsTruncated = true
            }
        }
        let rows = (firstRow...lastRow).map { index -> [String] in
            let values = kept[index] ?? [:]
            return columns.map { values[$0] ?? "" }
        }
        return Table(rows: rows, truncated: truncated, columnsTruncated: columnsTruncated)
    }

    // MARK: - XMLParserDelegate

    private static func localName(_ qualified: String) -> Substring {
        guard let colon = qualified.firstIndex(of: ":") else { return Substring(qualified) }
        return qualified[qualified.index(after: colon)...]
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        let name = Self.localName(elementName)
        if name == "sheetData" { inSheetData = true; return }
        guard inSheetData else { return }
        switch name {
        case "row":
            rowsSeen += 1
            if rowsSeen % 1000 == 0, isCancelled() {
                cancelled = true
                parser.abortParsing()
                return
            }
            row = attributes["r"].flatMap(Int.init).map { min(max($0, 0), Self.maximumRows) - 1 }
                ?? min(row + 1, Self.maximumRows)
            nextColumn = 0
        case "c":
            var column = nextColumn
            if let reference = attributes["r"], let parsed = Self.cellReference(reference) {
                column = parsed.column
                if parsed.row != row, parsed.row >= 0 { row = parsed.row }
            }
            nextColumn = min(column, Self.maximumColumns) + 1
            cell = (column, attributes["t"] ?? "n", attributes["s"].flatMap(Int.init) ?? 0)
            value = ""
            inlineText = ""
        case "v":
            inValue = cell != nil
        case "is":
            inInlineString = cell != nil
        case "rPh":
            phoneticDepth += 1
        case "t":
            inText = inInlineString && phoneticDepth == 0
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let name = Self.localName(elementName)
        switch name {
        case "sheetData":
            inSheetData = false
        case "v":
            inValue = false
        case "is":
            inInlineString = false
        case "rPh":
            phoneticDepth = max(0, phoneticDepth - 1)
        case "t":
            inText = false
        case "c":
            guard let current = cell else { return }
            cell = nil
            let text = display(type: current.type, style: current.style)
            guard !text.isEmpty else { return }
            store(text, row: row, column: current.column, parser: parser)
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inValue {
            value += string
        } else if inText {
            inlineText += string
        }
    }

    private func store(_ text: String, row: Int, column: Int, parser: XMLParser) {
        guard row >= 0, column >= 0, row < Self.maximumRows, column < Self.maximumColumns else { return }
        let first = min(firstRow ?? row, row)
        firstRow = first
        if row - first > maximumDataRows {
            truncated = true
            parser.abortParsing()
            return
        }
        storedCells += 1
        // Rows are capped, but a row can hold 16,384 cells; a sheet past this many is cut
        // rather than held in memory whole.
        if storedCells > Self.maximumCells {
            truncated = true
            parser.abortParsing()
            return
        }
        cells[row, default: [:]][column] = text
    }

    static let maximumCells = 1_000_000
    private var storedCells = 0

    /// A cell's value as the reader should see it.
    private func display(type: String, style: Int) -> String {
        switch type {
        case "s":
            guard let index = Int(value.trimmingCharacters(in: .whitespaces)),
                  sharedStrings.indices.contains(index) else { return "" }
            return sharedStrings[index]
        case "inlineStr":
            return inlineText
        case "b":
            switch value.trimmingCharacters(in: .whitespaces) {
            case "1": return "TRUE"
            case "0": return "FALSE"
            default: return value
            }
        case "e", "str", "d":
            return value
        default:
            let stored = value.trimmingCharacters(in: .whitespaces)
            if dateStyles.indices.contains(style), dateStyles[style],
               let serial = Double(stored),
               let date = SpreadsheetDates.string(fromSerial: serial, uses1904: uses1904) {
                return date
            }
            return stored
        }
    }

    /// `C12` → row 11, column 2.
    static func cellReference(_ reference: String) -> (row: Int, column: Int)? {
        var column = 0
        var letters = 0
        var digits = ""
        for character in reference.uppercased() {
            if let ascii = character.asciiValue, character >= "A", character <= "Z", digits.isEmpty {
                column = column * 26 + Int(ascii - 64)
                letters += 1
                guard letters <= 3 else { return nil }
            } else if character.isASCII, character.isNumber {
                digits.append(character)
            } else if character == "$" {
                continue
            } else {
                return nil
            }
        }
        guard letters > 0, digits.count <= 9, let row = Int(digits), row > 0 else { return nil }
        return (row - 1, column - 1)
    }
}

/// Reads `xl/sharedStrings.xml`, which holds most of a workbook's text and can be large.
final class SpreadsheetSharedStrings: NSObject, XMLParserDelegate {
    private var strings: [String] = []
    private var current = ""
    private var inItem = false
    private var inText = false
    private var phoneticDepth = 0

    /// The strings in index order, or nil when the part is not well-formed XML.
    static func read(_ data: Data) -> [String]? {
        let reader = SpreadsheetSharedStrings()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        return parser.parse() ? reader.strings : nil
    }

    private static func localName(_ qualified: String) -> Substring {
        guard let colon = qualified.firstIndex(of: ":") else { return Substring(qualified) }
        return qualified[qualified.index(after: colon)...]
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        switch Self.localName(elementName) {
        case "si":
            inItem = true
            current = ""
        case "rPh":
            // Phonetic guides (furigana) repeat the text's reading, not its content.
            phoneticDepth += 1
        case "t":
            inText = inItem && phoneticDepth == 0
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        switch Self.localName(elementName) {
        case "si":
            strings.append(current)
            inItem = false
        case "rPh":
            phoneticDepth = max(0, phoneticDepth - 1)
        case "t":
            inText = false
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { current += string }
    }
}

/// Excel stores dates as day counts; the cell's number format is the only sign that one is.
enum SpreadsheetDates {
    /// Per `cellXfs` index, whether the style's number format shows a date or time.
    static func dateStyles(in styles: OfficeImportElement) -> [Bool] {
        var customFormats: [Int: String] = [:]
        for format in styles.child("numFmts")?.children("numFmt") ?? [] {
            if let id = format.attribute("numFmtId").flatMap(Int.init), let code = format.attribute("formatCode") {
                customFormats[id] = code
            }
        }
        return (styles.child("cellXfs")?.children("xf") ?? []).map { style in
            let id = style.attribute("numFmtId").flatMap(Int.init) ?? 0
            return isDateFormat(id: id, code: customFormats[id])
        }
    }

    /// Built-in formats 14–22 and 45–47 are dates and times; any other format is one when its
    /// code has a date or time token outside quoted text and brackets.
    static func isDateFormat(id: Int, code: String?) -> Bool {
        if let code { return codeHasDateTokens(code) }
        return (14...22).contains(id) || (45...47).contains(id)
    }

    static func codeHasDateTokens(_ code: String) -> Bool {
        var characters = code.makeIterator()
        while let character = characters.next() {
            switch character {
            case "\"":
                while let inner = characters.next(), inner != "\"" {}
            case "[":
                while let inner = characters.next(), inner != "]" {}
            case "\\", "_", "*":
                // An escaped literal, a space the width of the next character, or a fill.
                _ = characters.next()
            case ";":
                // Only the first section — the one positive numbers use — decides.
                return false
            default:
                if "dmyhsDMYHS".contains(character) { return true }
            }
        }
        return false
    }

    /// `yyyy-MM-dd`, with ` HH:mm` (and `:ss` when there are seconds) for a time of day, or
    /// just the time for a serial below one day. Nil for serials that are not dates.
    static func string(fromSerial serial: Double, uses1904: Bool) -> String? {
        guard serial.isFinite, serial >= 0, serial < 2_958_466 else { return nil }   // up to 9999-12-31
        var days = Int(serial.rounded(.down))
        var seconds = Int(((serial - Double(days)) * 86_400).rounded())
        if seconds >= 86_400 {
            days += 1
            seconds -= 86_400
        }
        let time = String(format: "%02d:%02d", seconds / 3600, seconds % 3600 / 60)
            + (seconds % 60 == 0 ? "" : String(format: ":%02d", seconds % 60))

        if days == 0, !uses1904 {
            // Day 0 of the 1900 system is the non-date "January 0"; only a time makes sense.
            return seconds > 0 ? time : nil
        }
        if days == 0, uses1904, seconds > 0 { return time }

        let date: String
        if uses1904 {
            date = civilDate(daysSinceUnixEpoch: days - 24_107)          // 1904-01-01
        } else if days == 60 {
            // Excel keeps Lotus 1-2-3's leap day that 1900 did not have.
            date = "1900-02-29"
        } else if days < 60 {
            date = civilDate(daysSinceUnixEpoch: days - 25_568)          // 1899-12-31 + days
        } else {
            date = civilDate(daysSinceUnixEpoch: days - 25_569)          // 1899-12-30 + days
        }
        return seconds > 0 ? date + " " + time : date
    }

    /// Proleptic Gregorian `yyyy-MM-dd` for a day count from 1970-01-01.
    private static func civilDate(daysSinceUnixEpoch: Int) -> String {
        let z = daysSinceUnixEpoch + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthPart = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthPart + 2) / 5 + 1
        let month = monthPart < 10 ? monthPart + 3 : monthPart - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
