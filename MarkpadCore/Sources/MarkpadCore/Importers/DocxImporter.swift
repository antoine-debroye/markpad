import Foundation

/// Converts Word documents into Markdown.
///
/// Reads the Office Open XML package itself: the main document part, its styles (for headings,
/// quotes and code), its numbering (for bulleted versus numbered lists) and its relationships
/// (for links and pictures). Headers, footers, footnotes and comments are not converted.
public struct DocxImporter: Sendable {
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

        let zip: ZipReader
        do {
            zip = try ZipReader(url: url)
        } catch ZipReader.Failure.passwordProtected {
            throw ConversionError.passwordProtected(url)
        } catch {
            throw ConversionError.unreadableFile(url)
        }

        guard let partPath = Self.mainDocumentPart(in: zip) else { throw ConversionError.unreadableFile(url) }
        let documentData: Data?
        do {
            documentData = try zip.data(for: partPath)
        } catch {
            throw ConversionError.unreadableFile(url)
        }
        guard let documentData, let document = autoreleasepool(invoking: { DocxXML.parse(documentData) }),
              document.name == "w:document" else {
            throw ConversionError.unreadableFile(url)
        }
        let body = document.child("w:body") ?? document

        let relationships = DocxPartRelationship.read(for: partPath, in: zip)
        let styles = DocxStyles(Self.parsePart(
            DocxPartRelationship.part(ofKind: "styles", in: relationships, relativeTo: partPath), in: zip))
        let numbering = DocxNumbering(Self.parsePart(
            DocxPartRelationship.part(ofKind: "numbering", in: relationships, relativeTo: partPath), in: zip))

        try reporter.checkCancellation()
        reporter.report(.extractingText, fraction: 0.05)

        let collector = AssetCollector(folderName: options.assetFolderName)
        let reader = DocxBodyReader(
            zip: zip,
            partPath: partPath,
            relationships: relationships,
            styles: styles,
            numbering: numbering,
            collector: collector,
            reporter: reporter,
            totalParagraphs: body.count("w:p")
        )
        let blocks = try autoreleasepool { try reader.blocks(from: body) }

        try reporter.checkCancellation()
        reporter.reportAssembling()
        let markdown = MarkdownRenderer.render(blocks)
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConversionError.noTextFound(url)
        }
        reporter.reportFinished()
        return ImportedMarkdown(markdown: markdown, assets: collector.assets, notices: reader.notices)
    }

    /// The document part: the package's `officeDocument` relationship, else the part
    /// `[Content_Types].xml` declares as a Word main document, else the conventional path.
    static func mainDocumentPart(in zip: ZipReader) -> String? {
        let packageRelationships = DocxPartRelationship.read(for: "", in: zip)
        if let path = DocxPartRelationship.part(ofKind: "officeDocument", in: packageRelationships, relativeTo: ""),
           zip.contains(path) {
            return path
        }
        if let data = try? zip.data(for: "[Content_Types].xml"), let types = DocxXML.parse(data) {
            for override in types.children("ct:Override") {
                guard let type = override.attr("ContentType")?.lowercased(),
                      let name = override.attr("PartName") else { continue }
                let isWord = type.contains("wordprocessingml") || type.contains("ms-word")
                if isWord, type.hasSuffix(".main+xml"), zip.contains(name) {
                    return name.hasPrefix("/") ? String(name.dropFirst()) : name
                }
            }
        }
        return zip.contains("word/document.xml") ? "word/document.xml" : nil
    }

    private static func parsePart(_ path: String?, in zip: ZipReader) -> DocxNode? {
        guard let path, let data = try? zip.data(for: path) else { return nil }
        return DocxXML.parse(data)
    }
}
