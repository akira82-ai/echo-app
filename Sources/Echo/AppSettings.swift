import Foundation
import AppKit

/// Echo 应用配置:读写 UserDefaults(非敏感配置)。
///
/// 历史本身**不持久化**(纯内存,重启清空,符合设计约束),
/// 这里只持久化少量"用户偏好"——这些配置必须在重启后保留:
/// 1. 历史上限(默认 50)
/// 2. 全局热键(默认 ⌘\)
/// 3. 是否启用自动粘贴(默认开;关闭则零权限运行)
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    private init() {}

    // MARK: - Keys

    private enum Key {
        static let historyLimit = "historyLimit"
        static let hotkeyModifiers = "hotkeyModifiers"
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let autoPasteEnabled = "autoPasteEnabled"
    }

    // MARK: - 历史上限

    /// 历史记录条数上限(文本/图片/文件共享名额),默认 50。
    /// 超出后最旧条目被淘汰;若是图片则同步删盘。
    var historyLimit: Int {
        get {
            let v = defaults.integer(forKey: Key.historyLimit)
            return v > 0 ? v : Self.defaultHistoryLimit
        }
        set {
            // 防御:至少 1,最大 200(避免无意义的大值拖累内存)
            let clamped = max(1, min(200, newValue))
            defaults.set(clamped, forKey: Key.historyLimit)
        }
    }
    static let defaultHistoryLimit = 50

    // MARK: - 全局热键

    /// 热键修饰键(Carbon 修饰键掩码的位组合,如 cmdKey)。
    /// 默认 cmdKey(⌘)。
    var hotkeyModifiers: UInt32 {
        get {
            let v = defaults.object(forKey: Key.hotkeyModifiers) as? UInt32
            return v ?? Self.defaultHotkeyModifiers
        }
        set { defaults.set(newValue, forKey: Key.hotkeyModifiers) }
    }
    static let defaultHotkeyModifiers: UInt32 = 0x0100  // cmdKey

    /// 热键键码(virtual keycode),默认 42 = "\" 反斜杠键。
    var hotkeyKeyCode: UInt32 {
        get {
            let v = defaults.object(forKey: Key.hotkeyKeyCode) as? UInt32
            return v ?? Self.defaultHotkeyKeyCode
        }
        set { defaults.set(newValue, forKey: Key.hotkeyKeyCode) }
    }
    static let defaultHotkeyKeyCode: UInt32 = 42  // "\"

    /// 人类可读的热键描述,用于菜单/设置页显示。
    var hotkeyDisplayText: String {
        let keyChar = Self.keycodeToSymbol(hotkeyKeyCode)
        var prefix = ""
        if hotkeyModifiers & 0x0100 != 0 { prefix += "⌘" }       // cmd
        if hotkeyModifiers & 0x0200 != 0 { prefix += "⇧" }       // shift
        if hotkeyModifiers & 0x0800 != 0 { prefix += "⌥" }       // option
        if hotkeyModifiers & 0x1000 != 0 { prefix += "⌃" }       // control
        return prefix + keyChar
    }

    /// 把常见 virtual keycode 转成可读符号(覆盖设置页可选的预设)。
    static func keycodeToSymbol(_ keycode: UInt32) -> String {
        switch keycode {
        case 42: return "\\"
        case 9:  return "V"
        case 46: return "W"
        case 11: return "B"
        case 47: return "."
        case 43: return ","
        default: return "Key\(keycode)"
        }
    }

    // MARK: - 自动粘贴

    /// 是否启用自动粘贴(默认开)。
    /// 开启后,选中历史项会自动模拟 ⌘V 粘到目标 App(需要辅助功能权限)。
    /// 关闭后,App 完全零权限运行,选中项只写回剪贴板。
    var autoPasteEnabled: Bool {
        get {
            // object(forKey:) 对未设置返回 nil → 默认 true
            if defaults.object(forKey: Key.autoPasteEnabled) == nil { return true }
            return defaults.bool(forKey: Key.autoPasteEnabled)
        }
        set { defaults.set(newValue, forKey: Key.autoPasteEnabled) }
    }
}
