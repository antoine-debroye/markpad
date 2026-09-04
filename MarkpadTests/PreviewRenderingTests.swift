import AppKit
import XCTest
@testable import Markpad
@testable import MarkpadCore

/// Covers the read-only form of the editor that Quick Look shows.
///
/// The preview shares the editor's renderer, so what needs proving is the one thing that
/// differs: a document nobody is editing must render every block, including the first, and
/// must not open back into raw syntax when the reader clicks or selects.
final class PreviewRenderingTests: XCTestCase {
    // MARK: The reveal rule

    func testAnEditorRevealsTheBlockTheCaretIsIn() {
        let selected = NSRange(location: 3, length: 0)
        XCTAssertEqual(
            EditorReveal.selection(isEditable: true, selected: selected, length: 40),
            selected
        )
    }

    func testAPreviewReportsACaretPastTheEndOfTheDocument() {
        let reveal = EditorReveal.selection(
            isEditable: false,
            selected: NSRange(location: 0, length: 0),
            length: 40
        )
        XCTAssertGreaterThan(reveal.location, 40, "a preview must have no caret inside the text")
        XCTAssertEqual(reveal.length, 0)
    }

    func testAPreviewIgnoresWhateverTheReaderSelects() {
        // Selecting text to copy it must not turn the document back into Markdown source.
        let reveal = EditorReveal.selection(
            isEditable: false,
            selected: NSRange(location: 2, length: 6),
            length: 40
        )
        XCTAssertFalse(NSLocationInRange(reveal.location, NSRange(location: 0, length: 40)))
    }

    // MARK: Rendering

    /// The first block is the interesting one: a plain zero-length selection at 0 counts as
    /// inside it, which is what would show a document's opening heading as "# Title".
    func testThePreviewConcealsTheFirstBlocksSyntax() {
        let source = "# Title\n\nSome **bold** text.\n"
        let layout = StyleEngine().layout(for: source)
        let reveal = EditorReveal.selection(
            isEditable: false,
            selected: NSRange(location: 0, length: 0),
            length: (source as NSString).length
        )

        XCTAssertTrue(layout.activeBlockRanges(for: reveal).isEmpty,
                      "no block should be showing its source in a preview")

        let concealed = layout.concealedMarkers(selection: reveal).map(\.range)
        let heading = layout.markers.first { NSLocationInRange($0.range.location, layout.blocks[0].range) }
        let headingMarker = try? XCTUnwrap(heading)
        guard let headingMarker else { return }
        XCTAssertTrue(concealed.contains(headingMarker.range), "the heading's # must be concealed")
    }

    // MARK: The read-only host

    @MainActor
    func testTheHostBuildsANonEditableTextViewThatStillCopies() {
        let coordinator = EditorCoordinator(isEditable: false, rendersDiagrams: false)
        defer { coordinator.stopObserving() }
        let source = "# Title\n\nBody text.\n"

        let scrollView = EditorHost.make(
            text: source,
            documentDirectory: nil,
            coordinator: coordinator
        )
        let textView = try? XCTUnwrap(scrollView.documentView as? MarkdownTextView)
        guard let textView else { return }

        XCTAssertFalse(textView.isEditable)
        XCTAssertTrue(textView.isSelectable, "a preview's text must still be selectable to copy")
        XCTAssertFalse(textView.allowsUndo)
        XCTAssertNil(textView.onCheckboxToggle, "task boxes are not clickable in a preview")
        // The invariant the whole design rests on: the storage holds the source, unchanged.
        XCTAssertEqual(textView.string, source)
    }

    @MainActor
    func testTheEditorHostStaysEditable() {
        let coordinator = EditorCoordinator()
        defer { coordinator.stopObserving() }

        let scrollView = EditorHost.make(text: "text", documentDirectory: nil, coordinator: coordinator)
        let textView = try? XCTUnwrap(scrollView.documentView as? MarkdownTextView)
        guard let textView else { return }

        XCTAssertTrue(textView.isEditable)
        XCTAssertTrue(textView.allowsUndo)
        XCTAssertNotNil(textView.onCheckboxToggle)
    }
}
