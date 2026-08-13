import Foundation

/// Produces the HTML shown by the Quick Look preview.
///
/// It lives here, rather than inside the extension, so the preview's behaviour is covered by
/// the test suite — an app extension's own entry point cannot be invoked from a test, since
/// its request type has no public initialiser.
public enum PreviewRenderer {
    public struct Preview: Sendable {
        public let html: String
        public let title: String
    }

    public static func preview(forFileAt url: URL, theme: MarkdownTheme = .default) throws -> Preview {
        let markdown = try readText(at: url)
        let title = url.deletingPathExtension().lastPathComponent
        let directory = url.deletingLastPathComponent()

        let html = HTMLExporter().export(
            markdown: markdown,
            options: .init(
                standalone: true,
                title: title,
                theme: theme,
                // A preview runs sandboxed and cannot reach sibling files, so referenced
                // images have to travel inside the document.
                imageResolver: { source in DataURI.inline(source: source, relativeTo: directory) },
                // Quick Look renders files the user only selected, never opened, so embedded
                // markup is shown as text rather than executed.
                allowsRawHTML: false
            )
        )
        return Preview(html: html, title: title)
    }

    /// Markdown is UTF-8 by convention; a legacy encoding still previews rather than failing.
    static func readText(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .isoLatin1) { return text }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }
}
