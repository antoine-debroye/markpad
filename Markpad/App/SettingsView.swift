import SwiftUI

struct SettingsView: View {
    @AppStorage(AppearanceMode.storageKey) private var appearance = AppearanceMode.automatic.rawValue

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
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 260)
    }
}
