import AppKit
import MarkpadCore
import SwiftUI

/// State behind the Convert to Markdown window: what is staged, where it goes, and how each
/// file is getting on.
///
/// One instance for the app, so closing the window does not abandon a batch: it keeps running,
/// and reopening the window shows where it has got to.
@MainActor
final class ConverterModel: ObservableObject {
    static let shared = ConverterModel()

    enum Phase: Equatable {
        case staging
        case running
        case finished
    }

    enum LocationChoice: String, CaseIterable, Identifiable {
        case nextToSource
        case folder
        case mirror

        var id: String { rawValue }

        var title: String {
            switch self {
            case .nextToSource: return "Next to the originals"
            case .folder: return "In one folder"
            case .mirror: return "In one folder, keeping sub-folders"
            }
        }
    }

    enum RowStatus: Equatable {
        case waiting
        case downloading
        case converting
        case done
        case failed
        case cancelled
        case skipped
    }

    struct Row: Identifiable, Equatable {
        /// Plan item id for converted files; negative for skipped ones.
        let id: Int
        let source: URL
        var status: RowStatus
        var detail: String
        var fraction: Double?
        var output: URL?
        var notices: [String] = []
    }

    // Staging
    @Published private(set) var staged: [URL] = []
    @Published var location: LocationChoice = .nextToSource { didSet { refreshPreview() } }
    @Published var destination: URL? { didSet { refreshPreview() } }
    @Published var existingFiles: BatchExistingFilePolicy = .skip { didSet { refreshPreview() } }
    @Published var revealWhenDone = UserDefaults.standard.bool(forKey: "converter.revealWhenDone") {
        didSet { UserDefaults.standard.set(revealWhenDone, forKey: "converter.revealWhenDone") }
    }
    /// BCP 47 identifier of the spoken language for audio, or empty for the system language.
    @Published var speechLocale = UserDefaults.standard.string(forKey: "converter.speechLocale") ?? "" {
        didSet { UserDefaults.standard.set(speechLocale, forKey: "converter.speechLocale") }
    }
    @Published private(set) var preview: BatchPlan?
    @Published private(set) var isPreviewing = false

    // Running
    @Published private(set) var phase: Phase = .staging
    @Published private(set) var rows: [Row] = []
    private var plan: BatchPlan?
    private var task: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var activity: NSObjectProtocol?

    var isRunning: Bool { phase == .running }

    // MARK: Staging

    func add(_ urls: [URL]) {
        guard phase != .running else { return }
        if phase == .finished { resetToStaging(keepingStaged: false) }
        for url in urls where !staged.contains(url) {
            staged.append(url)
        }
        refreshPreview()
    }

    func remove(_ url: URL) {
        staged.removeAll { $0 == url }
        refreshPreview()
    }

    func clear() {
        staged = []
        refreshPreview()
    }

    /// Whether a converted image keeps the picture itself above its text. Shared by the
    /// converter, Import and Settings; on unless the user turns it off.
    static let includesPicturesKey = "convert.includesImagePictures"
    static var includesPictures: Bool {
        UserDefaults.standard.object(forKey: includesPicturesKey) as? Bool ?? true
    }

    /// A single Markdown file, as opposed to a folder or a file to convert.
    static func isMarkdownFile(_ url: URL) -> Bool {
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        return !isFolder && BatchPlanner.isMarkdownExtension(url.pathExtension)
    }

    var needsDestination: Bool { location != .nextToSource && destination == nil }

    var canStart: Bool {
        phase == .staging && !needsDestination && !(preview?.items.isEmpty ?? true) && !isPreviewing
    }

    var containsAudio: Bool {
        preview?.items.contains { $0.input == .audio } ?? false
    }

    var previewSummary: String {
        guard let preview else { return staged.isEmpty ? "" : "Looking for files…" }
        let count = preview.items.count
        var text = count == 1 ? "1 file to convert" : "\(count) files to convert"
        if !preview.skipped.isEmpty { text += " · \(preview.skipped.count) skipped" }
        return text
    }

