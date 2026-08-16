import AppKit
import XCTest
@testable import Markpad
@testable import MarkpadCore

/// Exercises the editor against real TextKit objects.
///
/// The point of these tests is the invariant the whole design rests on: the text storage
/// holds the Markdown source unchanged, and rendering only ever affects glyphs and
/// attributes. A regression here would silently corrupt users' files.
final class EditorRenderingTests: XCTestCase {
    private var storage: NSTextStorage!
    private var layoutManager: MarkdownLayoutManager!
    private var container: NSTextContainer!
    private let engine = StyleEngine()
    private let theme = EditorTheme()

    override func setUp() {
        super.setUp()
        storage = NSTextStorage()
        layoutManager = MarkdownLayoutManager()
        layoutManager.theme = theme
        layoutManager.delegate = layoutManager
        storage.addLayoutManager(layoutManager)

        container = NSTextContainer(size: CGSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)
    }

    /// Loads `source` and renders it with the caret at `caret`.
    @discardableResult
    private func render(_ source: String, caret: NSRange = NSRange(location: NSNotFound, length: 0)) -> MarkdownLayout {
        storage.setAttributedString(NSAttributedString(string: source))
        let layout = engine.layout(for: source)
        let selection = caret.location == NSNotFound
            ? NSRange(location: (source as NSString).length + 1000, length: 0)
            : caret
        let active = layout.activeBlockRanges(for: selection)

        MarkdownStyler(theme: theme).apply(layout: layout, to: storage, activeRanges: active)
        layoutManager.setConcealedRanges(layout.concealedMarkers(selection: selection).map(\.range))
        layoutManager.blocks = layout.blocks

        // Glyphs are generated once and cached, so a concealment change only takes effect
        // after invalidating them — the same step the editor performs on every restyle.
        let full = NSRange(location: 0, length: storage.length)
        layoutManager.invalidateGlyphs(forCharacterRange: full, changeInLength: 0, actualCharacterRange: nil)
        layoutManager.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
        layoutManager.ensureLayout(for: container)
        return layout
    }

    /// Horizontal position where a character is drawn, within its line.
    ///
    /// Glyph positions are the honest measure of concealment: a collapsed marker leaves the
    /// character after it starting exactly where the marker began.
    private func x(of characterIndex: Int) -> CGFloat {
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
        return layoutManager.location(forGlyphAt: glyphIndex).x
    }

    /// Advance consumed by a character range on its line.
    private func width(of range: NSRange) -> CGFloat {
        x(of: NSMaxRange(range)) - x(of: range.location)
    }

    // MARK: The core invariant

    func testStorageStillHoldsTheExactSourceAfterRendering() {
        let source = "# Title\n\nSome **bold** and `code` and a [link](https://example.com).\n"
        render(source)
        XCTAssertEqual(storage.string, source, "rendering must never alter the text")
    }

    func testCopyingRevealedAndConcealedTextYieldsMarkdown() {
        let source = "Some **bold** text"
        render(source)
        // Concealed markers are still part of the string, so a copy round-trips as Markdown.
        let copied = storage.attributedSubstring(from: NSRange(location: 0, length: storage.length)).string
        XCTAssertEqual(copied, source)
    }

    // MARK: Concealment

    func testSyntaxMarkersTakeNoWidthWhenTheBlockIsInactive() {
        let source = "Some **bold** text"
        let layout = render(source)
        let markerRange = try? XCTUnwrap(layout.markers.first)
        guard let markerRange else { return }

        XCTAssertEqual(width(of: markerRange.range), 0, accuracy: 0.01,
                       "hidden markers should collapse to zero width")
    }

    func testMarkersRegainWidthWhenTheCaretEntersTheBlock() {
        let source = "Some **bold** text"
        var layout = render(source)
        let marker = layout.markers.first!.range

        layout = render(source, caret: NSRange(location: 2, length: 0))
        XCTAssertGreaterThan(width(of: marker), 0, "the active block must show its syntax")
    }

