import XCTest
@testable import MarkpadCore

final class TableParserTests: XCTestCase {
    private let engine = StyleEngine()

    private func table(_ source: String) -> TableStructure? {
        engine.layout(for: source).tables.first
    }

    private func text(_ source: String, _ range: NSRange) -> String {
        (source as NSString).substring(with: range)
    }

    func testParsesHeaderAndBodyCells() throws {
        let source = "| Format | Extension |\n| --- | --- |\n| Word | docx |\n"
        let structure = try XCTUnwrap(table(source))

        XCTAssertEqual(structure.columnCount, 2)
        XCTAssertEqual(structure.rows.count, 2, "the separator line is not a row")
        XCTAssertTrue(structure.rows[0].isHeader)
        XCTAssertFalse(structure.rows[1].isHeader)

        XCTAssertEqual(structure.rows[0].cells.map { text(source, $0.range) }, ["Format", "Extension"])
        XCTAssertEqual(structure.rows[1].cells.map { text(source, $0.range) }, ["Word", "docx"])
    }

    func testCellRangesExcludePaddingSpaces() throws {
        let source = "|   A   |  B |\n| --- | --- |\n| 1 | 2 |\n"
        let structure = try XCTUnwrap(table(source))
        XCTAssertEqual(structure.rows[0].cells.map { text(source, $0.range) }, ["A", "B"])
    }

    func testAlignmentsAreRead() throws {
        let source = "| L | C | R |\n| :--- | :---: | ---: |\n| 1 | 2 | 3 |\n"
        let structure = try XCTUnwrap(table(source))
        XCTAssertEqual(structure.alignments, [.left, .center, .right])
    }

    func testTablesWithoutOuterPipesParse() throws {
        let source = "A | B\n--- | ---\n1 | 2\n"
        let structure = try XCTUnwrap(table(source))
        XCTAssertEqual(structure.columnCount, 2)
        XCTAssertEqual(structure.rows[0].cells.map { text(source, $0.range) }, ["A", "B"])
        XCTAssertEqual(structure.rows[1].cells.map { text(source, $0.range) }, ["1", "2"])
    }

    func testEveryPipeIsRecordedAsADelimiter() throws {
        let source = "| A | B |\n| --- | --- |\n| 1 | 2 |\n"
        let structure = try XCTUnwrap(table(source))
        // Three pipes on each of the three lines.
        XCTAssertEqual(structure.delimiters.count, 9)
        XCTAssertTrue(structure.delimiters.allSatisfy { text(source, $0) == "|" })
    }

    func testSeparatorRowIsIdentified() throws {
        let source = "| A |\n| --- |\n| 1 |\n"
        let structure = try XCTUnwrap(table(source))
        let separator = try XCTUnwrap(structure.separatorRange)
        XCTAssertEqual(text(source, separator), "| --- |")
    }

    func testEscapedPipeStaysInsideTheCell() throws {
        let source = "| A | B |\n| --- | --- |\n| a \\| b | c |\n"
        let structure = try XCTUnwrap(table(source))
        XCTAssertEqual(structure.rows[1].cells.count, 2, "an escaped pipe must not split the cell")
        XCTAssertEqual(text(source, structure.rows[1].cells[0].range), "a \\| b")
    }

    func testRaggedRowKeepsTheCellsItHas() throws {
        let source = "| A | B | C |\n| --- | --- | --- |\n| only |\n"
        let structure = try XCTUnwrap(table(source))
        XCTAssertEqual(structure.columnCount, 3)
        XCTAssertEqual(structure.rows[1].cells.count, 1)
    }

    func testMultiByteCellsGetCorrectRanges() throws {
        let source = "| 名前 | 😀 |\n| --- | --- |\n| é | b |\n"
        let structure = try XCTUnwrap(table(source))
        XCTAssertEqual(structure.rows[0].cells.map { text(source, $0.range) }, ["名前", "😀"])
        XCTAssertEqual(structure.rows[1].cells.map { text(source, $0.range) }, ["é", "b"])
    }

    func testNonTableTextProducesNoStructure() {
        XCTAssertNil(table("Just a paragraph with | a pipe in it.\n"))
        XCTAssertNil(table("| not | followed by a separator |\n"))
    }

    func testAlignmentParserRejectsProse() {
        XCTAssertNil(TableParser.parseAlignments("| some text |"))
        XCTAssertNil(TableParser.parseAlignments("|   |"))
        XCTAssertNotNil(TableParser.parseAlignments("| --- | :-: |"))
    }

    func testTableRangesStayInsideTheSource() throws {
        let source = try Fixtures.sampleMarkdown()
        let length = (source as NSString).length
        for structure in engine.layout(for: source).tables {
            XCTAssertLessThanOrEqual(NSMaxRange(structure.range), length)
            for row in structure.rows {
                for cell in row.cells {
                    XCTAssertLessThanOrEqual(NSMaxRange(cell.range), length)
                }
            }
            for delimiter in structure.delimiters {
                XCTAssertEqual(text(source, delimiter), "|")
            }
        }
    }

    func testSampleDocumentTableIsFound() throws {
        let source = try Fixtures.sampleMarkdown()
        let structure = try XCTUnwrap(engine.layout(for: source).tables.first)
        XCTAssertEqual(structure.columnCount, 3)
        XCTAssertEqual(structure.alignments, [.left, .center, .right])
        XCTAssertEqual(structure.rows.count, 4, "header plus three body rows")
    }
}
