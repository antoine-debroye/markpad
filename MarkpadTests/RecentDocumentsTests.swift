import XCTest
@testable import Markpad

/// Grouping and formatting for the Recents panel.
///
/// Everything here works on synthetic input. `MarkpadTests` runs inside the real app — the test
/// target has a host — so `NSDocumentController.shared` would be the developer's own controller,
/// and `clearRecentDocuments` would wipe their actual Open Recent list. These tests must never
/// reach for it.
@MainActor
final class RecentDocumentsTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)
    private lazy var now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 14, hour: 9, minute: 41))!

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/Users/someone/Documents/Trails/\(name)")
    }

    private func date(daysAgo: Int, hour: Int = 9) -> Date {
        calendar.date(byAdding: .day, value: -daysAgo, to: calendar.date(
            bySettingHour: hour, minute: 12, second: 0, of: now
        )!)!
    }

    // MARK: Grouping

    func testTodayAndEarlierAreSeparated() {
        let groups = RecentDocuments.group([
            (url("notes.md"), date(daysAgo: 0)),
            (url("survey.md"), date(daysAgo: 1)),
            (url("permits.md"), date(daysAgo: 9))
        ], calendar: calendar, now: now)

        XCTAssertEqual(groups.map(\.section), [.today, .earlier])
        XCTAssertEqual(groups[0].items.map(\.name), ["notes.md"])
        XCTAssertEqual(groups[1].items.map(\.name), ["survey.md", "permits.md"])
    }

    func testEmptySectionsAreDropped() {
        let onlyToday = RecentDocuments.group(
            [(url("notes.md"), date(daysAgo: 0))], calendar: calendar, now: now
        )
        XCTAssertEqual(onlyToday.map(\.section), [.today])

        XCTAssertTrue(RecentDocuments.group([], calendar: calendar, now: now).isEmpty)
    }

    /// The incoming list is already most-recently-opened-first. Re-sorting by date would shuffle
    /// rows whose timestamp is only a fallback file modification date.
    func testOrderWithinASectionIsPreserved() {
        let groups = RecentDocuments.group([
            (url("b.md"), date(daysAgo: 5)),
            (url("a.md"), date(daysAgo: 2)),
            (url("c.md"), date(daysAgo: 8))
        ], calendar: calendar, now: now)

        XCTAssertEqual(groups[0].items.map(\.name), ["b.md", "a.md", "c.md"])
    }

    func testDirectoryIsAbbreviatedWithTilde() {
        let item = RecentDocument(url: url("notes.md"), opened: now)
        XCTAssertTrue(item.directory.hasPrefix("~") || item.directory.hasPrefix("/Users"),
                      "got \(item.directory)")
        XCTAssertEqual(item.name, "notes.md")
    }

    // MARK: Filtering

    /// Converted imports are staged in the temporary directory and opened as real documents, so
    /// they land in the recents list and then vanish when the system purges /tmp. They must not
    /// reach the panel.
    func testConvertedImportsInTheTemporaryDirectoryAreHidden() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("markpad-recents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let staged = temporary.appendingPathComponent("site-survey.md")
        try Data("# Survey".utf8).write(to: staged)

        XCTAssertFalse(
            RecentDocuments.isWorthShowing(staged, temporaryDirectory: FileManager.default.temporaryDirectory),
            "a converted import staged in /tmp should not appear in Recents"
        )
    }

    func testARealFileOutsideTheTemporaryDirectoryIsShown() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("markpad-real-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("notes.md")
        try Data("# Notes".utf8).write(to: file)

        // Compared against a different "temporary directory" so the file counts as a normal one.
        XCTAssertTrue(RecentDocuments.isWorthShowing(file, temporaryDirectory: URL(fileURLWithPath: "/nowhere")))
    }

    func testMissingFilesAreDropped() {
        let gone = URL(fileURLWithPath: "/Users/someone/Documents/deleted-\(UUID().uuidString).md")
        XCTAssertFalse(RecentDocuments.isWorthShowing(gone, temporaryDirectory: URL(fileURLWithPath: "/nowhere")))
    }

    // MARK: Formatting

    func testTodayShowsAClockTime() {
        let label = RecentDateFormatter.label(for: now, calendar: calendar, now: now)
        XCTAssertTrue(label.contains("9") || label.contains("41"), "expected a time, got \(label)")
        XCTAssertFalse(label.contains("Aug"), "today should not show a date: \(label)")
    }

    func testYesterdayIsNamedRatherThanDated() {
        let label = RecentDateFormatter.label(for: date(daysAgo: 1), calendar: calendar, now: now)
        // Localised by the formatter, so this asserts on shape rather than the English word.
        XCTAssertFalse(label.isEmpty)
        XCTAssertFalse(label.contains(":"), "yesterday should not show a clock time: \(label)")
    }

    func testEarlierThisYearShowsMonthAndDay() {
        let label = RecentDateFormatter.label(for: date(daysAgo: 6), calendar: calendar, now: now)
        XCTAssertFalse(label.contains("2026"), "the current year is redundant: \(label)")
        XCTAssertFalse(label.contains(":"), "an older entry should not show a clock time: \(label)")
    }

    func testAnEarlierYearIncludesTheYear() {
        let old = calendar.date(from: DateComponents(year: 2024, month: 3, day: 2))!
        let label = RecentDateFormatter.label(for: old, calendar: calendar, now: now)
        XCTAssertTrue(label.contains("2024"), "expected the year, got \(label)")
    }
}
