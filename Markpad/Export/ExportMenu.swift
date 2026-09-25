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

    /// Chooses files of any convertible kind and hands them to `session`, which converts them
    /// off the main thread and opens each as a new document.
    @MainActor
    static func importFile(into session: ImportSession, onError: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ConversionInput.importableContentTypes
        panel.allowsMultipleSelection = true
        panel.message = "Choose files to convert to Markdown"

        panel.begin { response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            session.begin(urls: panel.urls, onError: onError)
        }
    }

    /// The pictures folder beside a converted document: `Report_assets`.
    static func assetFolderName(for name: String) -> String {
        (name.isEmpty ? "Converted" : name) + "_assets"
    }

    /// Opens converted text as a document the user can review, edit and save elsewhere.
    ///
    /// The content is staged as a real file so the standard document machinery — window
    /// title, autosave, Save As, revert — works exactly as it does for any other file. Each
    /// import gets a folder of its own, so two files with the same name do not overwrite each
    /// other, and its pictures sit beside it where the Markdown expects them.
    @MainActor
    static func openNewDocument(with imported: ImportedMarkdown, suggestedName: String, convertedFrom source: URL? = nil) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Converted", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        let safeName = suggestedName.isEmpty ? "Converted" : suggestedName
        let url = directory.appendingPathComponent("\(safeName).md")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !imported.assets.isEmpty {
                let assets = directory.appendingPathComponent(assetFolderName(for: safeName), isDirectory: true)
                try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
                for asset in imported.assets {
                    try asset.data.write(to: assets.appendingPathComponent(asset.name))
                }
            }
            try Data(imported.markdown.utf8).write(to: url, options: .atomic)
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
            Button("Import File as Markdown…") {
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

/// Opens the Convert to Markdown window. Sits beside Export in the document header, drawn as
/// the same bordered control.
struct ConvertButton: View {
    @Environment(\.openWindow) private var openWindow
    let palette: ChromePalette

    var body: some View {
        Button { openWindow(id: ConverterWindow.id) } label: {
            ChromePill(palette: palette, height: 26) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 11))
                    Text("Convert")
                        .font(.system(size: 12))
                }
                .foregroundStyle(palette.controlText)
            }
        }
        .buttonStyle(.plain)
        .help("Convert Word, PDF, web, spreadsheet, slide or audio files to Markdown (⌥⌘I)")
    }
}
