import XCTest
@testable import Markpad

/// The word count and reading estimate shown in the window chrome.
final class EditorStatusTests: XCTestCase {
    private func status(words: Int) -> EditorStatus {
        EditorStatus(words: words, characters: words * 6, outline: [])
    }

    /// The design's dark chrome reads "1,204 words · 6 min". That only holds at 200 words per
    /// minute, which is what pins the rate.
    func testReadingEstimateMatchesTheDesign() {
        XCTAssertEqual(status(words: 1204).readingDescription, "1,204 words · 6 min")
    }

    func testShortDocumentStillReadsAsOneMinute() {
        XCTAssertEqual(status(words: 12).readingMinutes, 1, "a rounded zero would read as '0 min'")
        XCTAssertEqual(status(words: 12).readingDescription, "12 words · 1 min")
    }

    func testEmptyDocumentHasNoEstimate() {
        XCTAssertEqual(status(words: 0).readingMinutes, 0)
        XCTAssertEqual(status(words: 0).readingDescription, "No words yet")
    }

    func testSingularWord() {
        XCTAssertEqual(status(words: 1).wordsDescription, "1 word")
        XCTAssertEqual(status(words: 2).wordsDescription, "2 words")
    }

    func testThousandsAreGrouped() {
        // The design writes the count with a separator; an unformatted "1204 words" would not
        // match it.
        XCTAssertTrue(status(words: 1204).wordsDescription.contains("1,204"),
                      status(words: 1204).wordsDescription)
    }

    func testEstimateRoundsRatherThanTruncating() {
        // 500 words is two and a half minutes; truncation would call it two.
        XCTAssertEqual(status(words: 500).readingMinutes, 3)
        XCTAssertEqual(status(words: 400).readingMinutes, 2)
    }
}
