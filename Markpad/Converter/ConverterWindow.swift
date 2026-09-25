import SwiftUI

/// The Convert to Markdown window. One of it, opened from File ▸ Convert Files to Markdown…
/// or the toolbar's Export menu.
struct ConverterWindow: Scene {
    static let id = "converter"

    var body: some Scene {
        Window("Convert to Markdown", id: Self.id) {
            ConverterView()
        }
        .defaultSize(width: 640, height: 600)
        .windowResizability(.contentMinSize)
    }
}
