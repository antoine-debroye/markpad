import CoreGraphics

/// The widths the editor lays text out at.
///
/// Prose is capped at a comfortable measure and centred, while the text view itself still fills
/// the window so the background reaches both edges. A table wider than the measure spends the
/// centring margin before the editor resorts to scrolling sideways.
///
/// This is a pure value type on purpose: it is the only part of the width logic that can be
/// tested without building an `NSTextView` and an `NSScrollView`.
struct EditorMetrics: Equatable {
    /// Smallest margin between the text and the window edge.
    static let gutter: CGFloat = 24
    static let verticalInset: CGFloat = 28
    /// Floor for the text column, so a very narrow window still lays out.
    static let minimumMeasure: CGFloat = 120

    /// Width the text container is given.
    let containerWidth: CGFloat
    /// Horizontal `textContainerInset`, which is what centres the column.
    let horizontalInset: CGFloat
    /// Width prose wraps at, when the container is wider than the measure. Nil when they match.
    let wrapWidth: CGFloat?
    /// True when content is wider than the window even with minimal margins.
    let overflows: Bool
    /// Width the text view itself should take when overflowing.
    ///
    /// Asymmetric on purpose: the leading margin keeps the prose centred at rest, and the
    /// trailing side needs only an ordinary gutter after the widest table.
    let documentWidth: CGFloat

    /// - Parameters:
    ///   - frameWidth: the scroll view's content width.
    ///   - contentWidth: the theme's preferred measure.
    ///   - widestTable: widest table in the document, or 0.
    init(frameWidth: CGFloat, contentWidth: CGFloat, widestTable: CGFloat) {
        // The scroll view has no size until it has been laid out, and the first styling pass can
        // run before that. Treat it as unknown rather than computing a nonsense inset.
        guard frameWidth > 0 else {
            containerWidth = max(frameWidth - Self.gutter * 2, Self.minimumMeasure)
            horizontalInset = Self.gutter
            wrapWidth = nil
            overflows = false
            documentWidth = containerWidth + Self.gutter * 2
            return
        }

        let available = max(frameWidth - Self.gutter * 2, Self.minimumMeasure)
        let measure = min(contentWidth, available)

        if widestTable > available + 1 {
            // Wider than the window itself: give the table its natural width and scroll to
            // reach it. The margin stays centred on the *measure* rather than collapsing to the
            // gutter, so the prose keeps its position and only the table extends past it.
            containerWidth = max(widestTable, available)
            horizontalInset = max(((frameWidth - measure) / 2).rounded(), Self.gutter)
            overflows = true
        } else {
            // Wider than the column but not the window: let it eat into the centring margin,
            // which is what keeps today's behaviour for tables that never needed a scroller.
            containerWidth = min(max(measure, widestTable), available)
            horizontalInset = max(((frameWidth - containerWidth) / 2).rounded(), Self.gutter)
            overflows = false
        }

        wrapWidth = containerWidth > measure ? measure : nil
        documentWidth = overflows
            ? horizontalInset + containerWidth + Self.gutter
            : containerWidth + horizontalInset * 2
    }
}
