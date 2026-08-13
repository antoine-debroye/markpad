import AppKit
import MarkpadCore

/// Bridges `MarkdownTheme`'s palette tokens to AppKit.
///
/// Colours resolve per appearance through `NSColor(name:dynamicProvider:)`, so the editor
/// follows Light/Dark/Automatic without rebuilding any attributes.
struct EditorTheme {
    let tokens: MarkdownTheme

    init(tokens: MarkdownTheme = .default) {
        self.tokens = tokens
    }

    // MARK: Colours

    private func dynamic(_ keyPath: KeyPath<MarkdownTheme.Palette, String>, _ name: String) -> NSColor {
        let light = NSColor(hex: tokens.light[keyPath: keyPath]) ?? .textColor
        let dark = NSColor(hex: tokens.dark[keyPath: keyPath]) ?? .textColor
        return NSColor(name: NSColor.Name("markpad.\(name)")) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    var background: NSColor { dynamic(\.background, "background") }
    var text: NSColor { dynamic(\.text, "text") }
    var secondaryText: NSColor { dynamic(\.secondaryText, "secondaryText") }
    var heading: NSColor { dynamic(\.heading, "heading") }
    var link: NSColor { dynamic(\.link, "link") }
    var codeText: NSColor { dynamic(\.codeText, "codeText") }
    var codeBackground: NSColor { dynamic(\.codeBackground, "codeBackground") }
    var quoteBar: NSColor { dynamic(\.quoteBar, "quoteBar") }
    var quoteText: NSColor { dynamic(\.quoteText, "quoteText") }
    var rule: NSColor { dynamic(\.rule, "rule") }
    var tableBorder: NSColor { dynamic(\.tableBorder, "tableBorder") }
    var syntaxMarker: NSColor { dynamic(\.syntaxMarker, "syntaxMarker") }

    // MARK: Metrics

    var baseFontSize: CGFloat { CGFloat(tokens.baseFontSize) }
    var lineHeightMultiple: CGFloat { CGFloat(tokens.lineHeight) / 1.28 }
    var contentWidth: CGFloat { CGFloat(tokens.contentWidth) }
    /// Kept small on purpose: the blank lines between Markdown blocks are real lines in the
    /// source and already supply most of the vertical rhythm.
    var paragraphSpacing: CGFloat { baseFontSize * 0.15 }
    /// Width of one list indentation step.
    var indentStep: CGFloat { baseFontSize * 1.6 }

    // MARK: Fonts

    var bodyFont: NSFont {
        .systemFont(ofSize: baseFontSize)
    }

    func headingFont(level: Int) -> NSFont {
        let size = CGFloat(tokens.fontSize(forHeadingLevel: level))
        let weight: NSFont.Weight = level <= 2 ? .bold : .semibold
        return .systemFont(ofSize: size, weight: weight)
    }

    var monospaceFont: NSFont {
        .monospacedSystemFont(ofSize: baseFontSize * 0.92, weight: .regular)
    }

    /// Applies bold/italic traits without losing the font's size or design.
    func applying(traits: InlineTraits, to font: NSFont) -> NSFont {
        var symbolic: NSFontDescriptor.SymbolicTraits = []
        if traits.contains(.bold) { symbolic.insert(.bold) }
        if traits.contains(.italic) { symbolic.insert(.italic) }
        guard !symbolic.isEmpty else { return font }

        let descriptor = font.fontDescriptor.withSymbolicTraits(symbolic)
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }
}

extension NSColor {
    /// Parses `#rrggbb` / `#rrggbbaa`, the form theme tokens are stored in.
    convenience init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6 || value.count == 8, let number = UInt32(value, radix: 16) else {
            return nil
        }

        let hasAlpha = value.count == 8
        let red = CGFloat((number >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let green = CGFloat((number >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let blue = CGFloat((number >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let alpha = hasAlpha ? CGFloat(number & 0xFF) / 255 : 1
        self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
