import Foundation
import XCTest
@testable import MarkpadCore

final class BatchPlannerTests: XCTestCase {
    private func touch(_ url: URL, _ text: String = "text") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func names(_ plan: BatchPlan) -> [String] {
        plan.items.map { $0.output.lastPathComponent }
    }

    func testExpandsFoldersRecursivelyAndFiltersNoise() throws {
        try Fixtures.withTemporaryDirectory { root in
            let folder = root.appendingPathComponent("Docs")
            try touch(folder.appendingPathComponent("a.txt"))
            try touch(folder.appendingPathComponent("sub/b.json"))
            try touch(folder.appendingPathComponent("sub/deeper/c.csv"))
            try touch(folder.appendingPathComponent(".hidden.txt"))
            try touch(folder.appendingPathComponent("~$lock.docx"))
            try touch(folder.appendingPathComponent("Thumbs.db"))
            try touch(folder.appendingPathComponent("notes.md"))
            try touch(folder.appendingPathComponent("archive.zip"))
            // A package is one document, not a folder to descend into.
            try touch(folder.appendingPathComponent("rich.rtfd/TXT.rtf"))

            let plan = BatchPlanner().plan([folder])
            XCTAssertEqual(Set(plan.items.map { $0.source.lastPathComponent }), ["a.txt", "b.json", "c.csv", "rich.rtfd"])
            let reasons = Dictionary(uniqueKeysWithValues: plan.skipped.map { ($0.source.lastPathComponent, $0.reason) })
            XCTAssertEqual(reasons["~$lock.docx"], .systemFile)
            XCTAssertEqual(reasons["Thumbs.db"], .systemFile)
            XCTAssertEqual(reasons["notes.md"], .alreadyMarkdown)
            XCTAssertEqual(reasons["archive.zip"], .unsupported)
            XCTAssertNil(reasons[".hidden.txt"], "hidden files are not listed at all")
            XCTAssertNil(reasons["TXT.rtf"], "package contents are not visited")
        }
    }

    func testNextToSourceNamingIsDeterministicAndTellsSameStemsApart() throws {
        try Fixtures.withTemporaryDirectory { root in
            try touch(root.appendingPathComponent("Report.pdf"))
            try touch(root.appendingPathComponent("Report.docx"))
            try touch(root.appendingPathComponent("Other.txt"))
            let files = ["Report.pdf", "Other.txt", "Report.docx"].map { root.appendingPathComponent($0) }

            let first = BatchPlanner().plan(files)
            let second = BatchPlanner().plan(files.reversed())
            XCTAssertEqual(names(first), ["Other.md", "Report (docx).md", "Report (pdf).md"])
            XCTAssertEqual(names(first), names(second), "input order does not change names")
            XCTAssertEqual(first.items.map(\.assetFolderName), ["Other_assets", "Report (docx)_assets", "Report (pdf)_assets"])
            XCTAssertTrue(first.items.allSatisfy { $0.output.deletingLastPathComponent() == root })
        }
    }

    func testExistingOutputIsSkippedOrKeptBoth() throws {
        try Fixtures.withTemporaryDirectory { root in
            let source = root.appendingPathComponent("Notes.txt")
            try touch(source)
            try touch(root.appendingPathComponent("Notes.md"), "keep me")
            try touch(root.appendingPathComponent("Notes 2_assets/x.png"))

            let skipped = BatchPlanner(existingFiles: .skip).plan([source])
            XCTAssertTrue(skipped.items.isEmpty)
            XCTAssertEqual(skipped.skipped.first?.reason, .outputExists(root.appendingPathComponent("Notes.md")))

            let kept = BatchPlanner(existingFiles: .keepBoth).plan([source])
            XCTAssertEqual(names(kept), ["Notes 3.md"], "both the .md and its pictures folder must be free")
        }
    }

