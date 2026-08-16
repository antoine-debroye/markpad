import MarkpadCore
import SwiftUI

@main
struct MarkpadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(AppearanceMode.storageKey) private var appearance = AppearanceMode.automatic.rawValue
    // Held for the life of the app: Sparkle's scheduled checks stop when the updater goes away.
    @StateObject private var updater = Updater()

    var body: some Scene {
        DocumentGroup(newDocument: { MarkdownDocument() }) { configuration in
            DocumentWindow(document: configuration.document, fileURL: configuration.fileURL)
                .onAppear { (AppearanceMode(rawValue: appearance) ?? .automatic).apply() }
        }
        .defaultSize(width: 920, height: 720)
        .commands {
            MarkpadCommands()
            UpdateCommands(updater: updater)
        }

        Settings {
            SettingsView(updater: updater)
        }
    }
}

/// Applies the stored appearance before the first window appears, so the app never flashes
/// the wrong theme at launch.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        AppearanceMode.current.apply()
    }

    /// Drives Dock-drop conversions. Held here because a drop can arrive before any document
    /// window exists, so there is no window-owned session to use.
    private let dropSession = ImportSession()

    func application(_ application: NSApplication, open urls: [URL]) {
        // PDFs and images dropped on the Dock icon are converted rather than opened.
        var toConvert: [URL] = []
        for url in urls {
            switch ConversionInput.detect(for: url) {
            case .pdf, .image:
                toConvert.append(url)
            default:
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                    if let error { NSApp.presentError(error) }
                }
            }
        }
        guard !toConvert.isEmpty else { return }
        convert(toConvert)
    }

    /// Converts dropped files one after another, behind a single progress panel.
    ///
    /// A sheet is not an option here: there may be no window yet, and an `NSApplicationDelegate`
    /// cannot present one regardless.
    private func convert(_ urls: [URL]) {
        ImportPanel.present(session: dropSession)
        dropSession.begin(urls: urls) { message in
            let alert = NSAlert()
            alert.messageText = "Import failed"
            alert.informativeText = message
            alert.runModal()
        }
        // The session clears itself when the queue drains or the user cancels.
        Task { @MainActor in
            while dropSession.isRunning { try? await Task.sleep(for: .milliseconds(120)) }
            ImportPanel.dismiss()
        }
    }
}

/// "Check for Updates…" in the application menu, where macOS users look for it. Updates also
/// install on their own in the background; this is for the person who wants to ask.
struct UpdateCommands: Commands {
    @ObservedObject var updater: Updater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
    }
}

/// File menu additions: exports, import, and the editing shortcuts the editor supports.
struct MarkpadCommands: Commands {
    @FocusedValue(\.markdownDocument) private var focused
    @FocusedValue(\.recentsPresentation) private var recentsPresentation

    var body: some Commands {
        // Beside the system's own Open Recent submenu.
        CommandGroup(after: .newItem) {
            Button("Recents") { recentsPresentation?.wrappedValue.toggle() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(recentsPresentation == nil)
        }

        CommandGroup(after: .saveItem) {
            Menu("Export") {
                ForEach([ConversionFormat.word, .html, .plainText], id: \.rawValue) { format in
                    Button("\(format.displayName)…") {
                        guard let focused else { return }
                        DocumentActions.export(
                            markdown: focused.document.text,
                            to: format,
                            baseName: focused.fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled",
                            resourceDirectory: focused.fileURL?.deletingLastPathComponent(),
                            onError: { message in
                                let alert = NSAlert()
                                alert.messageText = "Export failed"
                                alert.informativeText = message
                                alert.runModal()
                            }
                        )
                    }
                }
            }
            .disabled(focused == nil)

            Button("Import PDF or Image…") {
                guard let focused else { return }
                DocumentActions.importFile(into: focused.importSession, onError: { message in
                    let alert = NSAlert()
                    alert.messageText = "Import failed"
                    alert.informativeText = message
                    alert.runModal()
                })
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(focused == nil)
        }

        CommandMenu("Format") {
            Button("Bold") { sendFormatting(.bold) }
                .keyboardShortcut("b", modifiers: .command)
            Button("Italic") { sendFormatting(.italic) }
                .keyboardShortcut("i", modifiers: .command)
            Button("Inline Code") { sendFormatting(.code) }
                .keyboardShortcut("e", modifiers: .command)
            Divider()
            Button("Link") { sendFormatting(.link) }
                .keyboardShortcut("k", modifiers: .command)
        }
    }

    private func sendFormatting(_ action: FormattingAction) {
        NotificationCenter.default.post(name: .markpadFormatting, object: action)
    }
}

enum FormattingAction {
    case bold
    case italic
    case code
    case link

    var wrapper: String? {
        switch self {
        case .bold: return "**"
        case .italic: return "*"
        case .code: return "`"
        case .link: return nil
        }
    }
}

extension Notification.Name {
    static let markpadFormatting = Notification.Name("markpad.formatting")
}

/// Lets the File menu reach the document in the frontmost window.
struct FocusedDocument {
    let document: MarkdownDocument
    let fileURL: URL?
    /// The front window's import, so ⇧⌘I drives the same sheet the toolbar does.
    let importSession: ImportSession
}

private struct MarkdownDocumentFocusedValueKey: FocusedValueKey {
    typealias Value = FocusedDocument
}

/// Lets ⌘⇧R open the front window's Recents popover. A `Commands` struct cannot present one
/// itself, but it can flip the binding the window's popover is attached to.
private struct RecentsPresentationKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    var markdownDocument: FocusedDocument? {
        get { self[MarkdownDocumentFocusedValueKey.self] }
        set { self[MarkdownDocumentFocusedValueKey.self] = newValue }
    }

    var recentsPresentation: Binding<Bool>? {
        get { self[RecentsPresentationKey.self] }
        set { self[RecentsPresentationKey.self] = newValue }
    }
}