    private var planner: BatchPlanner {
        let resolved: BatchOutputLocation
        switch location {
        case .nextToSource: resolved = .nextToSource
        case .folder: resolved = destination.map { .folder($0) } ?? .nextToSource
        case .mirror: resolved = destination.map { .mirror($0) } ?? .nextToSource
        }
        return BatchPlanner(location: resolved, existingFiles: existingFiles)
    }

    /// Plans in the background: a dropped folder can hold thousands of files.
    private func refreshPreview() {
        previewTask?.cancel()
        guard !staged.isEmpty else {
            preview = nil
            isPreviewing = false
            return
        }
        isPreviewing = true
        let planner = self.planner
        let staged = self.staged
        previewTask = Task { [weak self] in
            let plan = await Task.detached(priority: .userInitiated) { planner.plan(staged) }.value
            guard !Task.isCancelled, let self else { return }
            self.preview = plan
            self.isPreviewing = false
        }
    }

    // MARK: Running

    func start() {
        guard canStart else { return }
        let planner = self.planner
        let staged = self.staged
        phase = .running
        rows = []

        task = Task { [weak self] in
            // Planned again rather than reusing the preview, so files added or removed on disk
            // since the preview are accounted for.
            let plan = await Task.detached(priority: .userInitiated) { planner.plan(staged) }.value
            guard let self else { return }
            self.plan = plan
            self.rows = plan.items.map {
                Row(id: $0.id, source: $0.source, status: .waiting, detail: "Waiting", fraction: nil)
            } + plan.skipped.enumerated().map { index, skipped in
                Row(id: -1 - index, source: skipped.source, status: .skipped, detail: skipped.explanation, fraction: nil)
            }

            if plan.items.contains(where: { $0.input == .audio }) {
                _ = await SpeechPermission.request()
            }
            await self.run(plan.items)
        }
    }

    func retryFailed() {
        guard phase == .finished, let plan else { return }
        let failedIDs = Set(rows.filter { $0.status == .failed || $0.status == .cancelled }.map(\.id))
        let items = plan.items.filter { failedIDs.contains($0.id) }
        guard !items.isEmpty else { return }
        for index in rows.indices where failedIDs.contains(rows[index].id) {
            rows[index].status = .waiting
            rows[index].detail = "Waiting"
            rows[index].fraction = nil
        }
        phase = .running
        task = Task { [weak self] in await self?.run(items) }
    }

    private func run(_ items: [BatchPlan.Item]) async {
        beginActivity()
        defer { endActivity() }

        var options = ImportOptions()
        options.audio.localeIdentifier = speechLocale.isEmpty ? nil : speechLocale
        options.document.includesOriginalPicture = Self.includesPictures
        let converter = BatchConverter(importOptions: options)

        let outcomes = await converter.run(items) { event in
            Task { @MainActor [weak self] in self?.apply(event) }
        }
        // Events hop to the main actor asynchronously and may still be in flight, so the
        // outcomes the converter returns settle each row; `apply` ignores anything later.
        for item in items {
            switch outcomes[item.id] {
            case .finished(let output, let notices)?:
                apply(.finished(item.id, output: output, notices: notices))
            case .failed(let message)?:
                apply(.failed(item.id, message: message))
            case .cancelled?, nil:
                apply(.cancelled(item.id))
            }
        }
        phase = .finished
        if revealWhenDone { revealOutputs() }
    }