    func testFolderAndMirrorLocations() throws {
        try Fixtures.withTemporaryDirectory { root in
            let tree = root.appendingPathComponent("Input/Project")
            try touch(tree.appendingPathComponent("a.txt"))
            try touch(tree.appendingPathComponent("sub/b.txt"))
            let loose = root.appendingPathComponent("Elsewhere/loose.txt")
            try touch(loose)
            let out = root.appendingPathComponent("Out")

            let flat = BatchPlanner(location: .folder(out)).plan([tree, loose])
            XCTAssertEqual(Set(flat.items.map { $0.output.path }), Set([
                out.appendingPathComponent("a.md").path,
                out.appendingPathComponent("b.md").path,
                out.appendingPathComponent("loose.md").path,
            ]))

            let mirror = BatchPlanner(location: .mirror(out)).plan([tree, loose])
            XCTAssertEqual(Set(mirror.items.map { $0.output.path }), Set([
                out.appendingPathComponent("Project/a.md").path,
                out.appendingPathComponent("Project/sub/b.md").path,
                out.appendingPathComponent("loose.md").path,
            ]), "mirrored under the dropped folder's own name; loose files at the top")
        }
    }

    func testFlatFolderCollisionsAcrossSubfolders() throws {
        try Fixtures.withTemporaryDirectory { root in
            try touch(root.appendingPathComponent("In/one/Same.txt"))
            try touch(root.appendingPathComponent("In/two/Same.txt"))
            let plan = BatchPlanner(location: .folder(root.appendingPathComponent("Out")))
                .plan([root.appendingPathComponent("In")])
            XCTAssertEqual(names(plan), ["Same (txt).md", "Same (txt) 2.md"])
        }
    }

    func testRerunSkipsOwnPicturesFolders() throws {
        try Fixtures.withTemporaryDirectory { root in
            try touch(root.appendingPathComponent("Deck.pptx"))
            try touch(root.appendingPathComponent("Deck.md"))
            try touch(root.appendingPathComponent("Deck_assets/image1.png"))
            let marked = root.appendingPathComponent("Renamed pictures")
            try touch(marked.appendingPathComponent("image2.png"))
            XCTAssertEqual(setxattr(marked.path, BatchPlanner.generatedAttribute, "1", 1, 0, 0), 0)

            let plan = BatchPlanner().plan([root])
            XCTAssertTrue(plan.items.isEmpty)
            XCTAssertEqual(Set(plan.skipped.map { $0.source.lastPathComponent }), ["Deck.md", "Deck.pptx"],
                           "the .md is already Markdown; the deck's output exists")
            XCTAssertFalse(plan.skipped.contains { $0.source.lastPathComponent.hasPrefix("image") }, "pictures folders are not scanned")
        }
    }

    func testDuplicatesAndSymlinksAreConvertedOnce() throws {
        try Fixtures.withTemporaryDirectory { root in
            let file = root.appendingPathComponent("a.txt")
            try touch(file)
            let link = root.appendingPathComponent("link.txt")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            let plan = BatchPlanner().plan([file, file, link])
            XCTAssertEqual(plan.items.count, 1)
        }
    }
}

