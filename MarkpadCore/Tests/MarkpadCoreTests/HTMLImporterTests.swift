import XCTest
@testable import MarkpadCore

final class HTMLImporterTests: XCTestCase {
    /// A 1×1 PNG.
    private static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!

    private func convert(
        _ html: String,
        name: String = "page.html",
        assets: String? = "page_assets",
        setUp: (URL) throws -> Void = { _ in }
    ) throws -> ImportedMarkdown {
        try convert(data: Data(html.utf8), name: name, assets: assets, setUp: setUp)
    }

    private func convert(
        data: Data,
        name: String = "page.html",
        assets: String? = "page_assets",
        setUp: (URL) throws -> Void = { _ in }
    ) throws -> ImportedMarkdown {
        try Fixtures.withTemporaryDirectory { directory in
            try setUp(directory)
            let url = directory.appendingPathComponent(name)
            try data.write(to: url)
            return try HTMLImporter().convert(url: url, options: .init(assetFolderName: assets))
        }
    }

    private func markdown(_ html: String) throws -> String {
        try convert(html).markdown
    }

    // MARK: - Blocks

    func testHeadingsParagraphsAndInlineStyles() throws {
        let html = """
        <html><body>
        <h1>Main   title</h1>
        <p>Some <strong>bold</strong>, <b>also bold</b>, <em>italic</em>, <i>also</i>,
           <s>gone</s> <del>deleted</del> <strike>struck</strike> and <code>x = 1</code> <kbd>K</kbd>.</p>
        <h2>Second</h2><h6>Sixth</h6>
        </body></html>
        """
        XCTAssertEqual(try markdown(html), """
        # Main title

        Some **bold**, **also bold**, *italic*, *also*, ~~gone deleted struck~~ and `x = 1` `K`.

        ## Second

        ###### Sixth

        """)
    }

    func testWhitespaceCollapsesAndLineBreaksAreKept() throws {
        let html = "<p>  one\n\n   two\tthree  <br>four<br/>  five </p><p>\n</p><div>   </div>"
        XCTAssertEqual(try markdown(html), "one two three\\\nfour\\\nfive\n")
    }

    func testTextDirectlyInsideContainersIsKept() throws {
        let html = """
        <div>Loose text<p>A paragraph</p>trailing text</div>
        <section>Section text</section><article><header>Head</header>Body</article>
        <nav><a href="https://example.com/">Home</a></nav><main>Main</main><footer>Foot</footer>
        """
        XCTAssertEqual(try markdown(html), """
        Loose text

        A paragraph

        trailing text

        Section text

        Head

        Body

        [Home](https://example.com/)

        Main

        Foot

        """)
    }

    func testEntitiesAreDecoded() throws {
        let html = "<p>Fish &amp; chips&nbsp;now &#x2014; caf&eacute; &copy; &#233; &lt;tag&gt; \u{4e2d}</p>"
        XCTAssertEqual(try markdown(html), "Fish & chips\u{A0}now \u{2014} caf\u{E9} \u{A9} \u{E9} \\<tag> \u{4e2d}\n")
    }

    func testScriptsStylesAndFormControlsAreDropped() throws {
        let html = """
        <html><head><title>T</title><style>p { color: red }</style>
        <script>document.write("<p>injected</p>")</script></head>
        <body><h1>Kept</h1><script>var a = 1 < 2;</script><noscript>Enable JS</noscript>
        <template><p>Template</p></template><svg><title>Icon</title><text>svg text</text></svg>
        <form><label>Name</label><input value="typed"><button>Send</button>
        <select><option>Choice</option></select><textarea>Area</textarea></form>
        <iframe src="x.html">frame</iframe><!-- a comment --><p>Done</p></body></html>
        """
        XCTAssertEqual(try markdown(html), "# Kept\n\nName\n\nDone\n")
    }

    func testTitleIsUsedOnlyWithoutATopLevelHeading() throws {
        XCTAssertEqual(
            try markdown("<html><head><title>Page  title</title></head><body><h2>Sub</h2><p>Text</p></body></html>"),
            "# Page title\n\n## Sub\n\nText\n")
        XCTAssertEqual(
            try markdown("<html><head><title>Page title</title></head><body><h1>Own</h1></body></html>"),
            "# Own\n")
    }

    func testLinks() throws {
        let html = """
        <p><a href="https://example.com/a?b=1">Web</a>, <a href="mailto:me@example.com">mail</a>,
        <a href="#section">anchor</a>, <a href="javascript:void(0)">script</a>,
        <a href="other.html"><b>relative</b></a>, <a>no href</a>.</p>
        """
        XCTAssertEqual(try markdown(html), """
        [Web](https://example.com/a?b=1), [mail](mailto:me@example.com), anchor, script, [**relative**](other.html), no href.

        """)
    }

