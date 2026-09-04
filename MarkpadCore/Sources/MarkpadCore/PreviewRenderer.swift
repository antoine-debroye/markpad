import Foundation

/// Reads a Markdown file for the Quick Look preview.
///
/// It lives here, rather than inside the extension, so the reading is covered by the test
/// suite — an app extension's own entry point cannot be invoked from a test, since its
/// request type has no public initialiser. The preview's appearance is the editor's, drawn by
/// the same rendering stack the app uses.
public enum PreviewRenderer {
    /// Markdown is UTF-8 by convention; a legacy encoding still previews rather than failing.
    public static func markdown(forFileAt url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .isoLatin1) { return text }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }
}
