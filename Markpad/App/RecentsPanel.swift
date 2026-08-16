import AppKit
import SwiftUI

/// The Recents popover: documents grouped into Today and Earlier.
struct RecentsPanel: View {
    @Binding var isPresented: Bool

    // Held here rather than in the window, because recents change while the app runs and the
    // list should be current each time the popover opens.
    @State private var sections: [(section: RecentSection, items: [RecentDocument])] = []
    @State private var missing: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if sections.isEmpty {
                Text("No recent documents")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            } else {
                ForEach(sections, id: \.section) { group in
                    Text(group.section.rawValue.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .kerning(0.5)
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                        .padding(.bottom, 3)

                    ForEach(group.items) { item in
                        RecentRow(item: item) { open(item) }
                    }
                }
            }

            Divider().padding(.vertical, 5)

            HStack {
                Text("⌘⇧R to open")
                Spacer()
                Button("Clear Recents") {
                    RecentDocuments.clear()
                    reload()
                }
                .buttonStyle(.link)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        .frame(width: 320)
        .onAppear(perform: reload)
        .alert("The file can't be found", isPresented: .constant(missing != nil)) {
            Button("OK") { missing = nil }
        } message: {
            Text("\(missing?.lastPathComponent ?? "The document") may have been moved, renamed or deleted.")
        }
    }

    private func reload() {
        sections = RecentDocuments.sections()
    }

    private func open(_ item: RecentDocument) {
        // Dismissed first, so the popover does not linger over the newly opened tab.
        isPresented = false
        RecentDocuments.open(item) { url in
            missing = url
            reload()
        }
    }
}

private struct RecentRow: View {
    let item: RecentDocument
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                    .resizable()
                    .frame(width: 16, height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .font(.callout)
                        .lineLimit(1)
                    Text(item.directory)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(RecentDateFormatter.label(for: item.opened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovered ? Color.accentColor.opacity(0.12) : .clear)
                    .padding(.horizontal, 5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
