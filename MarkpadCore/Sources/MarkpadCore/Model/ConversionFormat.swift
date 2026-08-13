import Foundation
import UniformTypeIdentifiers

/// The output formats Markpad can produce.
public enum ConversionFormat: String, CaseIterable, Sendable {
    case markdown
    case word
    case html
    case plainText

    public var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .word: return "docx"
        case .html: return "html"
        case .plainText: return "txt"
        }
    }

    public var displayName: String {
        switch self {
        case .markdown: return "Markdown"
        case .word: return "Word Document"
        case .html: return "HTML"
        case .plainText: return "Plain Text"
        }
    }

    public var contentType: UTType {
        switch self {
        case .markdown: return .markpadMarkdown
        case .word: return UTType("org.openxmlformats.wordprocessingml.document") ?? .data
        case .html: return .html
        case .plainText: return .plainText
        }
    }
}

/// The input kinds Markpad recognises.
public enum ConversionInput: Sendable {
    case markdown
    case pdf
    case image

    /// Classifies a file by content type, falling back to its path extension when the
    /// type is unknown (files arriving from Shortcuts sometimes lack a resolved type).
    public static func detect(for url: URL) -> ConversionInput? {
        if let type = UTType(filenameExtension: url.pathExtension.lowercased()) {
            if type.conforms(to: .pdf) { return .pdf }
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .markpadMarkdown) { return .markdown }
        }
        switch url.pathExtension.lowercased() {
        case "md", "markdown", "mdown", "mkd", "mdtext", "text", "txt": return .markdown
        case "pdf": return .pdf
        case "png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp": return .image
        default: return nil
        }
    }

    /// Formats this input can be converted into.
    public var availableOutputs: [ConversionFormat] {
        switch self {
        case .markdown: return [.word, .html, .plainText]
        case .pdf, .image: return [.markdown, .word, .html, .plainText]
        }
    }
}

public extension UTType {
    /// `net.daringfireball.markdown` is not declared by the system, so Markpad imports it.
    static let markpadMarkdown = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
}

public enum ConversionError: LocalizedError, Sendable {
    case unsupportedInput(URL)
    case unsupportedConversion(from: ConversionInput, to: ConversionFormat)
    case unreadableFile(URL)
    case noTextFound(URL)
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedInput(let url):
            return "Markpad can't read \(url.lastPathComponent). Supported inputs are Markdown, PDF and image files."
        case .unsupportedConversion(let input, let format):
            return "Converting \(input) to \(format.displayName) isn't supported."
        case .unreadableFile(let url):
            return "Couldn't read \(url.lastPathComponent)."
        case .noTextFound(let url):
            return "No text could be extracted from \(url.lastPathComponent)."
        case .exportFailed(let reason):
            return reason
        }
    }
}
