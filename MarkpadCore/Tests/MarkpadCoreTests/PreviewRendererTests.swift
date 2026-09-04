import XCTest
@testable import MarkpadCore

/// Covers the file reading behind Quick Look. The extension's own entry point cannot be
/// called from a test (its request type has no public initialiser), so the reading is tested
/// here and the extension is left as a thin wrapper around it and the editor's renderer.
final class PreviewRendererTests: XCTestCase {
    func testPreviewReadsTheDocumentSource() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("Meeting Notes.md")
            let source = "# Notes\n\nSome **bold** text."
            try source.write(to: url, atomically: true, encoding: .utf8)

            // The preview renders the source itself, so it must arrive unchanged: the editor
            // draws Markdown, it does not receive a converted document.
            XCTAssertEqual(try PreviewRenderer.markdown(forFileAt: url), source)
        }
    }

    func testNonUTF8FileStillPreviews() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("legacy.md")
            try Data([0x48, 0x69, 0x20, 0xE9]).write(to: url)  // "Hi é" in Latin-1

            XCTAssertEqual(try PreviewRenderer.markdown(forFileAt: url), "Hi é")
        }
    }

    func testMissingFileThrows() {
        XCTAssertThrowsError(try PreviewRenderer.markdown(forFileAt: URL(fileURLWithPath: "/tmp/markpad-none.md")))
    }
}
