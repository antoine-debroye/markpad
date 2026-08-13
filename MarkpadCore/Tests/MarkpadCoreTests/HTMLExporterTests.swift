import XCTest
@testable import MarkpadCore

final class HTMLExporterTests: XCTestCase {
    private let exporter = HTMLExporter()

    private func fragment(_ markdown: String) -> String {
        exporter.export(markdown: markdown, options: .init(standalone: false))
    }

    func testHeadingsRenderWithAnchors() {
        let html = fragment("# Hello World\n\n## Hello World\n")
        XCTAssertTrue(html.contains("<h1 id=\"hello-world\">Hello World</h1>"), html)
        // Duplicate heading text must not produce a duplicate anchor.
        XCTAssertTrue(html.contains("<h2 id=\"hello-world-2\">Hello World</h2>"), html)
    }

    func testInlineFormatting() {
        let html = fragment("**bold** *italic* ~~gone~~ `code`")
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
        XCTAssertTrue(html.contains("<em>italic</em>"))
        XCTAssertTrue(html.contains("<del>gone</del>"))
        XCTAssertTrue(html.contains("<code>code</code>"))
    }

    func testEscapingPreventsInjection() {
        let html = fragment("A < B & C \"quoted\"")
        XCTAssertTrue(html.contains("A &lt; B &amp; C &quot;quoted&quot;"), html)
    }

    func testCodeBlockCarriesLanguageAndEscapes() {
        let html = fragment("```swift\nlet a = 1 < 2\n```")
        XCTAssertTrue(html.contains("<pre><code class=\"language-swift\">"), html)
        XCTAssertTrue(html.contains("let a = 1 &lt; 2"), html)
    }

    func testTaskListRendersCheckboxes() {
        let html = fragment("- [x] done\n- [ ] pending\n")
        XCTAssertTrue(html.contains("class=\"task-list\""), html)
        XCTAssertTrue(html.contains("<input type=\"checkbox\" disabled checked>"), html)
        XCTAssertTrue(html.contains("<input type=\"checkbox\" disabled>"), html)
    }

    func testTableRendersHeadAndAlignment() {
        let markdown = "| A | B |\n| :--- | ---: |\n| 1 | 2 |\n"
        let html = fragment(markdown)
        XCTAssertTrue(html.contains("<thead>"), html)
        XCTAssertTrue(html.contains("text-align:left"), html)
        XCTAssertTrue(html.contains("text-align:right"), html)
        XCTAssertTrue(html.contains("<td style=\"text-align:left\">1</td>"), html)
    }

    func testOrderedListStartIsPreserved() {
        let html = fragment("3. three\n4. four\n")
        XCTAssertTrue(html.contains("<ol start=\"3\">"), html)
    }

    func testImageResolverRewritesSource() {
        let options = HTMLExporter.Options(standalone: false, imageResolver: { _ in "data:image/png;base64,AAA" })
        let html = exporter.export(markdown: "![alt](local.png)", options: options)
        XCTAssertTrue(html.contains("src=\"data:image/png;base64,AAA\""), html)
        XCTAssertTrue(html.contains("alt=\"alt\""), html)
    }

    func testRawHTMLPassesThroughWhenExportingYourOwnDocument() {
        // Markdown permits inline HTML, and an export is an explicit act by the author.
        let html = fragment("<div class=\"note\">kept</div>")
        XCTAssertTrue(html.contains("<div class=\"note\">kept</div>"), html)
    }

    func testRawHTMLIsNeutralisedWhenDisallowed() {
        let options = HTMLExporter.Options(standalone: false, allowsRawHTML: false)
        let block = exporter.export(markdown: "<script>alert(1)</script>", options: options)
        XCTAssertFalse(block.contains("<script>"), block)
        XCTAssertTrue(block.contains("&lt;script&gt;"), block)

        let inline = exporter.export(markdown: "text <img src=x onerror=alert(1)> more", options: options)
        XCTAssertFalse(inline.contains("<img src=x"), inline)
        XCTAssertTrue(inline.contains("&lt;img"), inline)
    }

    func testStandaloneDocumentEmbedsThemeAndTitle() {
        let html = exporter.export(markdown: "# My Title\n\nBody.")
        XCTAssertTrue(html.hasPrefix("<!DOCTYPE html>"))
        XCTAssertTrue(html.contains("<title>My Title</title>"), "title should default to first heading")
        XCTAssertTrue(html.contains("prefers-color-scheme: dark"), "dark palette must be present")
        XCTAssertTrue(html.contains("--mp-background: #ffffff;"))
        XCTAssertTrue(html.contains("--mp-background: #1c1c1e;"))
    }

    func testSampleDocumentRendersEveryConstruct() throws {
        let markdown = try Fixtures.sampleMarkdown()
        let html = exporter.export(markdown: markdown)
        for expected in ["<h1", "<h6", "<strong>", "<em>", "<del>", "<code>", "<pre>",
                         "<blockquote>", "<ul", "<ol>", "<table>", "<hr>", "<a href="] {
            XCTAssertTrue(html.contains(expected), "sample output is missing \(expected)")
        }
        XCTAssertFalse(html.contains("<p></p>"), "no empty paragraphs should be emitted")
    }
}
