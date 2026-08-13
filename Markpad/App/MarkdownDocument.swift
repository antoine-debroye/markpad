import MarkpadCore
import SwiftUI
import UniformTypeIdentifiers

/// A Markdown file open in the editor.
///
/// A reference document keeps a single string that the text view edits in place, so typing
/// does not rebuild a value type on every keystroke.
final class MarkdownDocument: ReferenceFileDocument {
    typealias Snapshot = String

    @Published var text: String

    static var readableContentTypes: [UTType] { [.markpadMarkdown, .plainText] }
    static var writableContentTypes: [UTType] { [.markpadMarkdown, .plainText] }

    init(text: String = "") {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // Markdown is UTF-8 by convention; fall back so a legacy file still opens rather
        // than failing outright.
        if let text = String(data: data, encoding: .utf8) {
            self.text = text
        } else if let text = String(data: data, encoding: .isoLatin1) {
            self.text = text
        } else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
    }

    func snapshot(contentType: UTType) throws -> String { text }

    func fileWrapper(snapshot: String, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(snapshot.utf8))
    }
}
