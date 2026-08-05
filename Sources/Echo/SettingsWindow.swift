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
        window.title = "Echo 设置"
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
    // 配置(经 AppSettings 读写 UserDefaults)
    @State private var historyLimit: Int = AppSettings.shared.historyLimit
    @State private var hotkeyModifiers: UInt32 = AppSettings.shared.hotkeyModifiers
    @State private var hotkeyKeyCode: UInt32 = AppSettings.shared.hotkeyKeyCode
    @State private var autoPasteEnabled: Bool = AppSettings.shared.autoPasteEnabled

    // AX 权限状态
    @State private var axGranted: Bool = AXIsProcessTrusted()
    @State private var historyCount: Int = HistoryStore.shared.count

    // 可选热键预设(避免复杂手势捕获,提供常用两键组合)
    private let hotkeyPresets: [(label: String, modifiers: UInt32, keycode: UInt32)] = [
        ("⌘ \\",  0x0100, 42),
        ("⌘ ⌥ V", 0x0100 | 0x0800, 9),
        ("⌘ ⇧ V", 0x0100 | 0x0200, 9),
        ("⌃ ⌘ V", 0x1000 | 0x0100, 9),
        ("⌘ B",   0x0100, 11),
    ]

    var body: some View {
        Form {
            // MARK: - 通用
            Section {
                LabeledContent("历史上限") {
                    Stepper(value: $historyLimit, in: 10...200, step: 10) {
                        Text("\(historyLimit)")
                            .font(.system(.body, design: .monospaced))
                            .frame(minWidth: 40)
                    }
                    .onChange(of: historyLimit) { newValue in
                        AppSettings.shared.historyLimit = newValue
                    }
                }
                Text("文本/图片/文件共享名额。超出后最旧条目被淘汰,图片同步删盘。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("通用")
            }

            // MARK: - 全局热键
            Section {
                Picker("呼出快捷键", selection: selectedHotkeyBinding) {
                    ForEach(hotkeyPresets.indices, id: \.self) { idx in
                        Text(hotkeyPresets[idx].label).tag(idx)
                    }
                }
                .onChange(of: selectedHotkeyBinding.wrappedValue) { _ in
                    applyHotkey()
                }

                Text("在任意 App 中按此快捷键呼出历史选择面板。⌘\\ 为默认(两键、左手区、系统几乎不占用)。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("全局热键")
            }

            // MARK: - 粘贴
            Section {
                Toggle("启用自动粘贴", isOn: $autoPasteEnabled)
                    .onChange(of: autoPasteEnabled) { newValue in
                        AppSettings.shared.autoPasteEnabled = newValue
                    }
                Text(autoPasteEnabled
                     ? "选中历史项后自动模拟 ⌘V 粘到当前 App。需要辅助功能权限(见下方)。"
                     : "关闭后 App 完全零权限运行。选中项只写回剪贴板,你回目标 App 自己按 ⌘V。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if autoPasteEnabled {
                    HStack {
                        if axGranted {
                            Label("辅助功能权限:已授予", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        } else {
                            Label("辅助功能权限:未授予(自动粘贴将降级)", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                            Button("打开设置") {
                                PermissionsManager.shared.openSystemSettings()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            } header: {
                Text("粘贴")
            }

            // MARK: - 数据
            Section {
                LabeledContent("当前历史") {
                    Text("\(historyCount) / \(historyLimit) 条")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Button(role: .destructive) {
                    HistoryStore.shared.clearAll()
                    historyCount = 0
                } label: {
                    Label("清空所有历史", systemImage: "trash")
                }
                Text("历史纯内存,App 重启也会清空。此处立即清空并删除图片缓存文件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("数据")
            } footer: {
                Text("Echo · 剪贴板历史管理器 · 本地运行,数据不出本机")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 560)
        .onAppear {
            axGranted = AXIsProcessTrusted()
            historyCount = HistoryStore.shared.count
        }
    }

    /// 热键 Picker 的双向绑定:读时匹配当前配置到预设索引,写时由 onChange 处理。
    private var selectedHotkeyBinding: Binding<Int> {
        Binding(
            get: {
                // 找当前配置匹配的预设索引,无则默认第一个
                hotkeyPresets.firstIndex {
                    $0.modifiers == hotkeyModifiers && $0.keycode == hotkeyKeyCode
                } ?? 0
            },
            set: { _ in }
        )
    }

    /// 把选中的预设应用到 AppSettings 并重新注册热键。
    private func applyHotkey() {
        let idx = selectedHotkeyBinding.wrappedValue
        let preset = hotkeyPresets[idx]
        hotkeyModifiers = preset.modifiers
        hotkeyKeyCode = preset.keycode
        AppSettings.shared.hotkeyModifiers = preset.modifiers
        AppSettings.shared.hotkeyKeyCode = preset.keycode
        GlobalHotkey.shared.reregister()
    }
}
