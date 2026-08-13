import XCTest
@testable import MarkpadCore

final class PlainTextExporterTests: XCTestCase {
    private let exporter = PlainTextExporter()

    private func text(_ markdown: String) -> String {
        exporter.export(markdown: markdown)
    }

    func testSyntaxMarkersAreRemoved() {
        let output = text("**bold** and *italic* and `code` and ~~gone~~")
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "bold and italic and code and gone")
        XCTAssertFalse(output.contains("*"))
        XCTAssertFalse(output.contains("`"))
    }

    func testStraightQuotesSurviveUnchanged() {
        // Smart punctuation must stay off so exported text matches what the author typed.
        let output = text("She said \"hello\" -- twice.")
        XCTAssertTrue(output.contains("\"hello\""), output)
        XCTAssertFalse(output.contains("\u{201C}"), "curly quotes should not be introduced")
    }

    func testHeadingsAreUnderlined() {
        let output = text("# Title\n\nBody")
        XCTAssertTrue(output.contains("Title\n====="), output)
    }

    func testLinksKeepTheirDestination() {
        let output = text("See [the docs](https://example.com).")
        XCTAssertTrue(output.contains("the docs (https://example.com)"), output)
    }

    func testLinkWithMatchingTextIsNotDuplicated() {
        let output = text("<https://example.com>")
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "https://example.com")
    }

    func testBulletAndOrderedListMarkers() {
        let output = text("- one\n- two\n\n1. first\n2. second\n")
        XCTAssertTrue(output.contains("•  one"), output)
        XCTAssertTrue(output.contains("1. first"), output)
        XCTAssertTrue(output.contains("2. second"), output)
    }

    func testOrderedListRespectsStartIndex() {
        let output = text("5. five\n6. six\n")
        XCTAssertTrue(output.contains("5. five"), output)
        XCTAssertTrue(output.contains("6. six"), output)
    }

    func testNestedListsAreIndented() {
        let output = text("- parent\n  - child\n")
        XCTAssertTrue(output.contains("•  parent"), output)
        XCTAssertTrue(output.contains("   •  child"), output)
    }

    func testListItemContinuationLinesAlignUnderTheirText() {
        let output = text("- first paragraph\n\n  second paragraph\n")
        // The continuation paragraph is indented to the marker width, not back to column 0.
        XCTAssertTrue(output.contains("•  first paragraph"), output)
        XCTAssertTrue(output.contains("   second paragraph"), output)
    }

    func testDocumentStartingWithCodeBlockKeepsItsIndent() {
        let output = text("```\nfirst line\n```\n")
        XCTAssertTrue(output.hasPrefix("    first line"), output.debugDescription)
    }

    func testTaskListShowsState() {
        let output = text("- [x] done\n- [ ] todo\n")
        XCTAssertTrue(output.contains("[x] done"), output)
        XCTAssertTrue(output.contains("[ ] todo"), output)
    }

    func testBlockQuotesArePrefixed() {
        let output = text("> quoted line\n")
        XCTAssertTrue(output.contains("> quoted line"), output)
    }

    func testCodeBlockIsIndentedWithoutFences() {
        let output = text("```swift\nlet a = 1\n```")
        XCTAssertTrue(output.contains("    let a = 1"), output)
        XCTAssertFalse(output.contains("```"))
    }

    func testTableIsColumnAligned() {
        let output = text("| Name | Qty |\n| --- | --- |\n| Apples | 3 |\n")
        XCTAssertTrue(output.contains("Name"), output)
        XCTAssertTrue(output.contains("Apples"), output)
        XCTAssertTrue(output.contains("─"), "a separator rule should follow the header row")
        XCTAssertFalse(output.contains("|"), "pipe syntax should be gone")
    }

    func testSampleDocumentHasNoResidualSyntax() throws {
        let output = exporter.export(markdown: try Fixtures.sampleMarkdown())
        XCTAssertFalse(output.contains("```"))
        XCTAssertFalse(output.contains("**"))
        XCTAssertFalse(output.contains("~~"))
        XCTAssertTrue(output.contains("Markpad Sample Document"))
        XCTAssertTrue(output.hasSuffix("\n"))
    }
}
