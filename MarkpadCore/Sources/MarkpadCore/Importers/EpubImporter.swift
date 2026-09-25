import Foundation

/// Converts EPUB books into Markdown.
///
/// Each document in the spine is converted in reading order, one after another with nothing
/// added between them: chapters carry their own headings, and one without a heading is not
/// given an invented one. The book's title leads only when the first document has no
/// top-level heading of its own. Books with DRM cannot be read and are reported as protected.
public struct EpubImporter: Sendable {
    public init() {}

    public func convert(
        url: URL,
        options: DocumentImportOptions = .init(),
        progress: ImportProgress.Handler? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> ImportedMarkdown {
        if isCancelled() { throw ConversionError.cancelled }

        let reader: ZipReader
        let package: EpubPackage
        do {
            reader = try ZipReader(url: url)
            if try EpubPackage.isProtected(reader: reader) { throw ConversionError.passwordProtected(url) }
            package = try EpubPackage(reader: reader)
        } catch let error as ConversionError {
            throw error
        } catch {
            throw Self.map(error, url: url)
        }

        let documents = package.readingOrder
        var reporter = ImportReporter(totalUnits: max(documents.count, 1), handler: progress, isCancelled: isCancelled)
        reporter.unitKind = .chapter
        reporter.report(.reading, index: 0)

        let collector = AssetCollector(folderName: options.assetFolderName)
        var blocks: [MarkdownBlock] = []
        var notices: [String] = []
        var firstChapterHasTitle: Bool?

        for (index, document) in documents.enumerated() {
            try reporter.checkCancellation()
            reporter.report(.extractingText, index: index)
            let chapter: [MarkdownBlock]? = try autoreleasepool {
                let data: Data
                do {
                    if let entry = reader.entry(named: document.path), entry.flags & 0x1 != 0 {
                        throw ConversionError.passwordProtected(url)
                    }
                    guard let bytes = try reader.data(for: document.path) else { return nil }
                    data = bytes
                } catch let error as ConversionError {
                    throw error
                } catch {
                    throw Self.map(error, url: url)
                }
                guard let xhtml = HTMLDocumentLoader.load(data, preferXML: true) else { return nil }
                let walker = HTMLToMarkdown(
                    resolveImage: { source in
                        Self.resolveImage(source, in: document.path, reader: reader, collector: collector)
                    },
                    resolveLink: Self.resolveLink)
                walker.convert(xhtml)
                return walker.blocks
            }
            guard let chapter else {
                notices.append("“\((document.path as NSString).lastPathComponent)” could not be read and was left out.")
                continue
            }
            if firstChapterHasTitle == nil {
                firstChapterHasTitle = chapter.contains { if case .heading(1, _) = $0 { return true } else { return false } }
            }
            blocks += chapter
        }

        try reporter.checkCancellation()
        reporter.reportAssembling()
        // A title alone is not the book's text.
        guard !blocks.isEmpty else { throw ConversionError.noTextFound(url) }
        if let title = package.title, firstChapterHasTitle != true {
            blocks.insert(.heading(level: 1, [MarkdownRun(title)]), at: 0)
        }
        let markdown = MarkdownRenderer.render(blocks)
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConversionError.noTextFound(url)
        }
        reporter.reportFinished()
        return ImportedMarkdown(markdown: markdown, assets: collector.assets, notices: notices)
    }

    // MARK: - Links and pictures

    /// Links between the book's own documents mean nothing once it is one Markdown file, so
    /// only links that leave the book are kept.
    static func resolveLink(_ href: String) -> String? {
        guard let kept = HTMLToMarkdown.keepMeaningfulLinks(href) else { return nil }
        let leavesTheBook = kept.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil
        return leavesTheBook ? kept : nil
    }

    static func resolveImage(_ source: String, in documentPath: String, reader: ZipReader, collector: AssetCollector) -> String? {
        let lower = source.lowercased()
        if lower.hasPrefix("data:") {
            guard let (bytes, name) = HTMLImporter.decodeDataURI(source) else { return nil }
            return collector.add(bytes, suggestedName: name)
        }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return source }
        guard let path = ZipReader.resolve(source, relativeTo: documentPath),
              let entry = reader.entry(named: path), entry.flags & 0x1 == 0,
              let bytes = try? reader.data(for: entry) else { return nil }
        return collector.add(bytes, suggestedName: (path as NSString).lastPathComponent)
    }

    private static func map(_ error: Error, url: URL) -> ConversionError {
        switch error {
        case ZipReader.Failure.passwordProtected:
            return .passwordProtected(url)
        default:
            return .unreadableFile(url)
        }
    }
}
