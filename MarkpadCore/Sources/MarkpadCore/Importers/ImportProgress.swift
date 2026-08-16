import Foundation

/// How far an import has got, and what it is doing.
///
/// Recognising a scanned page takes seconds, so an import has to be able to say more than
/// "working". The phase is reported *before* the slow step rather than after it, so the label
/// describes what is happening now rather than what just finished.
public struct ImportProgress: Sendable, Equatable {
    /// Called on the worker thread, not the main actor: a caller driving a UI hops itself.
    /// Isolating this to the main actor would make it unusable from Shortcuts and Quick Look.
    public typealias Handler = @Sendable (ImportProgress) -> Void

    public enum Phase: Sendable, Equatable {
        /// Opening the PDF or decoding the image.
        case reading
        /// Reading a page's embedded text layer, which is fast.
        case extractingText
        /// Recognising text on a page that has no text layer, which is not.
        case recognizingText
        /// Turning recognised lines into Markdown.
        case assembling
    }

    public let phase: Phase
    /// 1-based index of the page being worked on. Always 1 for a single image.
    public let unit: Int
    /// Total pages. Always 1 for a single image.
    public let totalUnits: Int
    /// 0...1, clamped, and non-decreasing across one import.
    public let fractionCompleted: Double

    public init(phase: Phase, unit: Int, totalUnits: Int, fractionCompleted: Double) {
        self.phase = phase
        self.unit = max(1, unit)
        self.totalUnits = max(1, totalUnits)
        self.fractionCompleted = min(max(fractionCompleted, 0), 1)
    }

    /// The line shown while importing, e.g. "Recognizing text on device — page 3 of 8".
    ///
    /// A single image has no pages to count, so it drops the trailing clause rather than
    /// claiming "page 1 of 1".
    public var statusDescription: String {
        let action: String
        switch phase {
        case .reading: action = "Reading the file"
        case .extractingText: action = "Extracting text"
        case .recognizingText: action = "Recognizing text on device"
        case .assembling: action = "Assembling Markdown"
        }
        guard totalUnits > 1 else { return action }
        return "\(action) — page \(unit) of \(totalUnits)"
    }
}

/// Everything an import needs beyond the file itself.
///
/// Progress is deliberately kept out of `PDFImporter.Options` and `ImageImporter.Options`: those
/// stay pure configuration, which makes it structurally impossible for the PDF importer to
/// forward its handler into the `ImageImporter` it uses for the OCR fallback.
public struct ImportOptions: Sendable {
    public var pdf: PDFImporter.Options
    public var image: ImageImporter.Options
    public var progress: ImportProgress.Handler?

    public init(
        pdf: PDFImporter.Options = .init(),
        image: ImageImporter.Options = .init(),
        progress: ImportProgress.Handler? = nil
    ) {
        self.pdf = pdf
        self.image = image
        self.progress = progress
    }
}

/// Reports progress and checks for cancellation, so importers do not repeat the arithmetic.
///
/// Cancellation is an injected predicate rather than `Task.checkCancellation()`. Ambient task
/// state would make the importers untestable — a text-layer page takes microseconds, so a
/// cancel-versus-completion race is not deterministic — and would silently change the Shortcuts
/// intents, whose `perform()` already runs inside a task.
struct ImportReporter {
    let totalUnits: Int
    let handler: ImportProgress.Handler?
    let isCancelled: @Sendable () -> Bool

    /// Fraction reserved for turning recognised lines into Markdown, after every page is read.
    private static let assemblyShare = 0.05

    func checkCancellation() throws {
        if isCancelled() { throw ConversionError.cancelled }
    }

    /// Reports a page about to be worked on. `index` is 0-based.
    func report(_ phase: ImportProgress.Phase, index: Int) {
        guard let handler else { return }
        let share = (1 - Self.assemblyShare) * Double(index) / Double(max(totalUnits, 1))
        handler(ImportProgress(
            phase: phase,
            unit: index + 1,
            totalUnits: totalUnits,
            fractionCompleted: share
        ))
    }

    func report(_ phase: ImportProgress.Phase, fraction: Double) {
        guard let handler else { return }
        handler(ImportProgress(
            phase: phase,
            unit: totalUnits,
            totalUnits: totalUnits,
            fractionCompleted: fraction
        ))
    }

    func reportAssembling() { report(.assembling, fraction: 1 - Self.assemblyShare) }
    func reportFinished() { report(.assembling, fraction: 1) }
}
