import SwiftUI

struct ChatConfigurationView: View {
    @Environment(\.colorScheme) private var colorScheme
    private var palette: EchoTheme.Palette { EchoTheme.palette(for: colorScheme) }
    @State private var key = ""
    @State private var keyLoaded = false
    @State private var status: String?
    @State private var prompt = ""
    @State private var promptLoaded = false

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
                Text(L10n.text("chat.systemPrompt"))
                Spacer()
                Button(L10n.text("chat.restorePrompt")) {
                    do { prompt = try ChatPrompt.defaultText(); promptLoaded = true; status = nil }
                    catch { status = "chat.promptInvalid" }
                }.controlSize(.small)
            }
            TextEditor(text: $prompt)
                .font(.system(size: 12))
                .frame(height: 160)
                .padding(5)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.controlBorder, lineWidth: 1))
                .accessibilityLabel(L10n.text("chat.systemPrompt"))
                .disabled(!promptLoaded)
            Text(L10n.text("chat.promptNote"))
                .font(.caption).foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
            if let status { Text(L10n.text(status)).font(.caption).foregroundStyle(palette.textSecondary) }
            Spacer(minLength: 8)
            Button(L10n.text("chat.save")) {
                do {
                    try ChatPrompt.validate(prompt)
                    _ = try ChatPrompt.defaultText()
                    try ChatSettings.saveKey(key.trimmingCharacters(in: .whitespacesAndNewlines))
                    try ChatPrompt().save(prompt)
                    status = "chat.saved"
                } catch { status = (error as? ChatFailure)?.key ?? "chat.keychainError" }
            }.disabled(!keyLoaded || !promptLoaded).buttonStyle(.bordered).controlSize(.small)
            }
        }
        .textFieldStyle(.roundedBorder)
        .onAppear {
            do { prompt = try ChatPrompt().effectiveText(); promptLoaded = true }
            catch { status = "chat.promptInvalid" }
            do {
                key = try ChatSettings.readKey()
                keyLoaded = true
            }
            catch { status = "chat.keychainError" }
        }
    }
}
