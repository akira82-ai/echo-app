import SwiftUI
import AppKit

final class SettingsWindowController: NSWindowController {
    init() {
        let hosting = NSHostingController(rootView: SettingsView())
        let window = SettingsWindow(contentViewController: hosting)
        window.title = L10n.text("settings.windowTitle")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

private final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            let actions: [String: Selector] = ["v": #selector(NSText.paste(_:)), "c": #selector(NSText.copy(_:)),
                "x": #selector(NSText.cut(_:)), "a": #selector(NSText.selectAll(_:))]
            if let action = actions[event.charactersIgnoringModifiers?.lowercased() ?? ""],
               NSApp.sendAction(action, to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Colors and spacing follow the approved single-panel HTML, independently of the quick panel.
enum SettingsStyle {
    static func color(_ light: UInt32, _ dark: UInt32, _ scheme: ColorScheme) -> Color {
        let hex = scheme == .dark ? dark : light
        return Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
                     blue: Double(hex & 255) / 255)
    }
    static func background(_ s: ColorScheme) -> Color { color(0xfbfcfa, 0x252a26, s) }
    static func card(_ s: ColorScheme) -> Color { color(0xffffff, 0x2d332e, s) }
    static func input(_ s: ColorScheme) -> Color { color(0xf0f3ed, 0x353d35, s) }
    static func ink(_ s: ColorScheme) -> Color { color(0x202923, 0xe3e9e1, s) }
    static func muted(_ s: ColorScheme) -> Color { color(0x7b827d, 0xa6b0a5, s) }
    static func accent(_ s: ColorScheme) -> Color { color(0x3e6652, 0x9dbfa5, s) }
    static func line(_ s: ColorScheme) -> Color { color(0xe1e6de, 0x414a40, s) }
}

struct SettingsView: View {
    @Environment(\.colorScheme) private var scheme
    @State private var historyLimit = AppSettings.shared.historyLimit
    @State private var autoPaste = AppSettings.shared.autoPasteEnabled
    @State private var axGranted = AXIsProcessTrusted()
    @State private var historyCount = HistoryStore.shared.count
    @State private var confirmClear = false
    @State private var confirmReset = false
    @State private var choosingLimit = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 15) {
                Text("Echo").font(.system(size: 22, weight: .semibold)).tracking(3)
                Rectangle().fill(SettingsStyle.line(scheme)).frame(width: 1, height: 14)
                Text(L10n.text("settings.shortTitle")).font(.system(size: 12)).foregroundStyle(SettingsStyle.muted(scheme))
                Spacer()
                Text(L10n.text("settings.tagline")).font(.system(size: 11)).foregroundStyle(SettingsStyle.muted(scheme))
            }.padding(.bottom, 2)
            sectionTitle("settings.general")
            SettingsCard {
                SettingsRow(title: L10n.text("settings.openShortcut"), subtitle: L10n.text("settings.openShortcut.note")) {
                    ShortcutRecorder().frame(width: 72, height: 28)
                }
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    SettingsRow(title: L10n.text("settings.autoPaste"), subtitle: L10n.text(autoPaste ? "settings.autoPaste.on" : "settings.autoPaste.off")) {
                        Toggle(L10n.text("settings.autoPaste"), isOn: $autoPaste).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    if autoPaste {
                        HStack(spacing: 5) {
                            Circle().fill(axGranted ? SettingsStyle.accent(scheme) : .orange).frame(width: 4, height: 4)
                            Text(L10n.text(axGranted ? "settings.accessibility.granted" : "settings.accessibility.denied"))
                            if !axGranted {
                                Button(L10n.text("settings.openSystemSettings")) { PermissionsManager.shared.openSystemSettings() }.buttonStyle(.plain)
                            }
                        }.font(.system(size: 10)).foregroundStyle(SettingsStyle.accent(scheme)).padding(.horizontal, 12).padding(.bottom, 5)
                    }
                }
                Divider()
                SettingsRow(title: L10n.text("settings.historyLimit"), subtitle: L10n.text("settings.historyLimit.note")) {
                    Button { choosingLimit.toggle() } label: {
                        HStack(spacing: 5) {
                            Text(L10n.format("settings.itemCount", historyLimit))
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.down").font(.system(size: 8))
                        }.padding(.horizontal, 9).frame(width: 72, height: 28)
                    }.buttonStyle(.plain)
                        .background(SettingsStyle.card(scheme), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(SettingsStyle.line(scheme)))
                        .settingsDropdown(isPresented: $choosingLimit) {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(Set([30, 50, 100, 200, historyLimit])).sorted(), id: \.self) { value in
                                    SettingsDropdownOption(title: L10n.format("settings.itemCount", value), selected: value == historyLimit) {
                                        historyLimit = value
                                        choosingLimit = false
                                    }
                                }
                            }
                        }
                }
            }
            Divider()
            sectionTitle("chat.settings")
            ChatConfigurationView()
            Divider()
            sectionTitle("settings.data")
            SettingsCard {
                SettingsRow(title: L10n.text("settings.clearAll"), subtitle: L10n.format("settings.clearCount", historyCount)) {
                    Button(L10n.text("settings.clear")) { confirmClear = true }.foregroundStyle(.red).buttonStyle(.bordered).controlSize(.small)
                }
                Divider()
                SettingsRow(title: L10n.text("settings.resetAchievements"), subtitle: L10n.text("settings.resetAchievements.note")) {
                    Button(L10n.text("settings.reset")) { confirmReset = true }.buttonStyle(.bordered).controlSize(.small)
                }
            }
            Divider()
            HStack {
                Text(L10n.text("settings.footer"))
                Spacer()
                Link("github.com/akira82-ai/echo-app ↗", destination: URL(string: "https://github.com/akira82-ai/echo-app")!)
            }.font(.system(size: 10)).foregroundStyle(SettingsStyle.muted(scheme))
        }
        .font(.system(size: 11)).foregroundStyle(SettingsStyle.ink(scheme))
        .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 10)
        .frame(width: 620).fixedSize(horizontal: false, vertical: true)
        .background(SettingsStyle.background(scheme)).tint(SettingsStyle.accent(scheme))
        .modifier(SettingsDropdownLayer())
        .onChange(of: historyLimit) { AppSettings.shared.historyLimit = $0 }
        .onChange(of: autoPaste) { AppSettings.shared.autoPasteEnabled = $0 }
        .onReceive(NotificationCenter.default.publisher(for: HistoryStore.didChangeNotification)) { _ in historyCount = HistoryStore.shared.count }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .onAppear(perform: refresh)
        .alert(L10n.text("settings.clearConfirm"), isPresented: $confirmClear) {
            Button(L10n.text("settings.cancel"), role: .cancel) { }
            Button(L10n.text("settings.clear"), role: .destructive) { HistoryStore.shared.clearAll() }
        } message: { Text(L10n.text("settings.clearConfirm.note")) }
        .alert(L10n.text("settings.resetConfirm"), isPresented: $confirmReset) {
            Button(L10n.text("settings.cancel"), role: .cancel) { }
            Button(L10n.text("settings.reset"), role: .destructive) { AchievementStore.shared.reset() }
        } message: { Text(L10n.text("settings.resetAchievements.note")) }
    }
    private func sectionTitle(_ key: String) -> some View {
        Text(L10n.text(key)).font(.system(size: 12, weight: .semibold))
    }
    private func refresh() { axGranted = AXIsProcessTrusted(); historyCount = HistoryStore.shared.count }
}

