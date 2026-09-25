import Markdown
import XCTest
@testable import MarkpadCore

final class MarkdownRendererTests: XCTestCase {
    func testHeadingsParagraphsAndRules() {
        let markdown = MarkdownRenderer.render([
            .heading(level: 1, [MarkdownRun("Title")]),
            .paragraph([MarkdownRun("Body text.")]),
            .rule,
            .heading(level: 9, [MarkdownRun("Clamped")]),
        ])
        XCTAssertEqual(markdown, "# Title\n\nBody text.\n\n---\n\n###### Clamped\n")
    }

    func testEmptyBlocksAreDropped() {
        let markdown = MarkdownRenderer.render([
            .paragraph([MarkdownRun("  ")]),
            .heading(level: 2, []),
            .paragraph([MarkdownRun("Kept")]),
        ])
        XCTAssertEqual(markdown, "Kept\n")
    }

    func testAdjacentEmphasisDoesNotCollide() {
        let runs = [
            MarkdownRun("plain "),
            MarkdownRun("bold", bold: true),
            MarkdownRun(" and "),
            MarkdownRun("both", bold: true, italic: true),
            MarkdownRun(" bold again", bold: true),
        ]
        XCTAssertEqual(
            MarkdownRenderer.inline(runs, lineStartEscaping: true),
            "plain **bold** and ***both* bold again**"
        )
    }

    func testWhitespaceMovesOutsideDelimiters() {
        let runs = [MarkdownRun("a"), MarkdownRun(" bold ", bold: true), MarkdownRun("b")]
        XCTAssertEqual(MarkdownRenderer.inline(runs, lineStartEscaping: true), "a **bold** b")
    }

    func testLinksGroupRunsAndEncodeDestinations() {
        let runs = [
            MarkdownRun("See "),
            MarkdownRun("the ", link: "https://example.com/a b"),
            MarkdownRun("docs", bold: true, link: "https://example.com/a b"),
            MarkdownRun("."),
        ]
        XCTAssertEqual(
            MarkdownRenderer.inline(runs, lineStartEscaping: true),
            "See [the **docs**](https://example.com/a%20b)."
        )
    }

    func testImagesAndCode() {
        let runs = [
            MarkdownRun("Run "),
            MarkdownRun("a`b", code: true),
            MarkdownRun(" "),
            .image(alt: "Chart [1]", destination: "My Report_assets/image1.png"),
        ]
        XCTAssertEqual(
            MarkdownRenderer.inline(runs, lineStartEscaping: true),
            "Run ``a`b`` ![Chart \\[1\\]](My%20Report_assets/image1.png)"
        )
    }

    func testProseIsEscaped() {
        let runs = [MarkdownRun("1990. A *great* year_for [links] <tags> ~x~ &amp;")]
        XCTAssertEqual(
            MarkdownRenderer.inline(runs, lineStartEscaping: true),
            "1990\\. A \\*great\\* year\\_for \\[links\\] \\<tags> \\~x\\~ \\&amp;"
        )
        XCTAssertEqual(MarkdownRenderer.inline([MarkdownRun("# not a heading")], lineStartEscaping: true),
                       "\\# not a heading")
        XCTAssertEqual(MarkdownRenderer.inline([MarkdownRun("- not a list")], lineStartEscaping: true),
                       "\\- not a list")
    }

    func testHardBreaks() {
        let runs = [MarkdownRun("line one"), .lineBreak, MarkdownRun("- line two"), .lineBreak]
        XCTAssertEqual(MarkdownRenderer.inline(runs, lineStartEscaping: true), "line one\\\n\\- line two")
    }

