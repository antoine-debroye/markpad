import AppKit
import MarkpadCore
import SwiftUI

/// SwiftUI wrapper around the Markdown text view.
///
/// The view itself is built by `EditorHost`, which the Quick Look preview also uses, so the
/// document reads the same whether it is being edited or merely looked at.
struct EditorView: NSViewRepresentable {
    @Binding var text: String
    /// Directory used to resolve relative image paths, when the document has been saved.
    var documentDirectory: URL?
    var onSelectionChange: ((EditorStatus) -> Void)?

    func makeCoordinator() -> EditorCoordinator {
        EditorCoordinator(
            onTextChange: { text = $0 },
            onSelectionChange: onSelectionChange
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        EditorHost.make(
            text: text,
            documentDirectory: documentDirectory,
            coordinator: context.coordinator,
            onLinkActivated: { destination in
                guard let url = URL(string: destination), url.scheme != nil else { return }
                NSWorkspace.shared.open(url)
            }
        )
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: EditorCoordinator) {
        coordinator.stopObserving()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let textView = coordinator.textView else { return }

        // A new document has no URL until it is saved, and SwiftUI can supply the URL after
        // the editor is built, so relative image paths only become resolvable here.
        if coordinator.documentDirectory != documentDirectory {
            coordinator.documentDirectory = documentDirectory
            coordinator.reloadImages()
        }

        // Only push text in when the change came from outside the editor (a revert, or an
        // undo driven by the document); otherwise typing would fight the binding.
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(NSRange(
                location: min(selection.location, (text as NSString).length),
                length: 0
            ))
            coordinator.restyle(force: true)
        }
    }
}
