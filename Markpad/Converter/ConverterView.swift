import AppKit
import MarkpadCore
import SwiftUI
import UniformTypeIdentifiers

/// The Convert to Markdown window: stage files and folders, choose where the Markdown goes,
/// watch each file convert, then review what happened.
struct ConverterView: View {
    @ObservedObject var model: ConverterModel = .shared
    @State private var isDropTargeted = false
    @State private var showRecents = false
    @AppStorage(ConverterModel.includesPicturesKey) private var includesPictures = true
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ChromePalette { ChromePalette(isDark: colorScheme == .dark) }

    var body: some View {
        VStack(spacing: 0) {
            switch model.phase {
            case .staging:
                stagingContent
            case .running, .finished:
                resultsContent
            }
        }
        .frame(minWidth: 560, minHeight: 440)
        // The same header as a document window, so moving between the two feels like one app.
        .toolbar { toolbarContent }
        .withoutToolbarTitle()
        .toolbarBackground(palette.toolbarBackground, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .onWindow { window in
            if let window { WindowChrome.apply(to: window) }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .overlay {
            if isDropTargeted && model.phase != .running {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Header

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if #available(macOS 26.0, *) {
            headerItems.sharedBackgroundVisibility(.hidden)
        } else {
            headerItems
        }
    }

    /// Mirrors the document window's header: Recents on the left, the title in the middle, and
    /// the way back to documents on the right where the document window has Convert.
    @ToolbarContentBuilder
    private var headerItems: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { showRecents.toggle() } label: {
                ChromePill(palette: palette, isActive: showRecents) {
                    HStack(spacing: 5) {
                        Image(systemName: "clock")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.secondary)
                        Text("Recents")
                            .font(.system(size: 11.5))
                            .foregroundStyle(palette.controlText)
                    }
                }
            }
            .buttonStyle(.plain)
            .help("Recently opened documents")
            .popover(isPresented: $showRecents, arrowEdge: .bottom) {
                RecentsPanel(isPresented: $showRecents)
            }
        }

        ToolbarItem(placement: .principal) {
            VStack(spacing: 0) {
                Text("Convert to Markdown")
                    .font(.system(size: 13, weight: colorScheme == .dark ? .regular : .semibold))
                    .foregroundStyle(palette.title)
                Text(headerSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.secondary)
                    .monospacedDigit()
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Button { NSDocumentController.shared.newDocument(nil) } label: {
                ChromePill(palette: palette, height: 26) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.pencil").font(.system(size: 11))
                        Text("New").font(.system(size: 12))
                    }
                    .foregroundStyle(palette.controlText)
                }
            }
            .buttonStyle(.plain)
            .help("New Markdown document (⌘N)")
        }

