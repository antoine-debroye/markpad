import AppKit

/// Keeps each document in its own window.
///
/// Native tab grouping and the app's own header cannot coexist: AppKit draws the tab bar
/// directly beneath the title bar, which is the space the header band occupies, and the bar
/// cannot be hidden while more than one tab is open — `Show Tab Bar` is disabled in that case
/// and `isTabBarVisible` is read-only. The result was a system tab bar cutting across the
/// header.
///
/// The designs are all drawn as single windows, so this follows them: windows never merge, and
/// the header stays intact. Documents are still reachable through Window ▸ the open document
/// list, and through the Recents panel.
enum WindowTabbing {
    @MainActor
    static func adopt(_ window: NSWindow) {
        guard !(window is NSPanel), window.styleMask.contains(.titled) else { return }
        window.tabbingMode = .disallowed

        // Disallowing tabs stops new windows joining a group, but does not break up one that
        // already exists — and macOS restores the window state of an earlier build, so anyone
        // upgrading would still see a system tab bar over the header until they closed the
        // windows. Split any restored group back into separate windows.
        guard let group = window.tabGroup, group.windows.count > 1 else { return }
        DispatchQueue.main.async {
            guard window.tabGroup?.windows.count ?? 0 > 1 else { return }
            window.moveTabToNewWindow(nil)
        }
    }
}