    func testCaretMovingAwayHidesMarkersAgain() {
        let source = "First **paragraph** here.\n\nSecond **paragraph** here.\n"
        let layout = engine.layout(for: source)
        let secondBlock = layout.blocks.last!

        // Caret in the first block: the second block's markers are concealed.
        render(source, caret: NSRange(location: 2, length: 0))
        let markerInSecond = layout.markers.first { NSLocationInRange($0.range.location, secondBlock.range) }!
        XCTAssertEqual(width(of: markerInSecond.range), 0, accuracy: 0.01)

        // Move into the second block and it reveals.
        render(source, caret: NSRange(location: secondBlock.range.location + 2, length: 0))
        XCTAssertGreaterThan(width(of: markerInSecond.range), 0)
    }

    func testHeadingHashIsHiddenButTheTitleKeepsItsWidth() {
        let source = "## A Heading\n"
        render(source)
        XCTAssertEqual(width(of: NSRange(location: 0, length: 3)), 0, accuracy: 0.01)
        XCTAssertGreaterThan(width(of: NSRange(location: 3, length: 9)), 0)
    }

    func testCodeFencesAreHidden() {
        let source = "```swift\nlet a = 1\n```\n"
        render(source)
        XCTAssertEqual(width(of: NSRange(location: 0, length: 8)), 0, accuracy: 0.01)
    }

    /// The quote indent is read by TextKit from the paragraph's *first* character — the ">" —
    /// which sits outside the range cmark reports for the quoted paragraph. Styling only that
    /// inner range left the indent at zero, so the quote bar drew straight over the text.
    /// The head indent at a given character, which is where TextKit reads a paragraph's style
    /// from — the first character of the paragraph.
    private func headIndent(at location: Int) throws -> CGFloat {
        let style = try XCTUnwrap(
            storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
        )
        return style.headIndent
    }

    func testQuoteIndentAppliesFromTheMarkerCharacter() throws {
        render("> Gate code changes on the first of the month.\n")
        XCTAssertEqual(try headIndent(at: 0), MarkdownStyler.QuoteBar.indent, accuracy: 0.01,
                       "the '>' character must carry the quote indent")
    }

    func testNestedQuotesIndentPerLevel() throws {
        render("> > deeply quoted\n")
        XCTAssertEqual(try headIndent(at: 0), MarkdownStyler.QuoteBar.indent * 2, accuracy: 0.01)
    }

    func testBodyParagraphIsNotIndented() throws {
        render("Just ordinary prose.\n")
        XCTAssertEqual(try headIndent(at: 0), 0, accuracy: 0.01)
    }

    /// A checkbox is painted over the characters beneath it, so those characters' width decides
    /// where the row's label starts. In the body font "[x]" is wider than "[ ]", which pushed a
    /// ticked row's label further right than its neighbours'. The design aligns them all.
    func testTaskLabelsAlignRegardlessOfTickState() throws {
        let source = "- [x] done\n- [ ] todo\n"
        render(source)

        let checked = (source as NSString).range(of: "[x]")
        let unchecked = (source as NSString).range(of: "[ ]")
        XCTAssertEqual(
            width(of: checked), width(of: unchecked), accuracy: 0.5,
            "a ticked and an unticked box must occupy the same width"
        )
    }

    func testBulletMarkerKeepsItsWidthSoTheSymbolCanBePainted() {
        let source = "- an item\n"
        let layout = render(source)
        let marker = layout.markers.first { $0.presentation == .bullet }!
        // The bullet is drawn over these characters, so they must not collapse.
        XCTAssertGreaterThan(width(of: marker.range), 0)
    }

    // MARK: Attributes