final class BatchConverterTests: XCTestCase {
    private func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testConvertsAndIsolatesFailures() async throws {
        try await Fixtures.withTemporaryDirectoryAsync { root in
            try write(root.appendingPathComponent("good.txt"), "# Hello\n")
            try write(root.appendingPathComponent("broken.pdf"), "not really a pdf")
            try write(root.appendingPathComponent("also good.txt"), "Second\n")

            let plan = BatchPlanner().plan([root])
            let log = EventLog()
            let outcomes = await BatchConverter(totalLimit: 2).run(plan.items) { log.append($0) }

            XCTAssertEqual(outcomes.count, 3)
            let byName = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.source.lastPathComponent, outcomes[$0.id]!) })
            // The enumerator reports /private/var for the /var temporary folder, so paths are
            // compared with links resolved on both sides.
            func output(_ outcome: BatchConverter.Outcome?) -> String? {
                guard case .finished(let url, let notices) = outcome, notices.isEmpty else { return nil }
                return url.resolvingSymlinksInPath().path
            }
            XCTAssertEqual(output(byName["good.txt"]), root.appendingPathComponent("good.md").resolvingSymlinksInPath().path)
            XCTAssertEqual(output(byName["also good.txt"]), root.appendingPathComponent("also good.md").resolvingSymlinksInPath().path)
            guard case .failed(let message) = byName["broken.pdf"] else { return XCTFail("expected failure") }
            XCTAssertTrue(message.contains("broken.pdf"), message)

            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("good.md"), encoding: .utf8), "# Hello\n")
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("broken.md").path))
            XCTAssertEqual(try leftovers(in: root), [], "no temporary files remain")
            XCTAssertTrue(log.events.contains(.started(plan.items[0].id)))
        }
    }

    func testRespectsConcurrencyLimits() async throws {
        try await Fixtures.withTemporaryDirectoryAsync { root in
            for index in 0..<12 {
                try write(root.appendingPathComponent("f\(index).txt"), "file \(index)")
            }
            let plan = BatchPlanner().plan([root])
            let log = EventLog()
            await BatchConverter(heavyLimit: 1, totalLimit: 3).run(plan.items) { log.append($0) }

            var running = 0
            var peak = 0
            for event in log.events {
                switch event {
                case .started: running += 1; peak = max(peak, running)
                case .finished, .failed, .cancelled: running -= 1
                default: break
                }
            }
            XCTAssertLessThanOrEqual(peak, 3)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".md") }.count, 12)
        }
    }

    func testCancellationStopsQueueAndKeepsFinishedFiles() async throws {
        try await Fixtures.withTemporaryDirectoryAsync { root in
            for index in 0..<30 {
                try write(root.appendingPathComponent(String(format: "f%02d.txt", index)), "file \(index)")
            }
            let plan = BatchPlanner().plan([root])
            let log = EventLog()
            let task = Task {
                await BatchConverter(totalLimit: 1).run(plan.items) { event in
                    log.append(event)
                    if case .finished = event, log.finishedCount == 2 { log.cancel() }
                }
            }
            log.onCancel = { task.cancel() }
            let outcomes = await task.value

            let finished = outcomes.values.filter { if case .finished = $0 { return true } else { return false } }.count
            let cancelled = outcomes.values.filter { $0 == .cancelled }.count
            XCTAssertGreaterThanOrEqual(finished, 2)
            XCTAssertLessThan(finished, 30)
            XCTAssertEqual(finished + cancelled, 30)
            let written = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".md") }
            XCTAssertEqual(written.count, finished, "exactly the finished items were written")
            XCTAssertEqual(try leftovers(in: root), [])
        }
    }

    func testWriterNeverOverwritesAndStagesPictures() throws {
        try Fixtures.withTemporaryDirectory { root in
            let output = root.appendingPathComponent("Doc.md")
            let imported = ImportedMarkdown(
                markdown: "![](Doc_assets/a.png)\n",
                assets: [.init(name: "a.png", data: Data([0x89, 0x50, 0x4E, 0x47]))]
            )
            try BatchWriter.write(imported, to: output, assetFolderName: "Doc_assets")
            XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "![](Doc_assets/a.png)\n")
            let picture = root.appendingPathComponent("Doc_assets/a.png")
            XCTAssertEqual(try Data(contentsOf: picture), Data([0x89, 0x50, 0x4E, 0x47]))
            XCTAssertGreaterThanOrEqual(getxattr(root.appendingPathComponent("Doc_assets").path, BatchPlanner.generatedAttribute, nil, 0, 0, 0), 0)

            // A second write to the same place must fail and leave the first untouched.
            let other = ImportedMarkdown(markdown: "replaced\n")
            XCTAssertThrowsError(try BatchWriter.write(other, to: output, assetFolderName: "Doc_assets"))
            XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "![](Doc_assets/a.png)\n")
            XCTAssertEqual(try leftovers(in: root), [])
        }
    }

    func testWriterCreatesMirrorFolders() throws {
        try Fixtures.withTemporaryDirectory { root in
            let output = root.appendingPathComponent("a/b/c.md")
            try BatchWriter.write(ImportedMarkdown(markdown: "x\n"), to: output, assetFolderName: "c_assets")
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("a/b/c_assets").path),
                           "no pictures, no folder")
        }
    }

    private func leftovers(in root: URL) throws -> [String] {
        let all = FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []
        return all.filter { $0.contains(".markpad-") }
    }
}

/// Collects events from worker threads.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [BatchConverter.Event] = []
    private var cancelRequested = false
    /// Set after the task starts; a cancel requested before then is replayed on assignment.
    var onCancel: (() -> Void)? {
        didSet {
            lock.lock(); let replay = cancelRequested; lock.unlock()
            if replay { onCancel?() }
        }
    }

    func append(_ event: BatchConverter.Event) {
        lock.lock(); stored.append(event); lock.unlock()
    }

    var events: [BatchConverter.Event] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    var finishedCount: Int {
        events.filter { if case .finished = $0 { return true } else { return false } }.count
    }

    func cancel() {
        lock.lock(); cancelRequested = true; lock.unlock()
        onCancel?()
    }
}
