import Foundation

/// Converts JSON and XML files into Markdown.
///
/// Data files are shown, not reinterpreted: the original text goes into a fenced code block,
/// so key order, number spelling (a 30-digit ID stays exact) and comments survive. The file is
/// only parsed to decide whether it deserves its language tag — a broken file is still shown,
/// untagged, with a notice, because the reader usually wants to see *why* it is broken.
public struct StructuredTextImporter: Sendable {
    public init() {}

    public func convert(
        url: URL,
        options: DocumentImportOptions = .init(),
        progress: ImportProgress.Handler? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> ImportedMarkdown {
        let reporter = ImportReporter(totalUnits: 1, handler: progress, isCancelled: isCancelled)
        try reporter.checkCancellation()
        reporter.report(.reading, index: 0)

        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw ConversionError.unreadableFile(url)
        }
        let isXML = url.pathExtension.lowercased() == "xml"
        let fallback = isXML ? Self.declaredXMLEncoding(in: data) : nil
        guard let decoded = StructuredTextDecoding.decode(data, fallbackEncoding: fallback) else {
            throw ConversionError.unreadableFile(url)
        }
        let text = Self.trimmed(decoded.text)
        guard !text.isEmpty else { throw ConversionError.noTextFound(url) }

        try reporter.checkCancellation()
        reporter.report(.extractingText, index: 0)

        var notices: [String] = []
        let language: String?
        if isXML {
            if Self.isWellFormedXML(data) {
                language = "xml"
            } else {
                language = nil
                notices.append("The file is not well-formed XML; it is shown as plain text.")
            }
        } else {
            if StructuredTextJSONSyntax.isValid(text) {
                language = "json"
            } else {
                language = nil
                notices.append("The file is not valid JSON; it is shown as plain text.")
            }
        }

        try reporter.checkCancellation()
        reporter.reportAssembling()
        let markdown = MarkdownRenderer.render([.code(text, language: language)])
        reporter.reportFinished()
        return ImportedMarkdown(markdown: markdown, notices: notices)
    }

    /// Drops blank lines before the content and whitespace after it; everything between is
    /// kept byte for byte.
    static func trimmed(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        while let first = lines.first, first.allSatisfy(\.isWhitespace) { lines.removeFirst() }
        var result = lines.joined(separator: "\n")
        while let last = result.last, last.isWhitespace { result.removeLast() }
        return result
    }

    /// Well-formedness per libxml2. External entities are never fetched (the parser's default).
    static func isWellFormedXML(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        return parser.parse()
    }

    /// The `encoding` named in an XML declaration, for files without a BOM that are not UTF-8.
    static func declaredXMLEncoding(in data: Data) -> String.Encoding? {
        guard let head = String(data: data.prefix(200), encoding: .isoLatin1),
              head.hasPrefix("<?xml"),
              let end = head.range(of: "?>"),
              let match = head[..<end.lowerBound].range(
                  of: "encoding\\s*=\\s*[\"'][A-Za-z0-9._:-]+[\"']", options: .regularExpression)
        else { return nil }
        let name = head[match].split(whereSeparator: { $0 == "\"" || $0 == "'" }).dropFirst().first.map(String.init)
        guard let name else { return nil }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }
}

/// A strict RFC 8259 syntax check.
///
/// `JSONSerialization` is not used for this: it accepts trailing commas and rejects numbers it
/// cannot represent as a `Double` (`1e999`), neither of which is what "valid JSON" means. This
/// checker builds nothing, so it is also cheap on large files, and it is iterative, so deep
/// nesting cannot overflow the stack.
enum StructuredTextJSONSyntax {
    static func isValid(_ text: String) -> Bool {
        var utf8 = Array(text.utf8)
        utf8.append(0) // Sentinel, so look-ahead never needs a bounds check.
        return utf8.withUnsafeBufferPointer { validate($0) }
    }

    private enum State { case value, key, afterValue }

