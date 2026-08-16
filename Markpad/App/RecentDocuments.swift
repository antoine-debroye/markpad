import AppKit
import Foundation

/// One row in the Recents panel.
struct RecentDocument: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let opened: Date

    var name: String { url.lastPathComponent }
    /// "~/Documents/Trails"
    var directory: String {
        (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }
}

enum RecentSection: String, CaseIterable {
    case today = "Today"
    case earlier = "Earlier"
}

/// Reads, groups and opens the documents shown in the Recents panel.
///
/// `NSDocumentController` records which files were opened but not *when*, so the timestamps the
/// panel shows are recorded here as documents open, with the file's modification date as a
/// fallback for anything opened before this existed.
@MainActor
enum RecentDocuments {
    private static let storageKey = "markpad.recentsOpenedAt"

    /// Notes that `url` has just been opened. Called from each document window.
    static func noteOpened(_ url: URL) {
        var stamps = openedDates()
        stamps[url.path] = Date()

        // Keep the store from growing without bound, and from remembering files the system has
        // already forgotten.
        let known = Set(NSDocumentController.shared.recentDocumentURLs.map(\.path) + [url.path])
        stamps = stamps.filter { known.contains($0.key) }

        UserDefaults.standard.set(
            stamps.mapValues { $0.timeIntervalSinceReferenceDate },
            forKey: storageKey
        )
    }

    static func clear() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    /// Recent documents worth showing, most recently opened first within each section.
    static func sections() -> [(section: RecentSection, items: [RecentDocument])] {
        let stamps = openedDates()
        let entries = NSDocumentController.shared.recentDocumentURLs
            .filter { isWorthShowing($0) }
            .map { url -> (URL, Date) in
                (url, stamps[url.path] ?? modificationDate(of: url) ?? .distantPast)
            }
        return group(entries)
    }

    /// Whether a recent entry should appear in the panel.
    ///
    /// Converted imports are staged in the temporary directory so they behave like real
    /// documents, which also means they are recorded as recents and then vanish when the system
    /// purges `/tmp`. Showing them would fill the panel with dead `/var/folders/…` rows.
    static func isWorthShowing(_ url: URL, temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let temporaryPath = temporaryDirectory.standardizedFileURL.path
        return !url.standardizedFileURL.path.hasPrefix(temporaryPath)
    }

    /// Splits entries into Today and Earlier, preserving the order they arrive in.
    ///
    /// Order is deliberately not re-sorted by date: the incoming list is already
    /// most-recently-opened-first, and a fallback modification date would otherwise shuffle rows
    /// into the wrong order.
    static func group(
        _ entries: [(URL, Date)],
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> [(section: RecentSection, items: [RecentDocument])] {
        var today: [RecentDocument] = []
        var earlier: [RecentDocument] = []

        for (url, date) in entries {
            let item = RecentDocument(url: url, opened: date)
            if calendar.isDate(date, inSameDayAs: now) {
                today.append(item)
            } else {
                earlier.append(item)
            }
        }

        var result: [(section: RecentSection, items: [RecentDocument])] = []
        if !today.isEmpty { result.append((.today, today)) }
        if !earlier.isEmpty { result.append((.earlier, earlier)) }
        return result
    }

    static func open(_ item: RecentDocument, onMissing: @escaping (URL) -> Void) {
        NSDocumentController.shared.openDocument(withContentsOf: item.url, display: true) { _, _, error in
            if error != nil { onMissing(item.url) }
        }
    }

    // MARK: Storage

    private static func openedDates() -> [String: Date] {
        let raw = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: Double] ?? [:]
        return raw.mapValues { Date(timeIntervalSinceReferenceDate: $0) }
    }

    private static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

/// Formats the time shown at the end of each Recents row.
///
/// `RelativeDateTimeFormatter` is deliberately not used: it produces "2 hours ago", and none of
/// the three shapes the design asks for.
enum RecentDateFormatter {
    private static let relative: DateFormatter = {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    /// "9:41" today, a localised "Yesterday", "Aug 8" this year, "Aug 8, 2025" before that.
    static func label(for date: Date, calendar: Calendar = .current, now: Date = Date()) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(.dateTime.hour().minute())
        }
        if calendar.isDateInYesterday(date) {
            // The formatter localises this, so it must not be a hard-coded "Yesterday".
            return relative.string(from: date)
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}
