import XCTest
@testable import MarkpadCore

final class ConversionServiceTests: XCTestCase {
    private let service = ConversionService()

    func testMarkdownFileConvertsToEveryOutputFormat() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let source = directory.appendingPathComponent("Notes.md")
            try "# Title\n\nSome **bold** text.".write(to: source, atomically: true, encoding: .utf8)

            for format in [ConversionFormat.html, .plainText, .word] {
                let result = try service.convert(fileAt: source, to: format)
                XCTAssertEqual(result.suggestedFilename, "Notes.\(format.fileExtension)")
                XCTAssertFalse(result.data.isEmpty, "\(format) produced no data")
            }
        }
    }

    func testInputDetectionCoversSupportedTypes() {
        XCTAssertEqual(ConversionInput.detect(for: URL(fileURLWithPath: "/a/b.md")), .markdown)
        XCTAssertEqual(ConversionInput.detect(for: URL(fileURLWithPath: "/a/b.markdown")), .markdown)
        XCTAssertEqual(ConversionInput.detect(for: URL(fileURLWithPath: "/a/b.pdf")), .pdf)
        XCTAssertEqual(ConversionInput.detect(for: URL(fileURLWithPath: "/a/b.PNG")), .image)
        XCTAssertEqual(ConversionInput.detect(for: URL(fileURLWithPath: "/a/b.heic")), .image)
        XCTAssertNil(ConversionInput.detect(for: URL(fileURLWithPath: "/a/b.zip")))
    }

    func testUnsupportedInputThrows() {
        XCTAssertThrowsError(try service.convert(fileAt: URL(fileURLWithPath: "/a/b.zip"), to: .html))
    }

    func testHTMLExportInlinesLocalImagesAsDataURIs() throws {
        try Fixtures.withTemporaryDirectory { directory in
            try TestImages.writePNG(to: directory.appendingPathComponent("photo.png"), width: 10, height: 10)
            let source = directory.appendingPathComponent("Doc.md")
            try "![shot](photo.png)".write(to: source, atomically: true, encoding: .utf8)

            let html = try XCTUnwrap(service.convert(fileAt: source, to: .html).text)
            // A standalone file cannot reach sibling images, so they must travel with it.
            XCTAssertTrue(html.contains("src=\"data:image/png;base64,"), String(html.prefix(400)))
            XCTAssertFalse(html.contains("src=\"photo.png\""))
        }
    }

    func testRemoteImagesAreLeftAsReferences() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let source = directory.appendingPathComponent("Doc.md")
            try "![remote](https://example.com/a.png)".write(to: source, atomically: true, encoding: .utf8)

            let html = try XCTUnwrap(service.convert(fileAt: source, to: .html).text)
            XCTAssertTrue(html.contains("src=\"https://example.com/a.png\""), html)
        }
    }

    func testWordResultHasNoTextRepresentation() throws {
        let result = try service.convert(markdown: "# Hi", to: .word)
        XCTAssertNil(result.text, "binary output should not be offered as text")
        XCTAssertEqual(result.suggestedFilename, "Document.docx")
    }

    func testPDFIsReadAsMarkdown() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("Report.pdf")
            try TestImages.writeTextPDF(to: url, pages: [[
                .init("Annual Report", fontSize: 24, bold: true),
                .init("The opening paragraph of the annual report text.", fontSize: 12)
            ]])

            let markdown = try service.markdown(fromFileAt: url)
            XCTAssertTrue(markdown.contains("Annual Report"), markdown)

            // And the same file can go straight to Word in one step.
            let word = try service.convert(fileAt: url, to: .word)
            XCTAssertEqual(word.suggestedFilename, "Report.docx")
            let inspector = try DocxInspector(data: word.data)
            try inspector.validate()
            XCTAssertTrue(inspector.documentText().contains("Annual Report"))
        }
    }

    func testAvailableOutputsMatchInputKind() {
        XCTAssertFalse(ConversionInput.markdown.availableOutputs.contains(.markdown))
        XCTAssertTrue(ConversionInput.pdf.availableOutputs.contains(.markdown))
        XCTAssertTrue(ConversionInput.image.availableOutputs.contains(.word))
    }
}
