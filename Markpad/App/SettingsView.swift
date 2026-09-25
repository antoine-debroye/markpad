import SwiftUI

struct SettingsView: View {
    @AppStorage(AppearanceMode.storageKey) private var appearance = AppearanceMode.automatic.rawValue
    @ObservedObject var updater: Updater
    @AppStorage(ConverterModel.includesPicturesKey) private var includesPictures = true

    var body: some View {
        Form {
            Picker(selection: $appearance) {
                ForEach(AppearanceMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbolName).tag(mode.rawValue)
                }
            } label: {
                Text("Appearance")
            }
            .pickerStyle(.inline)
            .onChange(of: appearance) { _, newValue in
                (AppearanceMode(rawValue: newValue) ?? .automatic).apply()
            }

            Text("Automatic follows the system setting. The editor, previews and exported HTML all use the selected appearance.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Converting images", selection: $includesPictures) {
                Text("Picture and its text").tag(true)
                Text("Text only").tag(false)
            }

            Text("With the picture, a photo converts to Markdown showing the image, with any text Markpad recognises in it underneath. The picture is saved in a folder beside the Markdown.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Check for updates automatically", isOn: Binding(
                get: { updater.automaticallyChecksForUpdates },
                set: { updater.automaticallyChecksForUpdates = $0 }
            ))

            Text("Markpad checks once a day and installs updates in the background, applying them the next time it launches. Updates are refused unless they are signed by the same key as this copy.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 470)
    }
}
