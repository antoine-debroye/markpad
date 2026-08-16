import AppIntents
import Foundation
import MarkpadCore
import UniformTypeIdentifiers

/// The output format offered by the Shortcuts actions.
enum IntentFormat: String, AppEnum {
    case markdown
    case word
    case html
    case plainText

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Format" }

    static var caseDisplayRepresentations: [IntentFormat: DisplayRepresentation] {
        [
            .markdown: "Markdown",
            .word: "Word (.docx)",
            .html: "HTML",
            .plainText: "Plain Text"
        ]
    }

    var conversionFormat: ConversionFormat {
        switch self {
        case .markdown: return .markdown
        case .word: return .word
        case .html: return .html
        case .plainText: return .plainText
        }
    }
}

/// Converts files between Markdown, Word, HTML, plain text — and turns PDFs and images into
/// Markdown. One action covers every direction so a shortcut can be built in a single step.
struct ConvertFileIntent: AppIntent {
    static var title: LocalizedStringResource { "Convert Files with Markpad" }

    static var description: IntentDescription {
        IntentDescription(
            "Converts Markdown to Word, HTML or plain text, and converts PDFs and images to Markdown.",
            categoryName: "Conversion",
            searchKeywords: ["markdown", "word", "docx", "html", "pdf", "ocr", "convert"]
        )
    }

    /// The conversion runs entirely in the background; bringing the app forward would
    /// interrupt whatever the user is doing.
    static var openAppWhenRun: Bool { false }

    // Content-type filtering on file parameters needs macOS 15; the intent validates the
    // input itself so it stays available on macOS 14.
    @Parameter(title: "Files", description: "Markdown, PDF or image files.")
    var files: [IntentFile]

    @Parameter(title: "Convert To", default: .word)
    var format: IntentFormat

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$files) to \(\.$format)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let service = ConversionService()
        var outputs: [IntentFile] = []

        for file in files {
            let url = try resolveURL(for: file)
            // Awaited rather than called synchronously: recognising a scanned PDF takes seconds,
            // and `perform` runs on the main actor.
            let result = try await service.importFile(at: url, to: format.conversionFormat)
            var output = IntentFile(
                data: result.data,
                filename: result.suggestedFilename,
                type: format.conversionFormat.contentType
            )
            output.removedOnCompletion = false
            outputs.append(output)
        }

        return .result(value: outputs)
    }

    /// Shortcuts may hand over a file reference or raw data; the importers need a real URL,
    /// so data-only inputs are staged in the app's temporary directory.
    private func resolveURL(for file: IntentFile) throws -> URL {
        if let url = file.fileURL, FileManager.default.fileExists(atPath: url.path) {
            return url
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IntentInputs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let name = file.filename.isEmpty ? "input" : URL(fileURLWithPath: file.filename).lastPathComponent
        let staged = directory.appendingPathComponent(name)
        try file.data.write(to: staged, options: .atomic)
        return staged
    }
}

/// Converts the given Markdown text (rather than a file) and returns the result as a file.
struct ConvertMarkdownTextIntent: AppIntent {
    static var title: LocalizedStringResource { "Convert Markdown Text with Markpad" }

    static var description: IntentDescription {
        IntentDescription(
            "Converts Markdown text into a Word, HTML or plain text file.",
            categoryName: "Conversion"
        )
    }

    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Markdown")
    var markdown: String

    @Parameter(title: "Convert To", default: .word)
    var format: IntentFormat

    @Parameter(title: "File Name", default: "Document")
    var name: String

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$markdown) to \(\.$format)") {
            \.$name
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let result = try ConversionService().convert(
            markdown: markdown,
            to: format.conversionFormat,
            baseName: name.isEmpty ? "Document" : name
        )
        var file = IntentFile(
            data: result.data,
            filename: result.suggestedFilename,
            type: format.conversionFormat.contentType
        )
        file.removedOnCompletion = false
        return .result(value: file)
    }
}

/// Extracts Markdown text from a PDF or image and returns it as text.
struct ExtractMarkdownIntent: AppIntent {
    static var title: LocalizedStringResource { "Get Markdown from File with Markpad" }

    static var description: IntentDescription {
        IntentDescription(
            "Reads a PDF or image and returns its content as Markdown text.",
            categoryName: "Conversion"
        )
    }

    static var openAppWhenRun: Bool { false }

    @Parameter(title: "File", description: "A PDF, image or Markdown file.")
    var file: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Get Markdown from \(\.$file)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let url: URL
        if let fileURL = file.fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            url = fileURL
        } else {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("IntentInputs", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            url = directory.appendingPathComponent(
                URL(fileURLWithPath: file.filename.isEmpty ? "input" : file.filename).lastPathComponent
            )
            try file.data.write(to: url, options: .atomic)
        }
        return .result(value: try await ConversionService().importMarkdown(fromFileAt: url))
    }
}

/// Ready-made actions so common conversions are one click in Shortcuts and the Finder's
/// Quick Actions menu.
struct MarkpadShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConvertFileIntent(),
            phrases: [
                "Convert files with \(.applicationName)",
                "Convert this file with \(.applicationName)"
            ],
            shortTitle: "Convert Files",
            systemImageName: "arrow.triangle.2.circlepath.doc.on.clipboard"
        )
        AppShortcut(
            intent: ExtractMarkdownIntent(),
            phrases: [
                "Get Markdown with \(.applicationName)",
                "Extract Markdown with \(.applicationName)"
            ],
            shortTitle: "Get Markdown",
            systemImageName: "doc.text.magnifyingglass"
        )
        AppShortcut(
            intent: ConvertMarkdownTextIntent(),
            phrases: [
                "Convert Markdown text with \(.applicationName)"
            ],
            shortTitle: "Convert Markdown Text",
            systemImageName: "doc.richtext"
        )
    }
}
