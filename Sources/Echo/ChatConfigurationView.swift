import SwiftUI

struct ChatConfigurationView: View {
    @Environment(\.colorScheme) private var colorScheme
    private var palette: EchoTheme.Palette { EchoTheme.palette(for: colorScheme) }
    @State private var key = ""
    @State private var keyLoaded = false
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsRow(title: L10n.text("chat.endpointLabel")) {
                Text(ChatSettings.endpoint).foregroundStyle(palette.textSecondary)
            }
            SettingsRow(title: L10n.text("chat.model")) {
                Text(ChatSettings.model).foregroundStyle(palette.textSecondary)
            }
            SettingsRow(title: "API Key") {
                TextField("API Key", text: $key).frame(width: 290)
            }
            Text(L10n.text("chat.configurationNote"))
                .font(.caption).foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.text("chat.searchNote"))
                .font(.caption).foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
            if let status { Text(L10n.text(status)).font(.caption).foregroundStyle(palette.textSecondary) }
            Spacer(minLength: 8)
            Button(L10n.text("chat.save")) {
                do {
                    try ChatSettings.saveKey(key.trimmingCharacters(in: .whitespacesAndNewlines))
                    status = "chat.saved"
                } catch { status = (error as? ChatFailure)?.key ?? "chat.keychainError" }
            }.disabled(!keyLoaded).buttonStyle(.bordered).controlSize(.small)
            }
        }
        .textFieldStyle(.roundedBorder)
        .onAppear {
            do {
                key = try ChatSettings.readKey()
                keyLoaded = true
            }
            catch { status = "chat.keychainError" }
        }
    }
}
