import AppKit
import SwiftUI

/// Window-level setup for the app's own header.
///
/// The header is built as a unified toolbar rather than drawn into the content view. Drawing it
/// in the content does not work: the title bar is a sibling view that macOS paints *above* the
/// content, so a band underneath it comes out washed-out and clipped along its top edge however
/// transparent the title bar claims to be. A unified toolbar is the same 50pt band with the
/// traffic lights inline, and macOS composites it correctly.
enum WindowChrome {
    @MainActor
    static func apply(to window: NSWindow) {
        // The header shows the file name itself.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        clearProxyIcon(on: window)
    }

    /// Removes the document proxy icon and its path chevron.
    ///
    /// Hiding the title leaves both behind, and they sit exactly where the design puts the
    /// outline toggle. Clearing the represented URL takes the chevron with it; the cost is the
    /// proxy drag and the ⌘-click path menu.
    ///
    /// Called again whenever the document's URL changes, because the document machinery sets it
    /// back each time.
    @MainActor
    static func clearProxyIcon(on window: NSWindow) {
        window.representedURL = nil
        window.standardWindowButton(.documentIconButton)?.isHidden = true
    }
}
