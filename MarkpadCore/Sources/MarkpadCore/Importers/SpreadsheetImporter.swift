import Foundation

/// Converts Excel workbooks into Markdown.
///
/// Every visible sheet with content becomes a level-2 heading and a table spanning its used
/// range: from the first to the last row that holds a value, and from the first to the last
/// such column. The first row is the table's header, as GFM requires one. Values are shown as
/// Excel stores them — numbers keep their stored digits rather than being re-rounded — except
/// that serial numbers in a date format become ISO dates.
public struct SpreadsheetImporter: Sendable {
    public init() {}

    public func convert(
        url: URL,
        options: DocumentImportOptions = .init(),
        progress: ImportProgress.Handler? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> ImportedMarkdown {
        do {
            return try importWorkbook(url: url, options: options, progress: progress, isCancelled: isCancelled)
        } catch {
            throw OfficeImportPackage.conversionError(for: error, url: url)
        }
    }

    private struct Sheet {
        let name: String
        let relationshipID: String?
        let hidden: Bool
    }

    private func importWorkbook(
        url: URL,
        options: DocumentImportOptions,
        progress: ImportProgress.Handler?,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> ImportedMarkdown {
        let zip = try OfficeImportPackage.open(url)
        let workbookPart = try OfficeImportPackage.mainPart(in: zip, fallback: "xl/workbook.xml")
        guard let workbook = try OfficeImportPackage.element(workbookPart, in: zip, url: url),
              workbook.name == "workbook" else {
            throw ConversionError.unreadableFile(url)
        }
        let relationships = try OfficeImportRelationships.load(for: workbookPart, in: zip)
        let uses1904 = workbook.child("workbookPr")?.flag("date1904") ?? false

        let sheets = (workbook.child("sheets")?.children("sheet") ?? []).map { element in
            let state = element.attribute("state") ?? "visible"
            return Sheet(
                name: element.attribute("name") ?? "",
                relationshipID: element.relationshipAttribute("id"),
                hidden: state == "hidden" || state == "veryHidden"
            )
        }
        let visible = sheets.filter { !$0.hidden }
        let hiddenNames = sheets.filter(\.hidden).map(\.name)

        var reporter = ImportReporter(totalUnits: max(visible.count, 1), handler: progress, isCancelled: isCancelled)
        reporter.unitKind = .sheet
        reporter.report(.reading, index: 0)

        var sharedStrings: [String] = []
        if let relationship = relationships.first(ofType: "sharedStrings"),
           let part = relationships.partPath(for: relationship),
           let data = try zip.data(for: part) {
            guard let strings = SpreadsheetSharedStrings.read(data) else { throw ConversionError.unreadableFile(url) }
            sharedStrings = strings
        }
        var dateStyles: [Bool] = []
        if let relationship = relationships.first(ofType: "styles"),
           let part = relationships.partPath(for: relationship),
           let styles = try OfficeImportPackage.element(part, in: zip, url: url) {
            dateStyles = SpreadsheetDates.dateStyles(in: styles)
        }

        var blocks: [MarkdownBlock] = []
        var notices: [String] = []
        if !hiddenNames.isEmpty {
            let names = Self.list(hiddenNames.map { "“\($0)”" })
            notices.append(hiddenNames.count == 1
                ? "The hidden sheet \(names) was left out."
                : "The hidden sheets \(names) were left out.")
        }
        var unreadable: [String] = []

        for (index, sheet) in visible.enumerated() {
            try reporter.checkCancellation()
            reporter.report(.extractingText, index: index)
            // Chart sheets and dialog sheets have no cells.
            guard let id = sheet.relationshipID, let relationship = relationships[id],
                  relationship.hasType("worksheet"),
                  let part = relationships.partPath(for: relationship) else { continue }

            try autoreleasepool {
                guard let data = try zip.data(for: part) else {
                    unreadable.append(sheet.name)
                    return
                }
                let reader = SpreadsheetSheetReader(
                    sharedStrings: sharedStrings,
                    dateStyles: dateStyles,
                    uses1904: uses1904,
                    maximumDataRows: max(options.maximumTableRows, 0),
                    isCancelled: isCancelled
                )
                guard let table = try reader.read(data) else {
                    unreadable.append(sheet.name)
                    return
                }
                guard !table.rows.isEmpty else { return }
                blocks.append(.heading(level: 2, [MarkdownRun(sheet.name)]))
                blocks.append(.table(table.rows.map { $0.map { $0.isEmpty ? [] : [MarkdownRun($0)] } }))
                if table.truncated {
                    let count = Self.count(options.maximumTableRows)
                    notices.append("Sheet “\(sheet.name)” was shortened to its first \(count) \(options.maximumTableRows == 1 ? "row" : "rows").")
                }
                if table.columnsTruncated {
                    notices.append("Sheet “\(sheet.name)” was cut to its first \(ImportLimits.maximumTableColumns) columns with content.")
                }
            }
        }

        if !unreadable.isEmpty {
            let names = Self.list(unreadable.map { "“\($0)”" })
            notices.append(unreadable.count == 1
                ? "Sheet \(names) couldn't be read and was left out."
                : "Sheets \(names) couldn't be read and were left out.")
        }

        try reporter.checkCancellation()
        reporter.reportAssembling()
        guard !blocks.isEmpty else { throw ConversionError.noTextFound(url) }
        let markdown = MarkdownRenderer.render(blocks)
        reporter.reportFinished()
        return ImportedMarkdown(markdown: markdown, notices: notices)
    }

    /// “A”, “A and B”, “A, B and C”.
    private static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }

    private static func count(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
