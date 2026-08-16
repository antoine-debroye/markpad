import Foundation
import XCTest
@testable import MarkpadCore

/// Access to the bundled test fixtures and scratch space for generated artefacts.
enum Fixtures {
    static func url(_ name: String) throws -> URL {
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? bundle.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
            throw XCTSkip("Fixture \(name) is missing from the test bundle")
        }
        return url
    }

    static func sampleMarkdown() throws -> String {
        try String(contentsOf: try url("sample.md"), encoding: .utf8)
    }

    /// A unique directory that is removed when `body` returns.
    static func withTemporaryDirectory<T>(_ body: (URL) throws -> T) rethrows -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("markpad-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory)
    }

    /// As above, for `async` callers.
    ///
    /// Deliberately a different name rather than an `async` overload: an overload sharing the
    /// label would make resolution ambiguous at the existing synchronous call sites.
    static func withTemporaryDirectoryAsync<T>(_ body: (URL) async throws -> T) async rethrows -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("markpad-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await body(directory)
    }
}

/// Collects progress events from the worker thread.
///
/// The handler is `@Sendable` and fires off the main actor, so the events need a lock rather
/// than a plain array.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ImportProgress] = []
    /// Called for each event, inside the lock. Used to trigger cancellation at a chosen page.
    var onEvent: ((ImportProgress) -> Void)?
    private(set) var sawMainThread = false

    func record(_ progress: ImportProgress) {
        lock.lock()
        defer { lock.unlock() }
        if Thread.isMainThread { sawMainThread = true }
        events.append(progress)
        onEvent?(progress)
    }

    var handler: ImportProgress.Handler {
        { [self] progress in record(progress) }
    }

    var all: [ImportProgress] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    /// Events that name a specific page being worked on.
    var pageEvents: [ImportProgress] {
        all.filter { $0.phase == .extractingText || $0.phase == .recognizingText }
    }
}
