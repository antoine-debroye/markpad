import AppKit
import XCTest
@testable import MarkpadCore

final class DocxExporterTests: XCTestCase {
    private let exporter = DocxExporter()

    private func inspect(_ markdown: String, resourceDirectory: URL? = nil) throws -> DocxInspector {
        let data = try exporter.export(
            markdown: markdown,
            options: .init(resourceDirectory: resourceDirectory)
        )
        let inspector = try DocxInspector(data: data)
        try inspector.validate()
        return inspector
    }

    func testPackageContainsRequiredPartsAndIsValid() throws {
        let inspector = try inspect("# Title\n\nSome text.")
        XCTAssertTrue(inspector.documentText().contains("Title"))
        XCTAssertTrue(inspector.documentText().contains("Some text."))
    }

    func testHeadingsUseOutlineStyles() throws {
        let inspector = try inspect("# One\n\n### Three\n")
        let xml = inspector.text("word/document.xml")
        XCTAssertTrue(xml.contains("<w:pStyle w:val=\"Heading1\"/>"), xml)
        XCTAssertTrue(xml.contains("<w:pStyle w:val=\"Heading3\"/>"), xml)
        // outlineLvl drives Word's navigation pane and generated tables of contents.
        XCTAssertTrue(inspector.text("word/styles.xml").contains("<w:outlineLvl w:val=\"0\"/>"))
    }

    func testInlineFormattingProducesRunProperties() throws {
        let inspector = try inspect("**bold** *italic* ~~struck~~ `code`")
        let xml = inspector.text("word/document.xml")
        XCTAssertTrue(xml.contains("<w:b/>"), xml)
        XCTAssertTrue(xml.contains("<w:i/>"), xml)
        XCTAssertTrue(xml.contains("<w:strike/>"), xml)
        XCTAssertTrue(xml.contains("<w:rStyle w:val=\"InlineCode\"/>"), xml)
    }

    func testHyperlinkIsExternalAndStyled() throws {
        let inspector = try inspect("[Apple](https://www.apple.com)")
        let xml = inspector.text("word/document.xml")
        XCTAssertTrue(xml.contains("<w:hyperlink r:id="), xml)
        XCTAssertTrue(xml.contains("<w:rStyle w:val=\"Hyperlink\"/>"), xml)
        let rels = inspector.text("word/_rels/document.xml.rels")
        XCTAssertTrue(rels.contains("TargetMode=\"External\""), rels)
        XCTAssertTrue(rels.contains("https://www.apple.com"), rels)
    }

    func testAmpersandInLinkIsEscapedInRelationships() throws {
        let inspector = try inspect("[q](https://example.com/?a=1&b=2)")
        let rels = inspector.text("word/_rels/document.xml.rels")
        XCTAssertTrue(rels.contains("a=1&amp;b=2"), rels)
        // Well-formedness is the real assertion; a bare & would break the package.
        XCTAssertNoThrow(try inspector.xml("word/_rels/document.xml.rels"))
    }

    func testConsecutiveOrderedListsRestartNumbering() throws {
        let markdown = """
        1. alpha
        2. beta

        Some separating text.

        1. gamma
        2. delta
        """
        let inspector = try inspect(markdown)
        let numbering = inspector.text("word/numbering.xml")
        let document = inspector.text("word/document.xml")

        // Two ordered lists must map to two distinct numbering instances, each starting at 1.
        XCTAssertTrue(document.contains("<w:numId w:val=\"2\"/>"), document)
        XCTAssertTrue(document.contains("<w:numId w:val=\"3\"/>"), document)
        XCTAssertTrue(numbering.contains("<w:num w:numId=\"2\">"), numbering)
        XCTAssertTrue(numbering.contains("<w:num w:numId=\"3\">"), numbering)
        XCTAssertTrue(numbering.contains("<w:startOverride w:val=\"1\"/>"), numbering)
    }

    func testOrderedListHonoursExplicitStart() throws {
        let inspector = try inspect("5. five\n6. six\n")
        XCTAssertTrue(inspector.text("word/numbering.xml").contains("<w:startOverride w:val=\"5\"/>"))
    }

    func testBulletListsShareOneNumberingInstance() throws {
        let inspector = try inspect("- a\n- b\n\ntext\n\n- c\n")
        let document = inspector.text("word/document.xml")
        XCTAssertTrue(document.contains("<w:numId w:val=\"1\"/>"), document)
        XCTAssertFalse(document.contains("<w:numId w:val=\"2\"/>"), "bullets should not mint new instances")
    }

    func testNestedListsUseIndentLevels() throws {
        let inspector = try inspect("- parent\n  - child\n    - grandchild\n")
        let xml = inspector.text("word/document.xml")
        XCTAssertTrue(xml.contains("<w:ilvl w:val=\"0\"/>"), xml)
        XCTAssertTrue(xml.contains("<w:ilvl w:val=\"1\"/>"), xml)
        XCTAssertTrue(xml.contains("<w:ilvl w:val=\"2\"/>"), xml)
    }

    func testTaskListsRenderCheckboxGlyphs() throws {
        let inspector = try inspect("- [x] done\n- [ ] todo\n")
        let text = inspector.documentText()
        XCTAssertTrue(text.contains("☑"), text)
        XCTAssertTrue(text.contains("☐"), text)
    }

