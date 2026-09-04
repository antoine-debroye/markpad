import AppKit
import MarkpadCore

/// Builds the scrolling text view the editor and the Quick Look preview both use.
///
/// The two differ only in whether the document can be edited, so the construction lives here
/// rather than in the SwiftUI wrapper: the preview extension has no SwiftUI in it, and a
/// preview that built its own text view would drift from the editor it is supposed to match.
@MainActor
enum EditorHost {
    /// Returns a scroll view showing `text`, wired to `coordinator`.
    ///
    /// The coordinator carries the editable flag; a read-only host gets no caret, no undo and
    /// no checkbox toggling, and its markers never open back into raw syntax.
    static func make(
        text: String,
        documentDirectory: URL?,
        coordinator: EditorCoordinator,
        onLinkActivated: ((String) -> Void)? = nil
    ) -> NSScrollView {
        let isEditable = coordinator.isEditable
        let theme = EditorTheme()

        let storage = NSTextStorage()
        let layoutManager = MarkdownLayoutManager()
        layoutManager.theme = theme
        layoutManager.delegate = layoutManager
        storage.addLayoutManager(layoutManager)

        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        // No implicit padding: table columns are positioned from the line's own origin, so
        // the text must start exactly at the container edge.
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        let textView = MarkdownTextView(frame: .zero, textContainer: container)
        textView.delegate = coordinator
        textView.isRichText = false
        textView.isEditable = isEditable
        // Selectable either way, so a preview's text can still be copied.
        textView.isSelectable = true
        textView.allowsUndo = isEditable
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        // Off by default: red underlines under headings and code read as errors in a
        // document that is mostly prose plus syntax. Edit ▸ Spelling turns it back on.
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.backgroundColor = theme.background
        textView.insertionPointColor = theme.text
        // Starting value only; the first styling pass centres the column once the scroll view
        // has a real width.
        textView.textContainerInset = CGSize(
            width: EditorMetrics.gutter,
            height: EditorMetrics.verticalInset
        )
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = CGSize(width: 0, height: 0)
        textView.maxSize = CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textStorage?.setAttributedString(NSAttributedString(string: text))

        if isEditable {
            textView.onCheckboxToggle = { [weak coordinator] range in
                coordinator?.toggleCheckbox(in: range, textView: textView)
            }
        }
        textView.onAppearanceChange = { [weak coordinator] in
            textView.backgroundColor = theme.background
            textView.insertionPointColor = theme.text
            // Deferred for the same reason as the width observers: this fires from
            // `viewDidChangeEffectiveAppearance`, which runs inside the display cycle, and a
            // restyle resizes the text container — invalidating constraints mid-pass throws.
            DispatchQueue.main.async { coordinator?.restyle(force: true) }
        }
        textView.onLinkActivated = onLinkActivated

        coordinator.textView = textView
        coordinator.layoutManager = layoutManager
        coordinator.theme = theme
        coordinator.documentDirectory = documentDirectory
        coordinator.observeCommands()
        // Table columns are measured against the available width, so the first styling pass
        // waits until the view has been given its real size.
        DispatchQueue.main.async { coordinator.restyle(force: true) }

        textView.postsFrameChangedNotifications = true
        coordinator.observe(NSView.frameDidChangeNotification, from: textView)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = theme.background
        scrollView.automaticallyAdjustsContentInsets = true
        // A second observer, because a wide table switches the text view's autoresizing mask to
        // height-only: its width then stops following the window, and resizing would fire
        // nothing at all through the observer above.
        scrollView.postsFrameChangedNotifications = true
        coordinator.observe(NSView.frameDidChangeNotification, from: scrollView)
        return scrollView
    }
}