    func testNestedLists() throws {
        let html = """
        <ul>
          <li>First</li>
          <li>Second
            <ol><li>Inner one</li><li>Inner <em>two</em>
              <ul><li>Deepest</li></ul></li></ol>
          </li>
          <li><p>Para one</p><p>Para two</p></li>
        </ul>
        <ol><li>Alpha</li><li>Beta</li></ol>
        """
        XCTAssertEqual(try markdown(html), """
        - First
        - Second
          1. Inner one
          2. Inner *two*
             - Deepest
        - Para one\\
          Para two
        1. Alpha
        2. Beta

        """)
    }

    func testBlockquoteFlattensNestedBlocks() throws {
        let html = "<blockquote><p>First line</p><p>Second <b>bold</b></p><ul><li>Item</li></ul></blockquote>"
        XCTAssertEqual(try markdown(html), "> First line\\\n> Second **bold**\\\n> Item\n")
    }

    func testPreformattedCodeKeepsWhitespaceAndLanguage() throws {
        let html = """
        <pre><code class="hljs language-swift">let a = 1
          if a &lt; 2 {
              print(a)
          }</code></pre>
        <pre>plain   text</pre>
        """
        XCTAssertEqual(try markdown(html), """
        ```swift
        let a = 1
          if a < 2 {
              print(a)
          }
        ```

        ```
        plain   text
        ```

        """)
    }

    func testRule() throws {
        XCTAssertEqual(try markdown("<p>Above</p><hr><p>Below</p>"), "Above\n\n---\n\nBelow\n")
    }

    func testTableWithHeaderColspanCaptionAndNestedTable() throws {
        let html = """
        <table>
          <caption>Results</caption>
          <thead><tr><th>Name</th><th>Score</th><th>Note</th></tr></thead>
          <tfoot><tr><td colspan="3">Footer</td></tr></tfoot>
          <tbody>
            <tr><td>Ann</td><td>10</td><td><p>Top</p><p>marks</p></td></tr>
            <tr><td colspan="2">Merged</td><td>a | b</td></tr>
            <tr><td>Nested</td><td><table><tr><td>x</td><td>y</td></tr></table></td><td></td></tr>
          </tbody>
        </table>
        """
        XCTAssertEqual(try markdown(html), """
        Results

        | Name | Score | Note |
        | --- | --- | --- |
        | Ann | 10 | Top marks |
        | Merged |  | a \\| b |
        | Nested | x y |  |
        | Footer |  |  |

        """)
    }

    func testDefinitionListAndFigure() throws {
        let html = """
        <dl><dt>Term</dt><dd>Definition of it.</dd></dl>
        <figure><img src="https://example.com/p.png" alt="Chart"><figcaption>Figure 1: a chart</figcaption></figure>
        """
        XCTAssertEqual(try markdown(html), """
        **Term**

        Definition of it.

        ![Chart](https://example.com/p.png)

        Figure 1: a chart

        """)
    }

    func testMalformedHTMLStillConverts() throws {
        // As in a browser, formatting left open carries on into the following blocks.
        let html = "<p>Unclosed <b>bold <i>both<p>Next para<ul><li>one<li>two</ul><div>Tail"
        XCTAssertEqual(try markdown(html), """
        Unclosed **bold *both***

        ***Next para***

        - ***one***
        - ***two***

        ***Tail***

        """)
        XCTAssertEqual(try markdown("<table><tr><td>a<td>b<tr><td>c</table><p>after"), """
        | a | b |
        | --- | --- |
        | c |  |

        after

        """)
    }

    func testPlainTextWithoutTags() throws {
        XCTAssertEqual(try markdown("just some text"), "just some text\n")
    }

    // MARK: - Pictures

    func testDataURIImageBecomesAnAsset() throws {
        let uri = "data:image/png;base64," + Self.png.base64EncodedString()
        let result = try convert("<p><img src=\"\(uri)\" alt=\"Dot\"></p>")
        XCTAssertEqual(result.markdown, "![Dot](page_assets/image.png)\n")
        XCTAssertEqual(result.assets, [.init(name: "image.png", data: Self.png)])
    }

