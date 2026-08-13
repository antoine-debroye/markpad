import XCTest
@testable import MarkpadCore

final class SourceIndexTests: XCTestCase {
    func testASCIIOffsetsMapDirectly() {
        let index = SourceIndex(source: "hello\nworld")
        XCTAssertEqual(index.offset(line: 1, column: 1), 0)
        XCTAssertEqual(index.offset(line: 2, column: 1), 6)
        XCTAssertEqual(index.offset(line: 2, column: 6), 11)
    }

    /// cmark reports UTF-8 byte columns; NSTextStorage counts UTF-16 units. These cases are
    /// where a naive implementation silently styles the wrong characters.
    func testMultiByteCharactersConvertCorrectly() {
        // "é" is 2 UTF-8 bytes but 1 UTF-16 unit.
        XCTAssertEqual(SourceIndex(source: "é**b**").offset(line: 1, column: 3), 1)
        // "日本" is 6 UTF-8 bytes, 2 UTF-16 units.
        XCTAssertEqual(SourceIndex(source: "日本**b**").offset(line: 1, column: 7), 2)
        // An emoji outside the BMP is 4 UTF-8 bytes and 2 UTF-16 units.
        XCTAssertEqual(SourceIndex(source: "😀**b**").offset(line: 1, column: 5), 2)
    }

    func testCRLFLineEndingsDoNotShiftColumns() {
        let index = SourceIndex(source: "one\r\ntwo")
        XCTAssertEqual(index.offset(line: 2, column: 1), 5)
    }

    func testOutOfRangeInputIsClamped() {
        let index = SourceIndex(source: "abc")
        XCTAssertEqual(index.offset(line: 99, column: 99), 3)
        XCTAssertEqual(index.offset(line: 0, column: 0), 0)
    }

    func testLineRangeLookup() {
        let index = SourceIndex(source: "first\nsecond\nthird")
        XCTAssertEqual(index.lineRange(containing: 0), NSRange(location: 0, length: 5))
        XCTAssertEqual(index.lineRange(containing: 8), NSRange(location: 6, length: 6))
        XCTAssertEqual(index.lineCount, 3)
    }
}

final class StyleEngineTests: XCTestCase {
    private let engine = StyleEngine()

    private func substring(_ source: String, _ range: NSRange) -> String {
        (source as NSString).substring(with: range)
    }

    func testBoldRunCoversTheStyledTextAndMarkersCoverTheAsterisks() {
        let source = "a **bold** b"
        let layout = engine.layout(for: source)

        let bold = try? XCTUnwrap(layout.inlines.first { $0.traits.contains(.bold) })
        XCTAssertEqual(substring(source, bold?.range ?? NSRange()), "**bold**")

        let markerText = layout.markers.map { substring(source, $0.range) }
        XCTAssertTrue(markerText.contains("**"), "asterisks should be marked as syntax: \(markerText)")
    }

    func testMarkersAreCorrectWhenTheLineContainsEmoji() {
        let source = "😀 **bold**"
        let layout = engine.layout(for: source)
        let markerText = layout.markers.map { substring(source, $0.range) }
        // A byte/unit mix-up here would slice the emoji or the word instead.
        XCTAssertEqual(markerText.filter { $0 == "**" }.count, 2, "got \(markerText)")
    }

    func testHeadingHashPrefixIsAMarker() {
        let source = "## Title\n"
        let layout = engine.layout(for: source)
        XCTAssertEqual(layout.blocks.first?.kind, .heading(level: 2))
        XCTAssertEqual(layout.markers.map { substring(source, $0.range) }, ["## "])
    }

    func testInlineCodeBackticksAreMarkers() {
        let source = "call `run()` now"
        let layout = engine.layout(for: source)
        XCTAssertTrue(layout.inlines.contains { $0.traits.contains(.code) })
        XCTAssertEqual(layout.markers.map { substring(source, $0.range) }, ["`", "`"])
    }

    func testLinkBracketsAndDestinationAreMarkers() {
        let source = "see [docs](https://example.com) here"
        let layout = engine.layout(for: source)

        let link = layout.inlines.first { $0.traits.contains(.link) }
        XCTAssertEqual(link?.link, "https://example.com")

        let markerText = layout.markers.map { substring(source, $0.range) }
        XCTAssertTrue(markerText.contains("["), markerText.description)
        XCTAssertTrue(markerText.contains("](https://example.com)"), markerText.description)
    }

    func testCodeFenceLinesAreMarkers() {
        let source = "```swift\nlet a = 1\n```\n"
        let layout = engine.layout(for: source)
        XCTAssertEqual(layout.blocks.first?.kind, .codeBlock(language: "swift"))
        let markerText = layout.markers.map { substring(source, $0.range) }
        XCTAssertTrue(markerText.contains("```swift"), markerText.description)
        XCTAssertTrue(markerText.contains("```"), markerText.description)
    }

    func testBlockQuotePrefixIsMarkedOnEveryLine() {
        let source = "> first line\n> second line\n"
        let layout = engine.layout(for: source)
        let quoteMarkers = layout.markers.filter { substring(source, $0.range) == "> " }
        XCTAssertEqual(quoteMarkers.count, 2)
        XCTAssertTrue(layout.blocks.allSatisfy { $0.quoteDepth == 1 })
    }

    func testBulletMarkerIsPaintedAndOrderedMarkerIsDimmed() {
        let bullet = engine.layout(for: "- item\n")
        XCTAssertEqual(bullet.markers.first?.presentation, .bullet)

        let ordered = engine.layout(for: "1. item\n")
        XCTAssertEqual(ordered.markers.first?.presentation, .dimmed)
    }

