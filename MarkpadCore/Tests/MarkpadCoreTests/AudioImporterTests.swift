import AVFoundation
import Foundation
import Speech
import XCTest
@testable import MarkpadCore

final class AudioImporterTests: XCTestCase {
    private func seg(_ text: String, _ start: Double, _ end: Double) -> AudioTranscriptSegment {
        AudioTranscriptSegment(text, start: start, end: end)
    }

    // MARK: - Layout (pure)

    func testBreaksOnSentenceEndPlusPauseAndOnLongPause() {
        let segments = [
            seg("The", 0, 0.3), seg(" quick", 0.3, 0.5), seg(" fox.", 0.5, 1.0),
            // 0.8 s after a full stop: new paragraph.
            seg(" Next", 1.8, 2.1), seg(" words", 2.1, 2.4),
            // 1.6 s with no punctuation: new paragraph.
            seg(" here", 4.0, 4.3),
        ]
        XCTAssertEqual(
            AudioTranscriptLayout.markdown(segments),
            "**\\[0:00\\]** The quick fox.\n\n**\\[0:01\\]** Next words\n\n**\\[0:04\\]** here\n"
        )
    }

    func testShortPausesDoNotBreak() {
        let segments = [
            seg("One.", 0, 0.5),
            seg(" Two", 1.1, 1.4), // 0.6 s after a full stop: below 0.7 s.
            seg(" three", 2.8, 3.0), // 1.4 s with no full stop: below 1.5 s.
        ]
        XCTAssertEqual(AudioTranscriptLayout.markdown(segments), "**\\[0:00\\]** One. Two three\n")
    }

    func testSegmentsWithoutSpacingAreJoinedSensibly() {
        let segments = [
            seg("Hello", 0, 0.4), seg(",", 0.4, 0.4), seg("world", 0.5, 0.9), seg("!", 0.9, 0.9),
            seg("你好", 3.0, 3.3), seg("世界", 3.3, 3.6),
        ]
        XCTAssertEqual(
            AudioTranscriptLayout.markdown(segments),
            "**\\[0:00\\]** Hello, world!\n\n**\\[0:03\\]** 你好世界\n"
        )
    }

    func testLongSpeechBreaksAtSentenceAfterPreferredLengthAndAlwaysAtMaximum() {
        // Back-to-back one-second words, with a full stop on the word spoken at 50 s.
        var segments: [AudioTranscriptSegment] = []
        for second in 0..<130 {
            let word = second == 50 ? " stop." : " w\(second)"
            segments.append(seg(second == 0 ? "w0" : word, Double(second), Double(second) + 1))
        }
        let paragraphs = AudioTranscriptLayout.paragraphs(segments)
        XCTAssertEqual(paragraphs.map(\.start), [0, 51, 111])
        XCTAssertTrue(paragraphs[0].text.hasSuffix("w49 stop."))
        XCTAssertTrue(paragraphs[1].text.hasPrefix("w51 "))
        XCTAssertTrue(paragraphs[1].text.hasSuffix("w110"))
    }

    func testTimestampsAndEscaping() {
        XCTAssertEqual(AudioTranscriptLayout.timestamp(0), "[0:00]")
        XCTAssertEqual(AudioTranscriptLayout.timestamp(65.9), "[1:05]")
        XCTAssertEqual(AudioTranscriptLayout.timestamp(3725.2), "[1:02:05]")
        XCTAssertEqual(AudioTranscriptLayout.timestamp(-3), "[0:00]")
        XCTAssertEqual(
            AudioTranscriptLayout.markdown([seg("# *nix", 65, 66)]),
            "**\\[1:05\\]** # \\*nix\n"
        )
    }

    func testEmptyAndWhitespaceSegmentsProduceNothing() {
        XCTAssertEqual(AudioTranscriptLayout.markdown([]), "")
        XCTAssertEqual(AudioTranscriptLayout.markdown([seg("  ", 0, 1), seg("\n", 1, 2)]), "")
    }

    func testCandidateLocalesAddBareLanguage() {
        XCTAssertEqual(AudioImporter.candidateLocales(for: "fr-CA").map(\.identifier), ["fr-CA", "fr"])
        XCTAssertFalse(AudioImporter.candidateLocales(for: nil).isEmpty)
    }

    // MARK: - Validation (no Speech needed)

    func testUnreadableFileIsReported() async throws {
        try await Fixtures.withTemporaryDirectoryAsync { directory in
            let url = directory.appendingPathComponent("broken.m4a")
            try Data("this is not audio".utf8).write(to: url)
            do {
                _ = try await AudioImporter().convert(url: url)
                XCTFail("Expected unreadableFile")
            } catch ConversionError.unreadableFile(let reported) {
                XCTAssertEqual(reported, url)
            }
        }
    }

    func testEmptyAudioHasNoText() async throws {
        try await Fixtures.withTemporaryDirectoryAsync { directory in
            let url = directory.appendingPathComponent("empty.caf")
            try Self.writeSilence(to: url, seconds: 0)
            do {
                _ = try await AudioImporter().convert(url: url)
                XCTFail("Expected noTextFound")
            } catch ConversionError.noTextFound(let reported) {
                XCTAssertEqual(reported, url)
            }
        }
    }

    func testCancelledBeforeStartingThrowsCancelled() async throws {
        try await Fixtures.withTemporaryDirectoryAsync { directory in
            let url = directory.appendingPathComponent("silence.caf")
            try Self.writeSilence(to: url, seconds: 1)
            do {
                _ = try await AudioImporter().convert(url: url, isCancelled: { true })
                XCTFail("Expected cancelled")
            } catch ConversionError.cancelled {}
        }
    }

