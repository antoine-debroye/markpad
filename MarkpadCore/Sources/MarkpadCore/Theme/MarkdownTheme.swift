import Foundation

/// Semantic colour and typography tokens shared by the editor, HTML export and Quick Look.
///
/// Colours are stored as sRGB hex strings so the same token table can drive both AppKit
/// (`NSColor`) and CSS without a second source of truth.
public struct MarkdownTheme: Sendable, Equatable {
    public struct Palette: Sendable, Equatable {
        public var background: String
        public var text: String
        public var secondaryText: String
        public var heading: String
        public var link: String
        public var codeText: String
        public var codeBackground: String
        public var quoteBar: String
        public var quoteText: String
        public var rule: String
        public var tableBorder: String
        public var tableHeaderBackground: String
        public var syntaxMarker: String
        public var selection: String
        /// Code token colours.
        public var codeKeyword: String
        public var codeString: String
        public var codeComment: String
        public var codeNumber: String
        public var codeType: String

        public init(
            background: String,
            text: String,
            secondaryText: String,
            heading: String,
            link: String,
            codeText: String,
            codeBackground: String,
            quoteBar: String,
            quoteText: String,
            rule: String,
            tableBorder: String,
            tableHeaderBackground: String,
            syntaxMarker: String,
            selection: String,
            codeKeyword: String,
            codeString: String,
            codeComment: String,
            codeNumber: String,
            codeType: String
        ) {
            self.background = background
            self.text = text
            self.secondaryText = secondaryText
            self.heading = heading
            self.link = link
            self.codeText = codeText
            self.codeBackground = codeBackground
            self.quoteBar = quoteBar
            self.quoteText = quoteText
            self.rule = rule
            self.tableBorder = tableBorder
            self.tableHeaderBackground = tableHeaderBackground
            self.syntaxMarker = syntaxMarker
            self.selection = selection
            self.codeKeyword = codeKeyword
            self.codeString = codeString
            self.codeComment = codeComment
            self.codeNumber = codeNumber
            self.codeType = codeType
        }
    }

    public var light: Palette
    public var dark: Palette

    /// Base body size in points. Heading sizes are derived from this by `headingScale`.
    public var baseFontSize: Double
    /// Multipliers for heading levels 1...6.
    public var headingScale: [Double]
    public var bodyFontFamily: String
    public var monospaceFontFamily: String
    public var lineHeight: Double
    /// Maximum measure for rendered documents, in points.
    public var contentWidth: Double

    public init(
        light: Palette,
        dark: Palette,
        baseFontSize: Double = 16,
        headingScale: [Double] = [1.9, 1.55, 1.3, 1.15, 1.0, 0.92],
        bodyFontFamily: String = "-apple-system, BlinkMacSystemFont, \"SF Pro Text\", \"Helvetica Neue\", sans-serif",
        monospaceFontFamily: String = "ui-monospace, \"SF Mono\", Menlo, monospace",
        lineHeight: Double = 1.62,
        contentWidth: Double = 620
    ) {
        self.light = light
        self.dark = dark
        self.baseFontSize = baseFontSize
        self.headingScale = headingScale
        self.bodyFontFamily = bodyFontFamily
        self.monospaceFontFamily = monospaceFontFamily
        self.lineHeight = lineHeight
        self.contentWidth = contentWidth
    }

    /// Point size for a heading level (1...6), clamped to the available scale.
    public func fontSize(forHeadingLevel level: Int) -> Double {
        let index = min(max(level, 1), headingScale.count) - 1
        return baseFontSize * headingScale[index]
    }

    public static let `default` = MarkdownTheme(
        light: Palette(
            background: "#ffffff",
            text: "#1d1d1f",
            secondaryText: "#6e6e73",
            heading: "#000000",
            link: "#0066cc",
            codeText: "#b02a37",
            codeBackground: "#f2f2f5",
            quoteBar: "#d2d2d7",
            quoteText: "#4a4a4f",
            rule: "#e0e0e5",
            tableBorder: "#dcdce1",
            tableHeaderBackground: "#f7f7f9",
            syntaxMarker: "#b8b8bf",
            selection: "#b3d7ff",
            codeKeyword: "#9b2393",
            codeString: "#c41a16",
            codeComment: "#707f8c",
            codeNumber: "#1c00cf",
            codeType: "#0b4f79"
        ),
        dark: Palette(
            background: "#1c1c1e",
            text: "#e8e8ed",
            secondaryText: "#9a9aa0",
            heading: "#ffffff",
            link: "#5aa9ff",
            codeText: "#ff9d9d",
            codeBackground: "#2c2c2e",
            quoteBar: "#48484a",
            quoteText: "#c0c0c6",
            rule: "#3a3a3c",
            tableBorder: "#3a3a3c",
            tableHeaderBackground: "#2c2c2e",
            syntaxMarker: "#5c5c61",
            selection: "#2f5d8f",
            codeKeyword: "#ff7ab2",
            codeString: "#ff8170",
            codeComment: "#7f8c98",
            codeNumber: "#d9c97c",
            codeType: "#6bdfff"
        )
    )
}
