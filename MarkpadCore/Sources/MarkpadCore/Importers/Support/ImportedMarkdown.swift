import CryptoKit
import Foundation

/// The result of importing a document: its Markdown, the pictures it referenced, and anything
/// the reader should know about how faithful the conversion is.
public struct ImportedMarkdown: Sendable, Equatable {
    public struct Asset: Sendable, Equatable {
        /// File name within the assets folder, e.g. `image1.png`.
        public let name: String
        public let data: Data

        public init(name: String, data: Data) {
            self.name = name
            self.data = data
        }
    }

    public var markdown: String
    /// Pictures the Markdown links to as `<assetFolderName>/<name>`. Written beside the `.md`
    /// by whoever saves it.
    public var assets: [Asset]
    /// Short, user-facing remarks, e.g. "Sheet “Data” was cut to its first 5,000 rows."
    public var notices: [String]

    public init(markdown: String, assets: [Asset] = [], notices: [String] = []) {
        self.markdown = markdown
        self.assets = assets
        self.notices = notices
    }
}

/// Collects the pictures a document contains and hands back the Markdown destination for each.
///
/// With no folder name the conversion has nowhere to put pictures — a Shortcuts action that
/// returns one Markdown file, say — and `add` returns nil so the importer can fall back to the
/// alt text rather than writing a link that points at nothing.
final class AssetCollector {
    let folderName: String?
    private(set) var assets: [ImportedMarkdown.Asset] = []
    private var destinationsByDigest: [String: String] = [:]
    private var usedNames: Set<String> = []

    init(folderName: String?) {
        self.folderName = folderName
    }

    /// Stores `data` and returns the destination to link to, or nil when pictures are not
    /// being kept. The same bytes added twice produce one file.
    func add(_ data: Data, suggestedName: String) -> String? {
        // An oversized picture is left out like one with nowhere to go: the caller falls back
        // to its alt text.
        guard let folderName, !data.isEmpty, data.count <= ImportLimits.maximumPictureBytes else { return nil }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let existing = destinationsByDigest[digest] { return existing }

        let name = uniqueName(for: suggestedName, data: data)
        usedNames.insert(name.lowercased())
        assets.append(.init(name: name, data: data))
        let destination = folderName + "/" + name
        destinationsByDigest[digest] = destination
        return destination
    }

    private func uniqueName(for suggestion: String, data: Data) -> String {
        let last = (suggestion as NSString).lastPathComponent
        var stem = (last as NSString).deletingPathExtension
        var ext = (last as NSString).pathExtension.lowercased()
        if ext.isEmpty { ext = Self.sniffExtension(data) }
        // Keep names portable: letters, digits, dash, underscore and dot only.
        stem = String(stem.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" })
        if stem.isEmpty { stem = "image" }
        var candidate = "\(stem).\(ext)"
        var counter = 2
        while usedNames.contains(candidate.lowercased()) {
            candidate = "\(stem)-\(counter).\(ext)"
            counter += 1
        }
        return candidate
    }

    /// The extension for image bytes whose source gave none.
    static func sniffExtension(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "gif" }
        if bytes.starts(with: [0x42, 0x4D]) { return "bmp" }
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00]) || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return "tiff" }
        if bytes.count >= 12, bytes[0...3] == [0x52, 0x49, 0x46, 0x46], bytes[8...11] == [0x57, 0x45, 0x42, 0x50] { return "webp" }
        if let head = String(data: data.prefix(256), encoding: .utf8), head.contains("<svg") { return "svg" }
        return "bin"
    }
}