    func testAuthorizationStatusOnlyReads() {
        // Reading must never prompt or crash, even without a usage description.
        _ = AudioImporter.authorizationStatus()
        if #available(macOS 26, *), SpeechTranscriber.isAvailable {
            XCTAssertFalse(AudioImporter.requiresSpeechAuthorization())
        }
    }

    // MARK: - End to end (skipped unless it can run without prompting or downloading)

    func testTranscribesSpokenSentence() async throws {
        try await requireSpeechWithoutPrompting()
        try await Fixtures.withTemporaryDirectoryAsync { directory in
            let url = try Self.speak(
                "The quick brown fox jumps over the lazy dog. Markpad converts audio on device.",
                in: directory)
            let log = ProgressLog()
            let result = try await AudioImporter().convert(
                url: url, options: .init(localeIdentifier: "en-US"), progress: log.handler)
            let markdown = result.markdown
            print("Transcript:\n\(markdown)")
            XCTAssertTrue(markdown.hasPrefix("**\\[0:00\\]** "), markdown)
            let lower = markdown.lowercased()
            XCTAssertTrue(lower.contains("quick brown fox"), markdown)
            XCTAssertTrue(lower.contains("lazy dog"), markdown)
            XCTAssertTrue(lower.contains("audio on device"), markdown)
            XCTAssertTrue(result.assets.isEmpty)

            let events = log.all
            XCTAssertEqual(events.first?.phase, .reading)
            let transcribing = events.filter { $0.phase == .transcribingAudio }
            XCTAssertFalse(transcribing.isEmpty)
            XCTAssertTrue(transcribing.allSatisfy { $0.unitKind == .second && $0.totalUnits == 6 })
            XCTAssertEqual(events.last?.fractionCompleted, 1)
            XCTAssertEqual(events.map(\.fractionCompleted), events.map(\.fractionCompleted).sorted())
        }
    }

    func testSilenceHasNoText() async throws {
        try await requireSpeechWithoutPrompting()
        try await Fixtures.withTemporaryDirectoryAsync { directory in
            let url = directory.appendingPathComponent("silence.caf")
            try Self.writeSilence(to: url, seconds: 3)
            do {
                let result = try await AudioImporter().convert(url: url, options: .init(localeIdentifier: "en-US"))
                XCTFail("Expected noTextFound, got \(result.markdown)")
            } catch ConversionError.noTextFound {}
        }
    }

    func testCancellingMidTranscriptionStops() async throws {
        try await requireSpeechWithoutPrompting()
        try await Fixtures.withTemporaryDirectoryAsync { directory in
            let sentence = "Markpad turns spoken words into Markdown paragraphs with timestamps. "
            let url = try Self.speak(String(repeating: sentence, count: 12), in: directory)
            let started = Date()
            let flag = CancelFlag()
            let log = ProgressLog()
            log.onEvent = { event in
                // Cancel shortly after transcription begins, not before.
                if event.phase == .reading { flag.cancel(after: 0.3) }
            }
            do {
                let result = try await AudioImporter().convert(
                    url: url, options: .init(localeIdentifier: "en-US"),
                    progress: log.handler, isCancelled: { flag.isCancelled })
                XCTFail("Expected cancelled, got \(result.markdown.prefix(80))…")
            } catch ConversionError.cancelled {
                print("Cancelled after \(Date().timeIntervalSince(started)) s")
            }
        }
    }

    // MARK: - Helpers

    /// Skips unless transcription can run here without a permission prompt or a model download.
    private func requireSpeechWithoutPrompting() async throws {
        if #available(macOS 26, *), SpeechTranscriber.isAvailable {
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
                throw XCTSkip("SpeechTranscriber does not support en-US on this Mac")
            }
            let installed = await SpeechTranscriber.installedLocales
            guard installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
                throw XCTSkip("The en-US speech model is not installed; the test would download it")
            }
        } else {
            guard AudioImporter.authorizationStatus() == .authorized else {
                throw XCTSkip("Speech recognition is not authorized for this process (status \(AudioImporter.authorizationStatus())); the importer never prompts")
            }
            guard SFSpeechRecognizer(locale: Locale(identifier: "en-US"))?.supportsOnDeviceRecognition == true else {
                throw XCTSkip("On-device en-US recognition is not available")
            }
        }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/say"),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/afconvert") else {
            throw XCTSkip("/usr/bin/say or /usr/bin/afconvert is missing")
        }
    }

    /// Speaks `text` with the system voice and encodes it as AAC in an M4A file.
    private static func speak(_ text: String, in directory: URL) throws -> URL {
        let aiff = directory.appendingPathComponent("speech.aiff")
        let m4a = directory.appendingPathComponent("speech.m4a")
        try run("/usr/bin/say", ["-o", aiff.path, text])
        try run("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", aiff.path, m4a.path])
        return m4a
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("\(tool) failed with status \(process.terminationStatus)")
        }
    }

    private static func writeSilence(to url: URL, seconds: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        guard frames > 0 else { return }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        memset(buffer.floatChannelData![0], 0, Int(frames) * MemoryLayout<Float>.size)
        try file.write(from: buffer)
    }
}

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var deadline: Date?

    func cancel(after delay: TimeInterval) {
        lock.withLock { if deadline == nil { deadline = Date().addingTimeInterval(delay) } }
    }

    var isCancelled: Bool {
        lock.withLock { deadline.map { Date() >= $0 } ?? false }
    }
}