        ToolbarItem(placement: .primaryAction) {
            Button { NSDocumentController.shared.openDocument(nil) } label: {
                ChromePill(palette: palette, height: 26) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text").font(.system(size: 11))
                        Text("Open…").font(.system(size: 12))
                    }
                    .foregroundStyle(palette.controlText)
                }
            }
            .buttonStyle(.plain)
            .help("Open a Markdown document (⌘O)")
        }
    }

    private var headerSubtitle: String {
        switch model.phase {
        case .staging: return model.staged.isEmpty ? "Word, PDF, web, sheets, slides, audio…" : model.previewSummary
        case .running: return model.runningSummary
        case .finished: return model.finishedSummary
        }
    }

    // MARK: - Staging

    private var stagingContent: some View {
        VStack(spacing: 0) {
            if model.staged.isEmpty {
                emptyDropZone
            } else {
                stagedList
            }
            Divider()
            optionsForm
            Divider()
            HStack {
                Text(model.previewSummary)
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Spacer()
                Button("Convert") { model.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canStart)
            }
            .padding(16)
        }
    }

    private var emptyDropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Drop files or folders to convert to Markdown")
                .font(.title3)
            Text("Word, rich text, web pages, PowerPoint, Excel, EPUB, CSV, JSON, XML, PDF, images and audio. Folders are searched, sub-folders included.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            addButtons
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundStyle(.tertiary)
                .padding(16)
        )
    }

    private var addButtons: some View {
        HStack {
            Button("Add Files…") { chooseFiles() }
            Button("Add Folder…") { chooseFolder() }
        }
    }

    private var stagedList: some View {
        VStack(spacing: 0) {
            List {
                ForEach(model.staged, id: \.self) { url in
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable()
                            .frame(width: 20, height: 20)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Text(kindDescription(url))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            model.remove(url)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Remove")
                        .accessibilityLabel("Remove \(url.lastPathComponent)")
                    }
                }
            }
            HStack {
                addButtons
                Spacer()
                Button("Clear") { model.clear() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private var optionsForm: some View {
        Form {
            Picker("Save Markdown", selection: $model.location) {
                ForEach(ConverterModel.LocationChoice.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            if model.location != .nextToSource {
                LabeledContent("Destination") {
                    HStack {
                        Text(model.destination.map { $0.path(percentEncoded: false) } ?? "None chosen")
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(model.destination == nil ? .secondary : .primary)
                        Button("Choose…") { chooseDestination() }
                    }
                }
            }
            Picker("If the Markdown file exists", selection: $model.existingFiles) {
                Text("Skip that file").tag(BatchExistingFilePolicy.skip)
                Text("Keep both").tag(BatchExistingFilePolicy.keepBoth)
            }
            // Always shown, like the other options, so it can be set before adding files.
            Picker("Converting images", selection: $includesPictures) {
                Text("Picture and its text").tag(true)
                Text("Text only").tag(false)
            }
            if model.containsAudio {
                SpeechLanguagePicker(selection: $model.speechLocale)
            }
            Toggle("Show the results in Finder when done", isOn: $model.revealWhenDone)
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func kindDescription(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if values?.isDirectory == true, values?.isPackage != true { return "Folder" }
        return ConversionInput.detect(for: url)?.displayName ?? "Not a format Markpad converts"
    }

    // MARK: - Running and results

    private var resultsContent: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(model.phase == .running ? "Converting…" : "Finished")
                        .font(.headline)
                    Spacer()
                    Text(model.phase == .running ? model.runningSummary : model.finishedSummary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if model.phase == .running {
                    ProgressView(value: model.overallFraction)
                        .progressViewStyle(.linear)
                }
            }
            .padding(16)

            Divider()

            List {
                ForEach(model.convertibleRows) { row in
                    ResultRow(row: row, onOpen: { model.open(row) })
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { model.open(row) }
                        .contextMenu {
                            if row.output != nil {
                                Button("Open in Markpad") { model.open(row) }
                                Button("Show in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([row.output!])
                                }
                            }
                            Button("Show Original in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([row.source])
                            }
                        }
                }
                if !model.skippedRows.isEmpty {
                    Section("Skipped") {
                        ForEach(model.skippedRows) { row in
                            ResultRow(row: row, onOpen: nil)
                        }
                    }
                }
            }

            Divider()

            HStack {
                if model.phase == .running {
                    Spacer()
                    Button("Cancel") { model.cancel() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("Show in Finder") { model.revealOutputs() }
                        .disabled(model.count(.done) == 0)
                    Button("Copy Errors") { model.copyErrors() }
                        .disabled(model.count(.failed) == 0)
                    Spacer()
                    if model.hasRetryable {
                        Button("Retry Failed") { model.retryFailed() }
                    }
                    // One result: opening it is the obvious next step, so it is the default.
                    if model.count(.done) == 1, let only = model.rows.first(where: { $0.status == .done }) {
                        Button("Convert More") { model.resetToStaging(keepingStaged: false) }
                        Button("Open in Markpad") { model.open(only) }
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button("Convert More") { model.resetToStaging(keepingStaged: false) }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(16)
        }
    }

    // MARK: - Choosing files

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard model.phase != .running else { return false }
        let group = DispatchGroup()
        let collected = URLCollector()
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { collected.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            receive(collected.urls)
        }
        return true
    }

    /// A Markdown file dropped here opens in the viewer, as it would from the Finder; anything
    /// else is staged for conversion.
    private func receive(_ urls: [URL]) {
        let markdown = urls.filter(ConverterModel.isMarkdownFile)
        for url in markdown {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        }
        let rest = urls.filter { !ConverterModel.isMarkdownFile($0) }
        if !rest.isEmpty { model.add(rest) }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ConversionInput.importableContentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Choose files to convert to Markdown"
        panel.prompt = "Add"
        if panel.runModal() == .OK { model.add(panel.urls) }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose folders to convert. Sub-folders are included."
        panel.prompt = "Add"
        if panel.runModal() == .OK { model.add(panel.urls) }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose where to save the Markdown files"
        panel.prompt = "Choose"
        if panel.runModal() == .OK { model.destination = panel.url }
    }
}

/// Collects URLs from item providers, which call back on arbitrary threads.
private final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URL] = []

    func append(_ url: URL) {
        lock.lock(); stored.append(url); lock.unlock()
    }

    var urls: [URL] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

/// One file in the running or finished list.
private struct ResultRow: View {
    let row: ConverterModel.Row
    /// Opens the converted file in the viewer. Nil for rows with nothing to open.
    let onOpen: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.source.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(row.detail)
                    .font(.caption)
                    .foregroundStyle(row.status == .failed ? Color.red : Color.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                if row.status == .converting {
                    if let fraction = row.fraction {
                        ProgressView(value: fraction).progressViewStyle(.linear)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                if row.notices.count > 1 {
                    ForEach(row.notices.dropFirst(), id: \.self) { notice in
                        Text(notice).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 8)
            if row.status == .done, row.output != nil, let onOpen {
                Button("Open", action: onOpen)
                    .controlSize(.small)
                    .help("Open \(row.output?.lastPathComponent ?? "") in Markpad")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch row.status {
        case .waiting:
            Image(systemName: "clock").foregroundStyle(.secondary).accessibilityLabel("Waiting")
        case .downloading:
            Image(systemName: "icloud.and.arrow.down").foregroundStyle(.secondary).accessibilityLabel("Downloading")
        case .converting:
            ProgressView().controlSize(.small).accessibilityLabel("Converting")
        case .done:
            Image(systemName: row.notices.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(row.notices.isEmpty ? .green : .orange)
                .accessibilityLabel(row.notices.isEmpty ? "Converted" : "Converted with notes")
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).accessibilityLabel("Failed")
        case .cancelled:
            Image(systemName: "minus.circle").foregroundStyle(.secondary).accessibilityLabel("Cancelled")
        case .skipped:
            Image(systemName: "arrow.uturn.right.circle").foregroundStyle(.secondary).accessibilityLabel("Skipped")
        }
    }
}

/// The spoken language for audio files. Lists the languages on-device transcription supports,
/// with the system language as the default.
struct SpeechLanguagePicker: View {
    @Binding var selection: String
    @State private var identifiers: [String] = []

    var body: some View {
        Picker("Spoken language", selection: $selection) {
            Text("System language").tag("")
            ForEach(identifiers, id: \.self) { identifier in
                Text(Locale.current.localizedString(forIdentifier: identifier) ?? identifier).tag(identifier)
            }
        }
        .task {
            identifiers = await SpeechPermission.supportedLocaleIdentifiers()
                .sorted { (Locale.current.localizedString(forIdentifier: $0) ?? $0) < (Locale.current.localizedString(forIdentifier: $1) ?? $1) }
        }
    }
}