    func testRelativeLocalImageIsCopied() throws {
        let result = try convert("<p><img src=\"pics/my%20dot.png\" alt=\"Dot\"></p>") { directory in
            let pics = directory.appendingPathComponent("pics")
            try FileManager.default.createDirectory(at: pics, withIntermediateDirectories: true)
            try Self.png.write(to: pics.appendingPathComponent("my dot.png"))
        }
        XCTAssertEqual(result.markdown, "![Dot](page_assets/my-dot.png)\n")
        XCTAssertEqual(result.assets.map(\.name), ["my-dot.png"])
        XCTAssertEqual(result.assets.first?.data, Self.png)
    }

    /// A page is untrusted: an `<img>` pointing at a private file must not copy it into the
    /// output. Absolute paths and `file:` URLs are covered by the next test.
    func testLocalFilesThatAreNotPicturesAreNeverCopied() throws {
        var secretPath = ""
        let result = try convert("""
            <p><img src="../secret/id_rsa" alt="a"><img src="notes.png" alt="c"></p>
            """, name: "inner/page.html") { directory in
            let secret = directory.appendingPathComponent("secret")
            try FileManager.default.createDirectory(at: secret, withIntermediateDirectories: true)
            try Data("-----BEGIN OPENSSH PRIVATE KEY-----".utf8).write(to: secret.appendingPathComponent("id_rsa"))
            secretPath = secret.appendingPathComponent("id_rsa").path
            let inner = directory.appendingPathComponent("inner")
            try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
            // Named like a picture, but it is text.
            try Data("not really a png".utf8).write(to: inner.appendingPathComponent("notes.png"))
        }
        XCTAssertFalse(secretPath.isEmpty)
        XCTAssertTrue(result.assets.isEmpty, "nothing was copied: \(result.assets.map(\.name))")
        XCTAssertFalse(result.markdown.contains("page_assets"), result.markdown)
    }