    func testNestedMixedLists() {
        let markdown = MarkdownRenderer.render([
            .listItem(level: 0, ordered: false, [MarkdownRun("one")]),
            .listItem(level: 1, ordered: true, [MarkdownRun("nested a")]),
            .listItem(level: 1, ordered: true, [MarkdownRun("nested b")]),
            .listItem(level: 3, ordered: false, [MarkdownRun("too deep, clamped")]),
            .listItem(level: 0, ordered: false, [MarkdownRun("two")]),
            .paragraph([MarkdownRun("After.")]),
            .listItem(level: 0, ordered: true, [MarkdownRun("fresh")]),
        ])
        XCTAssertEqual(markdown, """
        - one
          1. nested a
          2. nested b
             - too deep, clamped
        - two

        After.

        1. fresh

        """)
    }

    func testListTypeChangeRestartsNumbering() {
        let markdown = MarkdownRenderer.render([
            .listItem(level: 0, ordered: true, [MarkdownRun("a")]),
            .listItem(level: 0, ordered: true, [MarkdownRun("b")]),
            .listItem(level: 0, ordered: false, [MarkdownRun("c")]),
        ])
        XCTAssertEqual(markdown, "1. a\n2. b\n- c\n")
    }

    func testTablesPadAndEscape() {
        let markdown = MarkdownRenderer.render([
            .table([
                [[MarkdownRun("Name")], [MarkdownRun("Note")]],
                [[MarkdownRun("a|b")], [MarkdownRun("x", bold: true)], [MarkdownRun("extra")]],
                [[MarkdownRun("line\nbreak")]],
            ]),
        ])
        XCTAssertEqual(markdown, """
        | Name | Note |  |
        | --- | --- | --- |
        | a\\|b | **x** | extra |
        | line break |  |  |

        """)
    }

    func testQuotesAndFences() {
        let markdown = MarkdownRenderer.render([
            .quote([MarkdownRun("quoted"), .lineBreak, MarkdownRun("more")]),
            .code("let a = \"```\"\n", language: "swift"),
        ])
        XCTAssertEqual(markdown, "> quoted\\\n> more\n\n````swift\nlet a = \"```\"\n````\n")
    }

    /// The renderer's output must parse back to the structure it was built from.
    func testOutputParsesAsIntended() {
        let markdown = MarkdownRenderer.render([
            .heading(level: 2, [MarkdownRun("Heading")]),
            .paragraph([MarkdownRun("1. not a list, *not* emphasis")]),
            .listItem(level: 0, ordered: false, [MarkdownRun("item", bold: true)]),
            .listItem(level: 1, ordered: false, [MarkdownRun("child")]),
            .table([[[MarkdownRun("A")]], [[MarkdownRun("1")]]]),
        ])
        let document = Document(parsing: markdown, options: [])
        let kinds = document.children.map { String(describing: type(of: $0)) }
        XCTAssertEqual(kinds, ["Heading", "Paragraph", "UnorderedList", "Table"])
        let paragraph = document.child(at: 1) as? Paragraph
        XCTAssertEqual(paragraph?.plainText, "1. not a list, *not* emphasis")
        let list = document.child(at: 2) as? UnorderedList
        XCTAssertEqual(list.flatMap { Array($0.listItems).first }.map { $0.childCount }, 2, "child list nests inside the item")
    }

    // MARK: - Emphasis checked against the parser

    /// Renders `runs`, parses the result, and returns the text inside strong and emphasis
    /// nodes — what a reader actually sees as bold and italic.
    private func parsedEmphasis(_ runs: [MarkdownRun]) -> (markdown: String, strong: [String], emphasis: [String], text: String) {
        let markdown = MarkdownRenderer.inline(runs, lineStartEscaping: true)
        let document = Document(parsing: markdown, options: [])
        var strong: [String] = []
        var emphasis: [String] = []
        // The visible text is the text leaves: `plainText` on a strikethrough node would
        // include its `~` markers.
        func leaves(_ markup: Markup) -> String {
            if let text = markup as? Markdown.Text { return text.string }
            if let code = markup as? InlineCode { return code.code }
            return markup.children.map(leaves).joined()
        }
        func visit(_ markup: Markup) {
            if let node = markup as? Strong { strong.append(leaves(node)) }
            if let node = markup as? Emphasis { emphasis.append(leaves(node)) }
            for child in markup.children { visit(child) }
        }
        visit(document)
        let text = document.child(at: 0).map(leaves) ?? ""
        return (markdown, strong, emphasis, text)
    }

