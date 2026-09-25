import Foundation
import XCTest
@testable import MarkpadCore

final class SpreadsheetImporterTests: XCTestCase {
    private static let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    private static let relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    private struct SheetSpec {
        let name: String
        let part: String
        var state: String?
        let rows: String
    }

    private static func sheetXML(_ rows: String) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><worksheet xmlns=\"\(main)\" xmlns:r=\"\(relationships)\">"
            + "<dimension ref=\"A1\"/><sheetViews><sheetView workbookViewId=\"0\"/></sheetViews>"
            + "<sheetData>\(rows)</sheetData><pageMargins left=\"0.7\" right=\"0.7\" top=\"0.75\" bottom=\"0.75\" header=\"0.3\" footer=\"0.3\"/></worksheet>"
    }

    /// A workbook of `sheets` in that order, with shared strings and styles when given.
    private static func writeWorkbook(
        to url: URL,
        sheets: [SheetSpec],
        sharedStrings: [String]? = nil,
        styles: String? = nil,
        date1904: Bool = false
    ) throws {
        var package = OfficeTestPackage()
        var overrides = ["xl/workbook.xml": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"]
        for sheet in sheets {
            overrides["xl/" + sheet.part] = "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"
        }
        if sharedStrings != nil { overrides["xl/sharedStrings.xml"] = "application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml" }
        if styles != nil { overrides["xl/styles.xml"] = "application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml" }
        package.addPackageBasics(mainPart: "xl/workbook.xml", overrides: overrides)

        let sheetList = sheets.enumerated().map { index, sheet in
            "<sheet name=\"\(sheet.name.replacingOccurrences(of: "&", with: "&amp;"))\" sheetId=\"\(index + 1)\"" + (sheet.state.map { " state=\"\($0)\"" } ?? "")
                + " r:id=\"rIdS\(index)\"/>"
        }.joined()
        package.add("xl/workbook.xml",
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><workbook xmlns=\"\(main)\" xmlns:r=\"\(relationships)\">"
                + "<workbookPr\(date1904 ? " date1904=\"1\"" : "") defaultThemeVersion=\"166925\"/>"
                + "<bookViews><workbookView/></bookViews><sheets>\(sheetList)</sheets><calcPr calcId=\"191029\"/></workbook>")
        var workbookRelationships = sheets.enumerated().map { index, sheet in
            OfficeTestPackage.Relationship(id: "rIdS\(index)", type: "worksheet", target: sheet.part)
        }
        if let sharedStrings {
            workbookRelationships.append(.init(id: "rIdStrings", type: "sharedStrings", target: "sharedStrings.xml"))
            package.add("xl/sharedStrings.xml",
                "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
                    + "<sst xmlns=\"\(main)\" count=\"\(sharedStrings.count)\" uniqueCount=\"\(sharedStrings.count)\">"
                    + sharedStrings.joined() + "</sst>")
        }
        if let styles {
            workbookRelationships.append(.init(id: "rIdStyles", type: "styles", target: "styles.xml"))
            package.add("xl/styles.xml",
                "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><styleSheet xmlns=\"\(main)\">\(styles)</styleSheet>")
        }
        package.addRelationships(for: "xl/workbook.xml", workbookRelationships)
        for sheet in sheets { package.add("xl/" + sheet.part, sheetXML(sheet.rows)) }
        try package.write(to: url)
    }

    /// Styles: 0 General, 1 built-in date (14), 2 custom date, 3 custom number with a quoted
    /// "d", 4 built-in date and time (22), 5 custom time.
    private static let styles = "<numFmts count=\"3\">"
        + "<numFmt numFmtId=\"164\" formatCode=\"[$-409]d\\ mmm\\ yyyy;@\"/>"
        + "<numFmt numFmtId=\"165\" formatCode=\"0.00&quot;d&quot;\"/>"
        + "<numFmt numFmtId=\"166\" formatCode=\"[Red]h:mm:ss\"/>"
        + "</numFmts><fonts count=\"1\"><font/></fonts><fills count=\"1\"><fill/></fills><borders count=\"1\"><border/></borders>"
        + "<cellXfs count=\"6\"><xf numFmtId=\"0\"/><xf numFmtId=\"14\" applyNumberFormat=\"1\"/><xf numFmtId=\"164\" applyNumberFormat=\"1\"/>"
        + "<xf numFmtId=\"165\" applyNumberFormat=\"1\"/><xf numFmtId=\"22\" applyNumberFormat=\"1\"/><xf numFmtId=\"166\" applyNumberFormat=\"1\"/></cellXfs>"

    private static let sharedStrings = [
        "<si><t>Name</t></si>",
        "<si><r><rPr><b/></rPr><t>Bold</t></r><r><t xml:space=\"preserve\"> text</t></r></si>",
        "<si><t>東京</t><rPh sb=\"0\" eb=\"2\"><t>トウキョウ</t></rPh><phoneticPr fontId=\"1\"/></si>",
        "<si><t>Score</t></si>",
        "<si><t>a|b *c*</t></si>"
    ]

    private static func writeMainWorkbook(to url: URL) throws {
        let summary = """
            <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>3</v></c><c r="C1" t="inlineStr"><is><t>Inline</t></is></c></row>
            <row r="2"><c r="A2" t="s"><v>1</v></c><c r="B2"><v>0.1</v></c><c r="C2" t="b"><v>1</v></c></row>
            <row r="3"><c r="A3" t="s"><v>2</v></c><c r="B3" t="e"><v>#DIV/0!</v></c><c r="C3" t="str"><f>LOWER("ABC")</f><v>abc</v></c></row>
            <row r="4"><c r="A4"><v>0.30000000000000004</v></c><c r="B4" s="1"><v>45000</v></c><c r="C4" s="4"><v>45000.5</v></c></row>
            <row r="5"><c r="A5" s="2"><v>1</v></c><c r="B5" s="3"><v>2.5</v></c><c r="C5" s="1"><v>60</v></c></row>
            <row r="6"><c r="A6" t="inlineStr"><is><r><t>le</t></r><r><t>ft</t></r></is></c><c r="C6" t="b"><v>0</v></c></row>
            <row r="8"><c r="A8" s="1"><v>61</v></c><c r="B8" s="5"><v>0.75</v></c><c r="C8" t="s"><v>4</v></c></row>
            <row r="9"><c r="A9" s="1"/><c r="B9" s="2"/></row>
            """
        // Values start at B2, so leading and trailing blank rows and columns are dropped.
        let data = """
            <row r="1"><c r="A1" s="1"/></row>
            <row r="2"><c r="B2" t="inlineStr"><is><t>x</t></is></c><c r="D2" t="inlineStr"><is><t>y</t></is></c></row>
            <row r="3"><c r="B3"><v>1</v></c><c r="D3"><v>2</v></c><c r="F3" s="1"/></row>
            """
        try writeWorkbook(
            to: url,
            sheets: [
                SheetSpec(name: "Summary", part: "worksheets/sheet2.xml", rows: summary),
                SheetSpec(name: "Hidden", part: "worksheets/sheet4.xml", state: "hidden", rows: "<row r=\"1\"><c r=\"A1\"><v>9</v></c></row>"),
                SheetSpec(name: "Data & more", part: "worksheets/sheet1.xml", rows: data),
                SheetSpec(name: "Empty", part: "worksheets/sheet3.xml", rows: "<row r=\"1\"><c r=\"A1\" s=\"1\"/></row>"),
                SheetSpec(name: "Secret", part: "worksheets/sheet5.xml", state: "veryHidden", rows: "<row r=\"1\"><c r=\"A1\"><v>7</v></c></row>")
            ],
            sharedStrings: sharedStrings,
            styles: styles
        )
    }

    // MARK: - Tests

    func testConvertsVisibleSheetsInWorkbookOrder() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("Book.xlsx")
            try Self.writeMainWorkbook(to: url)
            let result = try SpreadsheetImporter().convert(url: url)
            XCTAssertEqual(result.markdown, """
                ## Summary

                | Name | Score | Inline |
                | --- | --- | --- |
                | Bold text | 0.1 | TRUE |
                | 東京 | #DIV/0! | abc |
                | 0.30000000000000004 | 2023-03-15 | 2023-03-15 12:00 |
                | 1900-01-01 | 2.5 | 1900-02-29 |
                | left |  | FALSE |
                |  |  |  |
                | 1900-03-01 | 18:00 | a\\|b \\*c\\* |

                ## Data & more

                | x |  | y |
                | --- | --- | --- |
                | 1 |  | 2 |

                """)
            XCTAssertEqual(result.notices, ["The hidden sheets “Hidden” and “Secret” were left out."])
            XCTAssertEqual(result.assets, [])
        }
    }

    func testDatesInThe1904System() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("Mac.xlsx")
            try Self.writeWorkbook(
                to: url,
                sheets: [SheetSpec(name: "Dates", part: "worksheets/sheet1.xml", rows: """
                    <row r="1"><c r="A1" t="inlineStr"><is><t>When</t></is></c></row>
                    <row r="2"><c r="A2" s="1"><v>0</v></c></row>
                    <row r="3"><c r="A3" s="1"><v>43538</v></c></row>
                    <row r="4"><c r="A4" s="4"><v>1.25</v></c></row>
                    <row r="5"><c r="A5" s="4"><v>1.0000115740740741</v></c></row>
                    """)],
                styles: Self.styles,
                date1904: true
            )
            let result = try SpreadsheetImporter().convert(url: url)
            XCTAssertEqual(result.markdown, """
                ## Dates

                | When |
                | --- |
                | 1904-01-01 |
                | 2023-03-15 |
                | 1904-01-02 06:00 |
                | 1904-01-02 00:00:01 |

                """)
        }
    }

    func testDateFormatDetection() {
        XCTAssertTrue(SpreadsheetDates.isDateFormat(id: 14, code: nil))
        XCTAssertTrue(SpreadsheetDates.isDateFormat(id: 47, code: nil))
        XCTAssertFalse(SpreadsheetDates.isDateFormat(id: 2, code: nil))
        XCTAssertTrue(SpreadsheetDates.isDateFormat(id: 170, code: "dd/mm/yyyy"))
        XCTAssertTrue(SpreadsheetDates.isDateFormat(id: 170, code: "[$-F800]dddd\\,\\ mmmm\\ dd\\,\\ yyyy"))
        XCTAssertFalse(SpreadsheetDates.isDateFormat(id: 170, code: "#,##0.00\" days\";[Red]-#,##0.00"))
        XCTAssertFalse(SpreadsheetDates.isDateFormat(id: 170, code: "[Blue]0.0_);\\(0.0\\)"))
        XCTAssertFalse(SpreadsheetDates.isDateFormat(id: 170, code: "General"))
        XCTAssertFalse(SpreadsheetDates.isDateFormat(id: 170, code: "0\\d"))
    }

    func testTruncatesSheetsPastTheRowLimit() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("Big.xlsx")
            let rows = (1...6).map { "<row r=\"\($0)\"><c r=\"A\($0)\"><v>\($0 * 10)</v></c></row>" }.joined()
            try Self.writeWorkbook(to: url, sheets: [
                SheetSpec(name: "Big", part: "worksheets/sheet1.xml", rows: rows),
                SheetSpec(name: "Small", part: "worksheets/sheet2.xml", rows: "<row r=\"3\"><c r=\"B3\"><v>1</v></c></row><row r=\"4\"><c r=\"B4\"><v>2</v></c></row>")
            ])
            let result = try SpreadsheetImporter().convert(url: url, options: .init(maximumTableRows: 2))
            XCTAssertEqual(result.markdown, """
                ## Big

                | 10 |
                | --- |
                | 20 |
                | 30 |

                ## Small

                | 1 |
                | --- |
                | 2 |

                """)
            XCTAssertEqual(result.notices, ["Sheet “Big” was shortened to its first 2 rows."])
        }
    }

    func testReportsProgressPerSheetAndCancels() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("Book.xlsx")
            try Self.writeMainWorkbook(to: url)
            let log = ProgressLog()
            _ = try SpreadsheetImporter().convert(url: url, progress: log.handler)
            XCTAssertEqual(log.pageEvents.map(\.unit), [1, 2, 3])
            XCTAssertTrue(log.all.allSatisfy { $0.unitKind == .sheet && $0.totalUnits == 3 })
            XCTAssertEqual(log.all.last?.fractionCompleted, 1)

            XCTAssertThrowsError(try SpreadsheetImporter().convert(url: url, isCancelled: { true })) { error in
                guard case ConversionError.cancelled = error else { return XCTFail("\(error)") }
            }
        }
    }

    /// A long sheet is checked for cancellation while it is being read, not only between sheets.
    func testCancelsWithinALongSheet() throws {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var calls = 0
            func next() -> Int { lock.lock(); defer { lock.unlock() }; calls += 1; return calls }
        }
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("Long.xlsx")
            let rows = (1...2500).map { "<row r=\"\($0)\"><c r=\"A\($0)\"><v>\($0)</v></c></row>" }.joined()
            try Self.writeWorkbook(to: url, sheets: [SheetSpec(name: "Long", part: "worksheets/sheet1.xml", rows: rows)])
            let counter = Counter()
            // The first check is the one before the sheet; the second is inside it.
            XCTAssertThrowsError(try SpreadsheetImporter().convert(url: url, isCancelled: { counter.next() >= 2 })) { error in
                guard case ConversionError.cancelled = error else { return XCTFail("\(error)") }
            }
        }
    }

    func testWorkbookWithOnlyEmptySheetsHasNoText() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("Blank.xlsx")
            try Self.writeWorkbook(to: url, sheets: [SheetSpec(name: "Sheet1", part: "worksheets/sheet1.xml", rows: "")])
            XCTAssertThrowsError(try SpreadsheetImporter().convert(url: url)) { error in
                guard case ConversionError.noTextFound = error else { return XCTFail("\(error)") }
            }
        }
    }

    func testRejectsPasswordProtectedAndDamagedFiles() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let locked = directory.appendingPathComponent("Locked.xlsx")
            var data = Data(ZipReader.compoundFileSignature)
            data.append(Data(count: 1024))
            try data.write(to: locked)
            XCTAssertThrowsError(try SpreadsheetImporter().convert(url: locked)) { error in
                guard case ConversionError.passwordProtected = error else { return XCTFail("\(error)") }
            }

            let garbage = directory.appendingPathComponent("Garbage.xlsx")
            try Data("PK but not really a workbook".utf8).write(to: garbage)
            XCTAssertThrowsError(try SpreadsheetImporter().convert(url: garbage)) { error in
                guard case ConversionError.unreadableFile = error else { return XCTFail("\(error)") }
            }

            // A workbook whose sheet XML is damaged: the sheet is reported, and with nothing
            // else to show the conversion has no text.
            let damaged = directory.appendingPathComponent("Damaged.xlsx")
            try Self.writeWorkbook(to: damaged, sheets: [
                SheetSpec(name: "Good", part: "worksheets/sheet1.xml", rows: "<row r=\"1\"><c r=\"A1\"><v>1</v></c></row>"),
                SheetSpec(name: "Bad", part: "worksheets/sheet2.xml", rows: "<row r=\"1\"><c r=\"A1\"><v>1</c></row>")
            ])
            let result = try SpreadsheetImporter().convert(url: damaged)
            XCTAssertEqual(result.markdown, "## Good\n\n| 1 |\n| --- |\n")
            XCTAssertEqual(result.notices, ["Sheet “Bad” couldn't be read and was left out."])
        }
    }

    func testCellReferences() {
        XCTAssertEqual(SpreadsheetSheetReader.cellReference("A1").map { [$0.row, $0.column] }, [0, 0])
        XCTAssertEqual(SpreadsheetSheetReader.cellReference("AB12").map { [$0.row, $0.column] }, [11, 27])
        XCTAssertEqual(SpreadsheetSheetReader.cellReference("XFD1048576").map { [$0.row, $0.column] }, [1_048_575, 16_383])
        XCTAssertNil(SpreadsheetSheetReader.cellReference("12"))
        XCTAssertNil(SpreadsheetSheetReader.cellReference("A0"))
    }
}
