import XCTest
@testable import Markpad

/// The width arithmetic behind the centred text column.
///
/// Worth testing directly: the inset, the measure and the table-overflow decision feed each
/// other, and wiring them the wrong way round produces a layout that oscillates on every window
/// resize rather than one that is obviously broken.
final class EditorMetricsTests: XCTestCase {
    private let measure: CGFloat = 720

    private func metrics(frame: CGFloat, table: CGFloat = 0) -> EditorMetrics {
        EditorMetrics(frameWidth: frame, contentWidth: measure, widestTable: table)
    }

    func testWideWindowCentresTheColumnAtTheMeasure() {
        let m = metrics(frame: 1400)
        XCTAssertEqual(m.containerWidth, 720)
        XCTAssertEqual(m.horizontalInset, (1400 - 720) / 2)
        XCTAssertNil(m.wrapWidth, "prose fills the container, so it needs no separate wrap width")
        XCTAssertFalse(m.overflows)
    }

    func testNarrowWindowKeepsTheBaseGutter() {
        // Below the measure plus both gutters, the column is simply the window less the gutters,
        // which is exactly what the editor did before it had a measure at all.
        let m = metrics(frame: 600)
        XCTAssertEqual(m.horizontalInset, EditorMetrics.gutter)
        XCTAssertEqual(m.containerWidth, 600 - EditorMetrics.gutter * 2)
        XCTAssertNil(m.wrapWidth)
        XCTAssertFalse(m.overflows)
    }

    func testUnlaidOutScrollViewIsInert() {
        let m = metrics(frame: 0)
        XCTAssertEqual(m.horizontalInset, EditorMetrics.gutter)
        XCTAssertFalse(m.overflows)
        XCTAssertNil(m.wrapWidth)
    }

    // MARK: Tables

    func testTableWiderThanTheColumnEatsTheMarginRatherThanScrolling() {
        // 900pt table in a 1400pt window: it fits the window comfortably, so it must not gain a
        // scroll bar just because the prose column is 720.
        let m = metrics(frame: 1400, table: 900)
        XCTAssertFalse(m.overflows, "a table that fits the window must not scroll")
        XCTAssertEqual(m.containerWidth, 900, "the container widens to hold the table")
        XCTAssertEqual(m.wrapWidth, measure, "prose keeps wrapping at the measure")
        XCTAssertEqual(m.horizontalInset, ((1400 - 900) / 2).rounded())
    }

    func testTableWiderThanTheWindowScrollsSideways() {
        let m = metrics(frame: 1000, table: 1600)
        XCTAssertTrue(m.overflows)
        XCTAssertEqual(m.containerWidth, 1600)
        XCTAssertEqual(m.wrapWidth, measure)
        // The table extends past the measure; the trailing side needs only a plain gutter.
        XCTAssertEqual(m.documentWidth, m.horizontalInset + 1600 + EditorMetrics.gutter)
    }

    /// A wide table used to collapse the margin to the gutter, which threw the whole document
    /// against the left edge — prose included. Only the table should overflow.
    func testOverflowKeepsTheProseCentred() {
        let withoutTable = metrics(frame: 1000)
        let withWideTable = metrics(frame: 1000, table: 1600)

        XCTAssertTrue(withWideTable.overflows)
        XCTAssertEqual(
            withWideTable.horizontalInset, withoutTable.horizontalInset,
            "a table wide enough to scroll must not move the prose"
        )
        XCTAssertEqual(withWideTable.horizontalInset, (1000 - measure) / 2)
    }

    func testTableNarrowerThanTheColumnChangesNothing() {
        let m = metrics(frame: 1400, table: 400)
        XCTAssertEqual(m.containerWidth, 720)
        XCTAssertNil(m.wrapWidth)
        XCTAssertFalse(m.overflows)
    }

    // MARK: Stability

    /// The reason the inset is derived from the scroll view rather than from itself. If the
    /// measure were computed from the current inset, each pass would produce a different answer
    /// and the layout would oscillate while the window is resized.
    func testApplyingTheMetricsTwiceIsAFixedPoint() {
        for frame in [420, 700, 1000, 1400, 2400] as [CGFloat] {
            for table in [0, 400, 900, 1600] as [CGFloat] {
                let first = metrics(frame: frame, table: table)
                let second = metrics(frame: frame, table: table)
                XCTAssertEqual(first, second, "frame \(frame), table \(table)")
            }
        }
    }

    func testColumnNeverExceedsTheWindow() {
        for frame in stride(from: CGFloat(300), through: 2000, by: 50) {
            let m = metrics(frame: frame)
            XCTAssertLessThanOrEqual(
                m.containerWidth + m.horizontalInset * 2, max(frame, m.containerWidth) + 1,
                "column plus margins should fit the window at width \(frame)"
            )
        }
    }
}
