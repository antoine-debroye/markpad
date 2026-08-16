import Combine
import Sparkle
import SwiftUI

/// Owns the Sparkle updater and exposes the two things the interface needs: whether a check
/// can be started right now, and whether background checking is on.
///
/// Updates are configured in `project.yml` rather than here — the feed URL, the public key and
/// the automatic-install behaviour are all Info.plist keys that Sparkle reads for itself. This
/// type exists so the menu item and the settings toggle have something to bind to.
///
/// Sparkle decides whether a release is newer by comparing `CFBundleVersion`, which is why the
/// build number has to keep rising; see scripts/version.sh.
@MainActor
final class Updater: ObservableObject {
    /// False while a check is already running, and whenever updating is unavailable — an
    /// unsigned build, or no public key configured. The menu item follows it so the command
    /// is greyed out rather than failing silently when clicked.
    @Published private(set) var canCheckForUpdates = false

    /// Mirrors Sparkle's own preference, which it persists itself.
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            controller.updater.automaticallyChecksForUpdates = newValue
            objectWillChange.send()
        }
    }

    private let controller: SPUStandardUpdaterController

    init() {
        // startingUpdater: true begins the scheduled background checks. Sparkle spaces the
        // first one out from launch on its own, so this does not cost anything at startup.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    /// Shows the update window, checking in the foreground with progress and errors visible.
    /// This is the manual path; background checks stay silent.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
