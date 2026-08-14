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
        // No implicit padding: table columns are positioned from the line's own origin, so
        // the text must start exactly at the container edge.
        container.lineFragmentPadding = 0
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
        textView.onAppearanceChange = { [weak coordinator] in
            textView.backgroundColor = theme.background
            textView.insertionPointColor = theme.text
            coordinator?.restyle(force: true)
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
        // Table columns are measured against the available width, so the first styling pass
        // waits until the view has been given its real size.
        DispatchQueue.main.async { coordinator.restyle(force: true) }

        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: textView,
            queue: .main
        ) { [weak coordinator] _ in
            coordinator?.reflowTables()
        }

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
    private let imageStore = ImageStore()
    private var layout = MarkdownLayout()
    private var activeRanges: [NSRange] = []
    private var restyleWorkItem: DispatchWorkItem?
    /// Guards against re-entrancy while the styler writes attributes.
    private var isStyling = false
    /// Width prose wraps at when the container has been widened for a table. Nil when the
    /// container matches the window, which is the usual case.
    private var wrapWidth: CGFloat?

    private var styler: MarkdownStyler {
        MarkdownStyler(theme: theme, wrapWidth: wrapWidth)
    }

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

        styler.apply(layout: layout, to: storage, activeRanges: activeRanges)
        buildTableGeometry()

        // Whether prose needs a wrap limit depends on how wide the tables turned out, so the
        // paragraph styles are settled in a second pass on the rare occasions it changes.
        let previousWrap = wrapWidth
        applyContentWidth()
        if wrapWidth != previousWrap {
            styler.apply(layout: layout, to: storage, activeRanges: activeRanges)
            buildTableGeometry()
        }

        prepareImages()
        applyConcealment()
        publishStatus()
    }

    /// Starts loading the pictures the document refers to, and drops any it no longer uses.
    private func prepareImages() {
        guard let textView, let layoutManager else { return }
        imageStore.documentDirectory = documentDirectory
        imageStore.onLoad = { [weak self] in
            // A picture that has just loaded changes the height of its line.
            self?.reflowImages()
        }
        imageStore.retain(sources: layout.images.map(\.source))
        for placement in layout.images {
            imageStore.prepare(placement.source)
        }

        layoutManager.imageStore = imageStore
        let width = textView.textContainer?.size.width ?? textView.bounds.width
        layoutManager.contentWidth = width

        // A picture replaces its syntax only once it has actually loaded, and only when the
        // caret is elsewhere. An image that is still loading, missing or unreadable keeps
        // its Markdown visible rather than leaving a blank gap in the document.
        layoutManager.images = layout.images.filter { placement in
            guard imageStore.entry(for: placement.source, availableWidth: width) != nil else { return false }
            return !activeRanges.contains { NSIntersectionRange($0, placement.range).length > 0 }
        }
    }

    /// Re-resolves every image, used when the document's folder becomes known.
    func reloadImages() {
        guard !layout.images.isEmpty else { return }
        reflowImages()
    }

    /// Re-runs image placement after one finishes loading or the window resizes.
    private func reflowImages() {
        guard let textView, let layoutManager, let storage = textView.textStorage, !isStyling else { return }
        isStyling = true
        prepareImages()
        isStyling = false
        applyConcealment()
        _ = layoutManager
        _ = storage
    }

    /// Re-measures tables after a resize. Column widths depend on the window, and a table
    /// that did not fit before may fit now (or the reverse).
    func reflowTables() {
        guard !layout.tables.isEmpty, !isStyling else { return }
        isStyling = true
        buildTableGeometry()
        isStyling = false
        applyConcealment()
    }

    /// Measures each table that should be drawn as a grid.
    ///
    /// A table the caret is inside stays as raw source so it can be edited, and one too wide
    /// for the window is left as aligned text rather than drawn as a broken grid.
    private func buildTableGeometry() {
        guard let textView, let layoutManager, let storage = textView.textStorage else { return }
        // The container already excludes the view's inset when it tracks the view's width.
        let available = textView.textContainer?.size.width
            ?? (textView.bounds.width - textView.textContainerInset.width * 2)

        let styler = self.styler
        var geometries: [TableGeometry] = []

        for structure in layout.tables {
            let isActive = activeRanges.contains { NSIntersectionRange($0, structure.range).length > 0 }
            guard !isActive else { continue }

            let geometry = TableGeometry(
                structure: structure,
                storage: storage,
                availableWidth: max(visibleWidth, 120),
                theme: theme
            )
            styler.applyTable(structure, scale: geometry.scale, to: storage)
            geometries.append(geometry)
        }
        layoutManager.tables = geometries
        _ = available
    }

    /// Width of the editor's visible text area, ignoring any horizontal overflow.
    private var visibleWidth: CGFloat {
        guard let textView else { return 600 }
        let scrollWidth = textView.enclosingScrollView?.contentSize.width ?? textView.bounds.width
        return max(scrollWidth - textView.textContainerInset.width * 2, 120)
    }

    /// Widens the text container when a table overflows, so it can be reached by scrolling
    /// sideways. Prose keeps wrapping at the visible width via `wrapWidth`, so widening the
    /// container for one table does not stretch every paragraph across it.
    private func applyContentWidth() {
        guard let textView,
              let container = textView.textContainer,
              let scrollView = textView.enclosingScrollView else { return }

        let visible = visibleWidth
        let widest = layoutManager?.tables.filter { !$0.fitsAvailableWidth }.map(\.width).max() ?? 0
        let needed = max(widest, visible)
        let overflows = needed > visible + 1

        wrapWidth = overflows ? visible : nil
        scrollView.hasHorizontalScroller = overflows

        if overflows {
            container.widthTracksTextView = false
            container.size = CGSize(width: needed, height: CGFloat.greatestFiniteMagnitude)
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = [.height]
            textView.minSize = CGSize(width: needed, height: 0)
            var frame = textView.frame
            frame.size.width = needed + textView.textContainerInset.width * 2
            textView.frame = frame
        } else if !container.widthTracksTextView {
            container.widthTracksTextView = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.minSize = CGSize(width: 0, height: 0)
            var frame = textView.frame
            frame.size.width = scrollView.contentSize.width
            textView.frame = frame
            container.size = CGSize(width: visible, height: CGFloat.greatestFiniteMagnitude)
        }
    }

    /// Recomputes which markers are collapsed and repaints the affected paragraphs.
    private func applyConcealment() {
        guard let textView, let layoutManager, let storage = textView.textStorage else { return }

        var concealed = layout.concealedMarkers(selection: textView.selectedRange()).map(\.range)
        // A table drawn as a grid hides its separator line; the pipes are handled as column
        // gaps rather than concealed, so they are excluded here.
        let delimiters = Set(layoutManager.tables.flatMap { $0.structure.delimiters.map(\.location) })
        concealed.removeAll { delimiters.contains($0.location) }
        for table in layoutManager.tables {
            if let separator = table.structure.separatorRange {
                concealed.append(separator)
            }
        }
        // An image's syntax collapses behind the picture, except for the first character,
        // which is the box the picture is drawn into.
        for placement in layoutManager.images where placement.range.length > 1 {
            concealed.append(NSRange(
                location: placement.range.location + 1,
                length: placement.range.length - 1
            ))
        }
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
