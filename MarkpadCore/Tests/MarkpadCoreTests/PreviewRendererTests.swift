import XCTest
@testable import MarkpadCore

/// Covers what Quick Look will show. The extension's own entry point cannot be called from a
/// test (its request type has no public initialiser), so the rendering is tested here and the
/// extension is left as a thin wrapper around it.
final class PreviewRendererTests: XCTestCase {
    func testPreviewRendersMarkdownAsStandaloneHTML() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("Meeting Notes.md")
            try "# Notes\n\nSome **bold** text.".write(to: url, atomically: true, encoding: .utf8)

            let preview = try PreviewRenderer.preview(forFileAt: url)
            XCTAssertEqual(preview.title, "Meeting Notes")
            XCTAssertTrue(preview.html.hasPrefix("<!DOCTYPE html>"))
            XCTAssertTrue(preview.html.contains("<h1 id=\"notes\">Notes</h1>"), preview.html)
            XCTAssertTrue(preview.html.contains("<strong>bold</strong>"))
            // The stylesheet must be embedded: a preview cannot load external resources.
            XCTAssertTrue(preview.html.contains("<style>"))
            XCTAssertFalse(preview.html.contains("<link"), "no external stylesheets")
        }
    }

    func testPreviewFollowsTheViewersAppearance() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("doc.md")
            try "text".write(to: url, atomically: true, encoding: .utf8)

            let html = try PreviewRenderer.preview(forFileAt: url).html
            XCTAssertTrue(html.contains("prefers-color-scheme: dark"), "dark palette must be present")
            XCTAssertTrue(html.contains("color-scheme: light dark"))
        }
    }

    func testLocalImagesAreEmbeddedBecauseThePreviewIsSandboxed() throws {
        try Fixtures.withTemporaryDirectory { directory in
            try TestImages.writePNG(to: directory.appendingPathComponent("shot.png"), width: 8, height: 8)
            let url = directory.appendingPathComponent("doc.md")
            try "![shot](shot.png)".write(to: url, atomically: true, encoding: .utf8)

            let html = try PreviewRenderer.preview(forFileAt: url).html
            XCTAssertTrue(html.contains("data:image/png;base64,"), "sibling images must be inlined")
        }
    }

    func testNonUTF8FileStillPreviews() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("legacy.md")
            try Data([0x48, 0x69, 0x20, 0xE9]).write(to: url)  // "Hi é" in Latin-1

            let preview = try PreviewRenderer.preview(forFileAt: url)
            XCTAssertTrue(preview.html.contains("Hi"), preview.html)
        }
    }

    func testMissingFileThrows() {
        XCTAssertThrowsError(try PreviewRenderer.preview(forFileAt: URL(fileURLWithPath: "/tmp/markpad-none.md")))
    }

    func testScriptsInSourceAreEscapedRatherThanExecuted() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("doc.md")
            try "A <script>alert(1)</script> tag in text".write(to: url, atomically: true, encoding: .utf8)

            let html = try PreviewRenderer.preview(forFileAt: url).html
            XCTAssertTrue(html.contains("&lt;script&gt;"), "inline text must be escaped: \(html)")
        }
    }
}
