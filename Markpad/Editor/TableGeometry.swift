import AppKit
import MarkpadCore

/// Column positions for one rendered table.
///
/// Markdown tables are laid out without changing the text: each `|` is turned into a
/// control glyph whose width is exactly the distance to the next column, so the cells after
/// it start on a shared boundary. This type works out those distances.
struct TableGeometry {
    /// Space either side of a cell's text.
    static let cellPadding: CGFloat = 10
    /// Smallest gap a delimiter may collapse to when a cell overruns its column.
    private static let minimumGap: CGFloat = 6

    let structure: TableStructure
    /// Left edge of each column, plus a final entry for the table's right edge.
    let boundaries: [CGFloat]
    /// Target x for each delimiter, keyed by its character location.
    private let delimiterTargets: [Int: CGFloat]
    /// Font scale applied to make a wide table fit.
    let scale: CGFloat

    var width: CGFloat { boundaries.last ?? 0 }

    func target(forDelimiterAt characterIndex: Int) -> CGFloat? {
        delimiterTargets[characterIndex]
    }

    /// Width a delimiter glyph should occupy, given where the pen currently sits.
    func gap(forDelimiterAt characterIndex: Int, penX: CGFloat) -> CGFloat {
        guard let target = target(forDelimiterAt: characterIndex) else { return 0 }
        return max(target - penX, Self.minimumGap)
    }

    /// Measures a table against the styled text.
    ///
    /// Returns nil when the table cannot be drawn as a grid in the space available, in which
    /// case the editor leaves it as aligned source rather than showing a broken table.
    init?(structure: TableStructure, storage: NSTextStorage, availableWidth: CGFloat, theme: EditorTheme) {
        self.structure = structure

        // Try the natural size first, then progressively smaller text before giving up.
        let candidates: [CGFloat] = [1.0, 0.92, 0.84, 0.76]
        var chosen: (widths: [CGFloat], scale: CGFloat)?

        for candidate in candidates {
            let widths = Self.columnWidths(structure: structure, storage: storage, scale: candidate)
            let total = widths.reduce(0, +)
            if total <= availableWidth {
                chosen = (widths, candidate)
                break
            }
        }
        guard let chosen else { return nil }

        var boundaries: [CGFloat] = [0]
        for width in chosen.widths {
            boundaries.append((boundaries.last ?? 0) + width)
        }
        self.boundaries = boundaries
        self.scale = chosen.scale

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