struct SettingsCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0, content: content)
            .background(SettingsStyle.card(scheme), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(SettingsStyle.line(scheme)))
    }
}

struct SettingsRow<Accessory: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let accessory: () -> Accessory
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium))
                if let subtitle { Text(subtitle).font(.system(size: 10)).foregroundStyle(SettingsStyle.muted(scheme)).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            accessory()
        }.padding(.horizontal, 12).padding(.vertical, 6).frame(minHeight: 39)
    }
}

/// A native focused control captures combinations without intercepting other text fields.
private struct ShortcutRecorder: NSViewRepresentable {
    func makeNSView(context: Context) -> RecorderButton { RecorderButton() }
    func updateNSView(_ button: RecorderButton, context: Context) {
        if !button.recording { button.title = AppSettings.shared.hotkeyDisplayText }
    }
    final class RecorderButton: NSButton {
        var recording = false
        override var acceptsFirstResponder: Bool { true }
        init() {
            super.init(frame: .zero)
            title = AppSettings.shared.hotkeyDisplayText
            bezelStyle = .rounded
            font = .systemFont(ofSize: 12)
            target = self; action = #selector(startRecording)
            setAccessibilityLabel(L10n.text("settings.openShortcut"))
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        @objc private func startRecording() { recording = true; title = "…"; window?.makeFirstResponder(self) }
        override func resignFirstResponder() -> Bool {
            recording = false; title = AppSettings.shared.hotkeyDisplayText
            return super.resignFirstResponder()
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if recording { keyDown(with: event); return true }
            return super.performKeyEquivalent(with: event)
        }
        override func keyDown(with event: NSEvent) {
            guard recording else { super.keyDown(with: event); return }
            if event.keyCode == 53 { recording = false; title = AppSettings.shared.hotkeyDisplayText; return }
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard !flags.intersection([.command, .control, .option]).isEmpty,
                  let character = event.charactersIgnoringModifiers, !character.isEmpty else { NSSound.beep(); return }
            var modifiers: UInt32 = 0
            if flags.contains(.command) { modifiers |= 0x0100 }
            if flags.contains(.shift) { modifiers |= 0x0200 }
            if flags.contains(.option) { modifiers |= 0x0800 }
            if flags.contains(.control) { modifiers |= 0x1000 }
            guard GlobalHotkey.shared.replace(modifiers: modifiers, keycode: UInt32(event.keyCode)) else {
                let alert = NSAlert(); alert.messageText = L10n.text("settings.hotkeyFailed"); alert.runModal(); return
            }
            recording = false
            title = flags.contains(.command) ? "⌘" : ""
            AppSettings.shared.hotkeyLabel = (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + character.uppercased()
            title = AppSettings.shared.hotkeyDisplayText
        }
    }
}


// Anchors are resolved at the window root so cards never clip the floating menus.
private struct SettingsDropdownEntry {
    let anchor: Anchor<CGRect>
    let content: AnyView
    let dismiss: () -> Void
}
private struct SettingsDropdownPreference: PreferenceKey {
    static var defaultValue: [SettingsDropdownEntry] = []
    static func reduce(value: inout [SettingsDropdownEntry], nextValue: () -> [SettingsDropdownEntry]) {
        value.append(contentsOf: nextValue())
    }
}
extension View {
    func settingsDropdown<Menu: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Menu) -> some View {
        anchorPreference(key: SettingsDropdownPreference.self, value: .bounds) { anchor in
            isPresented.wrappedValue ? [SettingsDropdownEntry(anchor: anchor, content: AnyView(content()), dismiss: { isPresented.wrappedValue = false })] : []
        }
    }
}
private struct SettingsDropdownLayer: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.overlayPreferenceValue(SettingsDropdownPreference.self) { entries in
            GeometryReader { proxy in
                if let entry = entries.last {
                    let rect = proxy[entry.anchor]
                    ZStack(alignment: .topLeading) {
                        Color.clear.contentShape(Rectangle()).onTapGesture { entries.forEach { $0.dismiss() } }
                        entry.content
                            .font(.system(size: 12)).foregroundStyle(SettingsStyle.ink(scheme))
                            .padding(4).frame(width: rect.width)
                            .background(SettingsStyle.background(scheme), in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(SettingsStyle.line(scheme)))
                            .shadow(color: .black.opacity(0.10), radius: 9, y: 4)
                            .offset(x: rect.minX, y: rect.maxY + 5)
                    }.onExitCommand { entries.forEach { $0.dismiss() } }
                }
            }
        }
    }
}
struct SettingsDropdownOption: View {
    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark").font(.system(size: 10)) }
            }.padding(.horizontal, 8).frame(minHeight: 30)
                .foregroundStyle(selected ? SettingsStyle.accent(scheme) : SettingsStyle.ink(scheme))
                .background(hovered || selected ? SettingsStyle.input(scheme) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovered = $0 }
    }
}
