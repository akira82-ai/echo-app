import AppKit
import CoreGraphics

/// 全局键盘监听器：检测 500ms 时间窗口内的连续三次 ⌘+C，
/// 触发后延迟读取剪贴板并存盘。
///
/// 需要用户授予「辅助功能（Accessibility）」权限，
/// 否则 `CGEvent.tapCreate` 会返回 nil。
final class HotkeyMonitor {
    /// 三连按的时间窗口（毫秒）
    static let windowMilliseconds: Int = 500

    /// 触发后读取剪贴板的延迟（毫秒），等待系统完成复制写入
    static let clipboardReadDelayMs: UInt64 = 80

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// 最近 ⌘+C 按下的时间戳（毫秒）
    private var pressTimestamps: [Int64] = []

    /// 是否已启动
    private(set) var isRunning = false

    /// 监听是否暂停（菜单栏可切换）
    var isPaused = false {
        didSet {
            if isPaused {
                pressTimestamps.removeAll()
            }
        }
    }

    /// 触发时执行的回调
    var onTriggered: (() -> Void)?

    /// 权限缺失时执行的回调
    var onPermissionDenied: (() -> Void)?

    // 用于在 CGEvent 回调（C 风格）中访问 self，存为 Unmanaged 以避免循环引用
    private static var current: HotkeyMonitor?

    /// 启动监听。返回 true 表示成功创建事件 tap。
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }

        // 检查辅助功能权限
        let trusted = AXIsProcessTrusted()
        guard trusted else {
            onPermissionDenied?()
            return false
        }

        let eventMask = (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { _, type, event, _ in
                return HotkeyMonitor.handleEvent(type: type, event: event)
            },
            userInfo: nil
        ) else {
            // 创建失败，通常是权限问题
            onPermissionDenied?()
            return false
        }

        self.eventTap = tap
        let rlSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        self.runLoopSource = rlSource
        CFRunLoopAddSource(CFRunLoopGetMain(), rlSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        HotkeyMonitor.current = self
        isRunning = true
        return true
    }

    /// 停止监听
    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        pressTimestamps.removeAll()
        isRunning = false
    }

    // MARK: - Event Handling

    /// CGEventTap 回调入口（静态，因 C 回调无法直接捕获 self）
    private static func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let monitor = current else { return Unmanaged.passRetained(event) }
        guard !monitor.isPaused else { return Unmanaged.passRetained(event) }

        // tap 本身被禁用时（如超时、锁屏），重新启用
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = monitor.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        guard type == .keyDown else { return Unmanaged.passRetained(event) }

        let flags = event.flags
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // ⌘ 键（0x37 = 55） + C 键（keycode 8）
        let isCommand = flags.contains(.maskCommand)
        let isC = keyCode == 8
        guard isCommand && isC else { return Unmanaged.passRetained(event) }

        monitor.recordPress()
        return Unmanaged.passRetained(event)
    }

    /// 记录一次 ⌘+C 按下，并在满足三连条件时触发
    private func recordPress() {
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        // 清理超出时间窗口的历史记录
        let threshold = now - Int64(HotkeyMonitor.windowMilliseconds)
        while let first = pressTimestamps.first, first < threshold {
            pressTimestamps.removeFirst()
        }

        pressTimestamps.append(now)

        // 500ms 内累计达到 3 次 → 触发
        if pressTimestamps.count >= 3 {
            pressTimestamps.removeAll()
            trigger()
        }
    }

    /// 触发：延迟读取剪贴板并存盘
    private func trigger() {
        // 在后台队列延迟读取，避免阻塞事件回调
        let delayMs = HotkeyMonitor.clipboardReadDelayMs
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(Int(delayMs))) {
            guard let content = ClipboardManager.shared.readAndDeduplicate() else {
                // 剪贴板为空或内容重复，跳过
                return
            }
            do {
                try StorageManager.shared.append(content: content)
                DispatchQueue.main.async { self.onTriggered?() }
            } catch {
                NSLog("[LarkAssistant] 写入文件失败: \(error.localizedDescription)")
            }
        }
    }
}
