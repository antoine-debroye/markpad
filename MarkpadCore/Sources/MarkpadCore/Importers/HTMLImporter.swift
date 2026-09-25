import Foundation
import UniformTypeIdentifiers
import ImageIO

/// Converts web pages into Markdown: `.html`, `.htm`, `.xhtml` and Safari `.webarchive` files.
///
/// Pictures embedded as `data:` URIs, stored in a web archive, or sitting beside the page on
/// disk are copied into the assets folder, so the Markdown still shows them wherever it is
/// saved. A picture on the web keeps its URL; a local picture that no longer exists keeps its
/// original path. Navigation, headers and footers are converted like any other content: which
/// parts of a page are boilerplate is not something the markup reliably says.
public struct HTMLImporter: Sendable {
    public init() {}

    public func convert(
        url: URL,
        options: DocumentImportOptions = .init(),
        progress: ImportProgress.Handler? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> ImportedMarkdown {
        var reporter = ImportReporter(totalUnits: 1, handler: progress, isCancelled: isCancelled)
        reporter.unitKind = .page
        try reporter.checkCancellation()
        reporter.report(.reading, index: 0)

        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw ConversionError.unreadableFile(url)
        }

        let page: Page
        if url.pathExtension.lowercased() == "webarchive" || data.starts(with: Data("bplist".utf8)) {
            guard let archive = Self.readWebArchive(data) else { throw ConversionError.unreadableFile(url) }
            page = archive
        } else {
            page = Page(html: data, encodingName: nil, baseURL: nil, subresources: [:])
        }

        guard !HTMLDocumentLoader.decode(page.html, declaredEncoding: page.encodingName)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConversionError.noTextFound(url)
        }
        let preferXML = ["xhtml", "xht"].contains(url.pathExtension.lowercased())
        guard let document = HTMLDocumentLoader.load(
            page.html, encodingName: page.encodingName, preferXML: preferXML) else {
            throw ConversionError.unreadableFile(url)
        }
        try reporter.checkCancellation()
        reporter.report(.extractingText, index: 0)

        let collector = AssetCollector(folderName: options.assetFolderName)
        let folder = url.deletingLastPathComponent()
        let walker = HTMLToMarkdown(
            resolveImage: { source in
                Self.resolveImage(source, page: page, folder: folder, collector: collector)
            },
            resolveLink: { href in
                guard let kept = HTMLToMarkdown.keepMeaningfulLinks(href) else { return nil }
                // A saved page's relative links only work against the address it came from.
                if let base = page.baseURL, !kept.contains(":"),
                   let absolute = URL(string: kept, relativeTo: base)?.absoluteString {
                    return absolute
                }
                return kept
            })
        walker.convert(document)
        try reporter.checkCancellation()
        reporter.reportAssembling()

