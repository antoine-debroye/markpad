import AppKit
import XCTest
@testable import MarkpadCore

final class RichTextImporterTests: XCTestCase {
    private static let sampleHTML = """
    <html><body>
    <h1>Title</h1>
    <p>Plain <b>bold</b> and <i>italic</i> with a <a href="https://example.com/x">link</a>.</p>
    <h2>Section</h2>
    <ul><li>one<ul><li>nested</li></ul></li><li>two</li></ul>
    <ol><li>first</li><li>second</li></ol>
    <table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table>
    <p>End.</p>
    </body></html>
    """

    /// Writes `html` and converts it with `textutil` to `format`, as a user's file would be.
    private func textutil(_ html: String, to format: String, in directory: URL) throws -> URL {
        let input = directory.appendingPathComponent("in.html")
        try Data(html.utf8).write(to: input)
        let output = directory.appendingPathComponent("sample.\(format)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", format, input.path, "-output", output.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return output
    }

    private func convert(html: String = sampleHTML, format: String) throws -> ImportedMarkdown {
        try Fixtures.withTemporaryDirectory { directory in
            let url = try textutil(html, to: format, in: directory)
            return try RichTextImporter().convert(url: url)
        }
    }

    private static func expected(link: Bool) -> String {
        let linkText = link ? "[link](https://example.com/x)" : "link"
        return """
        # Title

        Plain **bold** and *italic* with a \(linkText).

        ## Section

        - one
          - nested
        - two
        1. first
        2. second

        | A | B |
        | --- | --- |
        | 1 | 2 |

        End.

        """
    }

    func testRTF() throws {
        let result = try convert(format: "rtf")
        XCTAssertEqual(result.markdown, Self.expected(link: true))
        XCTAssertEqual(result.assets, [])
    }

    func testODT() throws {
        XCTAssertEqual(try convert(format: "odt").markdown, Self.expected(link: true))
    }

    func testDOCLosesLinksButKeepsStructure() throws {
        // The Word reader drops hyperlinks and writes list markers as literal text.
        XCTAssertEqual(try convert(format: "doc").markdown, Self.expected(link: false))
    }

    func testRTFDPictureBecomesAsset() throws {
        let png = TestImagePNG.make()
        let wrapper = FileWrapper(regularFileWithContents: png)
        wrapper.preferredFilename = "chart.png"
        let attachment = NSTextAttachment(fileWrapper: wrapper)
        let text = NSMutableAttributedString(string: "Before\n", attributes: [.font: NSFont(name: "Helvetica", size: 12)!])
        text.append(NSAttributedString(attachment: attachment))
        text.append(NSAttributedString(string: "\nAfter\n", attributes: [.font: NSFont(name: "Helvetica", size: 12)!]))

        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("doc.rtfd")
            let package = try XCTUnwrap(text.rtfdFileWrapper(
                from: NSRange(location: 0, length: text.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
            )
            try package.write(to: url, options: .atomic, originalContentsURL: nil)

            let result = try RichTextImporter().convert(url: url, options: .init(assetFolderName: "doc_assets"))
            XCTAssertEqual(result.markdown, "Before\n\n![](doc_assets/chart.png)\n\nAfter\n")
            XCTAssertEqual(result.assets.map(\.name), ["chart.png"])
            XCTAssertEqual(result.assets.first?.data, png)

            // Without an asset folder the picture, which has no alt text, is left out.
            let dropped = try RichTextImporter().convert(url: url)
            XCTAssertEqual(dropped.markdown, "Before\n\nAfter\n")
            XCTAssertEqual(dropped.assets, [])
        }
    }

    func testMonospaceBecomesCode() throws {
        let html = """
        <p>Run <code>make all</code> now.</p>
        <pre>let x = 1
        print(x)</pre>
        <p>Done.</p>
        """
        XCTAssertEqual(try convert(html: html, format: "rtf").markdown, """
        Run `make all` now.

        ```
        let x = 1
        print(x)
        ```

        Done.

        """)
    }

    func testStrikethroughLineBreakAndEscaping() throws {
        let html = "<p><s>gone</s> 1*2 [x]<br>next line</p><p>1990. A good year</p>"
        XCTAssertEqual(try convert(html: html, format: "rtf").markdown, """
        ~~gone~~ 1\\*2 \\[x\\]\\
        next line

        1990\\. A good year

        """)
    }

    func testTextListParagraphsWithWrittenMarkersAreNotDoubled() throws {
        // TextEdit (and some ODT readers) keep the NSTextList *and* write "\t•\t" into the text.
        let font = NSFont(name: "Helvetica", size: 12)!
        let text = NSMutableAttributedString()
        for (marker, format, body) in [("•", NSTextList.MarkerFormat.disc, "apple"), ("1.", .decimal, "step")] {
            let style = NSMutableParagraphStyle()
            style.textLists = [NSTextList(markerFormat: format, options: 0)]
            text.append(NSAttributedString(
                string: "\t\(marker)\t\(body)\n",
                attributes: [.font: font, .paragraphStyle: style]))
        }
        let data = try text.data(
            from: NSRange(location: 0, length: text.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("lists.rtf")
            try data.write(to: url)
            XCTAssertEqual(try RichTextImporter().convert(url: url).markdown, "- apple\n1. step\n")
        }
    }

    func testLiteralMarkers() {
        typealias Walker = RichTextWalker
        XCTAssertEqual(Walker.literalMarker(in: "\t•\tone", requireTab: false)?.length, 3)
        XCTAssertEqual(Walker.literalMarker(in: "\t•\tone", requireTab: false)?.ordered, false)
        XCTAssertEqual(Walker.literalMarker(in: "\t1\tfirst", requireTab: false)?.ordered, true)
        XCTAssertEqual(Walker.literalMarker(in: "a)\tstep", requireTab: false)?.ordered, true)
        XCTAssertEqual(Walker.literalMarker(in: "• typed bullet", requireTab: false)?.length, 2)
        XCTAssertNil(Walker.literalMarker(in: "1990. A good year", requireTab: false))
        XCTAssertNil(Walker.literalMarker(in: "- 5 degrees", requireTab: false))
        XCTAssertNil(Walker.literalMarker(in: "I like it", requireTab: false))
        XCTAssertNil(Walker.literalMarker(in: "•", requireTab: false))
    }

    func testDamagedFileIsUnreadable() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("broken.doc")
            try Data("not a word document at all".utf8).write(to: url)
            XCTAssertThrowsError(try RichTextImporter().convert(url: url)) { error in
                guard case ConversionError.unreadableFile = error else { return XCTFail("\(error)") }
            }
        }
    }

    func testEmptyRTFHasNoText() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("empty.rtf")
            try Data("{\\rtf1\\ansi \\par \\par }".utf8).write(to: url)
            XCTAssertThrowsError(try RichTextImporter().convert(url: url)) { error in
                guard case ConversionError.noTextFound = error else { return XCTFail("\(error)") }
            }
        }
    }

    func testRTFSavedAsDocIsReadAsRTF() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("old.doc")
            try Data("{\\rtf1\\ansi {\\b Hello} world\\par}".utf8).write(to: url)
            XCTAssertEqual(try RichTextImporter().convert(url: url).markdown, "**Hello** world\n")
        }
    }
}

/// A tiny PNG, drawn rather than committed.
private enum TestImagePNG {
    static func make() -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.setColor(.red, atX: 1, y: 1)
        return rep.representation(using: .png, properties: [:])!
    }
}