    private func apply(_ event: BatchConverter.Event) {
        func update(_ id: Int, _ change: (inout Row) -> Void) {
            guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
            // A row that has settled stays settled: a progress update still hopping to the
            // main actor must not reopen it.
            switch rows[index].status {
            case .done, .failed, .cancelled, .skipped: return
            default: change(&rows[index])
            }
        }
        switch event {
        case .downloading(let id):
            update(id) { $0.status = .downloading; $0.detail = "Downloading…"; $0.fraction = nil }
        case .started(let id):
            update(id) { $0.status = .converting; $0.detail = "Starting…"; $0.fraction = 0 }
        case .progress(let id, let progress):
            update(id) { row in
                guard row.status == .converting else { return }
                row.detail = progress.statusDescription
                row.fraction = progress.fractionCompleted
            }
        case .finished(let id, let output, let notices):
            update(id) {
                $0.status = .done
                $0.output = output
                $0.notices = notices
                $0.detail = notices.first ?? output.lastPathComponent
                $0.fraction = nil
            }
        case .failed(let id, let message):
            update(id) { $0.status = .failed; $0.detail = message; $0.fraction = nil }
        case .cancelled(let id):
            update(id) { $0.status = .cancelled; $0.detail = "Cancelled"; $0.fraction = nil }
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// Cancels and returns once every running file has stopped and its temporary files are
    /// gone, so quitting never strands half-written output in the user's folders.
    func cancelAndWait() async {
        let running = task
        running?.cancel()
        await running?.value
    }

    /// Back to an empty window, or to the same files for another run.
    func resetToStaging(keepingStaged: Bool) {
        guard phase != .running else { return }
        phase = .staging
        rows = []
        plan = nil
        if !keepingStaged { staged = [] }
        refreshPreview()
    }

    // MARK: Summary

    var convertibleRows: [Row] { rows.filter { $0.status != .skipped } }
    var skippedRows: [Row] { rows.filter { $0.status == .skipped } }

    func count(_ status: RowStatus) -> Int { rows.filter { $0.status == status }.count }

    var overallFraction: Double {
        let total = convertibleRows.count
        guard total > 0 else { return 0 }
        let settled = convertibleRows.reduce(0.0) { sum, row in
            switch row.status {
            case .done, .failed, .cancelled: return sum + 1
            case .converting: return sum + (row.fraction ?? 0)
            default: return sum
            }
        }
        return settled / Double(total)
    }

    var runningSummary: String {
        let total = convertibleRows.count
        let settled = count(.done) + count(.failed) + count(.cancelled)
        var text = "\(settled) of \(total)"
        if count(.failed) > 0 { text += " · \(count(.failed)) failed" }
        return text
    }

    var finishedSummary: String {
        var parts = ["\(count(.done)) converted"]
        if count(.failed) > 0 { parts.append("\(count(.failed)) failed") }
        if count(.cancelled) > 0 { parts.append("\(count(.cancelled)) cancelled") }
        if count(.skipped) > 0 { parts.append("\(count(.skipped)) skipped") }
        return parts.joined(separator: " · ")
    }

    var hasRetryable: Bool { count(.failed) + count(.cancelled) > 0 }

    func copyErrors() {
        let lines = rows.filter { $0.status == .failed }.map { "\($0.source.lastPathComponent): \($0.detail)" }
        guard !lines.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    func revealOutputs() {
        let outputs = rows.compactMap(\.output)
        guard !outputs.isEmpty else { return }
        // Selecting thousands of files in one Finder window is slow and unreadable.
        NSWorkspace.shared.activateFileViewerSelecting(Array(outputs.prefix(50)))
    }

    func open(_ row: Row) {
        guard let output = row.output else { return }
        NSDocumentController.shared.openDocument(withContentsOf: output, display: true) { _, _, error in
            if let error { NSApp.presentError(error) }
        }
    }

    // MARK: Keeping the app alive

    private func beginActivity() {
        // Sudden and automatic termination are both declared, and either would let macOS
        // quit the app mid-batch.
        ProcessInfo.processInfo.disableSuddenTermination()
        ProcessInfo.processInfo.disableAutomaticTermination("Converting files to Markdown")
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Converting files to Markdown"
        )
    }

    private func endActivity() {
        ProcessInfo.processInfo.enableSuddenTermination()
        ProcessInfo.processInfo.enableAutomaticTermination("Converting files to Markdown")
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }
}
