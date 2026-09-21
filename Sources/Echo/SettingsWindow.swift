import SwiftUI
import AppKit

/// 设置窗口控制器。
///
/// Echo 设置页:历史上限、全局热键、自动粘贴开关、清空历史、AX 权限状态。
/// 所有配置经 AppSettings 持久化到 UserDefaults。
final class SettingsWindowController: NSWindowController {
    init() {
        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = L10n.text("settings.windowTitle")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 显示窗口。菜单栏 App(.accessory)需先激活否则窗口灰着无法聚焦。
    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// 设置页 SwiftUI 视图。
struct SettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    // 配置(经 AppSettings 读写 UserDefaults)
    @State private var historyLimit: Int = AppSettings.shared.historyLimit
    @State private var hotkeyModifiers: UInt32 = AppSettings.shared.hotkeyModifiers
    @State private var hotkeyKeyCode: UInt32 = AppSettings.shared.hotkeyKeyCode
    @State private var autoPasteEnabled: Bool = AppSettings.shared.autoPasteEnabled
    @State private var hotkeyPresetIndex: Int = 0

    // AX 权限状态
    @State private var axGranted: Bool = AXIsProcessTrusted()
    @State private var historyCount: Int = HistoryStore.shared.count

    private var palette: EchoTheme.Palette {
        EchoTheme.palette(for: colorScheme)
    }

    // 可选热键预设(避免复杂手势捕获,提供常用两键组合)
    private let hotkeyPresets: [(label: String, modifiers: UInt32, keycode: UInt32)] = [
        ("⌘ \\",  0x0100, 42),
        ("⌘ ⌥ V", 0x0100 | 0x0800, 9),
        ("⌘ ⇧ V", 0x0100 | 0x0200, 9),
        ("⌃ ⌘ V", 0x1000 | 0x0100, 9),
        ("⌘ B",   0x0100, 11),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                settingsSection(title: L10n.text("settings.general")) {
                    settingRow(title: L10n.text("settings.historyLimit")) {
                        Stepper(value: $historyLimit, in: 10...200, step: 10) {
                            Text("\(historyLimit)")
                                .font(.system(.body, design: .monospaced))
                                .frame(minWidth: 44, alignment: .trailing)
                        }
                        .onChange(of: historyLimit) { newValue in
                            AppSettings.shared.historyLimit = newValue
                        }
                    }

                    settingNote(L10n.text("settings.historyLimit.note"))
                }

                settingsSection(title: L10n.text("settings.globalShortcut")) {
                    settingRow(title: L10n.text("settings.openShortcut")) {
                        Picker("", selection: $hotkeyPresetIndex) {
                            ForEach(hotkeyPresets.indices, id: \.self) { idx in
                                Text(hotkeyPresets[idx].label).tag(idx)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .onChange(of: hotkeyPresetIndex) { newValue in
                            applyHotkey(index: newValue)
                        }
                    }

                    settingNote(L10n.text("settings.openShortcut.note"))
                }

                settingsSection(title: L10n.text("settings.paste")) {
                    settingRow(
                        title: L10n.text("settings.autoPaste"),
                        subtitle: L10n.text(autoPasteEnabled ? "settings.autoPaste.on" : "settings.autoPaste.off")
                    ) {
                        Toggle("", isOn: $autoPasteEnabled)
                            .labelsHidden()
                            .onChange(of: autoPasteEnabled) { newValue in
                                AppSettings.shared.autoPasteEnabled = newValue
                            }
                    }

                    if autoPasteEnabled {
                        permissionRow
                    }
                }

                settingsSection(title: L10n.text("settings.data")) {
                    settingRow(title: L10n.text("settings.currentHistory")) {
                        Text(L10n.format("settings.historyCount", historyCount, historyLimit))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(palette.textSecondary)
                    }

                    settingRow(title: L10n.text("settings.clearAll"), subtitle: L10n.text("settings.clearAll.note")) {
                        Button(role: .destructive) {
                            HistoryStore.shared.clearAll()
                            historyCount = 0
                        } label: {
                            Text(L10n.text("settings.clear"))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    settingRow(
                        title: L10n.text("settings.resetAchievements"),
                        subtitle: L10n.text("settings.resetAchievements.note")
                    ) {
                        Button(role: .destructive) {
                            AchievementStore.shared.reset()
                        } label: {
                            Text(L10n.text("settings.reset"))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                Text(L10n.text("settings.footer"))
                    .font(.caption2)
                    .foregroundStyle(palette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 2)
            }
            .padding(18)
        }
        .frame(width: 520, height: 560)
        .background(palette.windowBackground)
        .onAppear {
            syncHotkeyPresetIndex()
            axGranted = AXIsProcessTrusted()
            historyCount = HistoryStore.shared.count
        }
        .onReceive(NotificationCenter.default.publisher(for: HistoryStore.didChangeNotification)) { _ in
            historyCount = HistoryStore.shared.count
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            axGranted = AXIsProcessTrusted()
            historyCount = HistoryStore.shared.count
            syncHotkeyPresetIndex()
        }
    }

    private var permissionRow: some View {
        HStack(spacing: 12) {
            if axGranted {
                Label(L10n.text("settings.accessibility.granted"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(palette.green)
            } else {
                Label(L10n.text("settings.accessibility.denied"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(palette.yellow)
                Button(L10n.text("settings.openSystemSettings")) {
                    PermissionsManager.shared.openSystemSettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(palette.controlBackground)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.controlBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// 设置页分组,贴近 design-plan.html 的 set-section 结构。
    private func settingsSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.08)
                .foregroundStyle(palette.accent)

            content()
        }
    }

    /// 单行设置项:左侧标题/副标题,右侧控件。
    private func settingRow<Accessory: View>(title: String, subtitle: String? = nil, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: subtitle == nil ? 0 : 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(palette.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textSecondary)
                }
            }

            Spacer(minLength: 16)

            accessory()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(palette.rowBackground)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func settingNote(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 根据当前配置同步热键预设索引。
    private func syncHotkeyPresetIndex() {
        hotkeyPresetIndex = hotkeyPresets.firstIndex {
            $0.modifiers == hotkeyModifiers && $0.keycode == hotkeyKeyCode
        } ?? 0
    }

    /// 把选中的预设应用到 AppSettings 并重新注册热键。
    private func applyHotkey(index: Int) {
        let clampedIndex = hotkeyPresets.indices.contains(index) ? index : 0
        let preset = hotkeyPresets[clampedIndex]
        hotkeyPresetIndex = clampedIndex
        hotkeyModifiers = preset.modifiers
        hotkeyKeyCode = preset.keycode
        AppSettings.shared.hotkeyModifiers = preset.modifiers
        AppSettings.shared.hotkeyKeyCode = preset.keycode
        GlobalHotkey.shared.reregister()
    }
}