    func testHeadingIsLargerThanBodyText() {
        render("# Big\n\nbody text\n")
        let headingFont = storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        let bodyFont = storage.attribute(.font, at: (("# Big\n\n") as NSString).length, effectiveRange: nil) as? NSFont
        XCTAssertGreaterThan(headingFont?.pointSize ?? 0, bodyFont?.pointSize ?? 0)
    }

    func testBoldTextGetsABoldFont() {
        let source = "a **bold** b"
        render(source)
        let index = (source as NSString).range(of: "bold").location
        let font = storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
    }

    func testBoldInsideAHeadingKeepsTheHeadingSize() {
        let source = "# Title with **bold**\n"
        render(source)
        let plainIndex = (source as NSString).range(of: "Title").location
        let boldIndex = (source as NSString).range(of: "bold").location
        let plain = storage.attribute(.font, at: plainIndex, effectiveRange: nil) as? NSFont
        let bold = storage.attribute(.font, at: boldIndex, effectiveRange: nil) as? NSFont

        XCTAssertEqual(plain?.pointSize, bold?.pointSize, "inline traits must compose with block styling")
        XCTAssertTrue(bold?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
    }

    func testInlineCodeUsesAMonospacedFont() {
        let source = "call `run()` now"
        render(source)
        let index = (source as NSString).range(of: "run()").location
        let font = storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false, "\(String(describing: font))")
    }

    func testLinkCarriesItsDestinationForClickHandling() {
        let source = "see [docs](https://example.com)"
        render(source)
        let index = (source as NSString).range(of: "docs").location
        let destination = storage.attribute(MarkdownStyler.linkDestination, at: index, effectiveRange: nil) as? String
        XCTAssertEqual(destination, "https://example.com")
    }

    func testStyleIsFullyReplacedWhenSyntaxIsRemoved() {
        // Rendering twice, second time without the bold markers, must not leave bold behind.
        render("a **bold** b")
        render("a bold b")
        let index = ("a " as NSString).length
        let font = storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont
        XCTAssertFalse(font?.fontDescriptor.symbolicTraits.contains(.bold) ?? true)
    }

    func testRenderingIsIdempotent() {
        let source = "# Title\n\n- one\n- two\n\n> quoted\n"
        render(source)
        let first = storage.attributedSubstring(from: NSRange(location: 0, length: storage.length))
        render(source)
        let second = storage.attributedSubstring(from: NSRange(location: 0, length: storage.length))
        XCTAssertEqual(first, second)
    }

    // MARK: Robustness

    func testAwkwardDocumentsRenderWithoutCrashing() {
        let sources = [
            "",
            "\n\n\n",
            "**",
            "# ",
            "```",
            "- [ ] ",
            "> > nested quote",
            "😀 **bold** 日本語 `code`",
            "|a|b|\n|-|-|\n|1|2|",
            String(repeating: "# Heading\n\ntext\n\n", count: 200)
        ]
        for source in sources {
            render(source)
            XCTAssertEqual(storage.string, source, "source changed for \(source.debugDescription)")
        }
    }

    func testMultiByteDocumentConcealsTheRightCharacters() {
        // The emoji shifts every byte offset; a mapping error would hide the wrong glyphs.
        let source = "😀 **bold** 日本"
        render(source)
        let markerRange = (source as NSString).range(of: "**")
        XCTAssertEqual(width(of: markerRange), 0, accuracy: 0.01)
        XCTAssertGreaterThan(width(of: (source as NSString).range(of: "日本")), 0)
        XCTAssertGreaterThan(width(of: (source as NSString).range(of: "😀")), 0)
    }
}

/// Return-key list behaviour, kept as pure logic so it can be checked exhaustively.
final class ListContinuationTests: XCTestCase {
    func testBulletContinues() {
        XCTAssertEqual(ListContinuation.next(after: "- item", caretAtLineOffset: 6), .insert("- "))
    }

    func testAsteriskBulletKeepsItsCharacter() {
        XCTAssertEqual(ListContinuation.next(after: "* item", caretAtLineOffset: 6), .insert("* "))
    }

