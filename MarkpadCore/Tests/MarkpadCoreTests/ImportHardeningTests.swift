import Foundation
import XCTest
@testable import MarkpadCore

/// Hostile and extreme inputs: each of these once crashed the app, ran without bound, or
/// copied a file it should not have.
final class ImportHardeningTests: XCTestCase {
    private func importDocument(_ url: URL, assets: String? = "out_assets") async throws -> ImportedMarkdown {
        var options = ImportOptions()
        options.document.assetFolderName = assets
        return try await ConversionService().importDocument(at: url, options: options)
    }

    // MARK: Nesting

    func testDeeplyNestedHTMLDoesNotCrash() async throws {
        try await Fixtures.withTemporaryDirectoryAsync { directory in
            let url = directory.appendingPathComponent("deep.html")
            let depth = 20_000
            let html = "<html><body><p>Top</p>" + String(repeating: "<div>", count: depth) + "deep"
                + String(repeating: "</div>", count: depth) + "<p>Bottom</p></body></html>"
            try Data(html.utf8).write(to: url)
            // Converting or refusing are both fine; crashing the process is not.
            if let result = try? await importDocument(url) {
                XCTAssertTrue(result.markdown.contains("Top"), result.markdown)
            }
        }
    }

    func testDeeplyNestedWordDocumentIsRefusedNotCrashed() async throws {
        try await Fixtures.withTemporaryDirectoryAsync { directory in
            var package = OfficeTestPackage()
            package.addPackageBasics(mainPart: "word/document.xml", overrides: [
                "word/document.xml": "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml",
            ])
            let depth = 20_000
            package.add("word/document.xml",
                "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:p>"
                    + String(repeating: "<w:hyperlink>", count: depth) + "<w:r><w:t>x</w:t></w:r>"
                    + String(repeating: "</w:hyperlink>", count: depth) + "</w:p></w:body></w:document>")
            let url = directory.appendingPathComponent("deep.docx")
            try package.write(to: url)
            do {
                _ = try await importDocument(url)
                XCTFail("expected the document to be refused")
            } catch ConversionError.unreadableFile {
                // Expected.
            }
        }
    }

    // MARK: Spreadsheets

    private func writeWorkbook(_ rows: String, to url: URL) throws {
        let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        var package = OfficeTestPackage()
        package.addPackageBasics(mainPart: "xl/workbook.xml", overrides: [
            "xl/workbook.xml": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml",
            "xl/worksheets/sheet1.xml": "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml",
        ])
        package.add("xl/workbook.xml", "<workbook xmlns=\"\(main)\" xmlns:r=\"\(rel)\"><sheets><sheet name=\"S\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>")
        package.addRelationships(for: "xl/workbook.xml", [.init(id: "rId1", type: "worksheet", target: "worksheets/sheet1.xml")])
        package.add("xl/worksheets/sheet1.xml", "<worksheet xmlns=\"\(main)\"><sheetData>\(rows)</sheetData></worksheet>")
        try package.write(to: url)
    }

    func testHugeRowNumbersDoNotOverflow() async throws {
        try await Fixtures.withTemporaryDirectoryAsync { directory in
            let url = directory.appendingPathComponent("rows.xlsx")
            try writeWorkbook("""
                <row r="1"><c r="A1" t="inlineStr"><is><t>ok</t></is></c></row>\
                <row r="9223372036854775807"><c><v>1</v></c></row>\
                <row><c r="A9223372036854775807"><v>2</v></c></row>
                """, to: url)
            let result = try await importDocument(url)
            XCTAssertTrue(result.markdown.contains("ok"), result.markdown)
        }
    }

    func testFarApartCellsStayBounded() async throws {
        try await Fixtures.withTemporaryDirectoryAsync { directory in
            let url = directory.appendingPathComponent("wide.xlsx")
            // Used range A1:XFD5000 (Excel's widest column) from three cells; this once ran for
            // minutes and took gigabytes. A column past XFD is not a real cell and is ignored.
            try writeWorkbook("""
                <row r="1"><c r="A1"><v>1</v></c><c r="XFD1"><v>2</v></c><c r="ZZZ1"><v>9</v></c></row>\
                <row r="5000"><c r="A5000"><v>3</v></c></row>
                """, to: url)
            let start = Date()
            let result = try await importDocument(url)
            XCTAssertLessThan(Date().timeIntervalSince(start), 10)
            let header = result.markdown.split(separator: "\n").dropFirst().first ?? ""
            XCTAssertLessThanOrEqual(header.filter { $0 == "|" }.count, ImportLimits.maximumTableColumns + 1)
            XCTAssertFalse(result.markdown.contains("9"), "beyond Excel's last column")
            XCTAssertTrue(result.markdown.contains("| 1 | 2 |"), "only the columns with content are kept: \(result.markdown.prefix(300))")
        }
    }

