import Foundation

/// Converts CSV and TSV files into Markdown.
///
/// The file becomes one GFM table whose first row is the header. Parsing follows RFC 4180 —
/// quoted fields, doubled quotes, delimiters and line breaks inside quotes — and is lenient
/// where real exports are not: rows may be ragged, line endings may be CR, LF or CRLF, and a
/// `.csv` may use semicolons (Excel in most of Europe), tabs or pipes.
public struct DelimitedTextImporter: Sendable {
    public init() {}

    public func convert(
        url: URL,
        options: DocumentImportOptions = .init(),
        progress: ImportProgress.Handler? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> ImportedMarkdown {
        let reporter = ImportReporter(totalUnits: 1, handler: progress, isCancelled: isCancelled)
        try reporter.checkCancellation()
        reporter.report(.reading, index: 0)

        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw ConversionError.unreadableFile(url)
        }
        guard let decoded = StructuredTextDecoding.decode(data) else {
            throw ConversionError.unreadableFile(url)
        }
        let text = decoded.text
        guard !text.allSatisfy(\.isWhitespace) else { throw ConversionError.noTextFound(url) }

        let delimiter: Unicode.Scalar = url.pathExtension.lowercased() == "tsv"
            ? "\t"
            : Self.sniffDelimiter(in: text)

        reporter.report(.extractingText, index: 0)
        let limit = max(options.maximumTableRows, 0)
        let parsed = try Self.parse(text, delimiter: delimiter, maximumDataRows: limit, reporter: reporter)
        guard parsed.rows.contains(where: { $0.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }) else {
            throw ConversionError.noTextFound(url)
        }

        try reporter.checkCancellation()
        reporter.reportAssembling()
        // One row with a million delimiters would otherwise pad every row to a million cells.
        let widest = parsed.rows.map(\.count).max() ?? 0
        let columnsTruncated = widest > ImportLimits.maximumTableColumns
        let table = parsed.rows.map { row in
            row.prefix(ImportLimits.maximumTableColumns).map { [MarkdownRun($0)] }
        }
        let markdown = MarkdownRenderer.render([.table(table)])
        var notices: [String] = []
        if columnsTruncated {
            notices.append("Only the first \(ImportLimits.maximumTableColumns) columns were kept.")
        }
        if parsed.truncated {
            let count = limit.formatted(.number.locale(Locale(identifier: "en_US")))
            notices.append("Only the first \(count) rows were kept.")
        }
        reporter.reportFinished()
        return ImportedMarkdown(markdown: markdown, notices: notices)
    }

    // MARK: - Delimiter

    static let candidateDelimiters: [Unicode.Scalar] = [",", ";", "\t", "|"]

    /// Picks the delimiter that splits the first lines most consistently.
    ///
    /// Each candidate is counted per line, outside quotes. The winner is the one whose most
    /// common count is shared by the most lines; ties go to the larger count, then to the
    /// earlier candidate, so a one-column file stays comma-separated.
    static func sniffDelimiter(in text: String, sampleLines: Int = 20) -> Unicode.Scalar {
        var counts: [[Int]] = Array(repeating: [], count: candidateDelimiters.count)
        var current = Array(repeating: 0, count: candidateDelimiters.count)
        var inQuotes = false
        var lineHasContent = false
        var lines = 0
        var previous: Unicode.Scalar?

        func endLine() {
            if lineHasContent {
                for index in counts.indices { counts[index].append(current[index]) }
                lines += 1
            }
            current = Array(repeating: 0, count: candidateDelimiters.count)
            lineHasContent = false
        }

        for scalar in text.unicodeScalars {
            if lines >= sampleLines { break }
            defer { previous = scalar }
            if scalar == "\"" {
                inQuotes.toggle()
                lineHasContent = true
                continue
            }
            if inQuotes { continue }
            if scalar == "\n" {
                if previous != "\r" { endLine() }
                continue
            }
            if scalar == "\r" {
                endLine()
                continue
            }
            lineHasContent = true
            if let index = candidateDelimiters.firstIndex(of: scalar) { current[index] += 1 }
        }
        if lines < sampleLines { endLine() }

        // A header names every column, so a real delimiter appears in the first line; one that
        // only turns up later is part of the data ("a|b" in a one-column file).
        let firstLineCounts = counts.map { $0.first ?? 0 }

        var best: (index: Int, agreeing: Int, count: Int)?
        for index in candidateDelimiters.indices where firstLineCounts[index] > 0 {
            var frequency: [Int: Int] = [:]
            for count in counts[index] where count > 0 { frequency[count, default: 0] += 1 }
            // The most common non-zero count, preferring the larger count on a tie.
            guard let mode = frequency.max(by: { ($0.value, $0.key) < ($1.value, $1.key) }) else { continue }
            let candidate = (index: index, agreeing: mode.value, count: mode.key)
            if let current = best {
                if (candidate.agreeing, candidate.count) > (current.agreeing, current.count) { best = candidate }
            } else {
                best = candidate
            }
        }
        return best.map { candidateDelimiters[$0.index] } ?? ","
    }

    // MARK: - Parsing

    struct Parsed {
        var rows: [[String]]
        /// True when data rows beyond the limit were dropped.
        var truncated: Bool
    }

    /// RFC 4180 with the usual leniencies. Keeps the header plus `maximumDataRows` rows.
    static func parse(
        _ text: String,
        delimiter: Unicode.Scalar,
        maximumDataRows: Int,
        reporter: ImportReporter? = nil
    ) throws -> Parsed {
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false
        var fieldWasQuoted = false
        var afterClosingQuote = false
        // A line with no characters at all is not a row; `a,` followed by nothing is.
        var rowHasContent = false
        var truncated = false

        let scalars = Array(text.unicodeScalars)
        var index = 0

        func endField() {
            row.append(String(field))
            field = String.UnicodeScalarView()
            fieldWasQuoted = false
            afterClosingQuote = false
        }

        /// Returns false once the row limit is reached.
        func endRow() -> Bool {
            endField()
            defer {
                row = []
                rowHasContent = false
            }
            guard rowHasContent else { return true }
            if rows.count > maximumDataRows {
                truncated = true
                return false
            }
            rows.append(row)
            return true
        }

        while index < scalars.count {
            let scalar = scalars[index]
            index += 1

            if inQuotes {
                if scalar == "\"" {
                    if index < scalars.count, scalars[index] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        inQuotes = false
                        afterClosingQuote = true
                    }
                } else {
                    field.append(scalar)
                }
                continue
            }

            switch scalar {
            case delimiter:
                rowHasContent = true
                endField()
            case "\r", "\n":
                if scalar == "\r", index < scalars.count, scalars[index] == "\n" { index += 1 }
                guard endRow() else { return Parsed(rows: rows, truncated: truncated) }
                if rows.count % 1_000 == 0 { try reporter?.checkCancellation() }
            case "\"" where field.isEmpty && !fieldWasQuoted && !afterClosingQuote:
                inQuotes = true
                fieldWasQuoted = true
                rowHasContent = true
            default:
                // Text after a closing quote, or a quote inside an unquoted field, is kept as-is.
                field.append(scalar)
                rowHasContent = true
            }
        }
        if rowHasContent || !field.isEmpty {
            _ = endRow()
        }
        return Parsed(rows: rows, truncated: truncated)
    }
}
