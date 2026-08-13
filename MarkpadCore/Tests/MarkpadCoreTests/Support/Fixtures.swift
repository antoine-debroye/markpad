import Foundation
import XCTest

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
}
