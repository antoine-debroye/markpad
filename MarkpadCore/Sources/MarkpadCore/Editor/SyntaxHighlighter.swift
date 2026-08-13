import Foundation

/// Colours code blocks by language.
///
/// A small hand-written tokenizer rather than a grammar engine: for reading code in a
/// document, telling comments, strings, numbers and keywords apart is most of the value, and
/// it costs no dependency and no per-language grammar files.
public enum SyntaxHighlighter {
    public enum Token: Sendable, Equatable {
        case keyword
        case string
        case comment
        case number
        case type
    }

    public struct Span: Sendable, Equatable {
        public var range: NSRange
        public var token: Token

        public init(range: NSRange, token: Token) {
            self.range = range
            self.token = token
        }
    }

    /// Languages recognised by name, including the aliases people actually write.
    public struct Language: Sendable {
        let keywords: Set<String>
        let lineComment: [String]
        let blockComment: (open: String, close: String)?
        let stringDelimiters: [Character]
        /// Treat capitalised words as type names.
        let highlightsTypes: Bool

        static let swift = Language(
            keywords: [
                "associatedtype", "actor", "async", "await", "break", "case", "catch", "class",
                "continue", "default", "defer", "deinit", "do", "else", "enum", "extension",
                "fallthrough", "false", "final", "for", "func", "guard", "if", "import", "in",
                "init", "inout", "internal", "is", "let", "lazy", "mutating", "nil", "open",
                "operator", "private", "protocol", "public", "repeat", "return", "self", "some",
                "static", "struct", "subscript", "super", "switch", "throw", "throws", "true",
                "try", "typealias", "var", "where", "while", "nonisolated", "any"
            ],
            lineComment: ["//"],
            blockComment: ("/*", "*/"),
            stringDelimiters: ["\""],
            highlightsTypes: true
        )

        static let javascript = Language(
            keywords: [
                "async", "await", "break", "case", "catch", "class", "const", "continue",
                "debugger", "default", "delete", "do", "else", "export", "extends", "false",
                "finally", "for", "from", "function", "if", "import", "in", "instanceof", "let",
                "new", "null", "of", "return", "static", "super", "switch", "this", "throw",
                "true", "try", "typeof", "undefined", "var", "void", "while", "yield",
                "interface", "type", "enum", "implements", "readonly", "as", "declare"
            ],
            lineComment: ["//"],
            blockComment: ("/*", "*/"),
            stringDelimiters: ["\"", "'", "`"],
            highlightsTypes: true
        )

        static let python = Language(
            keywords: [
                "and", "as", "assert", "async", "await", "break", "class", "continue", "def",
                "del", "elif", "else", "except", "False", "finally", "for", "from", "global",
                "if", "import", "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass",
                "raise", "return", "True", "try", "while", "with", "yield", "self", "match", "case"
            ],
            lineComment: ["#"],
            blockComment: nil,
            stringDelimiters: ["\"", "'"],
            highlightsTypes: false
        )

        static let shell = Language(
            keywords: [
                "if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac",
                "function", "return", "export", "local", "set", "echo", "cd", "source", "in"
            ],
            lineComment: ["#"],
            blockComment: nil,
            stringDelimiters: ["\"", "'"],
            highlightsTypes: false
        )

        static let json = Language(
            keywords: ["true", "false", "null"],
            lineComment: [],
            blockComment: nil,
            stringDelimiters: ["\""],
            highlightsTypes: false
        )

        static let css = Language(
            keywords: [
                "important", "media", "import", "supports", "keyframes", "from", "to", "and", "not"
            ],
            lineComment: [],
            blockComment: ("/*", "*/"),
            stringDelimiters: ["\"", "'"],
            highlightsTypes: false
        )

        static func named(_ name: String?) -> Language? {
            switch name?.lowercased() {
            case "swift": return .swift
            case "js", "javascript", "jsx", "ts", "typescript", "tsx", "json5": return .javascript
            case "py", "python": return .python
            case "sh", "bash", "zsh", "shell", "console", "terminal": return .shell
            case "json": return .json
            case "css", "scss", "less": return .css
            case "c", "cpp", "c++", "objc", "objective-c", "java", "kotlin", "go", "rust", "php":
                // Close enough for reading: C-family comments, quotes and numbers.
                return .javascript
            default: return nil
            }
        }
    }

    /// Highlights `code`, whose text starts at `offset` in the document.
    ///
    /// Returns an empty array for unknown languages, leaving the block in plain code styling.
    public static func spans(in code: String, language: String?, offset: Int = 0) -> [Span] {
        guard let language = Language.named(language) else { return [] }

        let text = code as NSString
        var spans: [Span] = []
        var index = 0

        func emit(_ start: Int, _ end: Int, _ token: Token) {
            guard end > start else { return }
            spans.append(Span(range: NSRange(location: offset + start, length: end - start), token: token))
        }

        func matches(_ candidate: String, at position: Int) -> Bool {
            let length = (candidate as NSString).length
            guard position + length <= text.length else { return false }
            return text.substring(with: NSRange(location: position, length: length)) == candidate
        }

        while index < text.length {
            let character = Character(UnicodeScalar(text.character(at: index)) ?? " ")

            // Comments run to the end of the line, or to their closing marker.
            if let comment = language.lineComment.first(where: { matches($0, at: index) }) {
                _ = comment
                var end = index
                while end < text.length, text.character(at: end) != 0x0A { end += 1 }
                emit(index, end, .comment)
                index = end
                continue
            }

            if let block = language.blockComment, matches(block.open, at: index) {
                var end = index + (block.open as NSString).length
                while end < text.length, !matches(block.close, at: end) { end += 1 }
                end = min(end + (block.close as NSString).length, text.length)
                emit(index, end, .comment)
                index = end
                continue
            }

            if language.stringDelimiters.contains(character) {
                let quote = text.character(at: index)
                var end = index + 1
                while end < text.length {
                    let current = text.character(at: end)
                    if current == UInt16(UnicodeScalar("\\").value) {
                        end += 2
                        continue
                    }
                    if current == quote { end += 1; break }
                    // An unterminated string ends at the line break rather than swallowing
                    // the rest of the block.
                    if current == 0x0A { break }
                    end += 1
                }
                emit(index, min(end, text.length), .string)
                index = min(end, text.length)
                continue
            }

            if character.isNumber {
                var end = index
                while end < text.length {
                    let scalar = Character(UnicodeScalar(text.character(at: end)) ?? " ")
                    guard scalar.isNumber || scalar == "." || scalar == "_"
                            || ("a"..."f").contains(scalar.lowercased()) || scalar == "x" else { break }
                    end += 1
                }
                emit(index, end, .number)
                index = end
                continue
            }

            if character.isLetter || character == "_" {
                var end = index
                while end < text.length {
                    let scalar = Character(UnicodeScalar(text.character(at: end)) ?? " ")
                    guard scalar.isLetter || scalar.isNumber || scalar == "_" else { break }
                    end += 1
                }
                let word = text.substring(with: NSRange(location: index, length: end - index))
                if language.keywords.contains(word) {
                    emit(index, end, .keyword)
                } else if language.highlightsTypes, let first = word.first, first.isUppercase {
                    emit(index, end, .type)
                }
                index = end
                continue
            }

            index += 1
        }
        return spans
    }

    public static func supports(language: String?) -> Bool {
        Language.named(language) != nil
    }
}
