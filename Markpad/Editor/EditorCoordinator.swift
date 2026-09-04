import AppKit
import MarkpadCore

/// Selection rules shared by the editor and the read-only preview.
enum EditorReveal {
    /// Where the renderer should believe the caret is.
    ///
    /// A read-only host reports a location past the end of the document. `BlockRun.intersects`
    /// treats a zero-length selection at 0 as inside the first block, so without this a preview
    /// would show its opening heading as `# Title`.
    static func selection(isEditable: Bool, selected: NSRange, length: Int) -> NSRange {
        guard !isEditable else { return selected }
        return NSRange(location: length + 1000, length: 0)
    }
}

/// Live document statistics shown in the window chrome.
struct EditorStatus: Equatable {
    var words: Int = 0
    var characters: Int = 0
    /// Headings in document order, for the outline sidebar.
    var outline: [OutlineItem] = []

    /// Words per minute used for the reading estimate.
    ///
    /// 200 is the figure the design was drawn against — its "1,204 words · 6 min" only holds at
    /// this rate.
    static let wordsPerMinute = 200

    /// Minutes to read, never less than one for a document with any words in it.
    var readingMinutes: Int {
        guard words > 0 else { return 0 }
        return max(1, Int((Double(words) / Double(Self.wordsPerMinute)).rounded()))
    }

    /// "412 words", as the light chrome shows it.
    var wordsDescription: String {
        words == 1 ? "1 word" : "\(words.formatted(.number)) words"
    }

    /// "1,204 words · 6 min", as the dark chrome's floating pill shows it.
    var readingDescription: String {
        guard words > 0 else { return "No words yet" }
        return "\(wordsDescription) · \(readingMinutes) min"
    }
}