        var blocks = walker.blocks
        if let title = walker.title, !walker.hasLevelOneHeading {
            blocks.insert(.heading(level: 1, [MarkdownRun(title)]), at: 0)
        }
        let markdown = MarkdownRenderer.render(blocks)
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConversionError.noTextFound(url)
        }
        reporter.reportFinished()
        return ImportedMarkdown(markdown: markdown, assets: collector.assets)
    }

    // MARK: - Pages and web archives

    struct Page {
        var html: Data
        var encodingName: String?
        var baseURL: URL?
        /// Resources saved with the page, by absolute URL.
        var subresources: [String: Data]
    }

    /// Reads a Safari web archive: a property list holding the page and the files it loaded.
    static func readWebArchive(_ data: Data) -> Page? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let root = plist as? [String: Any],
              let main = root["WebMainResource"] as? [String: Any],
              let html = main["WebResourceData"] as? Data else { return nil }
        let base = (main["WebResourceURL"] as? String).flatMap(URL.init(string:))
        var subresources: [String: Data] = [:]
        for resource in root["WebSubresources"] as? [[String: Any]] ?? [] {
            guard let address = resource["WebResourceURL"] as? String,
                  let bytes = resource["WebResourceData"] as? Data else { continue }
            subresources[address] = bytes
        }
        return Page(
            html: html,
            encodingName: main["WebResourceTextEncodingName"] as? String,
            baseURL: base,
            subresources: subresources)
    }

    // MARK: - Pictures

    static func resolveImage(_ source: String, page: Page, folder: URL, collector: AssetCollector) -> String? {
        if source.lowercased().hasPrefix("data:") {
            guard let (bytes, name) = decodeDataURI(source) else { return nil }
            return collector.add(bytes, suggestedName: name)
        }
        if let base = page.baseURL, !page.subresources.isEmpty {
            let absolute = URL(string: source, relativeTo: base)?.absoluteString ?? source
            if let bytes = page.subresources[absolute] ?? page.subresources[source] {
                let name = URL(string: absolute)?.lastPathComponent ?? "image"
                return collector.add(bytes, suggestedName: name.isEmpty || name == "/" ? "image" : name)
            }
        }
        let lower = source.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return source }
        if lower.hasPrefix("//") { return "https:" + source }
        if let base = page.baseURL, let absolute = URL(string: source, relativeTo: base)?.absoluteString {
            // A web archive's other pictures live on the web, relative to the page's address.
            return absolute
        }

        // A picture beside the page on disk: a relative path that stays inside the page's
        // folder. Absolute paths and `file:` URLs are never read, nor is anything a `..`
        // (or a symbolic link) leads out of the folder to — a page is untrusted, and
        // `<img src="../../Pictures/…">` must not copy the user's photos into the output.
        if lower.hasPrefix("file:") || source.hasPrefix("/") || source.hasPrefix("~") { return source }
        var path = String(source.prefix { $0 != "?" && $0 != "#" })
        path = path.removingPercentEncoding ?? path
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        let file = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/") else { return source }
        // Only pictures are copied, so a text file named `.png` is not.
        guard let bytes = readLocalPicture(at: file) else {
            // Missing, or not a picture: keep the reference as written.
            return source
        }
        return collector.add(bytes, suggestedName: file.lastPathComponent)
    }

    /// Largest local picture copied into a conversion.
    static let maximumLocalPictureBytes = ImportLimits.maximumPictureBytes

    /// The bytes of `file` if it is a regular file holding a picture ImageIO can decode (or an
    /// SVG), and not unreasonably large. Nil otherwise.
    static func readLocalPicture(at file: URL) -> Data? {
        let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true,
              let size = values?.fileSize, size > 0, size <= maximumLocalPictureBytes,
              let bytes = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        if let source = CGImageSourceCreateWithData(bytes as CFData, nil),
           CGImageSourceGetCount(source) > 0,
           let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }),
           type.conforms(to: .image) {
            return bytes
        }
        if isSVG(bytes) { return bytes }
        return nil
    }

    /// Whether `bytes` is an SVG document: well-formed XML whose root element is `svg`.
    static func isSVG(_ bytes: Data) -> Bool {
        final class RootReader: NSObject, XMLParserDelegate {
            var root: String?
            func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String] = [:]) {
                root = elementName
                parser.abortParsing()
            }
        }
        let parser = XMLParser(data: bytes)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = true
        let reader = RootReader()
        parser.delegate = reader
        parser.parse()
        return reader.root == "svg"
    }

    /// Decodes `data:[<media type>][;base64],<data>` into bytes and a file name to save it as.
    static func decodeDataURI(_ uri: String) -> (Data, String)? {
        guard let comma = uri.firstIndex(of: ",") else { return nil }
        let header = uri[uri.index(uri.startIndex, offsetBy: 5)..<comma].lowercased()
        let payload = String(uri[uri.index(after: comma)...])
        let parameters = header.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        let bytes: Data?
        if parameters.contains("base64") {
            let compact = payload.removingPercentEncoding ?? payload
            bytes = Data(base64Encoded: compact.filter { !$0.isWhitespace }, options: .ignoreUnknownCharacters)
        } else {
            bytes = (payload.removingPercentEncoding ?? payload).data(using: .utf8)
        }
        guard let bytes, !bytes.isEmpty else { return nil }
        let extensions = [
            "image/png": "png", "image/jpeg": "jpg", "image/jpg": "jpg", "image/gif": "gif",
            "image/webp": "webp", "image/svg+xml": "svg", "image/bmp": "bmp", "image/tiff": "tiff",
        ]
        let name = extensions[parameters.first ?? ""].map { "image." + $0 } ?? "image"
        return (bytes, name)
    }
}
