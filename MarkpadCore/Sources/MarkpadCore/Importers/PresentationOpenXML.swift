import Foundation

// Open Packaging Convention plumbing shared by the PowerPoint and Excel importers: a small
// namespace-aware element tree, relationship parts, and error mapping for the ZIP container.

/// An element of a parsed XML part.
///
/// Element names are local names with their namespace URI kept alongside, so a part written
/// with unusual prefixes — or in the ISO "strict" namespaces rather than the transitional
/// ones — reads the same as one from PowerPoint or Excel.
final class OfficeImportElement {
    let name: String
    let namespace: String
    /// Unprefixed attributes, by name. Unprefixed attributes belong to no namespace.
    private(set) var attributes: [String: String] = [:]
    /// Prefixed attributes, resolved to their namespace URI.
    private(set) var namespacedAttributes: [(namespace: String, name: String, value: String)] = []
    private(set) var children: [OfficeImportElement] = []
    /// Character data directly inside this element.
    fileprivate(set) var text = ""

    init(name: String, namespace: String) {
        self.name = name
        self.namespace = namespace
    }

    func attribute(_ name: String) -> String? { attributes[name] }

    /// A prefixed attribute whose namespace URI contains `fragment`, e.g. `r:id`.
    func attribute(_ name: String, namespaceContaining fragment: String) -> String? {
        namespacedAttributes.first { $0.name == name && $0.namespace.contains(fragment) }?.value
    }

    /// `r:id`, `r:embed` and friends. Transitional and strict relationship namespaces both
    /// contain "relationships".
    func relationshipAttribute(_ name: String) -> String? {
        attribute(name, namespaceContaining: "relationships")
    }

    /// True for `1`/`true`, the two spellings of `xsd:boolean` truth.
    func flag(_ name: String) -> Bool {
        guard let value = attributes[name] else { return false }
        return value == "1" || value.lowercased() == "true"
    }

    func child(_ name: String) -> OfficeImportElement? { children.first { $0.name == name } }

    func children(_ name: String) -> [OfficeImportElement] { children.filter { $0.name == name } }

    /// The first element named `name` below this one, depth first.
    func descendant(_ name: String) -> OfficeImportElement? {
        for child in children {
            if child.name == name { return child }
            if let found = child.descendant(name) { return found }
        }
        return nil
    }

    fileprivate func append(_ child: OfficeImportElement) { children.append(child) }

    fileprivate func setAttribute(_ name: String, namespace: String?, value: String) {
        if let namespace {
            namespacedAttributes.append((namespace, name, value))
        } else {
            attributes[name] = value
        }
    }
}

/// Parses a whole XML part into an `OfficeImportElement` tree. For the small parts —
/// presentation, slides, workbook, styles. Sheets and shared strings are streamed instead.
enum OfficeImportXML {
    static func parse(_ data: Data) -> OfficeImportElement? {
        let builder = TreeBuilder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        guard parser.parse(), builder.failed == false else { return nil }
        return builder.root
    }

    /// Splits `prefix:local`.
    static func split(_ qualified: String) -> (prefix: String?, local: String) {
        guard let colon = qualified.firstIndex(of: ":") else { return (nil, qualified) }
        return (String(qualified[..<colon]), String(qualified[qualified.index(after: colon)...]))
    }

    private final class TreeBuilder: NSObject, XMLParserDelegate {
        var root: OfficeImportElement?
        var failed = false
        private var stack: [OfficeImportElement] = []
        /// In-scope prefix → URI bindings, one dictionary per open element.
        private var scopes: [[String: String]] = [["xml": "http://www.w3.org/XML/1998/namespace"]]

        private func lookup(_ prefix: String) -> String? {
            for scope in scopes.reversed() {
                if let uri = scope[prefix] { return uri }
            }
            return nil
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            var scope: [String: String] = [:]
            for (key, value) in attributeDict {
                if key == "xmlns" {
                    scope[""] = value
                } else if key.hasPrefix("xmlns:") {
                    scope[String(key.dropFirst(6))] = value
                }
            }
            scopes.append(scope)

            let (prefix, local) = OfficeImportXML.split(elementName)
            let element = OfficeImportElement(name: local, namespace: lookup(prefix ?? "") ?? "")
            for (key, value) in attributeDict where key != "xmlns" && !key.hasPrefix("xmlns:") {
                let (attributePrefix, attributeName) = OfficeImportXML.split(key)
                if let attributePrefix {
                    element.setAttribute(attributeName, namespace: lookup(attributePrefix) ?? attributePrefix, value: value)
                } else {
                    element.setAttribute(attributeName, namespace: nil, value: value)
                }
            }
            if let parent = stack.last {
                parent.append(element)
            } else if root == nil {
                root = element
            }
            stack.append(element)
            // Deeper than any real document: stop rather than build a tree that recursion
            // over it would overflow the stack on.
            if stack.count > ImportLimits.maximumNestingDepth {
                failed = true
                parser.abortParsing()
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            if !stack.isEmpty { stack.removeLast() }
            if scopes.count > 1 { scopes.removeLast() }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            stack.last?.text += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
            failed = true
        }
    }
}

/// The relationships of one package part: `word/_rels/document.xml.rels` and the like.
struct OfficeImportRelationships {
    struct Relationship {
        let id: String
        let type: String
        let target: String
        let isExternal: Bool

