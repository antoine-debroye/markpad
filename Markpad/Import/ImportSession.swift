import AppKit
import MarkpadCore
import SwiftUI

/// Drives one import — or a queue of them, when several files are dropped at once.
///
/// The conversion runs off the main thread through `ConversionService.importFile`; this type
/// owns the task, mirrors its progress for the sheet, and turns the result into a document.
@MainActor
final class ImportSession: ObservableObject {
    /// What is being converted, resolved up front so the sheet is complete on its first frame.
    struct Source: Equatable {
        let url: URL
        let byteCount: Int64
        let icon: NSImage

        var displayName: String { url.lastPathComponent }
        var targetName: String { url.deletingPathExtension().lastPathComponent + ".md" }

        init(url: URL) {
            self.url = url
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            self.byteCount = Int64(values?.fileSize ?? 0)
            self.icon = NSWorkspace.shared.icon(forFile: url.path)
        }
    }

    @Published private(set) var source: Source?
    @Published private(set) var progress: ImportProgress?
    /// Position in a multi-file drop, 1-based. Nil when only one file was given.
    @Published private(set) var fileIndex: Int?
    @Published private(set) var fileCount: Int = 0

    private var task: Task<Void, Never>?

    var isRunning: Bool { source != nil }

    // MARK: Presentation

    var sizeText: String {
        guard let source, source.byteCount > 0 else { return "" }
        return source.byteCount.formatted(.byteCount(style: .file))
    }

    /// "site-survey.pdf · 2.4 MB", or just the name when the size is unknown.
    var titleText: String {
        guard let source else { return "" }
        return sizeText.isEmpty ? source.displayName : "\(source.displayName) · \(sizeText)"
    }

    var statusText: String {
        progress?.statusDescription ?? "Preparing…"
    }

    var fraction: Double { progress?.fractionCompleted ?? 0 }

    var percentText: String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    /// Shown only for a multi-file drop, above the per-page line.
    var queueText: String? {
        guard let fileIndex, fileCount > 1 else { return nil }
        return "File \(fileIndex) of \(fileCount)"
    }

    var footerText: String {
        guard let source else { return "" }
        return "Opens as a new unsaved document named \(source.targetName). Nothing leaves this Mac."
    }

    // MARK: Running

    /// Converts each URL in turn, opening a document for each result.
    ///
    /// Serial on purpose: several files dropped on the Dock at once would otherwise start
    /// several imports, each fighting for the same sheet.
    func begin(urls: [URL], onError: @escaping (String) -> Void) {
        guard let first = urls.first else { return }
        task?.cancel()

        // Set synchronously, before the task starts. The sheet and the Dock-drop panel both key
        // off `isRunning`, and a caller that checks it on the next line would otherwise see an
        // idle session and tear the progress UI straight back down.
        fileCount = urls.count
        fileIndex = 1
        source = Source(url: first)
        progress = nil

        task = Task { [weak self] in
            // The app declares sudden termination support, so without this the system could kill
            // it mid-conversion.
            ProcessInfo.processInfo.disableSuddenTermination()
            defer { ProcessInfo.processInfo.enableSuddenTermination() }

            for (index, url) in urls.enumerated() {
                guard let self, !Task.isCancelled else { return }
                if index > 0 {
                    self.source = Source(url: url)
                    self.fileIndex = index + 1
                    self.progress = nil
                }

                do {
                    let markdown = try await ConversionService().importMarkdown(
                        fromFileAt: url,
                        options: .init(progress: { [weak self] update in
                            // Fired on the worker thread.
                            Task { @MainActor in self?.progress = update }
                        })
                    )
                    guard !Task.isCancelled else { return }
                    DocumentActions.openNewDocument(
                        with: markdown,
                        suggestedName: url.deletingPathExtension().lastPathComponent,
                        convertedFrom: url
                    )
                } catch is CancellationError {
                    return
                } catch ConversionError.cancelled {
                    // The user asked for this; saying so would be noise.
                    return
                } catch {
                    onError(error.localizedDescription)
                }
            }
            self?.finish()
        }
    }

    /// Stops the import and clears the sheet immediately.
    ///
    /// The page already inside Vision cannot be interrupted, so it finishes before the loop sees
    /// the cancellation — but the sheet is gone by then and its result is discarded.
    func cancel() {
        task?.cancel()
        task = nil
        finish()
    }

    private func finish() {
        source = nil
        progress = nil
        fileIndex = nil
        fileCount = 0
    }

    deinit {
        task?.cancel()
    }
}
