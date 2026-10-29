import SwiftUI

struct ChatConfigurationView: View {
    @Environment(\.colorScheme) private var scheme
    @State private var key = ""
    @State private var prompt = ""
    @State private var model = ""
    @State private var savedKey = ""
    @State private var savedPrompt = ""
    @State private var savedModel = ""
    @State private var keyLoaded = false
    @State private var promptLoaded = false
    @State private var revealed = false
    @State private var expanded = false
    @State private var choosingModel = false
    @State private var models: [String] = []
    @State private var loading = false
    @State private var status: String?
    @State private var request: Task<Void, Never>?
    @State private var generation = UUID()
    @FocusState private var keyFocused: Bool
    @FocusState private var promptFocused: Bool

    private var changed: Bool { key != savedKey || prompt != savedPrompt || model != savedModel }
    private var cleanKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            SettingsCard {
                HStack(spacing: 9) {
                    Image(systemName: "arrow.up.right").font(.system(size: 14, weight: .medium))
                        .frame(width: 22, height: 22).background(SettingsStyle.input(scheme), in: RoundedRectangle(cornerRadius: 6))
                    Text("DeepSeek").font(.system(size: 12, weight: .medium))
                    Spacer()
                }.padding(.horizontal, 12).padding(.vertical, 6)
                Divider()
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        Group {
                            if revealed { TextField(L10n.text("settings.keyPlaceholder"), text: $key) }
                            else { SecureField(L10n.text("settings.keyPlaceholder"), text: $key) }
                        }.foregroundStyle(SettingsStyle.ink(scheme)).textFieldStyle(.plain).focused($keyFocused).accessibilityLabel("API Key").disabled(!keyLoaded)
                        Button(L10n.text(revealed ? "settings.hide" : "settings.show")) { revealed.toggle() }
                        Button(L10n.text(loading ? "settings.connecting" : "settings.testConnection")) { fetchModels(test: true) }
                            .disabled(cleanKey.isEmpty || loading || !keyLoaded)
                    }.buttonStyle(.plain).foregroundStyle(SettingsStyle.accent(scheme))
                        .padding(.horizontal, 10).frame(height: 30)
                        .background(SettingsStyle.input(scheme), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(keyFocused ? SettingsStyle.accent(scheme) : .clear, lineWidth: 1.5))
                    Button {
                        choosingModel.toggle()
                        if models.isEmpty { fetchModels(test: false) }
                    } label: {
                        HStack {
                            Text(model.isEmpty ? L10n.text("settings.chooseModel") : model)
                            Spacer()
                            Image(systemName: "chevron.down").font(.system(size: 8))
                        }.foregroundStyle(model.isEmpty ? SettingsStyle.muted(scheme) : SettingsStyle.ink(scheme))
                            .padding(.horizontal, 10).frame(height: 30)
                            .background(SettingsStyle.input(scheme), in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain).disabled(cleanKey.isEmpty || !keyLoaded)
                    .settingsDropdown(isPresented: $choosingModel) {
                        VStack(alignment: .leading, spacing: 2) {
                            if loading { ProgressView().controlSize(.small) }
                            else if models.isEmpty {
                                Text(L10n.text("settings.modelsFailed")).font(.caption)
                                Button(L10n.text("settings.retry")) { fetchModels(test: false) }
                            } else {
                                ForEach(models, id: \.self) { id in
                                    SettingsDropdownOption(title: id, selected: id == model) {
                                        model = id
                                        choosingModel = false
                                    }
                                }
                            }
                        }
                    }
                    Text(L10n.text("settings.modelNotice"))
                        .font(.system(size: 10)).foregroundStyle(SettingsStyle.muted(scheme))
                        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }.padding(.horizontal, 12).padding(.top, 7).padding(.bottom, 9)
            }
            Divider()
            DisclosureGroup(L10n.text("chat.systemPrompt"), isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 0) {
                    TextEditor(text: $prompt).foregroundStyle(SettingsStyle.ink(scheme)).font(.system(size: 12)).scrollContentBackground(.hidden)
                        .focused($promptFocused).frame(height: 96).padding(.horizontal, 8).padding(.top, 7)
                        .disabled(!promptLoaded).accessibilityLabel(L10n.text("chat.systemPrompt"))
                    HStack(spacing: 14) {
                        Button(L10n.text("chat.restorePrompt")) {
                            do { prompt = try ChatPrompt.defaultText(); promptLoaded = true }
                            catch { status = "chat.promptInvalid" }
                        }
                        Button(L10n.text("chat.save"), action: save)
                            .disabled(!changed || !keyLoaded || !promptLoaded)
                    }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(SettingsStyle.accent(scheme))
                        .frame(height: 28).padding(.horizontal, 12).padding(.bottom, 10)
                }.background(SettingsStyle.input(scheme), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(promptFocused ? SettingsStyle.accent(scheme) : .clear, lineWidth: 1.5))
                    .padding(.top, 7)
            }.font(.system(size: 11)).foregroundStyle(SettingsStyle.accent(scheme))
        }
        .onAppear(perform: load)
        .onChange(of: key) { _ in
            request?.cancel(); generation = UUID(); loading = false; models = []; choosingModel = false
            model = key == savedKey ? savedModel : ""
        }
        .onDisappear { request?.cancel(); generation = UUID(); loading = false; revealed = false }
        .alert(L10n.text("settings.configuration"), isPresented: Binding(get: { status != nil }, set: { if !$0 { status = nil } })) {
            Button("OK") { status = nil }
        } message: { Text(L10n.text(status ?? "")) }
    }

    private func load() {
        do { prompt = try ChatPrompt().effectiveText(); savedPrompt = prompt; promptLoaded = true }
        catch { status = "chat.promptInvalid" }
        do { key = try ChatSettings.readKey(); savedKey = key; keyLoaded = true }
        catch { status = "chat.keychainError" }
        model = cleanKey.isEmpty ? "" : ChatSettings.model; savedModel = model
    }

    private func save() {
        do {
            try ChatPrompt.validate(prompt)
            if !cleanKey.isEmpty && model.isEmpty { status = "settings.chooseModel"; return }
            // Validate everything before writing. Persist snapshots only after all writes succeed.
            try ChatSettings.saveKey(cleanKey)
            try ChatPrompt().save(prompt)
            if !model.isEmpty { ChatSettings.model = model }
            savedKey = key; savedPrompt = prompt; savedModel = model
        } catch { status = (error as? ChatFailure)?.key ?? "chat.keychainError" }
    }

    private func fetchModels(test: Bool) {
        guard !cleanKey.isEmpty else { return }
        request?.cancel()
        let id = UUID(); generation = id
        let snapshot = cleanKey
        loading = true
        request = Task { @MainActor in
            defer { if generation == id { loading = false; request = nil } }
            do {
                let result = try await ChatSettings.availableModels(key: snapshot)
                guard !Task.isCancelled, generation == id else { return }
                models = result
                if test { status = "settings.connectionOK" }
            } catch {
                guard !Task.isCancelled, generation == id else { return }
                models = []
                if test { status = "settings.modelsFailed" }
            }
        }
    }
}