    func testAbsolutePathToAPrivateFileIsNotCopied() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let secret = directory.appendingPathComponent("id_rsa")
            try Data("-----BEGIN OPENSSH PRIVATE KEY-----".utf8).write(to: secret)
            let page = directory.appendingPathComponent("page.html")
            try Data("<p><img src=\"\(secret.path)\" alt=\"k\"><img src=\"\(secret.absoluteString)\" alt=\"u\"></p>".utf8).write(to: page)
            let result = try HTMLImporter().convert(url: page, options: .init(assetFolderName: "page_assets"))
            XCTAssertTrue(result.assets.isEmpty)
        }
    }

    func testMissingLocalImageKeepsItsSource() throws {
        let result = try convert("<p><img src=\"missing/pic.png\" alt=\"Gone\"></p>")
        XCTAssertEqual(result.markdown, "![Gone](missing/pic.png)\n")
        XCTAssertTrue(result.assets.isEmpty)
    }

    func testWebImageKeepsItsURL() throws {
        let result = try convert("<p>See <img src=\"https://example.com/a.png\" alt=\"A\"> here</p>")
        XCTAssertEqual(result.markdown, "See ![A](https://example.com/a.png) here\n")
        XCTAssertTrue(result.assets.isEmpty)
    }

    func testPicturesFallBackToAltTextWithoutAnAssetFolder() throws {
        let uri = "data:image/png;base64," + Self.png.base64EncodedString()
        let result = try convert("<p>Before <img src=\"\(uri)\" alt=\"Dot\"> <img src=\"\(uri)\">after</p>", assets: nil)
        XCTAssertEqual(result.markdown, "Before Dot after\n")
        XCTAssertTrue(result.assets.isEmpty)
    }

    // MARK: - Encodings

    func testWindows1252WithMetaCharset() throws {
        let html = "<html><head><meta charset=\"windows-1252\"><title>x</title></head><body><h1>Caf\u{E9} \u{2014} \u{201C}quoted\u{201D}</h1></body></html>"
        let data = try XCTUnwrap(html.data(using: .windowsCP1252))
        XCTAssertEqual(try convert(data: data).markdown, "# Caf\u{E9} \u{2014} \u{201C}quoted\u{201D}\n")
    }

    func testUndeclaredUTF8AndUndeclaredWindows1252() throws {
        let text = "<p>Na\u{EF}ve \u{2019}s</p>"
        XCTAssertEqual(try convert(data: Data(text.utf8)).markdown, "Na\u{EF}ve \u{2019}s\n")
        let legacy = try XCTUnwrap(text.data(using: .windowsCP1252))
        XCTAssertEqual(try convert(data: legacy).markdown, "Na\u{EF}ve \u{2019}s\n")
    }

    func testHTTPEquivContentTypeAndBOM() throws {
        let html = "<html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=ISO-8859-1\"></head><body><p>\u{C5}ngstr\u{F6}m</p></body></html>"
        let latin = try XCTUnwrap(html.data(using: .isoLatin1))
        XCTAssertEqual(try convert(data: latin).markdown, "\u{C5}ngstr\u{F6}m\n")
        let bom = Data([0xEF, 0xBB, 0xBF]) + Data("<p>\u{1F600} \u{4e2d}</p>".utf8)
        XCTAssertEqual(try convert(data: bom).markdown, "\u{1F600} \u{4e2d}\n")
    }

    func testXHTMLIsParsedAsXML() throws {
        let xhtml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>X</title></head>
        <body><section><h1>Title</h1><p>Caf\u{E9} <b>b</b> <i>i</i></p></section><custom>kept</custom></body></html>
        """
        XCTAssertEqual(try convert(xhtml, name: "page.xhtml").markdown, "# Title\n\nCaf\u{E9} **b** *i*\n\nkept\n")
    }

    func testSVGCoverImageInXHTMLIsKept() throws {
        let xhtml = """
        <html xmlns="http://www.w3.org/1999/xhtml"><body><div>
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 10 10">
        <title>ignored</title><image width="10" height="10" xlink:href="https://example.com/cover.jpg"/></svg>
        </div><p>Text</p></body></html>
        """
        XCTAssertEqual(try convert(xhtml, name: "cover.xhtml").markdown, "![](https://example.com/cover.jpg)\n\nText\n")
    }

    // MARK: - Web archives

    func testWebArchiveUsesSubresources() throws {
        let html = """
        <html><head><title>Saved</title></head><body><h1>Saved page</h1>
        <p>Caf\u{E9} <a href="/about">About</a></p>
        <img src="images/dot.png" alt="Dot"><img src="https://cdn.example.com/other.png" alt="Other">
        <img src="late.png" alt="Late"></body></html>
        """
        let archive: [String: Any] = [
            "WebMainResource": [
                "WebResourceData": try XCTUnwrap(html.data(using: .isoLatin1)),
                "WebResourceMIMEType": "text/html",
                "WebResourceTextEncodingName": "ISO-8859-1",
                "WebResourceURL": "https://example.com/blog/post.html",
                "WebResourceFrameName": "",
            ],
            "WebSubresources": [
                [
                    "WebResourceData": Self.png,
                    "WebResourceMIMEType": "image/png",
                    "WebResourceURL": "https://example.com/blog/images/dot.png",
                ],
            ],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)
        let result = try convert(data: data, name: "Saved.webarchive")
        XCTAssertEqual(result.markdown, """
        # Saved page

        Caf\u{E9} [About](https://example.com/about)

        ![Dot](page_assets/dot.png)![Other](https://cdn.example.com/other.png) ![Late](https://example.com/blog/late.png)

        """)
        XCTAssertEqual(result.assets, [.init(name: "dot.png", data: Self.png)])
    }

    // MARK: - Errors and progress

    func testEmptyAndUnreadableFiles() throws {
        XCTAssertThrowsError(try convert("")) { error in
            guard case ConversionError.noTextFound = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try convert("<html><head><title></title></head><body><script>x()</script></body></html>")) { error in
            guard case ConversionError.noTextFound = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try convert(data: Data("bplist00garbage".utf8), name: "x.webarchive")) { error in
            guard case ConversionError.unreadableFile = error else { return XCTFail("\(error)") }
        }
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).html")
        XCTAssertThrowsError(try HTMLImporter().convert(url: missing)) { error in
            guard case ConversionError.unreadableFile = error else { return XCTFail("\(error)") }
        }
    }

    func testCancellationAndProgress() throws {
        XCTAssertThrowsError(try Fixtures.withTemporaryDirectory { directory -> ImportedMarkdown in
            let url = directory.appendingPathComponent("a.html")
            try Data("<p>x</p>".utf8).write(to: url)
            return try HTMLImporter().convert(url: url, isCancelled: { true })
        }) { error in
            guard case ConversionError.cancelled = error else { return XCTFail("\(error)") }
        }
        let log = ProgressLog()
        _ = try Fixtures.withTemporaryDirectory { directory -> ImportedMarkdown in
            let url = directory.appendingPathComponent("a.html")
            try Data("<p>x</p>".utf8).write(to: url)
            return try HTMLImporter().convert(url: url, progress: { log.record($0) })
        }
        XCTAssertEqual(log.all.last?.fractionCompleted, 1)
    }

    func testConversionServiceRoutesWebPages() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("page.htm")
            try Data("<h1>Hi</h1>".utf8).write(to: url)
            let result = try ConversionService.importDocument(
                at: url, as: .webPage, options: .init(), isCancelled: { false })
            XCTAssertEqual(result.markdown, "# Hi\n")
        }
    }
}
