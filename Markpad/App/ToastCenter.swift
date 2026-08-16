import AppKit
import MarkpadCore
import SwiftUI

/// A brief confirmation shown over a document window.
struct Toast: Identifiable, Equatable {
    /// A fresh id per message, so replacing one re-runs the appearance transition.
    let id = UUID()
    let message: String
    /// The window the toast belongs to, so a background window does not show it.
    let target: ObjectIdentifier?
}

/// Shows short confirmations — "Exported Notes.docx" — and takes them away again.
///
/// A singleton rather than per-window state because `DocumentActions` is a plain enum of static
/// functions with no view context, and the Dock-drop path has no window to route a closure to.
/// Which window a toast belongs to is carried on the toast instead.
@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    /// Matches the prototype.
    static let duration: Duration = .milliseconds(2600)

    @Published private(set) var toast: Toast?

    private var dismissal: Task<Void, Never>?

    private init() {}

    /// Shows `message`, replacing anything already on screen.
    ///
    /// Cancelling the pending dismissal before starting a new one is the whole of "replaces an
    /// in-flight toast": without it the first toast's timer would cut the second one short.
    func show(_ message: String, in window: NSWindow? = NSApp.keyWindow) {
        dismissal?.cancel()
        toast = Toast(message: message, target: window.map(ObjectIdentifier.init))

        // The pill is not interactive, so VoiceOver would otherwise never mention it.
        if let window {
            NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ])
        }

        dismissal = Task { [weak self] in
            try? await Task.sleep(for: Self.duration)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func dismiss() {
        dismissal?.cancel()
        toast = nil
    }

    /// Whether the current toast should be drawn in `window`.
    func toast(for window: NSWindow?) -> Toast? {
        guard let toast else { return nil }
        guard let target = toast.target else { return toast }
        guard let window else { return nil }
        return ObjectIdentifier(window) == target ? toast : nil
    }
}
