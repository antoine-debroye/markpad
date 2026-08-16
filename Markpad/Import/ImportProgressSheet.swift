import SwiftUI

/// Progress for a PDF or image being converted to Markdown.
///
/// Used both as a sheet over a document window and, for Dock drops that arrive with no window
/// open, as the content of a standalone panel.
struct ImportProgressSheet: View {
    @ObservedObject var session: ImportSession

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import PDF or Image")
                .font(.headline)

            if let source = session.source {
                HStack(spacing: 12) {
                    Image(nsImage: source.icon)
                        .resizable()
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.titleText)
                            .font(.callout)
                        Text("→ Markdown")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                if let queue = session.queueText {
                    Text(queue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: session.fraction)
                    .progressViewStyle(.linear)
                HStack {
                    Text(session.statusText)
                    Spacer(minLength: 12)
                    // Monospaced digits stop the percentage jittering as it counts up.
                    Text(session.percentText).monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { session.cancel() }
                    .keyboardShortcut(.cancelAction)
            }

            Divider()

            Text(session.footerText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(width: 440)
        // Cancel is the only way out: dismissing by other means would leave the task running.
        .interactiveDismissDisabled()
    }
}
