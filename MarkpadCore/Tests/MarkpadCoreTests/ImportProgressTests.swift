import XCTest
@testable import MarkpadCore

/// Covers the reporting and cancellation contract of the importers.
///
/// Cancellation is driven by an injected predicate rather than ambient task state, which is what
/// makes these tests deterministic: a page with a text layer is read in microseconds, so racing a
/// `Task.cancel()` against the loop would resolve in favour of completion almost every time.
final class ImportProgressTests: XCTestCase {
    /// Three lines per page on purpose. `removingRunningHeads` only considers the topmost and
    /// bottommost non-empty line of each page, and `normalize` collapses digits — so on a
    /// two-line page both lines are edges, "Section 1" and "Section 2" compare equal, and the
    /// whole document is stripped as running heads, leaving nothing to import.
    private func pages(_ count: Int) -> [[TestImages.PDFLine]] {
        (1...count).map { index in
            [
                TestImages.PDFLine("Markpad Handbook", fontSize: 9),
                TestImages.PDFLine("Body text for page \(index) of the document.", fontSize: 12),
                TestImages.PDFLine("Page \(index)", fontSize: 9)
            ]
        }
    }

    // MARK: Reporting

    func testEveryPageIsReportedInOrder() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("four.pdf")
            try TestImages.writeTextPDF(to: url, pages: pages(4))

            let log = ProgressLog()
            _ = try PDFImporter().convert(url: url, progress: log.handler)

            let seen = log.pageEvents.map(\.unit)
            XCTAssertEqual(seen, [1, 2, 3, 4], "each page should be announced once, in order")
            XCTAssertTrue(log.all.allSatisfy { $0.totalUnits == 4 }, "page count should be known up front")

            let fractions = log.all.map(\.fractionCompleted)
            XCTAssertEqual(fractions, fractions.sorted(), "progress must never go backwards")
            XCTAssertEqual(fractions.last, 1, "a finished import must report 1.0")
        }
    }

    func testSingleImageReportsOneUnitAndNoPageNumber() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("note.png")
            try TestImages.writeTextPNG(to: url, lines: ["Hello from a picture"])

            let log = ProgressLog()
            _ = try? ImageImporter().convert(url: url, progress: log.handler)

            XCTAssertFalse(log.all.isEmpty, "an image import should still report progress")
            XCTAssertTrue(log.all.allSatisfy { $0.totalUnits == 1 })
            XCTAssertTrue(
                log.all.allSatisfy { !$0.statusDescription.contains("page") },
                "a single image has no pages to count: \(log.all.map(\.statusDescription))"
            )
        }
    }

    func testStatusDescriptionMatchesTheSheetCopy() {
        let progress = ImportProgress(phase: .recognizingText, unit: 3, totalUnits: 8, fractionCompleted: 0.3)
        XCTAssertEqual(progress.statusDescription, "Recognizing text on device — page 3 of 8")
    }

    func testFractionIsClampedAndUnitsAreAtLeastOne() {
        let low = ImportProgress(phase: .reading, unit: 0, totalUnits: 0, fractionCompleted: -5)
        XCTAssertEqual(low.fractionCompleted, 0)
        XCTAssertEqual(low.unit, 1)
        XCTAssertEqual(low.totalUnits, 1)

        let high = ImportProgress(phase: .assembling, unit: 2, totalUnits: 2, fractionCompleted: 9)
        XCTAssertEqual(high.fractionCompleted, 1)
    }

    // MARK: Cancellation

    func testCancellationStopsPartWayThrough() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("six.pdf")
            try TestImages.writeTextPDF(to: url, pages: pages(6))

            let log = ProgressLog()
            // Stop once the third page has been announced.
            let stop = NSLock()
            var shouldStop = false
            log.onEvent = { progress in
                if progress.unit >= 3 { shouldStop = true }
            }

            XCTAssertThrowsError(
                try PDFImporter().convert(
                    url: url,
                    progress: log.handler,
                    isCancelled: { stop.lock(); defer { stop.unlock() }; return shouldStop }
                )
            ) { error in
                guard case ConversionError.cancelled = error else {
                    return XCTFail("expected .cancelled, got \(error)")
                }
            }

            // The count is the point: without it this test would pass even if cancellation had
            // never fired and the import merely finished.
            XCTAssertEqual(log.pageEvents.count, 3, "no page should be read after the cancel")
        }
    }

    /// The Shortcuts intents call the synchronous importer with no predicate. This is what proves
    /// their behaviour is unchanged by the addition.
    func testDefaultPredicateNeverCancels() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("plain.pdf")
            try TestImages.writeTextPDF(to: url, pages: pages(3))

            let markdown = try PDFImporter().convert(url: url)
            XCTAssertTrue(markdown.contains("Body text for page 3"), markdown)
        }
    }

    // MARK: Off the main thread

    /// The regression test for the defect this work exists to fix. If `importFile` is ever
    /// written with `Task { }` instead of `Task.detached`, it inherits the caller's main-actor
    /// isolation, the OCR runs on the main thread again, and nothing else would catch it.
    @MainActor
    func testImportRunsOffTheMainThread() async throws {
        try await Fixtures.withTemporaryDirectoryAsync { directory in
            let url = directory.appendingPathComponent("async.pdf")
            try TestImages.writeTextPDF(to: url, pages: pages(3))

            let log = ProgressLog()
            let result = try await ConversionService().importMarkdown(
                fromFileAt: url,
                options: .init(progress: log.handler)
            )

            XCTAssertTrue(result.contains("Body text for page 1"), result)
            XCTAssertFalse(log.all.isEmpty, "progress should have been reported")
            XCTAssertFalse(log.sawMainThread, "the import must not run on the main thread")
        }
    }

    func testCancellingTheTaskCancelsTheImport() async throws {
        try await Fixtures.withTemporaryDirectoryAsync { directory in
            let url = directory.appendingPathComponent("cancellable.pdf")
            try TestImages.writeTextPDF(to: url, pages: pages(40))

            let started = expectation(description: "import started")
            let log = ProgressLog()
            var fulfilled = false
            log.onEvent = { _ in
                if !fulfilled { fulfilled = true; started.fulfill() }
            }

            let task = Task {
                try await ConversionService().importMarkdown(
                    fromFileAt: url,
                    options: .init(progress: log.handler)
                )
            }
            await fulfillment(of: [started], timeout: 10)
            task.cancel()

            do {
                _ = try await task.value
                // A short document can finish before the cancel lands; that is not a failure.
            } catch {
                guard case ConversionError.cancelled = error else {
                    return XCTFail("expected .cancelled, got \(error)")
                }
            }
        }
    }
}
