import Foundation

/// Turns the bytes of a web page into an XHTML tree the Markdown walker can read.
///
/// Foundation's HTML mode (`XMLDocument` with `.documentTidyHTML`) repairs tag soup, but it
/// predates HTML5 and has three habits that lose text, all verified on macOS:
/// - Without a byte-order mark it reads the bytes as Latin-1 and silently drops every
///   character, named entity or numeric reference above U+00FF, and it ignores
///   `<meta charset>`. So the page is decoded here and handed over as UTF-8 with a BOM.
/// - It unwraps elements it does not know — `section`, `article`, `figure`, `nav` — so their
///   text runs into the previous paragraph. Those are renamed to `div`/`span` beforehand, with
///   the real name kept in `data-markpad-tag` for the walker.
/// - It lifts an inline `<svg>`'s `<title>` into the document head. SVG is removed first.
/// - An XML declaration makes it apply XML rules, so XHTML using HTML entities fails. The
///   declaration is removed; the text is already decoded by then.
enum HTMLDocumentLoader {
    /// Attribute carrying the original name of an element renamed for the tidier.
    static let originalTagAttribute = "data-markpad-tag"

    /// Parses a web page. `encodingName` is an IANA charset declared outside the page, as a
    /// web archive or an HTTP header does. `preferXML` tries a strict XML parse first, which
    /// keeps XHTML exactly as written, and falls back to the HTML repairer when it fails.
    /// Returns nil when the bytes cannot be read as a page at all.
    static func load(_ data: Data, encodingName: String? = nil, preferXML: Bool) -> XMLDocument? {
        if preferXML, let document = try? XMLDocument(
            data: data, options: [.nodePromoteSignificantWhitespace, .nodeLoadExternalEntitiesNever]),
           document.rootElement() != nil {
            return document
        }
        let text = decode(data, declaredEncoding: encodingName)
        return loadHTML(text)
    }

    /// Repairs and parses HTML source that has already been decoded.
    static func loadHTML(_ source: String) -> XMLDocument? {
        let prepared = prepareForTidy(source)
        guard !prepared.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let bytes = Data([0xEF, 0xBB, 0xBF]) + Data(prepared.utf8)
        guard let document = try? XMLDocument(
            data: bytes,
            options: [.documentTidyHTML, .nodePromoteSignificantWhitespace, .nodeLoadExternalEntitiesNever]),
              document.rootElement() != nil else { return nil }
        return document
    }

    // MARK: - Encoding

    /// Decodes page bytes: a byte-order mark wins, then an encoding declared outside the page,
    /// then one declared inside it (`<meta charset>`, `http-equiv` Content-Type or an XML
    /// declaration), then UTF-8 if the bytes are valid UTF-8, then Windows-1252.
    static func decode(_ data: Data, declaredEncoding: String? = nil) -> String {
        let bytes = [UInt8](data.prefix(4))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(decoding: data.dropFirst(3), as: UTF8.self)
        }
        if bytes.starts(with: [0xFE, 0xFF]), let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
            return text
        }
        if bytes.starts(with: [0xFF, 0xFE]), let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
            return text
        }
        for name in [declaredEncoding, sniffDeclaredEncoding(data)].compactMap({ $0 }) {
            if let encoding = encoding(named: name), let text = String(data: data, encoding: encoding) {
                return text
            }
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .windowsCP1252) { return text }
        // Windows-1252 leaves five bytes undefined; Latin-1 maps every byte.
        return String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
    }

    /// The charset a page declares in its first bytes, if any.
    static func sniffDeclaredEncoding(_ data: Data) -> String? {
        // Declarations are ASCII, so reading the prefix as Latin-1 cannot fail or shift offsets.
        guard let head = String(data: data.prefix(4096), encoding: .isoLatin1) else { return nil }
        let patterns = [
            #"<meta[^>]+charset\s*=\s*["']?\s*([A-Za-z0-9._:-]+)"#,
            #"<\?xml[^>]+encoding\s*=\s*["']([A-Za-z0-9._:-]+)"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: head, range: NSRange(head.startIndex..., in: head)),
                  let range = Range(match.range(at: 1), in: head) else { continue }
            return String(head[range])
        }
        return nil
    }

    /// Maps an IANA charset name to a Foundation encoding. As browsers do, Latin-1 and ASCII
    /// labels are read as Windows-1252, which pages mislabelled that way almost always are.
    static func encoding(named name: String) -> String.Encoding? {
        let lower = name.trimmingCharacters(in: .whitespaces).lowercased()
        if ["iso-8859-1", "iso8859-1", "latin1", "l1", "us-ascii", "ascii", "cp1252", "windows-1252"].contains(lower) {
            return .windowsCP1252
        }
        if lower == "utf8" { return .utf8 }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(lower as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    // MARK: - Preparing for the tidier

    /// HTML5 elements the tidier does not know, and what to present them as.
    private static let renamedBlocks = [
        "section", "article", "main", "header", "footer", "aside", "nav", "figure", "figcaption",
        "details", "summary", "hgroup", "dialog", "search", "template", "video", "audio", "canvas",
    ]
    private static let renamedInlines = ["mark", "time", "data", "output", "picture", "bdi", "meter", "progress"]

    private static let rewrites: [(NSRegularExpression, String)] = {
        func regex(_ pattern: String) -> NSRegularExpression {
            // The patterns are literals; a failure here is a programming error caught by tests.
            try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }
        let blocks = renamedBlocks.joined(separator: "|")
        let inlines = renamedInlines.joined(separator: "|")
        return [
            (regex(#"<!--[\s\S]*?-->"#), ""),
            // An XML declaration switches the tidier to XML rules, where `&nbsp;` is an error.
            (regex(#"<\?[\s\S]*?\?>"#), ""),
            (regex(#"<svg\b[\s\S]*?</svg\s*>"#), ""),
            (regex(#"<meta\b[^>]*charset[^>]*>"#), ""),
            (regex(#"<(?:source|track)\b[^>]*>"#), ""),
            (regex("<(\(blocks))(?=[\\s/>])"), "<div \(originalTagAttribute)=\"$1\""),
            (regex("</(?:\(blocks))\\s*>"), "</div>"),
            (regex("<(\(inlines))(?=[\\s/>])"), "<span \(originalTagAttribute)=\"$1\""),
            (regex("</(?:\(inlines))\\s*>"), "</span>"),
        ]
    }()

    static func prepareForTidy(_ source: String) -> String {
        var text = source
        for (regex, template) in rewrites {
            text = regex.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
        }
        return text
    }
}
