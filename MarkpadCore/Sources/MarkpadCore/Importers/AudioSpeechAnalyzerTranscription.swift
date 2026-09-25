import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Transcription with `SpeechAnalyzer` and `SpeechTranscriber` (macOS 26 and later).
///
/// Needs no speech-recognition permission: the SDK's documented SpeechAnalyzer workflow
/// (modules → assets → input → analyze → results) has no authorization step, and a process
/// whose `SFSpeechRecognizer.authorizationStatus()` is `.notDetermined` transcribes normally.
/// It does need the language's model, which the system downloads from Apple and shares
/// between apps.
@available(macOS 26, *)
enum AudioSpeechAnalyzerTranscription {
    /// The most specific supported locale for `candidates`, tried in order.
    static func supportedLocale(for candidates: [Locale]) async -> Locale? {
        for candidate in candidates {
            if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: candidate) { return locale }
        }
        return nil
    }

    static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        // Final results only, each word carrying its time range. The presets that include
        // time ranges also ask for alternatives, which this importer would throw away.
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
    }

    static func transcribe(
        url: URL,
        candidates: [Locale],
        tracker: AudioProgressTracker,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws -> [AudioTranscriptSegment] {
        guard let locale = await supportedLocale(for: candidates) else {
            throw ConversionError.speechUnavailable(
                "Transcribing \(AudioLanguageName.of(candidates[0])) isn't supported on this Mac.")
        }
        let transcriber = makeTranscriber(locale: locale)
        try await installAssets(for: transcriber, locale: locale, tracker: tracker, isCancelled: isCancelled)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () throws -> [AudioTranscriptSegment] in
            var segments: [AudioTranscriptSegment] = []
            for try await result in transcriber.results where result.isFinal {
                segments += Self.segments(of: result)
                tracker.reportTranscribed(through: result.range.end.seconds)
            }
            return segments
        }

        do {
            try await AudioCancellation.run(
                isCancelled: isCancelled,
                onCancel: {
                    await analyzer.cancelAndFinishNow()
                    collector.cancel()
                },
                operation: {
                    // Opened here rather than passed in: AVAudioFile is not Sendable.
                    let file = try AVAudioFile(forReading: url)
                    if let last = try await analyzer.analyzeSequence(from: file) {
                        try await analyzer.finalizeAndFinish(through: last)
                    } else {
                        await analyzer.cancelAndFinishNow()
                    }
                }
            )
            return try await collector.value
        } catch let error as ConversionError {
            collector.cancel()
            throw error
        } catch {
            collector.cancel()
            throw mapped(error, url: url)
        }
    }

    /// Makes sure the language's model is on this Mac, downloading it if it has to.
    ///
    /// `assetInstallationRequest` also reserves the locale for this app, and returns nil when
    /// the model is already on disk — `status` alone reads `.supported` until then, even for
    /// a model another app downloaded.
    private static func installAssets(
        for transcriber: SpeechTranscriber,
        locale: Locale,
        tracker: AudioProgressTracker,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws {
        let language = AudioLanguageName.of(locale)
        let status = await AssetInventory.status(forModules: [transcriber])
        if status == .unsupported {
            throw ConversionError.speechUnavailable("Transcribing \(language) isn't supported on this Mac.")
        }
        guard status != .installed else { return }
        do {
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
                return
            }
            tracker.reportReading()
            try await AudioCancellation.run(
                isCancelled: isCancelled,
                onCancel: {},
                operation: { try await request.downloadAndInstall() }
            )
        } catch let error as ConversionError {
            throw error
        } catch {
            throw ConversionError.speechUnavailable(
                "The speech model for \(language) couldn't be downloaded. Connect to the internet and try again. (\(error.localizedDescription))")
        }
    }

    /// One segment per word that carries a time range. Text between timed words (spacing,
    /// punctuation the model attached separately) joins the word before it.
    static func segments(of result: SpeechTranscriber.Result) -> [AudioTranscriptSegment] {
        var segments: [AudioTranscriptSegment] = []
        var pending = ""
        for run in result.text.runs {
            let text = String(result.text[run.range].characters)
            if let range = run.audioTimeRange, range.start.isNumeric {
                segments.append(AudioTranscriptSegment(
                    pending + text, start: range.start.seconds, end: range.end.seconds))
                pending = ""
            } else if segments.isEmpty {
                pending += text
            } else {
                segments[segments.count - 1].text += text
            }
        }
        if segments.isEmpty {
            let text = pending
            guard !AudioTranscriptLayout.normalized(text).isEmpty else { return [] }
            return [AudioTranscriptSegment(text, start: result.range.start.seconds, end: result.range.end.seconds)]
        }
        if !pending.isEmpty { segments[segments.count - 1].text += pending }
        return segments
    }

    private static func mapped(_ error: Error, url: URL) -> ConversionError {
        if let speech = error as? SFSpeechError {
            switch speech.code {
            case .audioReadFailed, .unexpectedAudioFormat, .incompatibleAudioFormats, .audioDisordered:
                return .unreadableFile(url)
            default:
                break
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSOSStatusErrorDomain || nsError.domain == AVFoundationErrorDomain {
            return .unreadableFile(url)
        }
        return .speechUnavailable("Transcription stopped: \(error.localizedDescription)")
    }
}
