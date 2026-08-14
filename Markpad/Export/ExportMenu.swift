import AppKit
import MarkpadCore
import SwiftUI
import UniformTypeIdentifiers

/// Export and import actions, shared by the toolbar menu and the File menu commands.
enum DocumentActions {
    /// Runs a save panel and writes the converted document.
    @MainActor
    static func export(
        markdown: String,
        to format: ConversionFormat,
        baseName: String,
        resourceDirectory: URL?,
        onError: @escaping (String) -> Void
    ) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(baseName).\(format.fileExtension)"
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.message = "Export as \(format.displayName)"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    var service = ConversionService()
                    // HTML carries diagrams as SVG, so they have to be drawn before writing.
                    if format == .html {
                        service.diagrams = await renderedDiagrams(in: markdown)
                    }
                    let result = try service.convert(
                        markdown: markdown,
                        to: format,
                        baseName: baseName,
                        resourceDirectory: resourceDirectory
                    )
                    try result.data.write(to: url, options: .atomic)
                } catch {
                    onError(error.localizedDescription)
                }
            }
        }
    }

    /// Renders every diagram in a document, returning source-to-SVG pairs.
    @MainActor
    static func renderedDiagrams(in markdown: String) async -> [String: String] {
        let placements = StyleEngine().layout(for: markdown).diagrams
        guard !placements.isEmpty else { return [:] }

        var rendered: [String: String] = [:]
        for placement in placements where rendered[placement.source] == nil {
            // Exports are viewed in a browser that follows the reader's own appearance, so
            // the light rendering is the sensible default.
            if let diagram = await MermaidRenderer.shared
                .diagramRenderingIfNeeded(placement.source, dark: false) {
                rendered[placement.source] = diagram.svg
            }
        }
        return rendered
    }

    /// Imports a PDF or image, opening the recognised Markdown in a new document.
    @MainActor
    static func importFile(onError: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a PDF or image to convert to Markdown"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let markdown = try ConversionService().markdown(fromFileAt: url)
                openNewDocument(with: markdown, suggestedName: url.deletingPathExtension().lastPathComponent)
            } catch {
                onError(error.localizedDescription)
            }
        }
    }

    /// Opens converted text as a document the user can review, edit and save elsewhere.
    ///
    /// The content is staged as a real file so the standard document machinery — window
    /// title, autosave, Save As, revert — works exactly as it does for any other file.
    @MainActor
    static func openNewDocument(with markdown: String, suggestedName: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Converted", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let safeName = suggestedName.isEmpty ? "Converted" : suggestedName
        let url = directory.appendingPathComponent("\(safeName).md")
        do {
            try Data(markdown.utf8).write(to: url, options: .atomic)
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        } catch {
            NSApp.presentError(error)
        }
    }
}

struct ExportMenu: View {
    @ObservedObject var document: MarkdownDocument
    let fileURL: URL?
    @Binding var error: ExportError?

    private var baseName: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    var body: some View {
        Menu {
            ForEach([ConversionFormat.word, .html, .plainText], id: \.rawValue) { format in
                Button("Export as \(format.displayName)…") {
                    DocumentActions.export(
                        markdown: document.text,
                        to: format,
                        baseName: baseName,
                        resourceDirectory: fileURL?.deletingLastPathComponent(),
                        onError: { error = ExportError(message: $0) }
                    )
                }
            }
            Divider()
            Button("Import PDF or Image…") {
                DocumentActions.importFile(onError: { error = ExportError(message: $0) })
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .help("Convert this document to Word, HTML or plain text")
    }
}
