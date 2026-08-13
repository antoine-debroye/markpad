import Foundation
import Markdown

/// One parsing configuration shared by every consumer — exporters, the editor styler and
/// Quick Look — so a document is interpreted identically wherever it is rendered.
public enum MarkdownParsing {
    /// Smart punctuation is disabled deliberately: cmark would rewrite `"` as typographic
    /// quotes, which silently changes the author's text on export and desynchronises the
    /// editor's rendered text from its source.
    public static let options: ParseOptions = [.parseBlockDirectives, .disableSmartOpts]

    public static func document(_ source: String) -> Document {
        Document(parsing: source, options: options)
    }
}
