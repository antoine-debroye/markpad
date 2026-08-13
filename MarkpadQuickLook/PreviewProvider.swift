import Foundation
import MarkpadCore
// On macOS the preview-extension types live in QuickLookUI; QuickLook itself carries only
// the older, document-side API.
import QuickLookUI

/// Renders Markdown files for Quick Look, so pressing Space in the Finder shows a formatted
/// document rather than raw text.
///
/// The preview is produced by the same exporter the app uses, so what the Finder shows
/// matches what Markpad writes. The rendering itself lives in `PreviewRenderer` where it can
/// be tested; this class is only the plumbing.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let preview = try PreviewRenderer.preview(forFileAt: request.fileURL)

        let reply = QLPreviewReply(
            dataOfContentType: .html,
            contentSize: CGSize(width: 800, height: 1000)
        ) { _ in
            Data(preview.html.utf8)
        }
        reply.title = preview.title
        reply.stringEncoding = .utf8
        return reply
    }
}
