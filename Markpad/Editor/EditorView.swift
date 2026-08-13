import AppKit
import MarkpadCore
import SwiftUI

/// SwiftUI wrapper around the Markdown text view.
struct EditorView: NSViewRepresentable {
    @Binding var text: String
    /// Directory used to resolve relative image paths, when the document has been saved.
    var documentDirectory: URL?
    var onSelectionChange: ((EditorStatus) -> Void)?

    func makeCoordinator() -> EditorCoordinator {
        EditorCoordinator(text: $text, onSelectionChange: onSelectionChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let theme = EditorTheme()

        let storage = NSTextStorage()
        let layoutManager = MarkdownLayoutManager()
        layoutManager.theme = theme
        layoutManager.delegate = layoutManager
        storage.addLayoutManager(layoutManager)

        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let textView = MarkdownTextView(frame: .zero, textContainer: container)
        textView.delegate = coordinator
        textView.isRichText = false
        textView.allowsUndo = true
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
        textView.textContainerInset = CGSize(width: 24, height: 28)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = CGSize(width: 0, height: 0)
        textView.maxSize = CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textStorage?.setAttributedString(NSAttributedString(string: text))

        textView.onCheckboxToggle = { [weak coordinator] range in
            coordinator?.toggleCheckbox(in: range, textView: textView)
        }
        textView.onLinkActivated = { destination in
            guard let url = URL(string: destination), url.scheme != nil else { return }
            NSWorkspace.shared.open(url)
        }

        coordinator.textView = textView
        coordinator.layoutManager = layoutManager
        coordinator.theme = theme
        coordinator.documentDirectory = documentDirectory
        coordinator.observeCommands()
        coordinator.restyle(force: true)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = theme.background
        scrollView.automaticallyAdjustsContentInsets = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.documentDirectory = documentDirectory
        guard let textView = coordinator.textView else { return }

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

/// Live document statistics shown in the toolbar.
struct EditorStatus: Equatable {
    var words: Int = 0
    var characters: Int = 0
    /// Headings in document order, for the outline sidebar.
    var outline: [OutlineItem] = []
}

struct OutlineItem: Equatable, Identifiable {
    let id: Int
    let level: Int
    let title: String
    let location: Int
}

/// Owns the parse → style → conceal cycle for one editor.
final class EditorCoordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
    @Binding private var text: String
    private let onSelectionChange: ((EditorStatus) -> Void)?

    weak var textView: MarkdownTextView?
    weak var layoutManager: MarkdownLayoutManager?
    var theme = EditorTheme()
    var documentDirectory: URL?

    private let engine = StyleEngine()
    private var layout = MarkdownLayout()
    private var activeRanges: [NSRange] = []
    private var restyleWorkItem: DispatchWorkItem?
    /// Guards against re-entrancy while the styler writes attributes.
    private var isStyling = false

    init(text: Binding<String>, onSelectionChange: ((EditorStatus) -> Void)?) {
        self._text = text
        self.onSelectionChange = onSelectionChange
    }

    // MARK: Text changes

    func textDidChange(_ notification: Notification) {
        guard let textView else { return }
        text = textView.string
        scheduleRestyle()
    }

    /// Coalesces bursts of typing into one parse. Parsing is fast; the expense is the
    /// attribute churn it triggers, so it is worth batching.
    private func scheduleRestyle() {
        restyleWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.restyle() }
        restyleWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    func restyle(force: Bool = false) {
        guard let textView, let layoutManager, !isStyling else { return }
        // Restyling during marked text would tear down an in-progress IME composition.
        guard !textView.hasMarkedText() || force else { return }
        guard let storage = textView.textStorage else { return }

        isStyling = true
        defer { isStyling = false }

        layout = engine.layout(for: textView.string)
        activeRanges = layout.activeBlockRanges(for: textView.selectedRange())

        MarkdownStyler(theme: theme).apply(layout: layout, to: storage, activeRanges: activeRanges)
        applyConcealment()
        publishStatus()
    }

    /// Recomputes which markers are collapsed and repaints the affected paragraphs.
    private func applyConcealment() {
        guard let textView, let layoutManager, let storage = textView.textStorage else { return }

        let concealed = layout.concealedMarkers(selection: textView.selectedRange()).map(\.range)
        let painted = layout.markers.filter { marker in
            switch marker.presentation {
            case .bullet, .checkbox:
                return !activeRanges.contains { NSIntersectionRange($0, marker.range).length > 0 }
            case .hidden, .dimmed:
                return false
            }
        }

        layoutManager.setConcealedRanges(concealed)
        layoutManager.paintedMarkers = painted
        layoutManager.blocks = layout.blocks
        textView.paintedMarkers = painted

        // Glyph generation has already happened for existing text, so it must be redone for
        // the concealment change to take effect.
        let full = NSRange(location: 0, length: storage.length)
        layoutManager.invalidateGlyphs(forCharacterRange: full, changeInLength: 0, actualCharacterRange: nil)
        layoutManager.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
        textView.needsDisplay = true
    }

    // MARK: Selection

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView, !isStyling else { return }
        let newActive = layout.activeBlockRanges(for: textView.selectedRange())
        guard newActive != activeRanges else { return }

        // The caret moved into a different block: re-reveal without a full reparse.
        activeRanges = newActive
        isStyling = true
        if let storage = textView.textStorage {
            MarkdownStyler(theme: theme).apply(layout: layout, to: storage, activeRanges: activeRanges)
        }
        isStyling = false
        applyConcealment()
    }

    // MARK: Commands

    /// Menu commands reach the focused editor through notifications, which keeps the text
    /// view out of SwiftUI's state graph.
    func observeCommands() {
        NotificationCenter.default.addObserver(
            forName: .markpadFormatting,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let textView = self.textView, textView.window?.isKeyWindow == true,
                  let action = notification.object as? FormattingAction else { return }
            if let wrapper = action.wrapper {
                textView.toggleWrap(wrapper)
            } else {
                textView.makeLink()
            }
            self.text = textView.string
            self.restyle(force: true)
        }

        NotificationCenter.default.addObserver(
            forName: .markpadScrollToLocation,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let textView = self.textView, textView.window?.isKeyWindow == true,
                  let location = notification.userInfo?["location"] as? Int else { return }
            let target = NSRange(location: min(location, (textView.string as NSString).length), length: 0)
            textView.setSelectedRange(target)
            textView.scrollRangeToVisible(target)
        }
    }

    // MARK: Actions

    func toggleCheckbox(in range: NSRange, textView: MarkdownTextView) {
        guard let storage = textView.textStorage, NSMaxRange(range) <= storage.length else { return }
        let current = (storage.string as NSString).substring(with: range)
        let replacement = current.lowercased().contains("x") ? "[ ]" : "[x]"
        guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
        storage.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        text = textView.string
        restyle(force: true)
    }

    private func publishStatus() {
        guard let onSelectionChange, let textView else { return }
        // Styling can run inside a SwiftUI view update; publishing on the next runloop pass
        // keeps the status change out of that update.
        let status = currentStatus(textView: textView)
        DispatchQueue.main.async { onSelectionChange(status) }
    }

    private func currentStatus(textView: MarkdownTextView) -> EditorStatus {
        let string = textView.string
        let words = string.split { $0.isWhitespace || $0.isNewline }.count

        let outline = layout.blocks.enumerated().compactMap { index, block -> OutlineItem? in
            guard case let .heading(level) = block.kind,
                  NSMaxRange(block.range) <= (string as NSString).length else { return nil }
            let raw = (string as NSString).substring(with: block.range)
            let title = raw.drop { $0 == "#" || $0 == " " }.trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return nil }
            return OutlineItem(id: index, level: level, title: title, location: block.range.location)
        }

        return EditorStatus(
            words: words,
            characters: (string as NSString).length,
            outline: outline
        )
    }
}
