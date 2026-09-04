import AppKit
import MarkpadCore
// On macOS the preview-extension types live in QuickLookUI; QuickLook itself carries only
// the older, document-side API.
import QuickLookUI

/// Renders Markdown files for Quick Look, so pressing Space in the Finder shows a formatted
/// document rather than raw text.
///
/// The preview is the editor's own rendering stack in read-only form, which is what makes it
/// scroll like the rest of macOS: an `NSScrollView` handles the wheel, rather than a web view
/// hosted by Quick Look that jumps a fixed distance per notch and rubber-bands against nested
/// scrolling boxes. It also means a document looks the same previewed as it does opened.
final class PreviewViewController: NSViewController, QLPreviewingController {
    private var coordinator: EditorCoordinator?

    /// Size the panel opens at before the user resizes it.
    private static let preferredSize = CGSize(width: 800, height: 1000)

    override func loadView() {
        // No nib: the default implementation would look for one named after this class.
        view = NSView(frame: NSRect(origin: .zero, size: Self.preferredSize))
        preferredContentSize = Self.preferredSize
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let markdown = try PreviewRenderer.markdown(forFileAt: url)

        let coordinator = EditorCoordinator(isEditable: false, rendersDiagrams: false)
        self.coordinator = coordinator

        let scrollView = EditorHost.make(
            text: markdown,
            // Sibling images are read directly, exactly as the editor reads them.
            documentDirectory: url.deletingLastPathComponent(),
            coordinator: coordinator
        )
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.width, .height]
        view.addSubview(scrollView)
    }

    deinit {
        MainActor.assumeIsolated { coordinator?.stopObserving() }
    }
}
