import AppKit
import MarkpadCore
import SwiftUI

/// The confirmation pill: dark, centred at the bottom of the document.
private struct ToastPill: View {
    let message: String

    // Deliberately dark in both appearances, so the colours come from the dark palette directly
    // rather than through `EditorTheme`, whose accessors resolve against the current appearance
    // and would render this light in Light mode.
    private static let palette = MarkdownTheme.default.dark

    var body: some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(Color(nsColor: NSColor(hex: Self.palette.text) ?? .white))
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(Color(nsColor: NSColor(hex: Self.palette.codeBackground) ?? .darkGray))
            )
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            // Never eat a click meant for the editor underneath.
            .allowsHitTesting(false)
    }
}

private struct ToastOverlay: ViewModifier {
    let window: NSWindow?
    @ObservedObject private var center = ToastCenter.shared

    func body(content: Content) -> some View {
        let toast = center.toast(for: window)
        content
            .overlay(alignment: .bottom) {
                if let toast {
                    ToastPill(message: toast.message)
                        .padding(.bottom, 18)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        .id(toast.id)
                }
            }
            .animation(.spring(duration: 0.28), value: toast?.id)
    }
}

extension View {
    /// Shows this window's confirmations along the bottom edge.
    func toastOverlay(window: NSWindow?) -> some View {
        modifier(ToastOverlay(window: window))
    }
}
