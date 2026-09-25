import Foundation

/// What an EPUB's package document says: its title and the reading order of its content.
///
/// Parsed from `META-INF/container.xml`, which names the package (`.opf`) file, and that file's
/// `metadata`, `manifest` and `spine` (EPUB 2 and 3 share this structure).
struct EpubPackage {
    struct Document: Equatable {
        /// Path of the content document inside the archive.
        let path: String
        let mediaType: String
        /// False for `linear="no"` spine items: notes and pop-ups outside the main reading order.
        let linear: Bool
    }

    let packagePath: String
    let title: String?
    /// Spine documents in reading order.
    let spine: [Document]

    enum Failure: Error {
        case missingContainer
        case missingPackage
        case malformed
    }

    init(reader: ZipReader) throws {
        guard let containerData = try reader.data(for: "META-INF/container.xml") else {
            throw Failure.missingContainer
        }
        guard let container = Self.xml(containerData) else { throw Failure.malformed }
        let rootfiles = Self.elements(named: "rootfile", in: container)
        let preferred = rootfiles.first {
            $0.attribute(forName: "media-type")?.stringValue == "application/oebps-package+xml"
        } ?? rootfiles.first
        guard let packagePath = preferred?.attribute(forName: "full-path")?.stringValue,
              !packagePath.isEmpty else { throw Failure.missingPackage }
        guard let packageData = try reader.data(for: packagePath) else { throw Failure.missingPackage }
        guard let package = Self.xml(packageData) else { throw Failure.malformed }

        self.packagePath = packagePath
        let metadata: XMLNode = Self.elements(named: "metadata", in: package).first ?? package
        let titleText = Self.elements(named: "title", in: metadata).first?.stringValue
            .map { HTMLToMarkdown.collapse($0).trimmingCharacters(in: .whitespaces) }
        title = titleText?.isEmpty == false ? titleText : nil

        var manifest: [String: (href: String, mediaType: String)] = [:]
        for item in Self.elements(named: "item", in: package) {
            guard let id = item.attribute(forName: "id")?.stringValue,
                  let href = item.attribute(forName: "href")?.stringValue else { continue }
            manifest[id] = (href, item.attribute(forName: "media-type")?.stringValue ?? "")
        }
        var spine: [Document] = []
        for itemref in Self.elements(named: "itemref", in: package) {
            guard let idref = itemref.attribute(forName: "idref")?.stringValue,
                  let item = manifest[idref],
                  let path = ZipReader.resolve(item.href, relativeTo: packagePath) else { continue }
            let linear = itemref.attribute(forName: "linear")?.stringValue?.lowercased() != "no"
            spine.append(Document(path: path, mediaType: item.mediaType, linear: linear))
        }
        self.spine = spine
    }

    /// The documents to convert, in order. Items marked `linear="no"` are kept — they are
    /// often footnotes or answers the reader would otherwise lose — but placed after the main
    /// reading order, where a reading system would also leave them.
    var readingOrder: [Document] {
        let textual = spine.filter { Self.isContentDocument($0.mediaType, path: $0.path) }
        return textual.filter(\.linear) + textual.filter { !$0.linear }
    }

    private static func isContentDocument(_ mediaType: String, path: String) -> Bool {
        let type = mediaType.lowercased()
        if type == "application/xhtml+xml" || type == "text/html" { return true }
        if type.isEmpty {
            let ext = (path as NSString).pathExtension.lowercased()
            return ["xhtml", "html", "htm", "xht"].contains(ext)
        }
        return false
    }

    // MARK: - Protection

    /// Font obfuscation algorithms: they scramble embedded fonts only, not the text.
    static let fontObfuscationAlgorithms: Set<String> = [
        "http://www.idpf.org/2008/embedding",
        "http://ns.adobe.com/pdf/enc#RC",
    ]

    /// True when `META-INF/encryption.xml` lists content encrypted with anything other than
    /// font obfuscation — the mark of DRM (Adobe ADEPT, Apple FairPlay, Readium LCP).
    static func isProtected(reader: ZipReader) throws -> Bool {
        guard let data = try reader.data(for: "META-INF/encryption.xml") else { return false }
        guard let document = xml(data) else {
            // An encryption manifest that cannot be read is not a book that can be.
            return true
        }
        for encrypted in elements(named: "EncryptedData", in: document) {
            let method = elements(named: "EncryptionMethod", in: encrypted).first
            let algorithm = method?.attribute(forName: "Algorithm")?.stringValue ?? ""
            if !fontObfuscationAlgorithms.contains(algorithm) { return true }
        }
        return false
    }

    // MARK: - XML helpers

    static func xml(_ data: Data) -> XMLDocument? {
        try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
    }

    /// Descendant elements with this local name, in document order, whatever their namespace.
    static func elements(named localName: String, in node: XMLNode) -> [XMLElement] {
        var result: [XMLElement] = []
        func visit(_ node: XMLNode) {
            for child in node.children ?? [] {
                guard let element = child as? XMLElement else { continue }
                if (element.localName ?? element.name) == localName { result.append(element) }
                visit(element)
            }
        }
        visit(node)
        return result
    }
}
