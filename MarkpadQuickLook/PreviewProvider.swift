import Foundation
import MarkpadCore
// On macOS the preview-extension types live in QuickLookUI; QuickLook itself carries only
// the older, document-side API.
import QuickLookUI

/// Renders Markdown files for Quick Look, so pressing Space in the Finder shows a formatted
/// document rather than raw text.
///
/// The preview is produced by the same `HTMLExporter` the app uses for export, so what the
/// Finder shows matches what Markpad produces. Local images are inlined as data URIs because
/// the preview cannot reach sibling files on disk.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        let markdown = try readMarkdown(at: url)
        let directory = url.deletingLastPathComponent()
        let title = url.deletingPathExtension().lastPathComponent

        let html = HTMLExporter().export(
            markdown: markdown,
            options: .init(
                standalone: true,
                title: title,
                theme: .default,
                imageResolver: { source in DataURI.inline(source: source, relativeTo: directory) }
            )
        )

        let reply = QLPreviewReply(
            dataOfContentType: .html,
            contentSize: CGSize(width: 800, height: 1000)
        ) { _ in
            Data(html.utf8)
        }
        reply.title = title
        reply.stringEncoding = .utf8
        return reply
    }

    private func readMarkdown(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .isoLatin1) { return text }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }
}
