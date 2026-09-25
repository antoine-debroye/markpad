import Foundation

/// Bounds on what an import will do with a file, because every input is an arbitrary file the
/// user picked — possibly damaged, possibly hostile — and a batch runs several at once.
enum ImportLimits {
    /// Deepest element nesting accepted in an XML part or walked in a web page. Real documents
    /// stay in the tens; thousands are only ever built to exhaust a reader's stack.
    static let maximumNestingDepth = 256

    /// Largest picture kept from inside a document.
    static let maximumPictureBytes = 25 * 1024 * 1024

    /// Total bytes one archive may expand to across every entry read from it.
    static let archiveExpansionBudget = 1024 * 1024 * 1024

    /// Widest table written. Wider than this is unreadable as Markdown, and a sheet with one
    /// cell in column ZZZ would otherwise pad every row to 18,000 cells.
    static let maximumTableColumns = 256

    /// Stack for the thread an import runs on. Parsers and tree walkers recurse per level of
    /// nesting; the cooperative pool's 512 KB threads overflow on a page nested a few thousand
    /// levels deep, and an overflow kills the app — and with it every file still queued.
    /// Reserved address space, not memory: pages are committed only as they are touched.
    static let importStackSize = 512 * 1024 * 1024

    /// Runs `body` on a thread with `importStackSize` of stack and waits for it.
    static func onLargeStack<T>(_ body: @escaping () throws -> T) throws -> T {
        var result: Result<T, Error>?
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            result = Result { try body() }
            done.signal()
        }
        thread.stackSize = importStackSize
        thread.qualityOfService = .userInitiated
        thread.name = "Markpad import"
        thread.start()
        done.wait()
        return try result!.get()
    }
}
