import Carbon
import AppKit

/// 全局热键管理器:用 Carbon `RegisterEventHotKey` 注册系统级快捷键。
///
/// 设计依据(详见 design-plan.html 板块3「RegisterEventHotKey」):
/// - **零权限**:公开 Carbon API,无需辅助功能/输入监控权限
/// - 比 CGEventTap 稳定(不会被系统超时禁用)
/// - 默认 ⌘\(反斜杠键,keycode 42)
///
/// 注册一次,常驻;按键配置可在设置页改,改后调 `reregister()` 重注册。
/// 触发回调在主线程执行(从 Carbon 线程切回主线程)。
final class GlobalHotkey {
    static let shared = GlobalHotkey()

    /// 热键触发时调用(主线程)。
    var onTriggered: (() -> Void)?

    /// 当前注册的热键引用(注销时用)
    private var hotKeyRef: EventHotKeyRef?
    /// 事件处理器引用(注册一次,生命周期与 App 相同)
    private var eventHandler: EventHandlerRef?

    private init() {}

    // MARK: - 生命周期

    /// 注册全局热键(从 AppSettings 读当前配置)。
    /// 在 AppDelegate 启动时调用一次。已注册则先注销再重注。
    func register() {
        unregister()

        let modifiers = AppSettings.shared.hotkeyModifiers
        let keycode = AppSettings.shared.hotkeyKeyCode

        // 1. 先装事件处理器(只装一次,负责接收所有热键事件)
        installEventHandlerIfNeeded()

        // 2. 注册具体热键
        let hotKeyId = EventHotKeyID(signature: fourCharCode("Echo"), id: 1)
        let status = RegisterEventHotKey(
            keycode,
            UInt32(modifiers),
            hotKeyId,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status != noErr {
            NSLog("[Echo] GlobalHotkey 注册失败,状态码: \(status)")
        }
    }

    /// 注销当前热键(保留事件处理器)。
    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    /// 配置变更后重新注册(设置页改热键后调用)。
    func reregister() {
        register()
    }

    // MARK: - 事件处理器

    /// 安装全局热键事件处理器(只装一次)。
    /// 处理器收到事件后回调到 onTriggered,切回主线程。
    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, eventRef, userData) -> OSStatus in
                guard let userData else { return noErr }
                let watcher = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
                watcher.handleHotKeyEvent()
                return noErr
            },
            1,
            &spec,
            selfPtr,
            &eventHandler
        )
    }

    /// 热键事件到达:切回主线程触发回调。
    private func handleHotKeyEvent() {
        DispatchQueue.main.async { [weak self] in
            self?.onTriggered?()
        }
    }

    // MARK: - Helpers

    /// 把 4 字符串转成 OSType 签名(用于 EventHotKeyID.signature)。
    private func fourCharCode(_ string: String) -> OSType {
        var result: UInt32 = 0
        for char in string.utf8.prefix(4) {
            result = (result << 8) | UInt32(char)
        }
        return result
    }
}
