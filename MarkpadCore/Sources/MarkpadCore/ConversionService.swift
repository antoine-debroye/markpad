import Foundation
import UniformTypeIdentifiers
import ImageIO

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
    /// Rendered diagrams, keyed by their source. The app fills this in before exporting;
    /// anything missing is written out as code rather than dropped.
    public var diagrams: [String: String]

    public init(theme: MarkdownTheme = .default, diagrams: [String: String] = [:]) {
        self.theme = theme
        self.diagrams = diagrams
    }

    /// Converts a file on disk into `format`.
    ///
    /// `progress` and `isCancelled` apply only to the import half — reading the source file.
    /// They both default to inert, so every existing caller behaves exactly as before. Audio is
    /// transcribed asynchronously and is refused here; use `importFile(at:to:options:)`.
    public func convert(
        fileAt url: URL,
        to format: ConversionFormat,
        options: ImportOptions = ImportOptions(),
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> Result {
        guard let input = ConversionInput.detect(for: url) else {
            throw ConversionError.unsupportedInput(url)
        }
        let baseName = url.deletingPathExtension().lastPathComponent

        if input == .markdown {
            return try convert(
                markdown: try Self.readMarkdown(at: url),
                to: format,
                baseName: baseName,
                resourceDirectory: url.deletingLastPathComponent()
            )
        }
        if input == .audio { throw ConversionError.requiresAsynchronousImport(url) }

        let options = Self.keepingPictures(options, for: format)
        let imported = try Self.importDocument(at: url, as: input, options: options, isCancelled: isCancelled)
        return try convert(imported: imported, to: format, baseName: baseName)
    }

    /// Converts an imported document, pictures included, into `format`.
    ///
    /// Word and HTML exports embed pictures, so they are staged in a scratch folder the
    /// exporters can read and removed afterwards. Markdown output carries the Markdown only:
    /// the caller decides where, if anywhere, the pictures are saved.
    public func convert(imported: ImportedMarkdown, to format: ConversionFormat, baseName: String) throws -> Result {
        guard format != .markdown, !imported.assets.isEmpty else {
            return try convert(markdown: imported.markdown, to: format, baseName: baseName)
        }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkpadExport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let folder = scratch.appendingPathComponent(Self.exportAssetFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for asset in imported.assets {
            try asset.data.write(to: folder.appendingPathComponent(asset.name))
        }
        return try convert(markdown: imported.markdown, to: format, baseName: baseName, resourceDirectory: scratch)
    }

    /// Imports any supported file as Markdown plus the pictures it contains. Not for audio,
    /// which needs `importDocument(at:options:)`.
    static func importDocument(
        at url: URL,
        as input: ConversionInput,
        options: ImportOptions,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> ImportedMarkdown {
        // Every importer runs on a thread with a large stack: see `ImportLimits.importStackSize`.
        try ImportLimits.onLargeStack {
            try importDocumentOnCurrentThread(at: url, as: input, options: options, isCancelled: isCancelled)
        }
    }

    private static func importDocumentOnCurrentThread(
        at url: URL,
        as input: ConversionInput,
        options: ImportOptions,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> ImportedMarkdown {
        let document = options.document
        let progress = options.progress
        switch input {
        case .markdown:
            return ImportedMarkdown(markdown: try readMarkdown(at: url))
        case .pdf:
            return ImportedMarkdown(markdown: try PDFImporter().convert(
                url: url, options: options.pdf, progress: progress, isCancelled: isCancelled))
        case .image:
            return try importImage(at: url, options: options, isCancelled: isCancelled)
        case .wordDocument:
            return try DocxImporter().convert(url: url, options: document, progress: progress, isCancelled: isCancelled)
        case .richText:
            return try RichTextImporter().convert(url: url, options: document, progress: progress, isCancelled: isCancelled)
        case .webPage:
            return try HTMLImporter().convert(url: url, options: document, progress: progress, isCancelled: isCancelled)
        case .presentation:
            return try PresentationImporter().convert(url: url, options: document, progress: progress, isCancelled: isCancelled)
        case .spreadsheet:
            return try SpreadsheetImporter().convert(url: url, options: document, progress: progress, isCancelled: isCancelled)
        case .ebook:
            return try EpubImporter().convert(url: url, options: document, progress: progress, isCancelled: isCancelled)
        case .delimitedText:
            return try DelimitedTextImporter().convert(url: url, options: document, progress: progress, isCancelled: isCancelled)
        case .json, .xml:
            return try StructuredTextImporter().convert(url: url, options: document, progress: progress, isCancelled: isCancelled)
        case .audio:
            throw ConversionError.requiresAsynchronousImport(url)
        }
    }

    /// An image's recognised text, with the picture itself above it when asked for.
    private static func importImage(
        at url: URL,
        options: ImportOptions,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> ImportedMarkdown {
        let keepsPicture = options.document.includesOriginalPicture && options.document.assetFolderName != nil
        let text: String
        do {
            text = try ImageImporter().convert(url: url, options: options.image, progress: options.progress, isCancelled: isCancelled)
        } catch ConversionError.noTextFound(_) where keepsPicture {
            // A photo with no writing in it is still worth converting when the picture is kept.
            text = ""
        }
        guard keepsPicture else { return ImportedMarkdown(markdown: text) }

        let collector = AssetCollector(folderName: options.document.assetFolderName)
        guard let (data, name) = portablePicture(at: url),
              let destination = collector.add(data, suggestedName: name) else {
            if text.isEmpty { throw ConversionError.noTextFound(url) }
            return ImportedMarkdown(markdown: text, notices: ["The picture was too large to include; only its text was kept."])
        }
        let alt = url.deletingPathExtension().lastPathComponent
        let picture = MarkdownRenderer.render([.paragraph([.image(alt: alt, destination: destination)])])
        return ImportedMarkdown(
            markdown: text.isEmpty ? picture : picture + "\n" + text,
            assets: collector.assets
        )
    }

    /// The picture's bytes in a format every viewer and exporter reads, with its file name.
    ///
    /// An iPhone photo is HEIC, which the editor shows but Word export, most browsers and
    /// GitHub do not, so HEIC, HEIF and WebP are re-encoded as JPEG — copying the source's
    /// properties, so a portrait photo stays upright. Everything else is kept byte for byte.
    static func portablePicture(at url: URL) -> (Data, String)? {
        guard let original = try? Data(contentsOf: url) else { return nil }
        let ext = url.pathExtension.lowercased()
        guard ["heic", "heif", "webp"].contains(ext) else { return (original, url.lastPathComponent) }

        let output = NSMutableData()
        guard let source = CGImageSourceCreateWithData(original as CFData, nil),
              let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return (original, url.lastPathComponent)
        }
        CGImageDestinationAddImageFromSource(destination, source, 0, [
            kCGImageDestinationLossyCompressionQuality: 0.85,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return (original, url.lastPathComponent) }
        return (output as Data, url.deletingPathExtension().lastPathComponent + ".jpg")
    }

    /// The folder name pictures are staged under for Word and HTML exports.
    static let exportAssetFolder = "images"

    /// Word and HTML exports can embed pictures, so they are always collected for those.
    private static func keepingPictures(_ options: ImportOptions, for format: ConversionFormat) -> ImportOptions {
        guard format != .markdown, options.document.assetFolderName == nil else { return options }
        var options = options
        options.document.assetFolderName = exportAssetFolder
        return options
    }

    static func readMarkdown(at url: URL) throws -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ConversionError.unreadableFile(url)
        }
        return text
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
            var options = HTMLExporter.Options(title: baseName, theme: theme)

            if let directory = resourceDirectory {
                let resolver: @Sendable (String) -> String? = { source in
                    DataURI.inline(source: source, relativeTo: directory)
                }
                options.imageResolver = resolver
            }
            if !diagrams.isEmpty {
                let rendered = diagrams
                let resolver: @Sendable (String) -> String? = { source in rendered[source] }
                options.diagramResolver = resolver
            }

            let html = HTMLExporter().export(markdown: markdown, options: options)
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

    /// Reads any supported file as Markdown, converting documents on the way in. Pictures are
    /// replaced by their alt text, since a returned string has nowhere to keep them.
    public func markdown(fromFileAt url: URL) throws -> String {
        try convert(fileAt: url, to: .markdown).text ?? ""
    }

    // MARK: Off the main thread

    /// Converts a file without blocking the caller, reporting progress and honouring cancellation.
    ///
    /// Deliberately named differently from `convert(fileAt:to:)` rather than being an `async`
    /// overload of it: the Shortcuts intents call the synchronous method from inside an `async`
    /// `perform()`, and an overload sharing those argument labels would silently re-resolve
    /// those calls and stop compiling.
    public func importFile(
        at url: URL,
        to format: ConversionFormat,
        options: ImportOptions = ImportOptions()
    ) async throws -> Result {
        if ConversionInput.detect(for: url) == .audio {
            let options = Self.keepingPictures(options, for: format)
            let imported = try await importDocument(at: url, options: options)
            return try convert(imported: imported, to: format, baseName: url.deletingPathExtension().lastPathComponent)
        }
        // `Task.detached`, not `Task { }`: `Task.init` inherits actor isolation, so started from
        // the main actor — which is where every caller lives — the work would run on the main
        // thread and the freeze this exists to fix would survive.
        let work = Task.detached(priority: .userInitiated) {
            try self.convert(fileAt: url, to: format, options: options, isCancelled: { Task.isCancelled })
        }
        // A detached task does not inherit cancellation, so without this bridge cancelling the
        // caller would never reach the importer and the Cancel button would do nothing.
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    /// Reads any supported file as Markdown without blocking the caller.
    public func importMarkdown(
        fromFileAt url: URL,
        options: ImportOptions = ImportOptions()
    ) async throws -> String {
        try await importDocument(at: url, options: options).markdown
    }

    /// Reads any supported file — audio included — as Markdown plus the pictures it contains,
    /// off the caller's thread. Pictures are kept only when `options.document.assetFolderName`
    /// names a folder to link them into.
    public func importDocument(
        at url: URL,
        options: ImportOptions = ImportOptions()
    ) async throws -> ImportedMarkdown {
        guard let input = ConversionInput.detect(for: url) else {
            throw ConversionError.unsupportedInput(url)
        }
        if input == .audio {
            return try await AudioImporter().convert(
                url: url,
                options: options.audio,
                progress: options.progress,
                isCancelled: { Task.isCancelled }
            )
        }
        let work = Task.detached(priority: .userInitiated) {
            try Self.importDocument(at: url, as: input, options: options, isCancelled: { Task.isCancelled })
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
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
