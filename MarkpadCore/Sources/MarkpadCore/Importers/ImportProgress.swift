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
        /// Recognising speech in an audio file.
        case transcribingAudio
    }

    /// What `unit` counts, so the status line can say "slide 3 of 8" rather than "page".
    public enum UnitKind: Sendable, Equatable {
        case page
        case slide
        case sheet
        case chapter
        /// Seconds of audio, shown as a time.
        case second
    }

    public let phase: Phase
    /// 1-based index of the page being worked on. Always 1 for a single image.
    public let unit: Int
    /// Total pages. Always 1 for a single image.
    public let totalUnits: Int
    /// 0...1, clamped, and non-decreasing across one import.
    public let fractionCompleted: Double
    public let unitKind: UnitKind

    public init(
        phase: Phase,
        unit: Int,
        totalUnits: Int,
        fractionCompleted: Double,
        unitKind: UnitKind = .page
    ) {
        self.phase = phase
        self.unit = max(1, unit)
        self.totalUnits = max(1, totalUnits)
        self.fractionCompleted = min(max(fractionCompleted, 0), 1)
        self.unitKind = unitKind
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
        case .transcribingAudio: action = "Transcribing audio on device"
        }
        guard totalUnits > 1 else { return action }
        switch unitKind {
        case .page: return "\(action) — page \(unit) of \(totalUnits)"
        case .slide: return "\(action) — slide \(unit) of \(totalUnits)"
        case .sheet: return "\(action) — sheet \(unit) of \(totalUnits)"
        case .chapter: return "\(action) — chapter \(unit) of \(totalUnits)"
        case .second: return "\(action) — \(Self.clock(unit)) of \(Self.clock(totalUnits))"
        }
    }

    /// `m:ss`, or `h:mm:ss` from an hour up.
    static func clock(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let rest = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
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
    public var document: DocumentImportOptions
    public var audio: AudioImporter.Options
    public var progress: ImportProgress.Handler?

    public init(
        pdf: PDFImporter.Options = .init(),
        image: ImageImporter.Options = .init(),
        document: DocumentImportOptions = .init(),
        audio: AudioImporter.Options = .init(),
        progress: ImportProgress.Handler? = nil
    ) {
        self.pdf = pdf
        self.image = image
        self.document = document
        self.audio = audio
        self.progress = progress
    }
}

/// Settings shared by the structured importers (Word, web, slides, sheets, books, tables).
public struct DocumentImportOptions: Sendable, Equatable {
    /// Folder the Markdown links pictures into, relative to the `.md` file. Nil drops pictures
    /// in favour of their alt text, for callers with nowhere to save them.
    public var assetFolderName: String?
    /// Rows kept per spreadsheet sheet or CSV file. A table far larger than this is unreadable
    /// as Markdown and slows the editor to a crawl.
    public var maximumTableRows: Int
    /// For an image: put the picture itself above its recognised text. Needs
    /// `assetFolderName`, since the picture is saved beside the Markdown. A picture with no
    /// text in it then converts to just the picture rather than failing.
    public var includesOriginalPicture: Bool

    public init(assetFolderName: String? = nil, maximumTableRows: Int = 5_000, includesOriginalPicture: Bool = false) {
        self.assetFolderName = assetFolderName
        self.maximumTableRows = maximumTableRows
        self.includesOriginalPicture = includesOriginalPicture
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
    var unitKind: ImportProgress.UnitKind = .page

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
            fractionCompleted: share,
            unitKind: unitKind
        ))
    }

    func report(_ phase: ImportProgress.Phase, fraction: Double) {
        guard let handler else { return }
        handler(ImportProgress(
            phase: phase,
            unit: totalUnits,
            totalUnits: totalUnits,
            fractionCompleted: fraction,
            unitKind: unitKind
        ))
    }

    func reportAssembling() { report(.assembling, fraction: 1 - Self.assemblyShare) }
    func reportFinished() { report(.assembling, fraction: 1) }
}
