import AppKit
import MarkpadCore

/// Column positions for one rendered table.
///
/// Markdown tables are laid out without changing the text: each `|` is turned into a
/// control glyph whose width is exactly the distance to the next column, so the cells after
/// it start on a shared boundary. This type works out those distances.
struct TableGeometry {
    /// Space either side of a cell's text. From the design's `padding: 8px 12px`.
    static let cellPadding: CGFloat = MarkdownStyler.Table.horizontalPadding
    /// Smallest gap a delimiter may collapse to when a cell overruns its column.
    private static let minimumGap: CGFloat = 6

    let structure: TableStructure
    /// Left edge of each column, plus a final entry for the table's right edge.
    let boundaries: [CGFloat]
    /// Target x for each delimiter, keyed by its character location.
    private let delimiterTargets: [Int: CGFloat]
    /// Font scale applied to make a wide table fit.
    let scale: CGFloat
    /// False when the table is wider than the window even at the smallest scale, in which
    /// case the editor scrolls horizontally to reach it.
    let fitsAvailableWidth: Bool

    var width: CGFloat { boundaries.last ?? 0 }

    func target(forDelimiterAt characterIndex: Int) -> CGFloat? {
        delimiterTargets[characterIndex]
    }

    /// Width a delimiter glyph should occupy, given where the pen currently sits.
    func gap(forDelimiterAt characterIndex: Int, penX: CGFloat) -> CGFloat {
        guard let target = target(forDelimiterAt: characterIndex) else { return 0 }
        return max(target - penX, Self.minimumGap)
    }

    /// Largest grid the editor will lay out, a guard against a pathological document.
    private static let maximumWidth: CGFloat = 12_000

    /// Measures a table against the styled text.
    ///
    /// A table that nearly fits is shrunk slightly to avoid a scroll bar; one that cannot
    /// fit keeps its natural size and is reached by scrolling, which beats clipping it or
    /// squeezing the text until it is unreadable.
    /// - Parameters:
    ///   - availableWidth: how wide the table may grow before it has to be scrolled to.
    ///   - stretchWidth: the text column's width. A table narrower than this is stretched to
    ///     fill it, because the design lays tables out as a grid spanning the measure rather
    ///     than shrink-wrapped around their contents.
    init(
        structure: TableStructure,
        storage: NSTextStorage,
        availableWidth: CGFloat,
        stretchWidth: CGFloat,
        theme: EditorTheme
    ) {
        self.structure = structure

        let candidates: [CGFloat] = [1.0, 0.94, 0.88]
        var chosen: (widths: [CGFloat], scale: CGFloat)?

        for candidate in candidates {
            let widths = Self.columnWidths(structure: structure, storage: storage, scale: candidate)
            if widths.reduce(0, +) <= availableWidth {
                chosen = (widths, candidate)
                break
            }
        }

        let resolved = chosen ?? (Self.columnWidths(structure: structure, storage: storage, scale: 1), 1)
        self.fitsAvailableWidth = chosen != nil
        self.scale = resolved.scale

        // Spread any slack across the columns in proportion to their measured width, so the
        // table meets both edges of the text column like the design's `1.4fr 1fr 1fr` grid.
        var widths = resolved.widths
        let natural = widths.reduce(0, +)
        if natural > 0, stretchWidth > natural {
            let factor = stretchWidth / natural
            widths = widths.map { $0 * factor }
        }

        var boundaries: [CGFloat] = [0]
        for width in widths {
            let next = (boundaries.last ?? 0) + width
            boundaries.append(min(next, Self.maximumWidth))
        }
        self.boundaries = boundaries

        // Map each delimiter to the boundary it should reach. A row that opens with a pipe
        // has one more delimiter than a row that does not, so the offset differs.
        var targets: [Int: CGFloat] = [:]
        for row in structure.rows {
            let pipes = structure.delimiters
                .filter { NSLocationInRange($0.location, row.range) }
                .sorted { $0.location < $1.location }
            guard !pipes.isEmpty else { continue }

            let opensWithPipe = pipes[0].location == Self.firstNonSpace(in: storage, range: row.range)
            for (index, pipe) in pipes.enumerated() {
                let boundaryIndex = opensWithPipe ? index : index + 1
                guard boundaryIndex < boundaries.count else { continue }
                targets[pipe.location] = boundaries[boundaryIndex]
            }
        }
        self.delimiterTargets = targets
    }

    private static func firstNonSpace(in storage: NSTextStorage, range: NSRange) -> Int {
        let text = storage.string as NSString
        var index = range.location
        while index < NSMaxRange(range), text.character(at: index) == UInt16(UnicodeScalar(" ").value) {
            index += 1
        }
        return index
    }

    /// Widest cell in each column, plus padding.
    private static func columnWidths(
        structure: TableStructure,
        storage: NSTextStorage,
        scale: CGFloat
    ) -> [CGFloat] {
        var widths = Array(repeating: CGFloat(0), count: structure.columnCount)

        for row in structure.rows {
            for cell in row.cells where cell.column < widths.count {
                guard cell.range.length > 0, NSMaxRange(cell.range) <= storage.length else { continue }
                let attributed = storage.attributedSubstring(from: cell.range)
                var measured = attributed.size().width
                if scale != 1 {
                    measured *= scale
                }
                widths[cell.column] = max(widths[cell.column], measured)
            }
        }
        return widths.map { $0 + cellPadding * 2 }
    }
}