    func testTaskCheckboxIsMarkedWithItsState() {
        let layout = engine.layout(for: "- [x] done\n- [ ] todo\n")
        let checkboxes = layout.markers.compactMap { marker -> Bool? in
            if case let .checkbox(checked) = marker.presentation { return checked }
            return nil
        }
        XCTAssertEqual(checkboxes, [true, false])
    }

    func testNestedListsReportTheirDepth() {
        let layout = engine.layout(for: "- one\n  - two\n")
        XCTAssertEqual(layout.blocks.map(\.listDepth), [1, 2])
    }

    func testImagesAreCollectedWithSourceAndAlt() {
        let source = "![a cat](cat.png)"
        let images = engine.images(in: source)
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?.source, "cat.png")
        XCTAssertEqual(images.first?.alt, "a cat")
        XCTAssertEqual(substring(source, images.first?.range ?? NSRange()), "![a cat](cat.png)")
    }

    // MARK: Reveal behaviour

    func testMarkersAreConcealedOnlyOutsideTheActiveBlock() {
        let source = "# Title\n\nSome **bold** text.\n"
        let layout = engine.layout(for: source)

        // Caret in the heading: the heading's own marker stays visible, the paragraph's hide.
        let caretInHeading = NSRange(location: 2, length: 0)
        let concealedForHeading = layout.concealedMarkers(selection: caretInHeading)
            .map { substring(source, $0.range) }
        XCTAssertFalse(concealedForHeading.contains("# "), concealedForHeading.description)
        XCTAssertTrue(concealedForHeading.contains("**"), concealedForHeading.description)

        // Caret in the paragraph: now the heading hides and the paragraph reveals.
        let caretInParagraph = NSRange(location: (source as NSString).range(of: "bold").location, length: 0)
        let concealedForParagraph = layout.concealedMarkers(selection: caretInParagraph)
            .map { substring(source, $0.range) }
        XCTAssertTrue(concealedForParagraph.contains("# "), concealedForParagraph.description)
        XCTAssertFalse(concealedForParagraph.contains("**"), concealedForParagraph.description)
    }

    func testSelectionSpanningBlocksRevealsAllOfThem() {
        let source = "# Title\n\nSome **bold** text.\n"
        let layout = engine.layout(for: source)
        let everything = NSRange(location: 0, length: (source as NSString).length)
        XCTAssertTrue(layout.concealedMarkers(selection: everything).isEmpty)
    }

    func testBulletAndCheckboxMarkersAreNeverConcealed() {
        let source = "- [x] done\n"
        let layout = engine.layout(for: source)
        // These are painted over rather than collapsed, so they must keep their width.
        let concealed = layout.concealedMarkers(selection: NSRange(location: 500, length: 0))
        XCTAssertTrue(concealed.isEmpty, "\(concealed)")
    }

    // MARK: Robustness

    func testEmptyAndWhitespaceSourcesProduceNoLayout() {
        XCTAssertTrue(engine.layout(for: "").markers.isEmpty)
        XCTAssertTrue(engine.layout(for: "\n\n\n").inlines.isEmpty)
    }

    func testEveryRangeStaysInsideTheSource() throws {
        let source = try Fixtures.sampleMarkdown()
        let length = (source as NSString).length
        let layout = engine.layout(for: source)

        for block in layout.blocks {
            XCTAssertLessThanOrEqual(NSMaxRange(block.range), length, "block out of bounds: \(block)")
        }
        for inline in layout.inlines {
            XCTAssertLessThanOrEqual(NSMaxRange(inline.range), length, "inline out of bounds: \(inline)")
        }
        for marker in layout.markers {
            XCTAssertLessThanOrEqual(NSMaxRange(marker.range), length, "marker out of bounds: \(marker)")
            XCTAssertGreaterThan(marker.range.length, 0)
        }
    }

    /// Guards against crashes and runaway ranges on inputs the parser handles unusually.
    func testMalformedMarkdownDoesNotProduceInvalidRanges() {
        let awkward = [
            "**unclosed bold",
            "`unclosed code",
            "# ",
            "> ",
            "- ",
            "|broken|table\n|---",
            "```\nunterminated fence",
            "[link without destination]",
            "![](empty.png)",
            String(repeating: "*", count: 200),
            "text with \u{200B} zero width space",
            "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} **family emoji**"
        ]
        for source in awkward {
            let length = (source as NSString).length
            let layout = engine.layout(for: source)
            for marker in layout.markers {
                XCTAssertGreaterThanOrEqual(marker.range.location, 0, source)
                XCTAssertLessThanOrEqual(NSMaxRange(marker.range), length, "overflow in \(source.debugDescription)")
            }
            for inline in layout.inlines {
                XCTAssertLessThanOrEqual(NSMaxRange(inline.range), length, "overflow in \(source.debugDescription)")
            }
        }
    }

    func testLayoutIsDeterministic() throws {
        let source = try Fixtures.sampleMarkdown()
        XCTAssertEqual(engine.layout(for: source), engine.layout(for: source))
    }

    func testLargeDocumentLayoutStaysFast() throws {
        let unit = try Fixtures.sampleMarkdown()
        let large = String(repeating: unit, count: 60)  // roughly 90 KB
        let start = Date()
        let layout = engine.layout(for: large)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertFalse(layout.blocks.isEmpty)
        XCTAssertLessThan(elapsed, 1.0, "layout of a 90 KB document took \(elapsed)s")
    }
}
