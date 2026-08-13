import XCTest
@testable import MarkpadCore

/// Structure inference is pure logic, so it is tested directly rather than through OCR.
final class TextBlockAssemblerTests: XCTestCase {
    private func line(_ text: String, size: Double? = nil, bold: Bool = false) -> TextBlockAssembler.Line {
        TextBlockAssembler.Line(text: text, fontSize: size, isBold: bold)
    }

    func testWrappedLinesJoinIntoOneParagraph() {
        let markdown = TextBlockAssembler.markdown(from: [
            line("This sentence continues"),
            line("onto the following line."),
            line(""),
            line("A separate paragraph.")
        ])
        XCTAssertEqual(markdown, "This sentence continues onto the following line.\n\nA separate paragraph.\n")
    }

    func testHyphenatedWordIsRejoined() {
        let markdown = TextBlockAssembler.markdown(from: [
            line("The conver-"),
            line("sion works.")
        ])
        XCTAssertEqual(markdown, "The conversion works.\n")
    }

    func testSentenceEndStartsANewParagraphWhenNextLineIsCapitalised() {
        let markdown = TextBlockAssembler.markdown(from: [
            line("First thought ends here."),
            line("Second thought begins.")
        ])
        XCTAssertEqual(markdown, "First thought ends here.\n\nSecond thought begins.\n")
    }

    func testHeadingsComeFromRelativeFontSize() {
        let markdown = TextBlockAssembler.markdown(from: [
            line("Document Title", size: 24),
            line("Body text that dominates the character count of this document.", size: 12),
            line("More body text to establish the baseline size for comparison.", size: 12),
            line("A Section", size: 18),
            line("Further body text follows the section heading here.", size: 12)
        ])
        XCTAssertTrue(markdown.contains("# Document Title"), markdown)
        XCTAssertTrue(markdown.contains("## A Section"), markdown)
        XCTAssertFalse(markdown.contains("### "), "only two heading levels are inferred")
    }

    func testHeadingInferenceCanBeDisabled() {
        let markdown = TextBlockAssembler.markdown(from: [
            line("Big Title", size: 30),
            line("Body text here that is much longer than the title line.", size: 12),
            line("Another body line to establish a baseline font size.", size: 12)
        ], options: .init(inferHeadings: false))
        XCTAssertFalse(markdown.contains("#"), markdown)
    }

    func testBulletsAndNumbersBecomeMarkdownLists() {
        let markdown = TextBlockAssembler.markdown(from: [
            line("• First"),
            line("• Second"),
            line(""),
            line("1. Step one"),
            line("2. Step two")
        ])
        XCTAssertTrue(markdown.contains("- First"), markdown)
        XCTAssertTrue(markdown.contains("- Second"), markdown)
        XCTAssertTrue(markdown.contains("1. Step one"), markdown)
        XCTAssertTrue(markdown.contains("2. Step two"), markdown)
    }

    func testMarkdownCharactersInSourceTextAreEscaped() {
        let markdown = TextBlockAssembler.markdown(from: [line("Use 5 * 3 and _underscores_ carefully")])
        XCTAssertTrue(markdown.contains(#"5 \* 3"#), markdown)
        XCTAssertTrue(markdown.contains(#"\_underscores\_"#), markdown)
    }

    func testLineStartingWithHashIsEscapedSoItIsNotAHeading() {
        let markdown = TextBlockAssembler.markdown(from: [line("#1 in the charts")])
        XCTAssertTrue(markdown.hasPrefix("\\#1"), markdown)
    }

    func testEmptyInputProducesEmptyOutput() {
        XCTAssertEqual(TextBlockAssembler.markdown(from: []).trimmingCharacters(in: .whitespacesAndNewlines), "")
    }
}

final class PDFImporterTests: XCTestCase {
    private let importer = PDFImporter()

    func testExtractsTextLayerWithHeadings() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("doc.pdf")
            try TestImages.writeTextPDF(to: url, pages: [[
                .init("Quarterly Report", fontSize: 24, bold: true),
                .init("This is the opening paragraph of the report and it", fontSize: 12),
                .init("wraps onto a second line of body text.", fontSize: 12),
                .init("Findings", fontSize: 17, bold: true),
                .init("The first finding is described in this sentence.", fontSize: 12)
            ]])

            let markdown = try importer.convert(url: url)
            XCTAssertTrue(markdown.contains("# Quarterly Report"), markdown)
            XCTAssertTrue(markdown.contains("## Findings"), markdown)
            XCTAssertTrue(
                markdown.contains("wraps onto a second line"),
                "wrapped lines should be joined: \(markdown)"
            )
        }
    }

    func testMultiPageDocumentDropsRepeatingRunningHeads() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("book.pdf")
            let pages = (1...4).map { index in
                [
                    TestImages.PDFLine("Markpad Handbook", fontSize: 9),
                    TestImages.PDFLine("Body content for page \(index) of the handbook.", fontSize: 12),
                    TestImages.PDFLine("Page \(index)", fontSize: 9)
                ]
            }
            try TestImages.writeTextPDF(to: url, pages: pages)

            let markdown = try importer.convert(url: url)
            XCTAssertFalse(markdown.contains("Markpad Handbook"), "running head should be removed: \(markdown)")
            XCTAssertFalse(markdown.contains("Page 2"), "page numbers should be removed: \(markdown)")
            XCTAssertTrue(markdown.contains("Body content for page 2"), markdown)
        }
    }

    func testUnreadableFileThrows() {
        let url = URL(fileURLWithPath: "/tmp/markpad-does-not-exist.pdf")
        XCTAssertThrowsError(try importer.convert(url: url))
    }

    /// A scanned page has no text layer, so this exercises the OCR fallback path.
    func testScannedPageFallsBackToTextRecognition() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("scan.pdf")
            try TestImages.writeScannedPDF(to: url, lines: [
                "Scanned Document",
                "The quick brown fox jumps over the lazy dog."
            ])

            let markdown = try importer.convert(url: url)
            // Recognition output varies between OS releases, so assert loosely.
            XCTAssertTrue(
                markdown.lowercased().contains("quick brown fox"),
                "OCR fallback produced: \(markdown)"
            )
        }
    }
}

final class ImageImporterTests: XCTestCase {
    private let importer = ImageImporter()

    func testRecognisesTextFromAnImage() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("note.png")
            try TestImages.writeTextPNG(to: url, lines: [
                "Meeting Notes",
                "Ship the converter this week."
            ])

            let markdown = try importer.convert(url: url)
            XCTAssertTrue(markdown.lowercased().contains("meeting notes"), markdown)
            XCTAssertTrue(markdown.lowercased().contains("ship the converter"), markdown)
        }
    }

    func testImageWithoutTextThrowsRatherThanReturningEmptyOutput() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("blank.png")
            try TestImages.writePNG(to: url, width: 300, height: 200)
            XCTAssertThrowsError(try importer.convert(url: url)) { error in
                guard case ConversionError.noTextFound = error else {
                    return XCTFail("expected noTextFound, got \(error)")
                }
            }
        }
    }

    func testUnreadableImageThrows() {
        XCTAssertThrowsError(try importer.convert(url: URL(fileURLWithPath: "/tmp/markpad-missing.png")))
    }
}
