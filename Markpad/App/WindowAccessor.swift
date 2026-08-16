import AppKit
import SwiftUI

/// Hands the enclosing `NSWindow` to SwiftUI.
///
/// `DocumentGroup` gives no access to the window it creates, but tab grouping and per-window
/// toasts both need one. This adds an invisible probe view purely to read `window` from it.
struct WindowAccessor: NSViewRepresentable {
    let onChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let probe = Probe()
        probe.onChange = onChange
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? Probe)?.onChange = onChange
    }

    private final class Probe: NSView {
        var onChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let captured = window
            // One runloop turn before reporting. At this point the window has not finished being
            // configured or ordered front, and setting `tabbingMode` or calling
            // `addTabbedWindow` here can pull it straight back out of the group AppKit is about
            // to place it in.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window === captured else { return }
                self.onChange?(captured)
            }
        }
    }
}

extension View {
    /// Calls `perform` with the window this view ends up in.
    func onWindow(_ perform: @escaping (NSWindow?) -> Void) -> some View {
        background(WindowAccessor(onChange: perform).frame(width: 0, height: 0))
    }
}