    private static func validate(_ b: UnsafeBufferPointer<UInt8>) -> Bool {
        let end = b.count - 1
        var i = 0
        var stack: [UInt8] = []
        var state = State.value

        func skipWhitespace() {
            while i < end, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D { i += 1 }
        }

        func string() -> Bool {
            guard b[i] == UInt8(ascii: "\"") else { return false }
            i += 1
            while i < end {
                let c = b[i]
                if c == UInt8(ascii: "\"") { i += 1; return true }
                if c < 0x20 { return false }
                if c == UInt8(ascii: "\\") {
                    i += 1
                    switch b[i] {
                    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"), UInt8(ascii: "b"),
                         UInt8(ascii: "f"), UInt8(ascii: "n"), UInt8(ascii: "r"), UInt8(ascii: "t"):
                        i += 1
                    case UInt8(ascii: "u"):
                        i += 1
                        for _ in 0..<4 {
                            guard i < end, isHex(b[i]) else { return false }
                            i += 1
                        }
                    default:
                        return false
                    }
                    continue
                }
                i += 1
            }
            return false
        }

        func number() -> Bool {
            if b[i] == UInt8(ascii: "-") { i += 1 }
            if b[i] == UInt8(ascii: "0") {
                i += 1
            } else if isDigit(b[i]) {
                while isDigit(b[i]) { i += 1 }
            } else {
                return false
            }
            if b[i] == UInt8(ascii: ".") {
                i += 1
                guard isDigit(b[i]) else { return false }
                while isDigit(b[i]) { i += 1 }
            }
            if b[i] == UInt8(ascii: "e") || b[i] == UInt8(ascii: "E") {
                i += 1
                if b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-") { i += 1 }
                guard isDigit(b[i]) else { return false }
                while isDigit(b[i]) { i += 1 }
            }
            return true
        }

        func literal(_ word: String) -> Bool {
            for byte in word.utf8 {
                guard i < end, b[i] == byte else { return false }
                i += 1
            }
            return true
        }

        while true {
            skipWhitespace()
            switch state {
            case .value:
                guard i < end else { return false }
                switch b[i] {
                case UInt8(ascii: "{"):
                    i += 1
                    stack.append(UInt8(ascii: "{"))
                    skipWhitespace()
                    if b[i] == UInt8(ascii: "}") {
                        i += 1
                        stack.removeLast()
                        state = .afterValue
                    } else {
                        state = .key
                    }
                case UInt8(ascii: "["):
                    i += 1
                    stack.append(UInt8(ascii: "["))
                    skipWhitespace()
                    if b[i] == UInt8(ascii: "]") {
                        i += 1
                        stack.removeLast()
                        state = .afterValue
                    }
                case UInt8(ascii: "\""):
                    guard string() else { return false }
                    state = .afterValue
                case UInt8(ascii: "t"):
                    guard literal("true") else { return false }
                    state = .afterValue
                case UInt8(ascii: "f"):
                    guard literal("false") else { return false }
                    state = .afterValue
                case UInt8(ascii: "n"):
                    guard literal("null") else { return false }
                    state = .afterValue
                default:
                    guard number() else { return false }
                    state = .afterValue
                }
            case .key:
                guard i < end, string() else { return false }
                skipWhitespace()
                guard b[i] == UInt8(ascii: ":") else { return false }
                i += 1
                state = .value
            case .afterValue:
                guard let top = stack.last else { return i == end }
                let c = b[i]
                if c == UInt8(ascii: ",") {
                    i += 1
                    state = top == UInt8(ascii: "{") ? .key : .value
                } else if (top == UInt8(ascii: "{") && c == UInt8(ascii: "}"))
                            || (top == UInt8(ascii: "[") && c == UInt8(ascii: "]")) {
                    i += 1
                    stack.removeLast()
                } else {
                    return false
                }
            }
        }
    }

    private static func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

    private static func isHex(_ c: UInt8) -> Bool {
        isDigit(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66)
    }
}