    func testItalicDirectlyFollowedByBold() {
        let result = parsedEmphasis([MarkdownRun("a", italic: true), MarkdownRun("b", bold: true), MarkdownRun(" c")])
        XCTAssertEqual(result.emphasis, ["a"], result.markdown)
        XCTAssertEqual(result.strong, ["b"], result.markdown)
        XCTAssertEqual(result.text, "ab c", result.markdown)
    }

    func testBoldDirectlyFollowedByItalic() {
        let result = parsedEmphasis([MarkdownRun("a", bold: true), MarkdownRun("b", italic: true), MarkdownRun(".")])
        XCTAssertEqual(result.strong, ["a"], result.markdown)
        XCTAssertEqual(result.emphasis, ["b"], result.markdown)
        XCTAssertEqual(result.text, "ab.", result.markdown)
    }

    func testTouchingStylesFollowedByALetterNeverShowStrayAsterisks() {
        // `_` cannot close before a letter, so the second run stays plain rather than broken.
        let result = parsedEmphasis([MarkdownRun("a", italic: true), MarkdownRun("b", bold: true), MarkdownRun("c")])
        XCTAssertEqual(result.text, "abc", result.markdown)
        XCTAssertEqual(result.emphasis, ["a"], result.markdown)
    }

    func testBoldStartingWithPunctuationAfterALetter() {
        let result = parsedEmphasis([MarkdownRun("a"), MarkdownRun("(b)", bold: true), MarkdownRun(" c")])
        XCTAssertEqual(result.strong.first?.contains("b"), true, result.markdown)
        XCTAssertEqual(result.text, "a(b) c", result.markdown)
    }

    func testBoldEndingWithPunctuationBeforeALetter() {
        let result = parsedEmphasis([MarkdownRun("Note:", bold: true), MarkdownRun("Text")])
        XCTAssertEqual(result.strong, ["Note"], result.markdown)
        XCTAssertEqual(result.text, "Note:Text", result.markdown)
    }

    func testPunctuationOnlyRunsCarryNoEmphasis() {
        let result = parsedEmphasis([MarkdownRun("x"), MarkdownRun("*", bold: true), MarkdownRun("y")])
        XCTAssertEqual(result.text, "x*y", result.markdown)
        XCTAssertTrue(result.strong.isEmpty, result.markdown)
    }

    /// Every pairing of styles, in both orders, with letters, spaces and punctuation around
    /// them: the reader must always see exactly the original text, never stray delimiters.
    func testNoStyleCombinationLeaksDelimiters() {
        let styles: [(Bool, Bool, Bool)] = [(false, false, false), (true, false, false), (false, true, false),
                                            (true, true, false), (false, false, true), (true, false, true)]
        let texts = ["word", "(p)", "end.", " sp ", "x"]
        for first in styles {
            for second in styles {
                for a in texts {
                    for b in texts {
                        let runs = [
                            MarkdownRun("A"),
                            MarkdownRun(a, bold: first.0, italic: first.1, strikethrough: first.2),
                            MarkdownRun(b, bold: second.0, italic: second.1, strikethrough: second.2),
                            MarkdownRun("Z"),
                        ]
                        let result = parsedEmphasis(runs)
                        let expected = ("A" + a + b + "Z").replacingOccurrences(of: "  ", with: " ")
                        XCTAssertEqual(result.text.replacingOccurrences(of: "  ", with: " "), expected,
                                       "\(first) \(a) | \(second) \(b) → \(result.markdown)")
                    }
                }
            }
        }
    }
}
