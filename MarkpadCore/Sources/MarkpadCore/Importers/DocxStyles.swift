import Foundation

/// Run formatting that matters for Markdown. Nil means "not said here", so a later layer
/// (a character style, then the run itself) only overrides what it actually sets.
struct DocxRunProperties: Equatable {
    var bold: Bool?
    var italic: Bool?
    var strikethrough: Bool?
    var hidden: Bool?
    var font: String?

    init() {}

    init(_ rPr: DocxNode?) {
        guard let rPr else { return }
        bold = Self.toggle(rPr.child("w:b"))
        italic = Self.toggle(rPr.child("w:i"))
        let strike = Self.toggle(rPr.child("w:strike"))
        let doubleStrike = Self.toggle(rPr.child("w:dstrike"))
        if strike == true || doubleStrike == true {
            strikethrough = true
        } else if strike != nil || doubleStrike != nil {
            strikethrough = false
        }
        hidden = Self.toggle(rPr.child("w:vanish"))
        if let fonts = rPr.child("w:rFonts") {
            font = fonts.attr("ascii") ?? fonts.attr("hAnsi") ?? fonts.attr("cs")
        }
    }

    /// `other` wins wherever it says something.
    func overlaid(with other: DocxRunProperties) -> DocxRunProperties {
        var result = self
        if let value = other.bold { result.bold = value }
        if let value = other.italic { result.italic = value }
        if let value = other.strikethrough { result.strikethrough = value }
        if let value = other.hidden { result.hidden = value }
        if let value = other.font { result.font = value }
        return result
    }

    var isMonospace: Bool { font.map(Self.isMonospaceFont) ?? false }

    /// An on/off property: present means on unless its value says otherwise.
    static func toggle(_ element: DocxNode?) -> Bool? {
        guard let element else { return nil }
        switch element.attr("val")?.lowercased() {
        case "0", "false", "off", "none": return false
        default: return true
        }
    }

    static func isMonospaceFont(_ name: String) -> Bool {
        let lower = name.lowercased()
        let known = ["courier", "consolas", "menlo", "monaco", "lucida console", "andale mono",
                     "source code", "fira code", "inconsolata", "ocr a", "letter gothic"]
        if known.contains(where: lower.contains) { return true }
        // "SF Mono", "Roboto Mono", "DejaVu Sans Mono", but not "Monotype Corsiva".
        return lower.range(of: "(^|[^a-z])mono($|[^a-z])", options: .regularExpression) != nil
            || lower.hasSuffix("mono")
    }
}

/// `styles.xml`: what each paragraph and character style implies.
struct DocxStyles {
    struct Style {
        let id: String
        let name: String
        let type: String
        let basedOn: String?
        let runProperties: DocxRunProperties
        /// `w:outlineLvl`, 0-based; 9 means body text.
        let outlineLevel: Int?
        let numberingID: String?
        let numberingLevel: Int?
    }

    private(set) var byID: [String: Style] = [:]
    private(set) var defaultParagraphStyle: String?

    init() {}

    init(_ root: DocxNode?) {
        guard let root else { return }
        for element in root.children("w:style") {
            guard let id = element.attr("styleId") else { continue }
            let type = element.attr("type") ?? "paragraph"
            let pPr = element.child("w:pPr")
            let numPr = pPr?.child("w:numPr")
            let style = Style(
                id: id,
                name: element.child("w:name")?.attr("val") ?? id,
                type: type,
                basedOn: element.child("w:basedOn")?.attr("val"),
                runProperties: DocxRunProperties(element.child("w:rPr")),
                outlineLevel: pPr?.child("w:outlineLvl")?.attr("val").flatMap { Int($0) },
                numberingID: numPr?.child("w:numId")?.attr("val"),
                numberingLevel: numPr?.child("w:ilvl")?.attr("val").flatMap { Int($0) }
            )
            if byID[id] == nil { byID[id] = style }
            if type == "paragraph", defaultParagraphStyle == nil,
               let flag = element.attr("default")?.lowercased(), ["1", "true", "on"].contains(flag) {
                defaultParagraphStyle = id
            }
        }
    }

    /// The style and the styles it is based on, nearest first. Cycles are cut.
    func chain(_ id: String?) -> [Style] {
        var result: [Style] = []
        var seen: Set<String> = []
        var current = id
        while let key = current, !seen.contains(key), let style = byID[key], result.count < 32 {
            seen.insert(key)
            result.append(style)
            current = style.basedOn
        }
        return result
    }

    /// Run properties a style gives its text, with its ancestors' underneath.
    func runProperties(_ id: String?) -> DocxRunProperties {
        chain(id).reversed().reduce(DocxRunProperties()) { $0.overlaid(with: $1.runProperties) }
    }

    /// 1-based heading level a paragraph style implies, or nil for body text.
    ///
    /// Recognised by style id (`Heading1`), by name (`heading 1` — a localised Word writes ids
    /// such as `berschrift1` or `Titre1` but keeps the English built-in name), or by outline level.
    func headingLevel(_ id: String?) -> Int? {
        for (offset, style) in chain(id).enumerated() {
            if offset == 0, Self.isSubtitle(style) { return nil }
            if let level = Self.headingLevel(named: style.id) ?? Self.headingLevel(named: style.name) {
                return level
            }
            if let outline = style.outlineLevel {
                return (0...8).contains(outline) ? outline + 1 : nil
            }
        }
        return nil
    }

    static func headingLevel(named name: String) -> Int? {
        let lower = name.trimmingCharacters(in: .whitespaces).lowercased()
        if lower == "title" { return 1 }
        guard let match = lower.range(of: "^heading ?[1-9]$", options: .regularExpression) else { return nil }
        return lower[match].last.flatMap { Int(String($0)) }
    }