    func testVeryWideCSVIsCut() async throws {
        try await Fixtures.withTemporaryDirectoryAsync { directory in
            let url = directory.appendingPathComponent("wide.csv")
            let header = (0..<100_000).map { "c\($0)" }.joined(separator: ",")
            try Data((header + "\n1,2\n").utf8).write(to: url)
            let result = try await importDocument(url)
            let first = result.markdown.split(separator: "\n").first ?? ""
            XCTAssertEqual(first.filter { $0 == "|" }.count, ImportLimits.maximumTableColumns + 1)
            XCTAssertEqual(result.notices, ["Only the first 256 columns were kept."])
        }
    }

    // MARK: Local files and archives

    /// A 1×1 PNG.
    private static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!

    func testPicturesOutsideThePageFolderAreNotCopied() async throws {
        try await Fixtures.withTemporaryDirectoryAsync { directory in
            let photos = directory.appendingPathComponent("Pictures")
            let site = directory.appendingPathComponent("Downloads/site")
            try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: site.appendingPathComponent("img"), withIntermediateDirectories: true)
            try Self.png.write(to: photos.appendingPathComponent("private.png"))
            try Self.png.write(to: site.appendingPathComponent("img/ok.png"))
            // A link inside the folder that points out of it.
            try FileManager.default.createSymbolicLink(
                at: site.appendingPathComponent("img/link.png"),
                withDestinationURL: photos.appendingPathComponent("private.png"))

            let page = site.appendingPathComponent("page.html")
            try Data("""
                <p><img src="../../Pictures/private.png" alt="a">\
                <img src="\(photos.appendingPathComponent("private.png").path)" alt="b">\
                <img src="\(photos.appendingPathComponent("private.png").absoluteString)" alt="c">\
                <img src="img/link.png" alt="d">\
                <img src="img/ok.png" alt="e"></p>
                """.utf8).write(to: page)
            let result = try await importDocument(page)
            XCTAssertEqual(result.assets.map(\.name), ["ok.png"], result.markdown)
            XCTAssertTrue(result.markdown.contains("![e](out_assets/ok.png)"), result.markdown)
            XCTAssertTrue(result.markdown.contains("![a](../../Pictures/private.png)"), "reference kept, file not read")
        }
    }

    func testArchiveExpansionHasAnOverallBudget() throws {
        var writer = ZipWriter()
        let chunk = Data(repeating: 0x41, count: 600)
        try writer.addFile(name: "a.bin", data: chunk)
        try writer.addFile(name: "b.bin", data: chunk)
        let reader = try ZipReader(data: try writer.finalize(), expansionBudget: 1_000)
        XCTAssertEqual(try reader.data(for: "a.bin"), chunk)
        XCTAssertThrowsError(try reader.data(for: "b.bin")) { error in
            XCTAssertEqual(error as? ZipReader.Failure, .tooLarge("b.bin"))
        }
    }

    func testOversizedPicturesAreLeftOut() {
        let collector = AssetCollector(folderName: "x_assets")
        XCTAssertNil(collector.add(Data(count: ImportLimits.maximumPictureBytes + 1), suggestedName: "big.png"))
        XCTAssertNotNil(collector.add(Self.png, suggestedName: "small.png"))
    }

    // MARK: Names

    func testLongNamesStayWithinTheFileSystemLimit() async throws {
        try await Fixtures.withTemporaryDirectoryAsync { directory in
            let stem = String(repeating: "é", count: 120)   // 240 bytes of UTF-8
            for ext in ["csv", "json"] {
                try Data("a,b\n1,2\n".utf8).write(to: directory.appendingPathComponent("\(stem).\(ext)"))
            }
            let plan = BatchPlanner().plan([directory])
            XCTAssertEqual(plan.items.count, 2)
            for item in plan.items {
                XCTAssertLessThanOrEqual(item.output.lastPathComponent.utf8.count, 255)
                XCTAssertLessThanOrEqual(item.assetFolderName.utf8.count, 255)
            }
            let outcomes = await BatchConverter().run(plan.items)
            XCTAssertTrue(outcomes.values.allSatisfy { if case .finished = $0 { return true } else { return false } },
                          "\(outcomes)")
        }
    }
}
