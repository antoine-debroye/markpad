import AppKit
import Foundation
import UniformTypeIdentifiers

/// Converts rich text documents into Markdown: RTF, RTFD, legacy Word (`.doc`) and
/// OpenDocument text (`.odt`).
///
/// AppKit's own readers do the decoding — they are the ones TextEdit uses, so a file that opens
/// there converts here — and `RichTextWalker` turns the attributed string into Markdown blocks.
/// The document type is always passed explicitly: letting AppKit guess could pick its HTML
/// reader, which needs WebKit on the main thread, and conversions run on a worker.
public struct RichTextImporter: Sendable {
    public init() {}

    public func convert(
        url: URL,
        options: DocumentImportOptions = .init(),
        progress: ImportProgress.Handler? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> ImportedMarkdown {
        let reporter = ImportReporter(totalUnits: 1, handler: progress, isCancelled: isCancelled)
        try reporter.checkCancellation()
        reporter.report(.reading, index: 0)

        guard let documentType = Self.documentType(for: url) else {
            throw ConversionError.unsupportedInput(url)
        }
        let attributed: NSAttributedString
        do {
            attributed = try NSAttributedString(
                url: url,
                options: [.documentType: documentType],
                documentAttributes: nil
            )
        } catch {
            throw ConversionError.unreadableFile(url)
        }

        try reporter.checkCancellation()
        reporter.report(.extractingText, index: 0)
        let collector = AssetCollector(folderName: options.assetFolderName)
        let blocks = try RichTextWalker(attributed: attributed, assets: collector, reporter: reporter).blocks()

        try reporter.checkCancellation()
        reporter.reportAssembling()
        let markdown = MarkdownRenderer.render(blocks)
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConversionError.noTextFound(url)
        }
        reporter.reportFinished()
        return ImportedMarkdown(markdown: markdown, assets: collector.assets)
    }

    /// The reader for a file, from its extension, corrected by its first bytes: plenty of
    /// `.doc` files are really RTF (older apps saved RTF under that name) or a renamed `.docx`.
    static func documentType(for url: URL) -> NSAttributedString.DocumentType? {
        let ext = url.pathExtension.lowercased()
        if ext == "rtfd" { return .rtfd }

        var head = Data()
        if let handle = try? FileHandle(forReadingFrom: url) {
            head = (try? handle.read(upToCount: 8)) ?? Data()
            try? handle.close()
        }
        if head.starts(with: Array("{\\rtf".utf8)) { return .rtf }
        switch ext {
        case "rtf": return .rtf
        case "odt": return .openDocument
        case "doc":
            return head.starts(with: [0x50, 0x4B, 0x03, 0x04]) ? .officeOpenXML : .docFormat
        default: return nil
        }
    }
}
