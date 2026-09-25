import Foundation
import Speech

/// Transcription with `SFSpeechRecognizer`, for macOS 14 and 15 (and any later Mac where
/// `SpeechTranscriber` is unavailable). On device only: Markpad promises audio never leaves
/// the Mac, so a language without an on-device model is refused rather than sent to a server.
///
/// Unlike SpeechAnalyzer this needs the user's speech-recognition permission. The importer only
/// reads the status — requesting it from a process without `NSSpeechRecognitionUsageDescription`
/// (a test runner, say) terminates the process, so asking is the app's job.
enum AudioLegacyTranscription {
    static let notAllowedMessage =
        "Speech recognition isn't allowed for Markpad. Allow it in System Settings ▸ Privacy & Security ▸ Speech Recognition."

    static func transcribe(
        url: URL,
        candidates: [Locale],
        tracker: AudioProgressTracker,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws -> [AudioTranscriptSegment] {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw ConversionError.speechUnavailable(notAllowedMessage)
        }
        let supported = SFSpeechRecognizer.supportedLocales()
        let locale = candidates.first { candidate in
            supported.contains { $0.identifier == candidate.identifier }
        } ?? candidates[0]
        let language = AudioLanguageName.of(locale)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw ConversionError.speechUnavailable("Transcribing \(language) isn't supported on this Mac.")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw ConversionError.speechUnavailable(
                "On-device transcription of \(language) isn't available on this Mac, and Markpad doesn't send audio off your Mac.")
        }
        guard recognizer.isAvailable else {
            throw ConversionError.speechUnavailable("Speech recognition isn't available right now. Try again later.")
        }

        // Handlers default to the main queue, which would deadlock a caller that waits on the
        // main thread for this import to finish.
        let queue = OperationQueue()
        queue.name = "Markpad audio transcription"
        queue.maxConcurrentOperationCount = 1
        recognizer.queue = queue

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        request.shouldReportPartialResults = true

        let session = RecognitionSession(isCancelled: isCancelled)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                session.begin(continuation) {
                    recognizer.recognitionTask(with: request) { result, error in
                        if let result {
                            if let last = result.bestTranscription.segments.last {
                                tracker.reportTranscribed(through: last.timestamp + last.duration)
                            }
                            if result.isFinal {
                                session.finish(.success(segments(of: result.bestTranscription)))
                                return
                            }
                        }
                        if let error {
                            session.finish(.failure(mapped(error, url: url, language: language)))
                        }
                    }
                }
            }
        } onCancel: {
            session.cancel()
        }
    }

    /// One segment per recognised word. Each takes the text since the previous word from the
    /// formatted transcript, so spacing and added punctuation are kept.
    static func segments(of transcription: SFTranscription) -> [AudioTranscriptSegment] {
        let formatted = transcription.formattedString as NSString
        var segments: [AudioTranscriptSegment] = []
        var cursor = 0
        for segment in transcription.segments {
            let range = segment.substringRange
            let end = range.location + range.length
            let text: String
            if range.location != NSNotFound, range.location >= cursor, end <= formatted.length {
                text = formatted.substring(with: NSRange(location: cursor, length: end - cursor))
                cursor = end
            } else {
                text = (segments.isEmpty ? "" : " ") + segment.substring
            }
            segments.append(AudioTranscriptSegment(
                text, start: segment.timestamp, end: segment.timestamp + segment.duration))
        }
        if cursor < formatted.length, !segments.isEmpty {
            segments[segments.count - 1].text += formatted.substring(from: cursor)
        }
        return segments
    }

    private static func mapped(_ error: Error, url: URL, language: String) -> ConversionError {
        let nsError = error as NSError
        // Codes from the table in SFSpeechRecognitionTask.h.
        switch (nsError.domain, nsError.code) {
        case ("kAFAssistantErrorDomain", 1110):
            return .noTextFound(url)
        case ("kAFAssistantErrorDomain", 1700):
            return .speechUnavailable(notAllowedMessage)
        case ("kLSRErrorDomain", 102):
            return .speechUnavailable("The on-device speech model for \(language) isn't installed on this Mac.")
        case ("kLSRErrorDomain", 201):
            return .speechUnavailable("Transcription needs Siri or Dictation, which is turned off on this Mac.")
        case ("kLSRErrorDomain", 301):
            return .cancelled
        case (SFSpeechError.errorDomain, SFSpeechError.Code.audioReadFailed.rawValue):
            return .unreadableFile(url)
        default:
            return .speechUnavailable("Transcription stopped: \(error.localizedDescription)")
        }
    }
}

/// Bridges one recognition task to a continuation, resuming it exactly once whichever comes
/// first: the final result, an error, or a cancellation.
private final class RecognitionSession: @unchecked Sendable {
    private let lock = NSLock()
    private let isCancelled: @Sendable () -> Bool
    private var continuation: CheckedContinuation<[AudioTranscriptSegment], Error>?
    private var task: SFSpeechRecognitionTask?
    private var timer: DispatchSourceTimer?
    private var finished = false

    init(isCancelled: @escaping @Sendable () -> Bool) {
        self.isCancelled = isCancelled
    }

    func begin(
        _ continuation: CheckedContinuation<[AudioTranscriptSegment], Error>,
        start: () -> SFSpeechRecognitionTask
    ) {
        lock.lock()
        if finished {
            // Cancelled before the continuation existed.
            lock.unlock()
            continuation.resume(throwing: ConversionError.cancelled)
            return
        }
        self.continuation = continuation
        lock.unlock()

        let task = start()
        lock.lock()
        if finished {
            lock.unlock()
            task.cancel()
            return
        }
        self.task = task
        // Speech does not know about the injected predicate, so poll it.
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self, self.isCancelled() else { return }
            self.cancel()
        }
        self.timer = timer
        timer.resume()
        lock.unlock()
    }

    func cancel() {
        let task = lock.withLock { self.task }
        task?.cancel()
        finish(.failure(ConversionError.cancelled))
    }

    func finish(_ result: Result<[AudioTranscriptSegment], Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let timer = self.timer
        self.timer = nil
        self.task = nil
        lock.unlock()

        timer?.cancel()
        continuation?.resume(with: result)
    }
}
