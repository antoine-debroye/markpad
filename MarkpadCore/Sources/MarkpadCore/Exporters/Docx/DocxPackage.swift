import Foundation

/// Assembles the OPC (zip) container for a `.docx` file.
///
/// Parts are added in a deterministic order so byte output is reproducible, which keeps
/// golden-file tests meaningful.
struct DocxPackage {
    private(set) var parts: [(path: String, data: Data)] = []

    mutating func add(_ path: String, xml: String) {
        add(path, data: Data(xml.utf8))
    }

    mutating func add(_ path: String, data: Data) {
        parts.append((path, data))
    }

    /// Paths declared in the package, used by the integrity checks in tests.
    var paths: [String] { parts.map(\.path) }

    func archiveData() throws -> Data {
        var writer = ZipWriter()
        for part in parts {
            try writer.addFile(name: part.path, data: part.data)
        }
        return try writer.finalize()
    }
}

/// A relationship inside `word/_rels/document.xml.rels`.
struct DocxRelationship {
    enum Kind {
        case styles
        case numbering
        case image
        case hyperlink

        var type: String {
            let base = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
            switch self {
            case .styles: return base + "styles"
            case .numbering: return base + "numbering"
            case .image: return base + "image"
            case .hyperlink: return base + "hyperlink"
            }
        }
    }

    let id: String
    let kind: Kind
    let target: String

    var isExternal: Bool { kind == .hyperlink }
}

/// XML text escaping for element content and attribute values.
enum XML {
    static func escape(_ string: String) -> String {
        var out = ""
        out.reserveCapacity(string.count)
        for character in string.unicodeScalars {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default:
                // Strip control characters that are illegal in XML 1.0.
                if character.value < 0x20 && character != "\t" && character != "\n" { continue }
                out.unicodeScalars.append(character)
            }
        }
        return out
    }

    static let declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
}
