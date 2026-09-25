import AVFoundation
import Foundation
import Speech

/// Whether Markpad may use speech recognition, as the system last recorded it.
public enum AudioSpeechAuthorization: Sendable, Equatable {
    case authorized
    case denied
    case restricted
    case notDetermined
}

/// Transcribes speech in an audio file into Markdown, on device.
///
/// On macOS 26 and later this uses `SpeechAnalyzer`, which needs no permission but may download
/// the language's model from Apple the first time. Earlier systems use `SFSpeechRecognizer`
/// with on-device recognition required, which needs the user's speech-recognition permission —
/// see `requiresSpeechAuthorization()`. The importer never asks for it; the app does.
///
/// The transcript is broken into paragraphs where the speaker pauses, each starting with a bold
/// `[m:ss]` timestamp.
public struct AudioImporter: Sendable {
    public struct Options: Sendable, Equatable {
        /// BCP 47 identifier of the spoken language, e.g. `en-GB`. Nil uses the system language.
        public var localeIdentifier: String?

        public init(localeIdentifier: String? = nil) {
            self.localeIdentifier = localeIdentifier
        }
    }

    public init() {}

    public func convert(
        url: URL,
        options: Options = .init(),
        progress: ImportProgress.Handler? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws -> ImportedMarkdown {
        let duration: Double
        do {
            let file = try AVAudioFile(forReading: url)
            let sampleRate = file.processingFormat.sampleRate
            duration = sampleRate > 0 ? Double(file.length) / sampleRate : 0
        } catch {
            throw ConversionError.unreadableFile(url)
        }
        guard duration.isFinite, duration > 0 else { throw ConversionError.noTextFound(url) }

        let tracker = AudioProgressTracker(duration: duration, handler: progress)
        var reporter = ImportReporter(totalUnits: tracker.totalSeconds, handler: progress, isCancelled: isCancelled)
        reporter.unitKind = .second
        try reporter.checkCancellation()
        tracker.reportReading()

        let candidates = Self.candidateLocales(for: options.localeIdentifier)
        let segments: [AudioTranscriptSegment]
        if #available(macOS 26, *), SpeechTranscriber.isAvailable {
            segments = try await AudioSpeechAnalyzerTranscription.transcribe(
                url: url, candidates: candidates, tracker: tracker, isCancelled: isCancelled)
        } else {
            segments = try await AudioLegacyTranscription.transcribe(
                url: url, candidates: candidates, tracker: tracker, isCancelled: isCancelled)
        }
        try reporter.checkCancellation()

        reporter.reportAssembling()
        let markdown = AudioTranscriptLayout.markdown(segments)
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConversionError.noTextFound(url)
        }
        reporter.reportFinished()
        return ImportedMarkdown(markdown: markdown)
    }

    /// Whether transcribing needs the user's speech-recognition permission on this Mac.
    ///
    /// False on macOS 26 and later, where `SpeechAnalyzer` needs none. When true, the app should
    /// request it (`SFSpeechRecognizer.requestAuthorization`, with an
    /// `NSSpeechRecognitionUsageDescription` in its Info.plist) before converting.
    public static func requiresSpeechAuthorization() -> Bool {
        if #available(macOS 26, *), SpeechTranscriber.isAvailable { return false }
        return true
    }

    /// The speech-recognition permission as last recorded. Only reads it: never prompts.
    public static func authorizationStatus() -> AudioSpeechAuthorization {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    /// BCP 47 identifiers of the languages this Mac can transcribe on device, sorted, for a
    /// language picker. A language listed here may still need its model downloaded on first use
    /// (macOS 26 and later).
    public static func supportedLocaleIdentifiers() async -> [String] {
        var identifiers: Set<String> = []
        if #available(macOS 26, *), SpeechTranscriber.isAvailable {
            for locale in await SpeechTranscriber.supportedLocales {
                identifiers.insert(locale.identifier(.bcp47))
            }
        } else {
            for locale in SFSpeechRecognizer.supportedLocales() {
                guard let recognizer = SFSpeechRecognizer(locale: locale),
                      recognizer.supportsOnDeviceRecognition else { continue }
                identifiers.insert(locale.identifier(.bcp47))
            }
        }
        return identifiers.sorted()
    }

    /// The language asked for, then its bare language code; or the system language and the
    /// user's preferred languages when none was chosen.
    static func candidateLocales(for identifier: String?) -> [Locale] {
        var candidates: [Locale] = []
        if let identifier, !identifier.trimmingCharacters(in: .whitespaces).isEmpty {
            candidates.append(Locale(identifier: identifier))
        } else {
            candidates.append(Locale.current)
            candidates += Locale.preferredLanguages.map { Locale(identifier: $0) }
        }
        var withLanguages: [Locale] = []
        for locale in candidates {
            withLanguages.append(locale)
            if let code = locale.language.languageCode?.identifier {
                withLanguages.append(Locale(identifier: code))
            }
        }
        var seen: Set<String> = []
        return withLanguages.filter { seen.insert($0.identifier).inserted }
    }
}
