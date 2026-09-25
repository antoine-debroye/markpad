import MarkpadCore
import XCTest
@testable import Markpad

/// The Convert to Markdown window's model, run against real files in a scratch folder.
///
/// Uses its own `ConverterModel`, never `.shared`, and never opens documents: this suite runs
/// inside the real app, so `NSDocumentController` is the developer's own.
@MainActor
final class ConverterModelTests: XCTestCase {
    private var folder: URL!
    private var savedReveal: Any?

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("converter-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        // The test host shares the app's defaults; keep the user's setting and restore it.
        savedReveal = UserDefaults.standard.object(forKey: "converter.revealWhenDone")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
        if let savedReveal {
            UserDefaults.standard.set(savedReveal, forKey: "converter.revealWhenDone")
        } else {
            UserDefaults.standard.removeObject(forKey: "converter.revealWhenDone")
        }
    }

    private func write(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: folder.appendingPathComponent(name))
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func makeModel() -> ConverterModel {
        let model = ConverterModel()
        model.revealWhenDone = false
        return model
    }

    func testStagesRunsAndSummarises() async throws {
        try write("team.csv", "Name,Role\nAda,Lead\n")
        try write("data.json", "{\"a\": 1}")
        try write("Sub/page.html", "<h1>Title</h1><p>Body</p>")
        try write("broken.pdf", "not a pdf")
        try write("notes.md", "# already\n")
        try write("~$lock.docx", "x")

        let model = makeModel()
        model.add([folder])
        try await waitUntil { model.preview != nil && !model.isPreviewing }
        XCTAssertEqual(model.previewSummary, "4 files to convert · 2 skipped")
        XCTAssertTrue(model.canStart)

        model.start()
        XCTAssertEqual(model.phase, .running)
        try await waitUntil { model.phase == .finished }

        XCTAssertEqual(model.count(.done), 3)
        XCTAssertEqual(model.count(.failed), 1)
        XCTAssertEqual(model.count(.skipped), 2)
        XCTAssertEqual(model.finishedSummary, "3 converted · 1 failed · 2 skipped")
        XCTAssertTrue(model.hasRetryable)
        XCTAssertEqual(
            try String(contentsOf: folder.appendingPathComponent("Sub/page.md"), encoding: .utf8),
            "# Title\n\nBody\n"
        )
        XCTAssertEqual(
            try String(contentsOf: folder.appendingPathComponent("team.md"), encoding: .utf8),
            "| Name | Role |\n| --- | --- |\n| Ada | Lead |\n"
        )
        XCTAssertTrue(model.rows.allSatisfy { $0.status != .waiting && $0.status != .converting })

        // Retrying the failure runs only that file, which fails again the same way.
        model.retryFailed()
        try await waitUntil { model.phase == .finished }
        XCTAssertEqual(model.count(.done), 3)
        XCTAssertEqual(model.count(.failed), 1)

        // A second batch over the same folder converts nothing new.
        model.resetToStaging(keepingStaged: false)
        model.add([folder])
        try await waitUntil { model.preview != nil && !model.isPreviewing }
        XCTAssertEqual(model.preview?.items.map { $0.source.lastPathComponent }, ["broken.pdf"])
    }

    func testDestinationIsRequiredForFolderModes() async throws {
        try write("a.csv", "x\n1\n")
        let model = makeModel()
        model.add([folder.appendingPathComponent("a.csv")])
        try await waitUntil { model.preview != nil && !model.isPreviewing }
        XCTAssertTrue(model.canStart)

        model.location = .folder
        XCTAssertTrue(model.needsDestination)
        try await waitUntil { !model.isPreviewing }
        XCTAssertFalse(model.canStart)

        let out = folder.appendingPathComponent("Out")
        model.destination = out
        try await waitUntil { !model.isPreviewing }
        XCTAssertTrue(model.canStart)
        XCTAssertEqual(model.preview?.items.first?.output.lastPathComponent, "a.md")
        XCTAssertEqual(model.preview?.items.first?.output.deletingLastPathComponent().lastPathComponent, "Out")
    }

    func testCancelSettlesEveryRow() async throws {
        for index in 0..<40 { try write("f\(index).csv", "a\n\(index)\n") }
        let model = makeModel()
        model.add([folder])
        try await waitUntil { model.preview != nil && !model.isPreviewing }
        model.start()
        try await waitUntil { model.rows.contains { $0.status == .done } }
        model.cancel()
        try await waitUntil { model.phase == .finished }
        XCTAssertEqual(model.count(.done) + model.count(.cancelled), 40)
        XCTAssertTrue(model.rows.allSatisfy { [.done, .cancelled, .skipped].contains($0.status) })
        let written = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".md") }
        XCTAssertEqual(written.count, model.count(.done))
    }

    func testDockOpensTextAndConvertsDocuments() {
        func converts(_ name: String) -> Bool { AppDelegate.convertsOnOpen(URL(fileURLWithPath: "/tmp/\(name)")) }
        XCTAssertFalse(converts("notes.md"))
        XCTAssertFalse(converts("notes.txt"))
        XCTAssertFalse(converts("table.csv"), "CSV is plain text and keeps opening for editing")
        XCTAssertFalse(converts("archive.zip"))
        XCTAssertTrue(converts("report.docx"))
        XCTAssertTrue(converts("page.html"))
        XCTAssertTrue(converts("scan.pdf"))
        XCTAssertTrue(converts("photo.png"))
        XCTAssertTrue(converts("talk.m4a"))
        XCTAssertTrue(converts("data.json"))
        XCTAssertTrue(converts("Notes.rtfd"))
    }
}

@MainActor
final class ConverterMarkdownRoutingTests: XCTestCase {
    func testMarkdownFilesOpenRatherThanConvert() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("route-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("notes.md"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertTrue(ConverterModel.isMarkdownFile(URL(fileURLWithPath: "/tmp/a.md")))
        XCTAssertTrue(ConverterModel.isMarkdownFile(URL(fileURLWithPath: "/tmp/a.markdown")))
        XCTAssertFalse(ConverterModel.isMarkdownFile(URL(fileURLWithPath: "/tmp/a.docx")))
        XCTAssertFalse(ConverterModel.isMarkdownFile(URL(fileURLWithPath: "/tmp/a.txt")), "text is converted")
        XCTAssertFalse(ConverterModel.isMarkdownFile(folder.appendingPathComponent("notes.md")), "a folder named .md is staged")
    }
}