    func testTableHasGridMatchingColumnCount() throws {
        let inspector = try inspect("| A | B | C |\n| - | - | - |\n| 1 | 2 | 3 |\n")
        let xml = inspector.text("word/document.xml")
        XCTAssertEqual(xml.components(separatedBy: "<w:gridCol").count - 1, 3, "one gridCol per column")
        XCTAssertTrue(xml.contains("<w:tblLayout w:type=\"fixed\"/>"), xml)
        XCTAssertTrue(inspector.documentText().contains("A"))
        XCTAssertTrue(inspector.documentText().contains("3"))
    }

    func testRaggedTableRowStillFillsEveryCell() throws {
        // A short row must not produce a row with fewer cells than the grid.
        let inspector = try inspect("| A | B |\n| - | - |\n| only |\n")
        let xml = inspector.text("word/document.xml")
        let rows = xml.components(separatedBy: "<w:tr>").dropFirst()
        for row in rows {
            XCTAssertEqual(row.components(separatedBy: "<w:tc>").count - 1, 2, "each row needs 2 cells")
        }
    }

    func testCodeBlockKeepsOneParagraphPerLine() throws {
        let inspector = try inspect("```swift\nlet a = 1\nlet b = 2\n```")
        let xml = inspector.text("word/document.xml")
        XCTAssertEqual(xml.components(separatedBy: "<w:pStyle w:val=\"SourceCode\"/>").count - 1, 2)
        XCTAssertTrue(inspector.documentText().contains("let a = 1"))
    }

    func testThematicBreakBecomesBorderedParagraph() throws {
        let inspector = try inspect("above\n\n---\n\nbelow")
        XCTAssertTrue(inspector.text("word/document.xml").contains("<w:pBdr>"))
    }

    func testImageIsEmbeddedWithUniqueIdentifiers() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let imageURL = directory.appendingPathComponent("shot.png")
            try TestImages.writePNG(to: imageURL, width: 400, height: 200)

            let inspector = try inspect("![first](shot.png)\n\n![second](shot.png)\n",
                                        resourceDirectory: directory)
            XCTAssertNotNil(inspector.parts["word/media/image1.png"])
            XCTAssertNotNil(inspector.parts["word/media/image2.png"])

            let xml = inspector.text("word/document.xml")
            XCTAssertTrue(xml.contains("<w:drawing>"), xml)
            XCTAssertTrue(xml.contains("cx=\"3810000\""), "400px at 96dpi should be 3810000 EMU: \(xml)")
            XCTAssertTrue(inspector.text("[Content_Types].xml").contains("Extension=\"png\""))
        }
    }

    func testOversizedImageIsClampedPreservingAspectRatio() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let imageURL = directory.appendingPathComponent("wide.png")
            try TestImages.writePNG(to: imageURL, width: 2000, height: 1000)

            let inspector = try inspect("![wide](wide.png)", resourceDirectory: directory)
            let xml = inspector.text("word/document.xml")
            XCTAssertTrue(xml.contains("cx=\"5943600\""), "width should clamp to the text column: \(xml)")
            XCTAssertTrue(xml.contains("cy=\"2971800\""), "height should scale with the width: \(xml)")
        }
    }

    func testMissingImageFallsBackToAltText() throws {
        let inspector = try inspect("![a diagram](missing.png)")
        XCTAssertTrue(inspector.documentText().contains("[a diagram]"), inspector.documentText())
    }

    func testSampleDocumentIsStructurallyValid() throws {
        let inspector = try inspect(try Fixtures.sampleMarkdown())
        let text = inspector.documentText()
        for expected in ["Markpad Sample Document", "bold text", "Nested item one",
                         "Ship it", "struct Greeter", "Word", "Level six"] {
            XCTAssertTrue(text.contains(expected), "document text is missing \(expected)")
        }
    }

    /// Proves Apple's own Office importer accepts the package — the same code path Pages,
    /// TextEdit and Quick Look use.
    func testCocoaOfficeImporterReadsTheDocument() throws {
        let data = try exporter.export(markdown: try Fixtures.sampleMarkdown())
        let attributed = try NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
            documentAttributes: nil
        )
        let text = attributed.string
        XCTAssertTrue(text.contains("Markpad Sample Document"), String(text.prefix(300)))
        XCTAssertTrue(text.contains("Ship it"))
        XCTAssertTrue(text.contains("struct Greeter"))
        XCTAssertFalse(text.contains("**"), "markdown syntax should not survive into Word output")
    }

    /// A second, independent importer: the `textutil` command line tool.
    func testTextutilConvertsTheDocument() throws {
        let data = try exporter.export(markdown: try Fixtures.sampleMarkdown())
        try Fixtures.withTemporaryDirectory { directory in
            let docxURL = directory.appendingPathComponent("sample.docx")
            try data.write(to: docxURL)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
            process.arguments = ["-convert", "txt", "-stdout", docxURL.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            XCTAssertEqual(process.terminationStatus, 0, "textutil failed to read the docx")
            let text = String(data: output, encoding: .utf8) ?? ""
            XCTAssertTrue(text.contains("Markpad Sample Document"), String(text.prefix(300)))
        }
    }
}
