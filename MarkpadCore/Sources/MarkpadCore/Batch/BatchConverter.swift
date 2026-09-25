import Foundation

/// Runs a `BatchPlan`: converts each item and writes its Markdown and pictures.
///
/// A failure is confined to its own item. Cancelling stops queued items and interrupts running
/// ones; what has already been written stays written, and nothing half-written is left behind.
public struct BatchConverter: Sendable {
    public enum Event: Sendable, Equatable {
        /// The source is a cloud file being downloaded before it can be read.
        case downloading(BatchPlan.Item.ID)
        case started(BatchPlan.Item.ID)
        case progress(BatchPlan.Item.ID, ImportProgress)
        case finished(BatchPlan.Item.ID, output: URL, notices: [String])
        case failed(BatchPlan.Item.ID, message: String)
        case cancelled(BatchPlan.Item.ID)
    }

    public enum Outcome: Sendable, Equatable {
        case finished(output: URL, notices: [String])
        case failed(message: String)
        case cancelled
    }

    /// Items converted at once. OCR and speech each keep several cores and a lot of memory
    /// busy, so they are limited separately from the fast text formats.
    public var heavyLimit: Int
    public var totalLimit: Int
    /// Settings passed to every import, e.g. the speech language. Pictures folders and progress
    /// are filled in per item.
    public var importOptions: ImportOptions

    public init(heavyLimit: Int? = nil, totalLimit: Int? = nil, importOptions: ImportOptions = .init()) {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        self.heavyLimit = max(1, heavyLimit ?? (cores >= 8 ? 2 : 1))
        self.totalLimit = max(1, totalLimit ?? min(4, max(2, cores / 2)))
        self.importOptions = importOptions
    }

    /// Converts `items`, reporting each step through `events` from worker threads. Returns the
    /// outcome for every item, keyed by id.
    @discardableResult
    public func run(
        _ items: [BatchPlan.Item],
        events: @escaping @Sendable (Event) -> Void = { _ in }
    ) async -> [BatchPlan.Item.ID: Outcome] {
        var outcomes: [BatchPlan.Item.ID: Outcome] = [:]
        var queue = items[...]
        var heavyRunning = 0
        var running = 0

        await withTaskGroup(of: (BatchPlan.Item, Outcome).self) { group in
            func startWhatFits() {
                // Starts the earliest queued items that fit, so a queue of slow PDFs does not
                // hold up the text files behind it.
                var index = queue.startIndex
                while running < totalLimit, index < queue.endIndex {
                    let item = queue[index]
                    if item.input.isHeavy && heavyRunning >= heavyLimit {
                        index = queue.index(after: index)
                        continue
                    }
                    queue.remove(at: index)
                    running += 1
                    if item.input.isHeavy { heavyRunning += 1 }
                    group.addTask { (item, await self.convert(item, events: events)) }
                }
            }

            startWhatFits()
            while let (item, outcome) = await group.next() {
                running -= 1
                if item.input.isHeavy { heavyRunning -= 1 }
                outcomes[item.id] = outcome
                if Task.isCancelled {
                    for pending in queue {
                        outcomes[pending.id] = .cancelled
                        events(.cancelled(pending.id))
                    }
                    queue = []
                } else {
                    startWhatFits()
                }
            }
        }
        return outcomes
    }

    private func convert(_ item: BatchPlan.Item, events: @escaping @Sendable (Event) -> Void) async -> Outcome {
        if Task.isCancelled {
            events(.cancelled(item.id))
            return .cancelled
        }
        do {
            try await BatchFileAccess.materialise(item.source) { events(.downloading(item.id)) }
            events(.started(item.id))

            var options = importOptions
            options.document.assetFolderName = item.assetFolderName
            let id = item.id
            options.progress = { progress in events(.progress(id, progress)) }

            let imported = try await ConversionService().importDocument(at: item.source, options: options)
            try Task.checkCancellation()
            try BatchWriter.write(imported, to: item.output, assetFolderName: item.assetFolderName)

            events(.finished(item.id, output: item.output, notices: imported.notices))
            return .finished(output: item.output, notices: imported.notices)
        } catch let error as ConversionError {
            if case .cancelled = error {
                events(.cancelled(item.id))
                return .cancelled
            }
            let message = error.errorDescription ?? "The file couldn't be converted."
            events(.failed(item.id, message: message))
            return .failed(message: message)
        } catch is CancellationError {
            events(.cancelled(item.id))
            return .cancelled
        } catch {
            let message = BatchWriter.describe(error, for: item)
            events(.failed(item.id, message: message))
            return .failed(message: message)
        }
    }
}

