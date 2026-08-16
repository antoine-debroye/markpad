import AppKit
import MarkpadCore
import SwiftUI

/// Colours for the window chrome.
///
/// Most come straight from `MarkdownTheme`: the control borders are the quote-bar grey, the
/// band's rule is the document rule, and the dark chrome's fills are the dark code background.
/// Only the band gradient and the control fill are specific to the chrome.
struct ChromePalette {
    let isDark: Bool

    private var tokens: MarkdownTheme.Palette {
        isDark ? MarkdownTheme.default.dark : MarkdownTheme.default.light
    }

    private func color(_ hex: String) -> Color {
        Color(nsColor: NSColor(hex: hex) ?? .textColor)
    }

    /// The light chrome's 50pt band, top to bottom.
    var bandTop: Color { color("#f7f7f8") }
    var bandBottom: Color { color("#f0f0f2") }
    /// Fill behind a pressed or active control.
    var controlActive: Color { isDark ? color("#3a3a3c") : color("#e6e6ea") }

    /// Behind the header. Light is the design's gradient band; dark is flat, since that design
    /// has no band and the controls simply sit on the window's own colour.
    var toolbarBackground: AnyShapeStyle {
        isDark
            ? AnyShapeStyle(background)
            : AnyShapeStyle(LinearGradient(colors: [bandTop, bandBottom], startPoint: .top, endPoint: .bottom))
    }

    var rule: Color { color(tokens.rule) }
    var controlBorder: Color { isDark ? color(tokens.rule) : color(tokens.quoteBar) }
    var controlFill: Color { isDark ? color(tokens.codeBackground) : color(tokens.background) }
    var controlText: Color { color(tokens.text) }
    var title: Color { isDark ? color(tokens.secondaryText) : color(tokens.text) }
    var secondary: Color { color(tokens.secondaryText) }
    var background: Color { color(tokens.background) }
}

extension View {
    /// Drops SwiftUI's own toolbar title.
    ///
    /// The header draws the file name itself, centred with the word count beneath it; without
    /// this the name appears twice. `toolbar(removing:)` needs macOS 15, so older systems fall
    /// back to clearing the navigation title.
    @ViewBuilder
    func withoutToolbarTitle() -> some View {
        if #available(macOS 15.0, *) {
            toolbar(removing: .title)
        } else {
            navigationTitle("")
        }
    }
}

/// The mini-sidebar glyph the design uses for the outline toggle, rather than an SF Symbol.
struct OutlineGlyph: View {
    let palette: ChromePalette
    let isOn: Bool

    var body: some View {
        ZStack {
            // Filled left column, hairline divider, empty pane — clipped as one shape so the
            // rounded corners cut all three together.
            HStack(spacing: 0) {
                Rectangle().fill(palette.controlActive).frame(width: 9)
                Rectangle().fill(palette.controlBorder).frame(width: 1)
                Rectangle().fill(isOn ? palette.controlFill : palette.controlFill.opacity(0.4))
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))

            RoundedRectangle(cornerRadius: 6).stroke(palette.controlBorder, lineWidth: 1)
        }
        .frame(width: 26, height: 22)
        .contentShape(Rectangle())
    }
}

/// A bordered pill, the shape both designs use for chrome actions.
struct ChromePill<Content: View>: View {
    let palette: ChromePalette
    var height: CGFloat = 22
    var isActive: Bool = false
    @ViewBuilder var content: Content

    @State private var isHovered = false

    var body: some View {
        content
            .padding(.horizontal, 9)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive || isHovered ? palette.controlActive : palette.controlFill)
            )
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.controlBorder, lineWidth: 1))
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}

/// The dark design's floating word count and reading estimate.
struct StatusPill: View {
    let status: EditorStatus
    let palette: ChromePalette

    var body: some View {
        Text(status.readingDescription)
            .font(.system(size: 11.5))
            .foregroundStyle(palette.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(palette.controlFill.opacity(0.85))
                    .overlay(Capsule().stroke(palette.controlBorder, lineWidth: 1))
            )
            .padding(.trailing, 18)
            .padding(.bottom, 16)
            .allowsHitTesting(false)
    }
}
