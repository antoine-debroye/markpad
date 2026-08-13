import AppKit
import SwiftUI

/// The user's appearance preference. "Automatic" leaves the app following the system.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case automatic
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var symbolName: String {
        switch self {
        case .automatic: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .automatic: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// Applies the preference process-wide. A nil appearance hands control back to macOS.
    func apply() {
        NSApp?.appearance = nsAppearance
    }

    static let storageKey = "appearanceMode"

    static var current: AppearanceMode {
        UserDefaults.standard.string(forKey: storageKey)
            .flatMap(AppearanceMode.init(rawValue:)) ?? .automatic
    }
}
