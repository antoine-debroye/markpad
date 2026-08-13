import Foundation

/// A styled description of a Markdown source string, expressed entirely as ranges into that
/// source. Nothing here knows about AppKit — the editor maps these runs onto text attributes
/// and custom drawing.
public struct MarkdownLayout: Sendable, Equatable {
    public var blocks: [BlockRun]
    public var inlines: [InlineRun]
    public var markers: [Marker]
    public var tables: [TableStructure]
    public var images: [ImagePlacement]
    /// Coloured spans inside fenced code blocks.
    public var code: [SyntaxHighlighter.Span]

    public init(
        blocks: [BlockRun] = [],
        inlines: [InlineRun] = [],
        markers: [Marker] = [],
        tables: [TableStructure] = [],
        images: [ImagePlacement] = [],
        code: [SyntaxHighlighter.Span] = []
    ) {
        self.blocks = blocks
        self.inlines = inlines
        self.markers = markers
        self.tables = tables
        self.images = images
        self.code = code
    }

    /// True when the caret sits inside `range`, meaning its raw source should be shown.
    public func isActive(_ range: NSRange, selection: NSRange) -> Bool {
        activeBlockRanges(for: selection).contains { NSIntersectionRange($0, range).length > 0 }
    }

    /// Leaf blocks intersecting `selection` — the blocks whose raw syntax should be revealed
    /// because the caret is inside them.
    public func activeBlockRanges(for selection: NSRange) -> [NSRange] {
        blocks.compactMap { block in
            guard block.intersects(selection) else { return nil }
            return block.range
        }
    }

    /// Markers that should be concealed given the current selection.
    public func concealedMarkers(selection: NSRange) -> [Marker] {
        let active = activeBlockRanges(for: selection)
        return markers.filter { marker in
            guard marker.presentation.isConcealable else { return false }
            return !active.contains { NSIntersectionRange($0, marker.range).length > 0
                || NSLocationInRange(marker.range.location, $0) }
        }
    }
}

public struct BlockRun: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case paragraph
        case heading(level: Int)
        case codeBlock(language: String?)
        case thematicBreak
        case table
        case html
    }

    public var range: NSRange
    public var kind: Kind
    /// Blockquote nesting, 0 when not quoted.
    public var quoteDepth: Int
    /// List nesting, 0 when not in a list.
    public var listDepth: Int
    /// True for the first block of a list item, which carries the marker.
    public var isListItemStart: Bool

    public init(
        range: NSRange,
        kind: Kind,
        quoteDepth: Int = 0,
        listDepth: Int = 0,
        isListItemStart: Bool = false
    ) {
        self.range = range
        self.kind = kind
        self.quoteDepth = quoteDepth
        self.listDepth = listDepth
        self.isListItemStart = isListItemStart
    }

    /// A caret sitting at either edge of the block counts as inside it.
    func intersects(_ selection: NSRange) -> Bool {
        let blockEnd = range.location + range.length
        let selectionEnd = selection.location + selection.length
        return selection.location <= blockEnd && selectionEnd >= range.location
    }
}

public struct InlineTraits: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let bold = InlineTraits(rawValue: 1 << 0)
    public static let italic = InlineTraits(rawValue: 1 << 1)
    public static let strikethrough = InlineTraits(rawValue: 1 << 2)
    public static let code = InlineTraits(rawValue: 1 << 3)
    public static let link = InlineTraits(rawValue: 1 << 4)
}

public struct InlineRun: Sendable, Equatable {
    public var range: NSRange
    public var traits: InlineTraits
    public var link: String?

    public init(range: NSRange, traits: InlineTraits, link: String? = nil) {
        self.range = range
        self.traits = traits
        self.link = link
    }
}

extension InlineTraits: Equatable {}

/// A run of Markdown syntax that is presented differently from the text it decorates.
public struct Marker: Sendable, Equatable {
    public enum Presentation: Sendable, Equatable {
        /// Collapsed to zero width when the block is not being edited.
        case hidden
        /// Keeps its width; the editor paints a bullet over it.
        case bullet
        /// Keeps its width; the editor paints a checkbox over it.
        case checkbox(checked: Bool)
        /// Always visible, drawn in the secondary colour.
        case dimmed

        /// Whether this marker disappears when its block is inactive.
        var isConcealable: Bool { self == .hidden }
    }

    public var range: NSRange
    public var presentation: Presentation

    public init(range: NSRange, presentation: Presentation) {
        self.range = range
        self.presentation = presentation
    }
}

/// Where an image should be drawn, and what it refers to.
public struct ImagePlacement: Sendable, Equatable {
    public var range: NSRange
    public var source: String
    public var alt: String

    public init(range: NSRange, source: String, alt: String) {
        self.range = range
        self.source = source
        self.alt = alt
    }
}