    private static func isSubtitle(_ style: Style) -> Bool {
        style.id.lowercased() == "subtitle" || style.name.lowercased() == "subtitle"
    }

    /// Numbering a paragraph style carries, e.g. Word's "List Bullet".
    func numbering(_ id: String?) -> (id: String, level: Int?)? {
        for style in chain(id) {
            if let numberingID = style.numberingID {
                return (numberingID, style.numberingLevel)
            }
        }
        return nil
    }

    func isQuote(_ id: String?) -> Bool {
        guard let style = id.flatMap({ byID[$0] }) else { return false }
        return [style.id, style.name].contains { name in
            let lower = name.lowercased()
            return lower.contains("quote") || lower == "block text" || lower == "blocktext"
        }
    }

    /// A paragraph style meant for source code: "Source Code", "HTML Preformatted", or any
    /// style whose font is monospaced.
    func isCode(_ id: String?) -> Bool {
        guard let style = id.flatMap({ byID[$0] }) else { return false }
        let named = [style.id, style.name].contains { name in
            let lower = name.lowercased()
            return lower.contains("code") || lower.contains("preformatted") || lower.contains("verbatim")
        }
        return named || runProperties(id).isMonospace
    }

    /// A character style meant for inline code: "HTML Code", "Inline Code", Pandoc's "Verbatim Char".
    func isCodeCharacterStyle(_ id: String?) -> Bool {
        chain(id).contains { style in
            [style.id, style.name].contains { name in
                let lower = name.lowercased()
                return lower.contains("code") || lower.contains("verbatim")
                    || lower.contains("typewriter") || lower.contains("keyboard")
            }
        }
    }
}

/// `numbering.xml`: whether a list level is bulleted or numbered.
struct DocxNumbering {
    private var abstractFormats: [String: [Int: String]] = [:]
    private var abstractStyleLinks: [String: String] = [:]
    private var instances: [String: (abstractID: String, overrides: [Int: String])] = [:]

    init() {}

    init(_ root: DocxNode?) {
        guard let root else { return }
        for abstract in root.children("w:abstractNum") {
            guard let id = abstract.attr("abstractNumId") else { continue }
            abstractFormats[id] = Self.formats(of: abstract.children("w:lvl"))
            if let link = abstract.child("w:numStyleLink")?.attr("val") { abstractStyleLinks[id] = link }
        }
        for num in root.children("w:num") {
            guard let id = num.attr("numId"), let abstractID = num.child("w:abstractNumId")?.attr("val") else {
                continue
            }
            let overrides = Self.formats(of: num.children("w:lvlOverride").compactMap { $0.child("w:lvl") })
            instances[id] = (abstractID, overrides)
        }
    }

    private static func formats(of levels: [DocxNode]) -> [Int: String] {
        var result: [Int: String] = [:]
        for level in levels {
            guard let index = level.attr("ilvl").flatMap({ Int($0) }) else { continue }
            if let format = level.child("w:numFmt")?.attr("val") { result[index] = format }
        }
        return result
    }

    /// Whether list `numberingID` at `level` is numbered. Unknown lists count as bulleted.
    func isOrdered(_ numberingID: String, level: Int, styles: DocxStyles) -> Bool {
        guard let format = format(numberingID, level: level, styles: styles, depth: 0) else { return false }
        return format != "bullet" && format != "none"
    }

    private func format(_ numberingID: String, level: Int, styles: DocxStyles, depth: Int) -> String? {
        guard depth < 4, let instance = instances[numberingID] else { return nil }
        if let format = instance.overrides[level] { return format }
        if let format = abstractFormats[instance.abstractID]?[level] { return format }
        // A list style's abstract definition points at the style, whose numbering has the levels.
        if let link = abstractStyleLinks[instance.abstractID],
           let linked = styles.numbering(link)?.id, linked != numberingID {
            return format(linked, level: level, styles: styles, depth: depth + 1)
        }
        return nil
    }
}

/// One entry of a `.rels` part.
struct DocxPartRelationship {
    let id: String
    let type: String
    let target: String
    let isExternal: Bool

    /// The relationships of the part at `partPath` (or of the package, for `""`), keyed by id.
    static func read(for partPath: String, in zip: ZipReader) -> [String: DocxPartRelationship] {
        let relsPath: String
        if partPath.isEmpty {
            relsPath = "_rels/.rels"
        } else {
            let directory = (partPath as NSString).deletingLastPathComponent
            let file = (partPath as NSString).lastPathComponent
            relsPath = (directory.isEmpty ? "" : directory + "/") + "_rels/" + file + ".rels"
        }
        guard let data = try? zip.data(for: relsPath), let root = DocxXML.parse(data) else { return [:] }
        var result: [String: DocxPartRelationship] = [:]
        for element in root.children("pr:Relationship") {
            guard let id = element.attr("Id"), let target = element.attr("Target") else { continue }
            result[id] = DocxPartRelationship(
                id: id,
                type: element.attr("Type") ?? "",
                target: target,
                isExternal: element.attr("TargetMode")?.lowercased() == "external"
            )
        }
        return result
    }

    /// The part a relationship of type `…/<kind>` points at, resolved against `partPath`.
    static func part(ofKind kind: String, in relationships: [String: DocxPartRelationship], relativeTo partPath: String) -> String? {
        relationships.values
            .sorted { $0.id < $1.id }
            .first { $0.type.hasSuffix("/" + kind) && !$0.isExternal }
            .flatMap { ZipReader.resolve($0.target, relativeTo: partPath) }
    }
}
