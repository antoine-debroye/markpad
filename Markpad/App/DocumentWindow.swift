import MarkpadCore
import SwiftUI

/// The editor window: outline sidebar, editing surface and status.
struct DocumentWindow: View {
    @ObservedObject var document: MarkdownDocument
    let fileURL: URL?

    @State private var status = EditorStatus()
    @State private var showOutline = false
    @State private var scrollTarget: Int?
    @State private var exportError: ExportError?

    var body: some View {
        HSplitView {
            if showOutline {
                OutlineSidebar(items: status.outline) { item in
                    NotificationCenter.default.post(
                        name: .markpadScrollToLocation,
                        object: nil,
                        userInfo: ["location": item.location]
                    )
                }
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
            }

            EditorView(
                text: $document.text,
                documentDirectory: fileURL?.deletingLastPathComponent(),
                onSelectionChange: { status = $0 }
            )
            .frame(minWidth: 420)
        }
        .focusedSceneValue(\.markdownDocument, FocusedDocument(document: document, fileURL: fileURL))
        // The count belongs to the document, not to a control: as a subtitle it sits under
        // the file name as plain text instead of being drawn as another button.
        .navigationSubtitle(status.words == 1 ? "1 word" : "\(status.words) words")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showOutline.toggle() }
                } label: {
                    Label("Outline", systemImage: "sidebar.left")
                }
                .help("Show or hide the document outline")
                .disabled(status.outline.isEmpty && !showOutline)
            }

            ToolbarItem(placement: .primaryAction) {
                ExportMenu(document: document, fileURL: fileURL, error: $exportError)
            }
        }
        .alert(item: $exportError) { error in
            Alert(
                title: Text("Export failed"),
                message: Text(error.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

struct ExportError: Identifiable {
    let id = UUID()
    let message: String
}

extension Notification.Name {
    static let markpadScrollToLocation = Notification.Name("markpad.scrollToLocation")
}

private struct OutlineSidebar: View {
    let items: [OutlineItem]
    let onSelect: (OutlineItem) -> Void

    var body: some View {
        List {
            if items.isEmpty {
                Text("No headings yet")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ForEach(items) { item in
                    Button {
                        onSelect(item)
                    } label: {
                        Text(item.title)
                            .lineLimit(1)
                            .font(item.level <= 2 ? .body.weight(.medium) : .callout)
                            .foregroundStyle(item.level <= 2 ? .primary : .secondary)
                            .padding(.leading, CGFloat(item.level - 1) * 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.sidebar)
    }
}