        /// Relationship types are URIs ending in a short name: `…/slide`, `…/notesSlide`.
        func hasType(_ shortName: String) -> Bool { type.hasSuffix("/" + shortName) }
    }

    /// The part these relationships belong to; "" for the package itself.
    let sourcePart: String
    let all: [Relationship]
    private let byID: [String: Relationship]

    init(sourcePart: String, relationships: [Relationship]) {
        self.sourcePart = sourcePart
        self.all = relationships
        var byID: [String: Relationship] = [:]
        for relationship in relationships where byID[relationship.id] == nil {
            byID[relationship.id] = relationship
        }
        self.byID = byID
    }

    subscript(id: String) -> Relationship? { byID[id] }

    /// `ppt/slides/slide1.xml` → `ppt/slides/_rels/slide1.xml.rels`; the package's own are
    /// at `_rels/.rels`.
    static func path(for part: String) -> String {
        guard !part.isEmpty else { return "_rels/.rels" }
        let components = part.split(separator: "/", omittingEmptySubsequences: false)
        let directory = components.dropLast().joined(separator: "/")
        let file = components.last.map(String.init) ?? part
        return (directory.isEmpty ? "" : directory + "/") + "_rels/" + file + ".rels"
    }

    /// Loads the relationships of `part`. A part without any has an empty set.
    static func load(for part: String, in zip: ZipReader) throws -> OfficeImportRelationships {
        guard let data = try zip.data(for: path(for: part)), let root = OfficeImportXML.parse(data) else {
            return OfficeImportRelationships(sourcePart: part, relationships: [])
        }
        let relationships = root.children("Relationship").compactMap { element -> Relationship? in
            guard let id = element.attribute("Id"), let target = element.attribute("Target") else { return nil }
            return Relationship(
                id: id,
                type: element.attribute("Type") ?? "",
                target: target,
                isExternal: element.attribute("TargetMode")?.lowercased() == "external"
            )
        }
        return OfficeImportRelationships(sourcePart: part, relationships: relationships)
    }

    /// The package path an internal relationship points at.
    func partPath(for id: String) -> String? {
        guard let relationship = byID[id], !relationship.isExternal else { return nil }
        return partPath(for: relationship)
    }

    func partPath(for relationship: Relationship) -> String? {
        guard !relationship.isExternal else { return nil }
        return ZipReader.resolve(relationship.target, relativeTo: sourcePart.isEmpty ? "root" : sourcePart)
    }

    func first(ofType shortName: String) -> Relationship? { all.first { $0.hasType(shortName) } }
}

/// Opening an Office package and turning container failures into `ConversionError`s.
enum OfficeImportPackage {
    static func open(_ url: URL) throws -> ZipReader {
        do {
            return try ZipReader(url: url)
        } catch {
            throw conversionError(for: error, url: url)
        }
    }

    /// Every failure a package can produce, mapped onto what the user is told.
    static func conversionError(for error: Error, url: URL) -> ConversionError {
        if let conversion = error as? ConversionError { return conversion }
        if let failure = error as? ZipReader.Failure, failure == .passwordProtected {
            return .passwordProtected(url)
        }
        return .unreadableFile(url)
    }

    /// The main part — `ppt/presentation.xml`, `xl/workbook.xml` — as the package's root
    /// relationships name it, falling back to the conventional location.
    static func mainPart(in zip: ZipReader, fallback: String) throws -> String {
        let relationships = try OfficeImportRelationships.load(for: "", in: zip)
        if let main = relationships.first(ofType: "officeDocument"),
           let path = relationships.partPath(for: main),
           zip.contains(path) {
            return path
        }
        return fallback
    }

    /// Parses a part, or returns nil when the package has no such part.
    /// A part that is present but not well-formed XML is a damaged file.
    static func element(_ part: String, in zip: ZipReader, url: URL) throws -> OfficeImportElement? {
        guard let data = try zip.data(for: part) else { return nil }
        guard let root = OfficeImportXML.parse(data) else { throw ConversionError.unreadableFile(url) }
        return root
    }
}