    func testOrderedListIncrements() {
        XCTAssertEqual(ListContinuation.next(after: "3. item", caretAtLineOffset: 7), .insert("4. "))
    }

    func testOrderedListKeepsItsDelimiter() {
        XCTAssertEqual(ListContinuation.next(after: "1) item", caretAtLineOffset: 7), .insert("2) "))
    }

    func testIndentationIsPreserved() {
        XCTAssertEqual(ListContinuation.next(after: "    - item", caretAtLineOffset: 10), .insert("    - "))
    }

    func testTaskItemContinuesUnchecked() {
        // A finished task should not produce another finished task.
        XCTAssertEqual(ListContinuation.next(after: "- [x] done", caretAtLineOffset: 10), .insert("- [ ] "))
    }

    func testEmptyItemEndsTheList() {
        XCTAssertEqual(ListContinuation.next(after: "- ", caretAtLineOffset: 2), .end(markerRange: NSRange(location: 0, length: 2)))
        XCTAssertEqual(ListContinuation.next(after: "1. ", caretAtLineOffset: 3), .end(markerRange: NSRange(location: 0, length: 3)))
    }

    func testEmptyTaskItemEndsTheList() {
        guard case .end = ListContinuation.next(after: "- [ ] ", caretAtLineOffset: 6) else {
            return XCTFail("an empty task item should end the list")
        }
    }

    func testNonListLinesAreLeftAlone() {
        XCTAssertNil(ListContinuation.next(after: "just a paragraph", caretAtLineOffset: 5))
        XCTAssertNil(ListContinuation.next(after: "", caretAtLineOffset: 0))
        XCTAssertNil(ListContinuation.next(after: "# heading", caretAtLineOffset: 9))
    }

    func testCaretInsideTheMarkerDoesNotContinue() {
        // Pressing Return before the text should split the line, not add a bullet.
        XCTAssertNil(ListContinuation.next(after: "- item", caretAtLineOffset: 1))
    }

    func testRecognisesListItems() {
        XCTAssertTrue(ListContinuation.isListItem("- a"))
        XCTAssertTrue(ListContinuation.isListItem("  12. a"))
        XCTAssertFalse(ListContinuation.isListItem("plain"))
        XCTAssertFalse(ListContinuation.isListItem("-nospace"))
    }
}

final class AppearanceModeTests: XCTestCase {
    func testAutomaticDefersToTheSystem() {
        XCTAssertNil(AppearanceMode.automatic.nsAppearance, "automatic must not force an appearance")
        XCTAssertEqual(AppearanceMode.light.nsAppearance?.name, .aqua)
        XCTAssertEqual(AppearanceMode.dark.nsAppearance?.name, .darkAqua)
    }

    func testThemeColoursResolvePerAppearance() {
        let theme = EditorTheme()
        let light = NSAppearance(named: .aqua)!
        let dark = NSAppearance(named: .darkAqua)!

        var lightBackground: NSColor?
        var darkBackground: NSColor?
        light.performAsCurrentDrawingAppearance { lightBackground = theme.background.usingColorSpace(.sRGB) }
        dark.performAsCurrentDrawingAppearance { darkBackground = theme.background.usingColorSpace(.sRGB) }

        XCTAssertNotNil(lightBackground)
        XCTAssertNotNil(darkBackground)
        XCTAssertNotEqual(lightBackground, darkBackground, "the palette must differ between appearances")
        XCTAssertGreaterThan(lightBackground!.brightnessComponent, darkBackground!.brightnessComponent)
    }

    func testHexParsing() {
        XCTAssertEqual(NSColor(hex: "#ffffff")?.usingColorSpace(.sRGB)?.redComponent, 1)
        XCTAssertEqual(NSColor(hex: "000000")?.usingColorSpace(.sRGB)?.redComponent, 0)
        XCTAssertNil(NSColor(hex: "not-a-colour"))
    }
}
