import Foundation

/// One element of a WordprocessingML part, reduced to what the Word importer reads.
///
/// Element names are normalised to a fixed prefix per namespace (`w:p`, `a:blip`, `mc:Choice`),
/// because the prefixes in a file are the writer's choice: textutil, for one, declares the
/// markup-compatibility namespace as `ve`, and Strict OOXML uses different namespace URIs for
/// the same elements.
final class DocxNode {
    let name: String
    let attributes: [String: String]
    private(set) var children: [DocxNode] = []
    /// Character data, kept only for the elements whose text is content (`w:t`, `w:instrText`…).
    fileprivate(set) var text = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    /// An attribute by local name. Relationship-namespace attributes are keyed `r:<name>`, so
    /// `r:id` and `w:id` do not collide.
    func attr(_ key: String) -> String? { attributes[key] }

    func child(_ name: String) -> DocxNode? { children.first { $0.name == name } }

    func children(_ name: String) -> [DocxNode] { children.filter { $0.name == name } }

    /// Every descendant called `name`, without looking inside a match or inside any element
    /// named in `skipping`.
    func descendants(_ name: String, skipping: Set<String> = []) -> [DocxNode] {
        var found: [DocxNode] = []
        func walk(_ node: DocxNode) {
            for child in node.children {
                if child.name == name {
                    found.append(child)
                } else if !skipping.contains(child.name) {
                    walk(child)
                }
            }
        }
        walk(self)
        return found
    }

    func firstDescendant(_ name: String, skipping: Set<String> = []) -> DocxNode? {
        for child in children {
            if child.name == name { return child }
            if skipping.contains(child.name) { continue }
            if let match = child.firstDescendant(name, skipping: skipping) { return match }
        }
        return nil
    }

    /// Number of descendants called `name`, for progress estimates.
    func count(_ name: String) -> Int {
        children.reduce(0) { $0 + ($1.name == name ? 1 : 0) + $1.count(name) }
    }

    fileprivate func append(_ child: DocxNode) { children.append(child) }
}

enum DocxXML {
    /// Parses a part into a tree, or returns nil when it is not well-formed XML.
    static func parse(_ data: Data) -> DocxNode? {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        let builder = Builder()
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else { return nil }
        return root
    }

    /// The fixed prefix used for a namespace URI. Unknown namespaces share `x`.
    static func prefix(for uri: String?) -> String {
        switch uri ?? "" {
        case "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
             "http://purl.oclc.org/ooxml/wordprocessingml/main":
            return "w"
        case "http://schemas.openxmlformats.org/officeDocument/2006/relationships",
             "http://purl.oclc.org/ooxml/officeDocument/relationships":
            return "r"
        case "http://schemas.openxmlformats.org/drawingml/2006/main",
             "http://purl.oclc.org/ooxml/drawingml/main":
            return "a"
        case "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
             "http://purl.oclc.org/ooxml/drawingml/wordprocessingDrawing":
            return "wp"
        case "http://schemas.openxmlformats.org/drawingml/2006/picture",
             "http://purl.oclc.org/ooxml/drawingml/picture":
            return "pic"
        case "urn:schemas-microsoft-com:vml":
            return "v"
        case "urn:schemas-microsoft-com:office:office":
            return "o"
        case "http://schemas.openxmlformats.org/markup-compatibility/2006":
            return "mc"
        case "http://schemas.openxmlformats.org/officeDocument/2006/math",
             "http://purl.oclc.org/ooxml/officeDocument/math":
            return "m"
        case "http://schemas.openxmlformats.org/package/2006/relationships":
            return "pr"
        case "http://schemas.openxmlformats.org/package/2006/content-types":
            return "ct"
        default:
            return "x"
        }
    }

    /// Elements whose character data is document text.
    private static let textElements: Set<String> = ["w:t", "w:instrText", "w:delText", "m:t"]

    private final class Builder: NSObject, XMLParserDelegate {
        var root: DocxNode?
        private var stack: [DocxNode] = []
        private var prefixes: [String: [String]] = [:]

        func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
            prefixes[prefix, default: []].append(namespaceURI)
        }

        func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
            if prefixes[prefix]?.isEmpty == false { prefixes[prefix]?.removeLast() }
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            var attributes: [String: String] = [:]
            for (key, value) in attributeDict {
                let normalised: String
                if let colon = key.firstIndex(of: ":") {
                    let prefix = String(key[..<colon])
                    let local = String(key[key.index(after: colon)...])
                    if prefix == "xml" || prefix == "xmlns" {
                        normalised = prefix + ":" + local
                    } else {
                        let tag = DocxXML.prefix(for: prefixes[prefix]?.last)
                        normalised = tag == "r" ? "r:" + local : local
                    }
                } else {
                    normalised = key
                }
                if attributes[normalised] == nil { attributes[normalised] = value }
            }
            let node = DocxNode(name: DocxXML.prefix(for: namespaceURI) + ":" + elementName, attributes: attributes)
            if let parent = stack.last { parent.append(node) } else if root == nil { root = node }
            stack.append(node)
            // Deeper than any real document: stop rather than build a tree that recursion
            // over it would overflow the stack on.
            if stack.count > ImportLimits.maximumNestingDepth { parser.abortParsing() }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            if !stack.isEmpty { stack.removeLast() }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard let current = stack.last, DocxXML.textElements.contains(current.name) else { return }
            current.text += string
        }
    }
}
