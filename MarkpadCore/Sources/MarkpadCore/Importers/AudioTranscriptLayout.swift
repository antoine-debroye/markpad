import Foundation

/// A stretch of recognised speech — usually one word — and where it sits in the audio.
///
/// `text` may carry the spacing the recogniser put before the word (SpeechAnalyzer does); a
/// segment without any is separated from the previous one by a space unless it starts with
/// punctuation or either side is in a script written without spaces.
struct AudioTranscriptSegment: Equatable, Sendable {
    var text: String
    /// Seconds from the start of the file.
    var start: Double
    var end: Double

    init(_ text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = max(start, end)
    }
}

/// Turns timed speech into timestamped paragraphs. Pure, so it is testable without Speech.
///
/// A transcript is one long run of words; what makes it readable is breaking it where the
/// speaker paused. A new paragraph starts:
/// - after a pause of `pauseBreak` seconds or more, whatever the punctuation;
/// - after a sentence end followed by a pause of `sentencePauseBreak` seconds or more;
/// - after a sentence end once the paragraph has run `preferredParagraphLength` seconds;
/// - before any word once the paragraph has run `maximumParagraphLength` seconds, so speech
///   the recogniser left unpunctuated still breaks up.
enum AudioTranscriptLayout {
    static let pauseBreak = 1.5
    static let sentencePauseBreak = 0.7
    static let preferredParagraphLength = 45.0
    static let maximumParagraphLength = 60.0

    struct Paragraph: Equatable {
        var start: Double
        var text: String
    }

    static func paragraphs(_ segments: [AudioTranscriptSegment]) -> [Paragraph] {
        var result: [Paragraph] = []
        var current = ""
        var paragraphStart = 0.0
        var previous: AudioTranscriptSegment?

        func flush() {
            let text = normalized(current)
            if !text.isEmpty { result.append(Paragraph(start: paragraphStart, text: text)) }
            current = ""
        }

        for segment in segments {
            guard !normalized(segment.text).isEmpty else { continue }
            if let previous {
                let gap = segment.start - previous.end
                let elapsed = segment.start - paragraphStart
                let sentenceEnded = endsSentence(previous.text)
                let breaks = gap >= pauseBreak
                    || (sentenceEnded && gap >= sentencePauseBreak)
                    || (sentenceEnded && elapsed >= preferredParagraphLength)
                    || elapsed >= maximumParagraphLength
                if breaks {
                    flush()
                    paragraphStart = segment.start
                }
            } else {
                paragraphStart = segment.start
            }
            if needsSpace(between: current, and: segment.text) { current += " " }
            current += segment.text
            previous = segment
        }
        flush()
        return result
    }

    /// `[m:ss]`, or `[h:mm:ss]` from an hour up, rounded down to the second.
    static func timestamp(_ seconds: Double) -> String {
        let whole = seconds.isFinite ? Int(max(0, seconds).rounded(.down)) : 0
        return "[" + ImportProgress.clock(whole) + "]"
    }

    static func blocks(_ segments: [AudioTranscriptSegment]) -> [MarkdownBlock] {
        paragraphs(segments).map { paragraph in
            .paragraph([MarkdownRun(timestamp(paragraph.start), bold: true), MarkdownRun(" " + paragraph.text)])
        }
    }

    static func markdown(_ segments: [AudioTranscriptSegment]) -> String {
        MarkdownRenderer.render(blocks(segments))
    }

    /// Collapses runs of whitespace, newlines included, to one space and trims the ends.
    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// Whether two pieces of speech need a space between them when neither supplies one.
    static func needsSpace(between left: String, and right: String) -> Bool {
        guard let last = left.last, let first = right.first else { return false }
        if last.isWhitespace || first.isWhitespace { return false }
        if attachesToPrevious.contains(first) { return false }
        return !isUnspaced(last) && !isUnspaced(first)
    }

    private static let attachesToPrevious: Set<Character> = [
        ".", ",", ";", ":", "!", "?", "…", ")", "]", "}", "%", "”", "’", "»", "。", "、", "，", "！", "？", "：", "；", "」", "』",
    ]

    /// Han, kana, Thai, Lao, Khmer and Myanmar are written without spaces between words.
    private static func isUnspaced(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x0E00...0x0EFF, // Thai, Lao
             0x1000...0x109F, // Myanmar
             0x1780...0x17FF, // Khmer
             0x3000...0x30FF, // CJK punctuation, Hiragana, Katakana
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, // Han
             0xFF00...0xFFEF, // Full-width forms
             0x20000...0x2FFFF:
            return true
        default:
            return false
        }
    }

    private static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "»", "」", "』"]
    private static let terminators: Set<Character> = [".", "!", "?", "…", "。", "！", "？", "؟", "।"]

    static func endsSentence(_ text: String) -> Bool {
        var trimmed = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        while let last = trimmed.last, closers.contains(last) { trimmed = trimmed.dropLast() }
        guard let last = trimmed.last else { return false }
        return terminators.contains(last)
    }
}
