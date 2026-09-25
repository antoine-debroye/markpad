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
public enum ConversionInput: String, CaseIterable, Sendable {
    case markdown
    case pdf
    case image
    /// `.docx`, read directly from its OOXML parts.
    case wordDocument
    /// `.doc`, `.rtf`, `.rtfd` and `.odt`, read through Cocoa's text importers.
    case richText
    /// `.html`, `.htm`, `.xhtml` and Safari `.webarchive`.
    case webPage
    case presentation
    case spreadsheet
    case ebook
    /// `.csv` and `.tsv`.
    case delimitedText
    case json
    case xml
    case audio

    /// Classifies a file by its extension.
    ///
    /// The extension table is checked before the content type: several of these kinds conform
    /// to broader types (CSV is plain text, `.rtfd` has no system type at all), so asking the
    /// type system first would put them in the wrong bucket.
    public static func detect(for url: URL) -> ConversionInput? {
        let ext = url.pathExtension.lowercased()
        if let kind = byExtension[ext] { return kind }
        guard let type = UTType(filenameExtension: ext) else { return nil }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .markpadMarkdown) { return .markdown }
        // MIDI conforms to public.audio but has no speech in it.
        if type.conforms(to: .audio), !type.conforms(to: .midi) { return .audio }
        return nil
    }

    private static let byExtension: [String: ConversionInput] = {
        var table: [String: ConversionInput] = [:]
        for (kind, extensions) in extensionsByKind {
            for ext in extensions { table[ext] = kind }
        }
        return table
    }()

    /// Every extension recognised by name, per kind.
    public static let extensionsByKind: [ConversionInput: [String]] = [
        .markdown: ["md", "markdown", "mdown", "mkd", "mdtext", "text", "txt"],
        .pdf: ["pdf"],
        .image: ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp"],
        .wordDocument: ["docx", "docm", "dotx"],
        .richText: ["doc", "rtf", "rtfd", "odt"],
        .webPage: ["html", "htm", "xhtml", "webarchive"],
        .presentation: ["pptx", "pptm", "potx"],
        .spreadsheet: ["xlsx", "xlsm", "xltx"],
        .ebook: ["epub"],
        .delimitedText: ["csv", "tsv"],
        .json: ["json"],
        .xml: ["xml"],
        .audio: ["m4a", "mp3", "wav", "aif", "aiff", "caf", "aac", "flac"],
    ]

    /// Content types for open panels. The system does not map the `.rtfd` extension to its
    /// declared type (`com.apple.rtfd`), so that one is added by constant.
    public static var importableContentTypes: [UTType] {
        var types: [UTType] = [.pdf, .image, .audio]
        for (kind, extensions) in extensionsByKind where kind != .markdown {
            for ext in extensions {
                if let type = UTType(filenameExtension: ext), !type.isDynamic, !types.contains(type) {
                    types.append(type)
                }
            }
        }
        if !types.contains(.rtfd) { types.append(.rtfd) }
        return types
    }

    /// How the kind is described to people, e.g. in an error or a list row.
    public var displayName: String {
        switch self {
        case .markdown: return "Markdown"
        case .pdf: return "PDF"
        case .image: return "Image"
        case .wordDocument: return "Word document"
        case .richText: return "Rich text document"
        case .webPage: return "Web page"
        case .presentation: return "PowerPoint presentation"
        case .spreadsheet: return "Excel workbook"
        case .ebook: return "EPUB book"
        case .delimitedText: return "CSV/TSV table"
        case .json: return "JSON"
        case .xml: return "XML"
        case .audio: return "Audio"
        }
    }

    /// Recognising text in pictures and transcribing speech are slow and memory-hungry, so a
    /// batch runs fewer of these at once.
    public var isHeavy: Bool {
        switch self {
        case .pdf, .image, .audio: return true
        default: return false
        }
    }

    /// Formats this input can be converted into.
    public var availableOutputs: [ConversionFormat] {
        switch self {
        case .markdown: return [.word, .html, .plainText]
        default: return [.markdown, .word, .html, .plainText]
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
    /// The file is locked with a password. Converting it needs the password, which Markpad
    /// never asks for.
    case passwordProtected(URL)
    /// Speech recognition has not been allowed for Markpad, or is unavailable on this Mac.
    case speechUnavailable(String)
    /// Audio can only be transcribed through the asynchronous entry points.
    case requiresAsynchronousImport(URL)
    /// The caller asked for the conversion to stop. Not a failure: callers that present errors
    /// should filter this case rather than showing it, since the user already knows.
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "The conversion was cancelled."
        case .unsupportedInput(let url):
            return "Markpad can't convert \(url.lastPathComponent). Supported inputs are Markdown, PDF, images, "
                + "Word, rich text, web pages, PowerPoint, Excel, EPUB, CSV, JSON, XML and audio files."
        case .unsupportedConversion(let input, let format):
            return "Converting \(input.displayName) to \(format.displayName) isn't supported."
        case .unreadableFile(let url):
            return "Couldn't read \(url.lastPathComponent)."
        case .noTextFound(let url):
            return "No text could be extracted from \(url.lastPathComponent)."
        case .exportFailed(let reason):
            return reason
        case .passwordProtected(let url):
            return "\(url.lastPathComponent) is protected with a password. Remove the password in the app that made it, then convert it again."
        case .speechUnavailable(let reason):
            return reason
        case .requiresAsynchronousImport(let url):
            return "\(url.lastPathComponent) is audio, which is transcribed in the background. Use Markpad's import or converter window."
        }
    }
}
