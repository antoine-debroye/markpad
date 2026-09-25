import Foundation

/// Reports how many seconds of audio have been transcribed.
///
/// Results arrive on Speech's own tasks and queues, so this is locked; it also keeps the
/// fraction non-decreasing, as `ImportProgress` promises, when results arrive out of order.
final class AudioProgressTracker: @unchecked Sendable {
    /// Matches `ImportReporter`'s assembly share: transcription fills the first 95%.
    private static let transcriptionShare = 0.95

    private let handler: ImportProgress.Handler?
    private let duration: Double
    let totalSeconds: Int
    private let lock = NSLock()
    private var fraction = 0.0

    init(duration: Double, handler: ImportProgress.Handler?) {
        self.duration = duration
        self.handler = handler
        totalSeconds = max(1, Int(duration.rounded(.up)))
    }

    /// Before the audio is touched, or while a speech model downloads. No clock: there is
    /// nothing to count yet.
    func reportReading() {
        guard let handler else { return }
        let current = lock.withLock { fraction }
        handler(ImportProgress(phase: .reading, unit: 1, totalUnits: 1, fractionCompleted: current, unitKind: .second))
    }

    /// `seconds` of audio, from the start, have been transcribed.
    func reportTranscribed(through seconds: Double) {
        guard let handler, seconds.isFinite else { return }
        let clamped = min(max(seconds, 0), duration)
        let update: (unit: Int, fraction: Double) = lock.withLock {
            let candidate = Self.transcriptionShare * clamped / max(duration, .ulpOfOne)
            fraction = max(fraction, candidate)
            return (Int(clamped.rounded(.down)), fraction)
        }
        handler(ImportProgress(
            phase: .transcribingAudio,
            unit: update.unit,
            totalUnits: totalSeconds,
            fractionCompleted: update.fraction,
            unitKind: .second
        ))
    }
}

enum AudioCancellation {
    /// How often the injected `isCancelled` predicate is polled.
    static let pollInterval: UInt64 = 100_000_000

    private enum Outcome<Value: Sendable>: Sendable {
        case finished(Value)
        case cancelRequested
    }

    /// Runs `operation`, stopping it when `isCancelled` turns true or the calling task is
    /// cancelled. `onCancel` tells Speech to stop, since it does not watch either signal.
    static func run<Value: Sendable>(
        isCancelled: @escaping @Sendable () -> Bool,
        onCancel: @escaping @Sendable () async -> Void,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        if isCancelled() || Task.isCancelled { throw ConversionError.cancelled }
        do {
            return try await withThrowingTaskGroup(of: Outcome<Value>.self) { group in
                group.addTask { .finished(try await operation()) }
                group.addTask {
                    while !Task.isCancelled {
                        if isCancelled() { return .cancelRequested }
                        try? await Task.sleep(nanoseconds: pollInterval)
                    }
                    // Either the operation finished and the group is winding down, or the
                    // caller's task was cancelled; the loop below tells them apart.
                    return .cancelRequested
                }
                while let outcome = try await group.next() {
                    switch outcome {
                    case .finished(let value):
                        group.cancelAll()
                        return value
                    case .cancelRequested:
                        await onCancel()
                        group.cancelAll()
                        throw ConversionError.cancelled
                    }
                }
                throw ConversionError.cancelled
            }
        } catch is CancellationError {
            await onCancel()
            throw ConversionError.cancelled
        }
    }
}

enum AudioLanguageName {
    /// "English (United States)", for messages.
    static func of(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }
}
