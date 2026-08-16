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
        host: NSWindow? = nil,
        onError: @escaping (String) -> Void
    ) {
        // The window is passed in rather than read from `NSApp.keyWindow`. Two things make that
        // unreliable here: the action runs while the toolbar menu is still tracking, and
        // `NSSavePanel.begin` then presents its own window — so by the time the completion block
        // runs, the key window is anything but the document being exported.
        let host = host ?? NSApp.mainWindow
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
                    // The panel's own URL, not `baseName`: renaming the file in the save panel
                    // should be reflected in what the confirmation says.
                    ToastCenter.shared.show("Exported \(url.lastPathComponent)", in: host)
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

    /// Chooses a PDF or image and hands it to `session`, which converts it off the main thread.
    @MainActor
    static func importFile(into session: ImportSession, onError: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a PDF or image to convert to Markdown"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            session.begin(urls: [url], onError: onError)
        }
    }

    /// Opens converted text as a document the user can review, edit and save elsewhere.
    ///
    /// The content is staged as a real file so the standard document machinery — window
    /// title, autosave, Save As, revert — works exactly as it does for any other file.
    @MainActor
    static func openNewDocument(with markdown: String, suggestedName: String, convertedFrom source: URL? = nil) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Converted", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let safeName = suggestedName.isEmpty ? "Converted" : suggestedName
        let url = directory.appendingPathComponent("\(safeName).md")
        do {
            try Data(markdown.utf8).write(to: url, options: .atomic)
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error {
                    NSApp.presentError(error)
                    return
                }
                guard let source else { return }
                // Targeted at the new document's window, which `display: true` has just made
                // key — not at the window the import was started from.
                ToastCenter.shared.show(
                    "Imported \(source.lastPathComponent) as \(url.lastPathComponent)",
                    in: NSApp.keyWindow
                )
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
    let importSession: ImportSession
    /// The document's own window, so its confirmation lands on it.
    let hostWindow: NSWindow?
    let palette: ChromePalette

    private var baseName: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    var body: some View {
        Menu {
            ForEach([ConversionFormat.word, .html, .plainText], id: \.rawValue) { format in
                Button("\(format.displayName)…") {
                    DocumentActions.export(
                        markdown: document.text,
                        to: format,
                        baseName: baseName,
                        resourceDirectory: fileURL?.deletingLastPathComponent(),
                        host: hostWindow,
                        onError: { error = ExportError(message: $0) }
                    )
                }
            }
            Divider()
            Button("Import PDF or Image…") {
                DocumentActions.importFile(
                    into: importSession,
                    onError: { error = ExportError(message: $0) }
                )
            }
        } label: {
            // The design's bordered button with a text label, not a bare toolbar icon.
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 11))
                Text("Export")
                    .font(.system(size: 12))
            }
            .foregroundStyle(palette.controlText)
        }
        .menuStyle(.borderlessButton)
        // The design shows a small chevron after the label. Drawing one in the label does not
        // survive `menuStyle`, which re-renders it, so the built-in indicator is used instead.
        .menuIndicator(.visible)
        .fixedSize()
        // Applied around the menu rather than inside its label: `menuStyle` re-renders the
        // label, and a background set in there is dropped.
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.controlFill))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.controlBorder, lineWidth: 1))
        .help("Convert this document to Word, HTML or plain text")
    }
}
