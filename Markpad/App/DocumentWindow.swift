import MarkpadCore
import SwiftUI

/// The editor window: its own header, the outline sidebar and the editing surface.
///
/// The window draws its own chrome rather than using the system title bar, and the two designs
/// differ by appearance: light gets a header band, dark drops the band entirely and floats quiet
/// controls over the text with a status pill in the corner.
struct DocumentWindow: View {
    @ObservedObject var document: MarkdownDocument
    let fileURL: URL?

    @Environment(\.colorScheme) private var colorScheme

    @State private var status = EditorStatus()
    // Open by default, as the design shows it.
    @State private var showOutline = true
    @State private var exportError: ExportError?
    @State private var window: NSWindow?
    @State private var showRecents = false
    @StateObject private var importSession = ImportSession()

    private var isDark: Bool { colorScheme == .dark }
    private var palette: ChromePalette { ChromePalette(isDark: isDark) }
    private var title: String { fileURL?.lastPathComponent ?? "Untitled" }
    private var outlineDisabled: Bool { status.outline.isEmpty && !showOutline }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                if showOutline {
                    OutlineSidebar(items: status.outline, palette: palette) { item in
                        NotificationCenter.default.post(
                            name: .markpadScrollToLocation,
                            object: nil,
                            userInfo: ["location": item.location]
                        )
                    }
                    .frame(minWidth: 180, idealWidth: 210, maxWidth: 320)
                }

                EditorView(
                    text: $document.text,
                    documentDirectory: fileURL?.deletingLastPathComponent(),
                    onSelectionChange: { status = $0 }
                )
                .frame(minWidth: 420)
            }
        }
        .background(palette.background)
        // The dark design has no header band and shows the count as a floating pill instead.
        .overlay(alignment: .bottomTrailing) {
            if isDark { StatusPill(status: status, palette: palette) }
        }
        .toolbar { toolbarContent }
        .withoutToolbarTitle()
        // Light gets the design's gradient band. Dark has no band, but the background is painted
        // flat rather than hidden: hiding it lets the sidebar's colour show through on the left,
        // which splits the row into two tones. A flat fill keeps the top uniform, which is what
        // the dark design shows.
        .toolbarBackground(palette.toolbarBackground, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .toastOverlay(window: window)
        .onWindow { newWindow in
            window = newWindow
            guard let newWindow else { return }
            WindowChrome.apply(to: newWindow)
            WindowTabbing.adopt(newWindow)
        }
        .sheet(isPresented: Binding(
            get: { importSession.isRunning },
            // Only reachable via Cancel: the sheet disables interactive dismissal.
            set: { if !$0 { importSession.cancel() } }
        )) {
            ImportProgressSheet(session: importSession)
        }
        .onDisappear { importSession.cancel() }
        // Every open path — Finder, Open Recent, this panel, a Dock-drop conversion — ends in a
        // window with a file URL, so this is where "when was it opened" gets recorded.
        .task(id: fileURL) {
            if let fileURL { RecentDocuments.noteOpened(fileURL) }
            // The document machinery re-sets the represented URL whenever it changes, which
            // brings the proxy icon back on top of the header.
            if let window { WindowChrome.clearProxyIcon(on: window) }
        }
        .focusedSceneValue(\.recentsPresentation, $showRecents)
        .focusedSceneValue(
            \.markdownDocument,
            FocusedDocument(document: document, fileURL: fileURL, importSession: importSession)
        )
        .alert(item: $exportError) { error in
            Alert(
                title: Text("Export failed"),
                message: Text(error.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if #available(macOS 26.0, *) {
            items.sharedBackgroundVisibility(.hidden)
        } else {
            items
        }
    }

    /// The header's controls.
    ///
    /// macOS 26 gives every toolbar item a shared "glass" background. The design's band is flat,
    /// with borders only on the controls that have them, so that background is turned off and
    /// each control draws its own.
    @ToolbarContentBuilder
    private var items: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { outlineBinding.wrappedValue.toggle() } label: {
                OutlineGlyph(palette: palette, isOn: showOutline)
            }
            .buttonStyle(.plain)
            .disabled(outlineDisabled)
            .help("Show or hide the document outline")
        }

        ToolbarItem(placement: .navigation) {
            Button { showRecents.toggle() } label: {
                ChromePill(palette: palette, isActive: showRecents) {
                    HStack(spacing: 5) {
                        Image(systemName: "clock")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.secondary)
                        // Labelled in both appearances: the dark design gives Export a text
                        // label too, so dropping this one made the two controls inconsistent.
                        Text("Recents")
                            .font(.system(size: 11.5))
                            .foregroundStyle(palette.controlText)
                    }
                }
            }
            .buttonStyle(.plain)
            .help("Recently opened documents")
            .popover(isPresented: $showRecents, arrowEdge: .bottom) {
                RecentsPanel(isPresented: $showRecents)
            }
        }

        // The file name sits centred in the band, with the word count beneath it. The dark
        // design shows the count in its floating pill instead, so the title stands alone.
        ToolbarItem(placement: .principal) {
            VStack(spacing: 0) {
                Text(title)
                    .font(.system(size: 13, weight: isDark ? .regular : .semibold))
                    .foregroundStyle(palette.title)
                if !isDark {
                    Text(status.wordsDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.secondary)
                }
            }
        }

        ToolbarItem(placement: .primaryAction) {
            ExportMenu(
                document: document,
                fileURL: fileURL,
                error: $exportError,
                importSession: importSession,
                hostWindow: window,
                palette: palette
            )
        }
    }

    private var outlineBinding: Binding<Bool> {
        Binding(
            get: { showOutline },
            set: { newValue in
                withAnimation(.easeInOut(duration: 0.15)) { showOutline = newValue }
            }
        )
    }

}

struct ExportError: Identifiable {
    let id = UUID()
    let message: String
}

extension Notification.Name {
    static let markpadScrollToLocation = Notification.Name("markpad.scrollToLocation")
}

/// The outline, drawn as the design's flat panel rather than a system sidebar.
private struct OutlineSidebar: View {
    let items: [OutlineItem]
    let palette: ChromePalette
    let onSelect: (OutlineItem) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if items.isEmpty {
                    Text("No headings yet")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                } else {
                    ForEach(items) { item in
                        OutlineRow(item: item, palette: palette) { onSelect(item) }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(palette.isDark ? palette.controlFill : Color(nsColor: NSColor(hex: "#f4f4f6") ?? .windowBackgroundColor))
        .overlay(alignment: .trailing) {
            Rectangle().fill(palette.rule).frame(width: 1)
        }
    }
}

private struct OutlineRow: View {
    let item: OutlineItem
    let palette: ChromePalette
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(item.title)
                .font(.system(size: 13, weight: item.level <= 1 ? .medium : .regular))
                .foregroundStyle(item.level <= 1 ? palette.controlText : palette.secondary)
                .lineLimit(1)
                // Level 1 sits at 10, everything deeper steps in from 22, as the design draws it.
                .padding(.leading, item.level <= 1 ? 10 : CGFloat(22 + (item.level - 2) * 12))
                .padding(.trailing, 10)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovered ? palette.controlActive : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