/// Makes sure a cloud file is on disk before it is read.
enum BatchFileAccess {
    /// Downloads an iCloud or File Provider placeholder, calling `onDownload` first when one
    /// is needed. Coordinated reading is what makes a File Provider (OneDrive, Dropbox)
    /// materialise the file; for an ordinary local file it returns at once.
    static func materialise(_ url: URL, onDownload: () -> Void) async throws {
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        if let values = try? url.resourceValues(forKeys: keys),
           values.isUbiquitousItem == true,
           values.ubiquitousItemDownloadingStatus != .current {
            onDownload()
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
        // The asynchronous form waits on a queue of its own rather than blocking a shared
        // thread for the whole download, and can be cancelled.
        let coordinator = NSFileCoordinator(filePresenter: nil)
        let intent = NSFileAccessIntent.readingIntent(with: url, options: [.withoutChanges])
        let queue = OperationQueue()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                coordinator.coordinate(with: [intent], queue: queue) { error in
                    if let error {
                        let cancelled = (error as NSError).domain == NSCocoaErrorDomain
                            && (error as NSError).code == NSUserCancelledError
                        continuation.resume(throwing: cancelled ? ConversionError.cancelled : error)
                    } else if !FileManager.default.isReadableFile(atPath: intent.url.path) {
                        continuation.resume(throwing: ConversionError.unreadableFile(url))
                    } else {
                        continuation.resume()
                    }
                }
            }
        } onCancel: {
            coordinator.cancel()
        }
    }
}

/// Writes a converted document without ever replacing an existing file.
///
/// Each file is written in full under a temporary name in the destination folder and then
/// renamed into place with `RENAME_EXCL`, which fails rather than overwrites. A crash or quit
/// mid-write therefore leaves at most a hidden temporary file, never a truncated `.md`.
enum BatchWriter {
    static func write(_ imported: ImportedMarkdown, to output: URL, assetFolderName: String) throws {
        let fileManager = FileManager.default
        let directory = output.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        // Pictures first, so the Markdown never exists pointing at a folder that does not.
        var assetsFolder: URL?
        if !imported.assets.isEmpty {
            let final = directory.appendingPathComponent(assetFolderName, isDirectory: true)
            // Short staging names: the final name may already be near the 255-byte limit.
            let staging = directory.appendingPathComponent(".markpad-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
            do {
                for asset in imported.assets {
                    try asset.data.write(to: staging.appendingPathComponent(asset.name))
                }
                _ = setxattr(staging.path, BatchPlanner.generatedAttribute, "1", 1, 0, 0)
                try renameExclusively(staging, to: final)
            } catch {
                try? fileManager.removeItem(at: staging)
                throw error
            }
            assetsFolder = final
        }

        let staging = directory.appendingPathComponent(".markpad-\(UUID().uuidString)")
        do {
            try Data(imported.markdown.utf8).write(to: staging)
            try renameExclusively(staging, to: output)
        } catch {
            try? fileManager.removeItem(at: staging)
            if let assetsFolder { try? fileManager.removeItem(at: assetsFolder) }
            throw error
        }
    }

    static func renameExclusively(_ source: URL, to destination: URL) throws {
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            if code == EEXIST {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: destination.path])
        }
    }

    /// A readable message for a write or read failure.
    static func describe(_ error: Error, for item: BatchPlan.Item) -> String {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == CocoaError.fileWriteFileExists.rawValue {
            return "\(item.output.lastPathComponent) appeared while converting, so it was left alone."
        }
        if nsError.domain == NSCocoaErrorDomain,
           [CocoaError.fileWriteNoPermission.rawValue, CocoaError.fileReadNoPermission.rawValue].contains(nsError.code) {
            return "Markpad doesn't have permission to write to \(item.output.deletingLastPathComponent().lastPathComponent)."
        }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == CocoaError.fileWriteOutOfSpace.rawValue {
            return "The disk is full."
        }
        return nsError.localizedDescription
    }
}
