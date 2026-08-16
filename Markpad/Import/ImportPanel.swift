import AppKit
import SwiftUI

/// Shows import progress when there is no document window to put a sheet on.
///
/// Files dropped on the Dock icon can arrive before any window exists, and neither an
/// `NSApplicationDelegate` nor a `Commands` struct can present a sheet. This hosts the same view
/// the sheet uses, so there is only one progress UI in the app.
@MainActor
final class ImportPanel {
    private let panel: NSPanel
    /// Held so the panel is not deallocated the moment it goes out of scope at the call site.
    private static var presented: ImportPanel?

    private init(session: ImportSession) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 260),
            styleMask: [.titled, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Import"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.contentViewController = NSHostingController(rootView: ImportProgressSheet(session: session))
        panel.center()
    }

    static func present(session: ImportSession) {
        presented?.close()
        let panel = ImportPanel(session: session)
        panel.panel.makeKeyAndOrderFront(nil)
        presented = panel
    }

    static func dismiss() {
        presented?.close()
        presented = nil
    }

    private func close() {
        panel.orderOut(nil)
    }
}