struct OutlineItem: Equatable, Identifiable {
    let id: Int
    let level: Int
    let title: String
    let location: Int
}
/// Owns the parse → style → conceal cycle for one editor.
///
/// Everything here touches the text view, so the whole type is main-actor bound rather than
/// hopping per call.
@MainActor
final class EditorCoordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
    /// Called when the editor changes the text, so the document can follow. Nil in a
    /// read-only host such as the Quick Look preview.
    private let onTextChange: ((String) -> Void)?
    private let onSelectionChange: ((EditorStatus) -> Void)?
    /// False for a preview: the document is shown, never edited.
    let isEditable: Bool
    /// Whether Mermaid diagrams are drawn as pictures.
    ///
    /// Off in the Quick Look preview: rendering them needs the bundled Mermaid library and a
    /// web view, neither of which the extension ships. Their source stays visible as a code
    /// block, which is what the preview showed before.
    let rendersDiagrams: Bool

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
    /// Notification registrations, kept so they can be removed when the editor goes away.
    private var observers: [NSObjectProtocol] = []
    /// Coalesces a burst of frame-change notifications into one deferred re-layout.
    private var hasPendingWidthReflow = false
    /// Width the editor was last laid out for, so an unchanged width does no work.
    private var lastReflowWidth: CGFloat = -1
    /// Width prose wraps at when the container has been widened for a table. Nil when the
    /// container matches the window, which is the usual case.
    private var wrapWidth: CGFloat?

    private var styler: MarkdownStyler {
        MarkdownStyler(theme: theme, wrapWidth: wrapWidth)
    }

    init(
        isEditable: Bool = true,
        rendersDiagrams: Bool = true,
        onTextChange: ((String) -> Void)? = nil,
        onSelectionChange: ((EditorStatus) -> Void)? = nil
    ) {
        self.isEditable = isEditable
        self.rendersDiagrams = rendersDiagrams
        self.onTextChange = onTextChange
        self.onSelectionChange = onSelectionChange
    }

    /// Selection the rendering treats as the caret.
    ///
    /// Raw syntax comes back for the block the caret is in, which is what makes the document
    /// editable in place. A preview has no caret to speak of, so it reports one past the end
    /// of the document: every block then stays rendered, including the first, which a plain
    /// zero-length selection at 0 would otherwise expand.
    var revealSelection: NSRange {
        guard let textView else { return EditorReveal.selection(isEditable: isEditable, selected: .init(location: 0, length: 0), length: 0) }
        return EditorReveal.selection(
            isEditable: isEditable,
            selected: textView.selectedRange(),
            length: (textView.string as NSString).length
        )
    }

    // MARK: Text changes

    func textDidChange(_ notification: Notification) {
        guard let textView else { return }
        onTextChange?(textView.string)
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
        activeRanges = layout.activeBlockRanges(for: revealSelection)

        // Before anything reads a width: `buildTableGeometry` below measures against the inset,
        // and `applyContentWidth` runs too late to correct it — its second styling pass only
        // fires when `wrapWidth` happens to change, which it usually does not.
        applyMeasureInset()

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

        // Pictures fit the text column rather than the window, so they sit with the prose.
        let width = measureWidth
        layoutManager.contentWidth = width

        let isDark = textView.effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let renderer = rendersDiagrams ? MermaidRenderer.shared : nil
        renderer?.onRender = { [weak self] in self?.reflowImages() }
        renderer?.retain(sources: layout.diagrams.map(\.source), dark: isDark)
        for diagram in layout.diagrams {
            renderer?.prepare(diagram.source, dark: isDark)
        }

        func isActive(_ range: NSRange) -> Bool {
            activeRanges.contains { NSIntersectionRange($0, range).length > 0 }
        }

        // A picture replaces its syntax only once it is actually available, and only when
        // the caret is elsewhere. Anything still loading, missing or unreadable keeps its
        // Markdown visible rather than leaving a blank gap in the document.
        var artworks: [MarkdownLayoutManager.Artwork] = []

        for placement in layout.images where !isActive(placement.range) {
            guard let entry = imageStore.entry(for: placement.source, availableWidth: width) else { continue }
            artworks.append(.init(range: placement.range, image: entry.image, size: entry.displaySize))
        }

        for placement in layout.diagrams where !isActive(placement.range) {
            guard let diagram = renderer?.diagram(for: placement.source, dark: isDark) else { continue }
            artworks.append(.init(
                range: placement.range,
                image: diagram.image,
                size: Self.fit(diagram.size, within: width)
            ))
        }

        layoutManager.artworks = artworks.sorted { $0.range.location < $1.range.location }
    }

    /// Scales a picture down to the available width, never up.
    private static func fit(_ size: CGSize, within width: CGFloat) -> CGSize {
        guard size.width > width, size.width > 0 else { return size }
        return CGSize(width: width, height: size.height * width / size.width)
    }

    /// Re-resolves every image, used when the document's folder becomes known.
    func reloadImages() {
        guard !layout.images.isEmpty else { return }
        reflowImages()
    }

    /// Re-runs image placement after one finishes loading or the window resizes.
    private func reflowImages() {
        guard !isStyling else { return }
        isStyling = true
        prepareImages()
        isStyling = false
        applyConcealment()
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

    /// Re-lays out after the window changes width.
    ///
    /// Deliberately not `reflowTables()`, which returns immediately when the document has no
    /// tables — a plain prose document would then never re-centre. Pictures were also never
    /// re-fitted on resize, which this fixes on the way past.
    func reflowForWidthChange() {
        guard !isStyling else { return }
        isStyling = true
        applyContentWidth()
        if !layout.tables.isEmpty { buildTableGeometry() }
        if !layout.images.isEmpty || !layout.diagrams.isEmpty { prepareImages() }
        isStyling = false
        applyConcealment()
    }

    /// Measures each table that should be drawn as a grid.
    ///
    /// A table the caret is inside stays as raw source so it can be edited, and one too wide
    /// for the window is left as aligned text rather than drawn as a broken grid.
    private func buildTableGeometry() {
        guard let textView, let layoutManager, let storage = textView.textStorage else { return }
        let styler = self.styler
        var geometries: [TableGeometry] = []

        for structure in layout.tables {
            let isActive = activeRanges.contains { NSIntersectionRange($0, structure.range).length > 0 }
            guard !isActive else { continue }

            // Measured against the window, not the text column. Measuring against the column
            // would push every table between the measure and the window width down the
            // shrink-to-fit ladder, quietly reducing table font size on wide windows.
            let geometry = TableGeometry(
                structure: structure,
                storage: storage,
                availableWidth: availableWidth,
                stretchWidth: measureWidth,
                theme: theme
            )
            styler.applyTable(structure, scale: geometry.scale, to: storage)
            geometries.append(geometry)
        }
        layoutManager.tables = geometries
    }

    /// Width of the window's text area, before the centring margin is taken out.
    ///
    /// Deliberately derived from the scroll view rather than from `textContainerInset`: the inset
    /// is computed *from* this, so reading it back here would make the two define each other and
    /// the layout would never settle.
    private var availableWidth: CGFloat {
        guard let textView else { return 600 }
        let scrollWidth = textView.enclosingScrollView?.contentSize.width ?? textView.bounds.width
        return max(scrollWidth - EditorMetrics.gutter * 2, EditorMetrics.minimumMeasure)
    }

    /// Width prose, pictures and diagrams are laid out at.
    private var measureWidth: CGFloat {
        min(theme.contentWidth, availableWidth)
    }

    /// Centres the text column by adjusting the container inset.
    ///
    /// Called before anything reads a width, from both `restyle()` and the resize path.
    @discardableResult
    private func applyMeasureInset() -> EditorMetrics {
        let frameWidth = textView?.enclosingScrollView?.contentSize.width ?? 0
        let widest = layoutManager?.tables.map(\.width).max() ?? 0
        let metrics = EditorMetrics(
            frameWidth: frameWidth,
            contentWidth: theme.contentWidth,
            widestTable: widest
        )

        if let textView, abs(textView.textContainerInset.width - metrics.horizontalInset) > 0.5 {
            textView.textContainerInset = CGSize(
                width: metrics.horizontalInset,
                height: EditorMetrics.verticalInset
            )
        }
        return metrics
    }

    /// Widens the text container when a table overflows, so it can be reached by scrolling
    /// sideways. Prose keeps wrapping at the visible width via `wrapWidth`, so widening the
    /// container for one table does not stretch every paragraph across it.
    private func applyContentWidth() {
        guard let textView,
              let container = textView.textContainer,
              let scrollView = textView.enclosingScrollView else { return }

        let metrics = applyMeasureInset()

        wrapWidth = metrics.wrapWidth
        scrollView.hasHorizontalScroller = metrics.overflows

        if metrics.overflows {
            container.widthTracksTextView = false
            setContainerWidth(metrics.containerWidth, on: container)
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = [.height]
            textView.minSize = CGSize(width: metrics.documentWidth, height: 0)
            setFrameWidth(metrics.documentWidth, on: textView)
        } else {
            if !container.widthTracksTextView {
                container.widthTracksTextView = true
                textView.isHorizontallyResizable = false
                textView.autoresizingMask = [.width]
                textView.minSize = CGSize(width: 0, height: 0)
            }
            // The text view keeps filling the scroll view, so the background reaches both edges;
            // only the container inside it narrows.
            setFrameWidth(scrollView.contentSize.width, on: textView)
            setContainerWidth(metrics.containerWidth, on: container)
        }
    }

    /// Resizes the text view only when the width actually changes.
    ///
    /// This is what stops the width logic spinning. Setting the frame posts
    /// `frameDidChangeNotification`, which is the notification that calls back into
    /// `reflowForWidthChange()` — so an unconditional write re-triggers itself forever. A
    /// document with a table wide enough to take the overflow branch pinned the app at 100% CPU.
    private func setFrameWidth(_ width: CGFloat, on textView: NSTextView) {
        guard abs(textView.frame.width - width) > 0.5 else { return }
        var frame = textView.frame
        frame.size.width = width
        textView.frame = frame
    }

    private func setContainerWidth(_ width: CGFloat, on container: NSTextContainer) {
        guard abs(container.size.width - width) > 0.5 else { return }
        container.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
    }

    /// Recomputes which markers are collapsed and repaints the affected paragraphs.
    private func applyConcealment() {
        guard let textView, let layoutManager, let storage = textView.textStorage else { return }

        var concealed = layout.concealedMarkers(selection: revealSelection).map(\.range)
        // A table drawn as a grid hides its separator line; the pipes are handled as column
        // gaps rather than concealed, so they are excluded here.
        let delimiters = Set(layoutManager.tables.flatMap { $0.structure.delimiters.map(\.location) })
        concealed.removeAll { delimiters.contains($0.location) }
        for table in layoutManager.tables {
            if let separator = table.structure.separatorRange {
                concealed.append(separator)
            }
        }
        // A picture's syntax collapses behind it, except for the first character, which is
        // the box the picture is drawn into.
        for artwork in layoutManager.artworks where artwork.range.length > 1 {
            concealed.append(NSRange(
                location: artwork.range.location + 1,
                length: artwork.range.length - 1
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
        let newActive = layout.activeBlockRanges(for: revealSelection)
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

    /// Watches `name` on `object` and re-lays out when the width changes.
    func observe(_ name: Notification.Name, from object: AnyObject) {
        observers.append(NotificationCenter.default.addObserver(
            forName: name,
            object: object,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleWidthReflow()
        })
    }

    /// Re-lays out for a new width on the next runloop pass.
    ///
    /// Never synchronously: a notification delivered to `.main` while already on the main
    /// thread runs inline, and these frame changes arrive *during* the window's constraints
    /// pass. Resizing the text view from inside that pass invalidates constraints while AppKit
    /// is updating them, which throws — the app crashed at launch on
    /// `_postWindowNeedsUpdateConstraints`. Deferring also coalesces the burst of notifications
    /// a single resize produces into one pass.
    private func scheduleWidthReflow() {
        guard !hasPendingWidthReflow else { return }
        hasPendingWidthReflow = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasPendingWidthReflow = false

            // Only act on an actual change of width. Re-laying out itself invalidates layout
            // and posts more frame-change notifications; deferring them past the `isStyling`
            // re-entrancy guard means each one would start another pass, which spins the app at
            // 100% CPU. Comparing the width is what terminates the cycle.
            let width = self.textView?.enclosingScrollView?.contentSize.width ?? 0
            guard abs(width - self.lastReflowWidth) > 0.5 else { return }
            self.lastReflowWidth = width
            self.reflowForWidthChange()
        }
    }

    /// Drops every registration. Without this each closed document left its observers behind:
    /// they no-op, because they hold the coordinator weakly and check for the key window, but
    /// they accumulate for the lifetime of the process.
    func stopObserving() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Menu commands reach the focused editor through notifications, which keeps the text
    /// view out of SwiftUI's state graph.
    func observeCommands() {
        guard isEditable else { return }
        observers.append(NotificationCenter.default.addObserver(
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
            self.onTextChange?(textView.string)
            self.restyle(force: true)
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .markpadScrollToLocation,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let textView = self.textView, textView.window?.isKeyWindow == true,
                  let location = notification.userInfo?["location"] as? Int else { return }
            let target = NSRange(location: min(location, (textView.string as NSString).length), length: 0)
            textView.setSelectedRange(target)
            textView.scrollRangeToVisible(target)
        })
    }

    // MARK: Actions

    func toggleCheckbox(in range: NSRange, textView: MarkdownTextView) {
        guard let storage = textView.textStorage, NSMaxRange(range) <= storage.length else { return }
        let current = (storage.string as NSString).substring(with: range)
        let replacement = current.lowercased().contains("x") ? "[ ]" : "[x]"
        guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
        storage.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        onTextChange?(textView.string)
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
