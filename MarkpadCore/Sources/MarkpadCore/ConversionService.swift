import Foundation

/// One entry point for every conversion Markpad performs.
///
/// The app menus, the Shortcuts actions and the Quick Look extension all route through this
/// type so a conversion behaves identically wherever it is started from.
public struct ConversionService: Sendable {
    public struct Result: Sendable {
        public let data: Data
        public let suggestedFilename: String
        public let format: ConversionFormat

        /// Text output as a string, for callers that want to display rather than save it.
        public var text: String? {
            format == .word ? nil : String(data: data, encoding: .utf8)
        }
    }

    public var theme: MarkdownTheme

    public init(theme: MarkdownTheme = .default) {
        self.theme = theme
    }

    /// Converts a file on disk into `format`.
    public func convert(fileAt url: URL, to format: ConversionFormat) throws -> Result {
        guard let input = ConversionInput.detect(for: url) else {
            throw ConversionError.unsupportedInput(url)
        }

        let markdown: String
        switch input {
        case .markdown:
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                throw ConversionError.unreadableFile(url)
            }
            markdown = text
        case .pdf:
            markdown = try PDFImporter().convert(url: url)
        case .image:
            markdown = try ImageImporter().convert(url: url)
        }

        let baseName = url.deletingPathExtension().lastPathComponent
        return try convert(
            markdown: markdown,
            to: format,
            baseName: baseName,
            resourceDirectory: input == .markdown ? url.deletingLastPathComponent() : nil
        )
    }

    /// Converts in-memory Markdown into `format`.
    public func convert(
        markdown: String,
        to format: ConversionFormat,
        baseName: String = "Document",
        resourceDirectory: URL? = nil
    ) throws -> Result {
        let filename = "\(baseName).\(format.fileExtension)"
        switch format {
        case .markdown:
            return Result(data: Data(markdown.utf8), suggestedFilename: filename, format: format)

        case .html:
            let html = HTMLExporter().export(
                markdown: markdown,
                options: .init(
                    title: baseName,
                    theme: theme,
                    imageResolver: resourceDirectory.map { directory in
                        { source in DataURI.inline(source: source, relativeTo: directory) }
                    }
                )
            )
            return Result(data: Data(html.utf8), suggestedFilename: filename, format: format)

        case .plainText:
            let text = PlainTextExporter().export(markdown: markdown)
            return Result(data: Data(text.utf8), suggestedFilename: filename, format: format)

        case .word:
            let data = try DocxExporter().export(
                markdown: markdown,
                options: .init(resourceDirectory: resourceDirectory, theme: theme)
            )
            return Result(data: data, suggestedFilename: filename, format: format)
        }
    }

    /// Reads any supported file as Markdown, converting PDFs and images on the way in.
    public func markdown(fromFileAt url: URL) throws -> String {
        try convert(fileAt: url, to: .markdown).text ?? ""
    }
}

/// Embeds local images directly in exported HTML.
///
/// A standalone `.html` file or a Quick Look preview cannot reach sibling files on disk, so
/// referenced images travel with the document as data URIs.
public enum DataURI {
    /// Images above this size are left as plain references rather than bloating the output.
    public static let maximumInlineBytes = 8 * 1024 * 1024

    public static func inline(source: String, relativeTo directory: URL) -> String? {
        guard !source.isEmpty else { return nil }
        if let url = URL(string: source), let scheme = url.scheme, scheme != "file" { return nil }

        let decoded = source.removingPercentEncoding ?? source
        let fileURL = URL(fileURLWithPath: decoded, relativeTo: directory).standardizedFileURL
        guard let data = try? Data(contentsOf: fileURL), data.count <= maximumInlineBytes else {
            return nil
        }
        let mime = mimeType(forExtension: fileURL.pathExtension)
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    public static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "tiff", "tif": return "image/tiff"
        default: return "application/octet-stream"
        }
    }
}
