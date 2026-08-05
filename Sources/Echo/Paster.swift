import AppKit
import CoreGraphics

/// 粘贴执行器:把选中的历史项写回剪贴板,并(可选)模拟 ⌘V 自动粘到目标 App。
///
/// 设计依据(详见 design-plan.html 板块3「AX 权限降级粘贴」):
/// 1. 按类型写回 NSPasteboard(文本 / NSImage / NSURL)
/// 2. 若启用自动粘贴且有 AX 权限 → CGEvent 模拟 ⌘V
/// 3. 无权限 / 关闭自动粘贴 → 静默只写剪贴板,用户回目标 App 自己按 ⌘V(降级)
///
/// 这是整个 App 唯一依赖 AX 权限的功能。关闭"自动粘贴"后 App 完全零权限运行。
///
/// 时序(关键,否则粘到错的地方):
/// - 面板关闭后先等 ~80ms,让目标 App 恢复 key 状态
/// - 写剪贴板前调 ClipboardWatcher.suppressNext(),避免写回被误采为新复制
/// - 写完再延迟一小段,最后模拟 ⌘V
final class Paster {
    static let shared = Paster()

    private init() {}

    // MARK: - 执行粘贴

    /// 粘贴指定历史项。
    /// - Parameters:
    ///   - entry: 用户选中的条目
    ///   - targetApp: 面板显示前的最前台 App,粘贴时需激活它让 ⌘V 送达
    /// - Note: 在主线程调用(QuickPanel 选中回调已在主线程)。
    func paste(_ entry: ClipEntry, targetApp: NSRunningApplication? = nil) {
        // 等面板完全关闭,目标 App 恢复 key 状态
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80)) { [weak self] in
            self?.performPaste(entry, targetApp: targetApp)
        }
    }

    /// 实际执行:写剪贴板 → 激活目标 App → 模拟 ⌘V。
    private func performPaste(_ entry: ClipEntry, targetApp: NSRunningApplication?) {
        // 抑制 watcher 把这次写回误判为新复制
        ClipboardWatcher.shared.suppressNext()

        // 写回剪贴板
        writeBack(entry)

        guard AppSettings.shared.autoPasteEnabled, AXIsProcessTrusted() else {
            // 降级:静默,只写剪贴板。用户回目标 App 自己按 ⌘V。
            NSLog("[Echo] 自动粘贴已降级(权限不足或已关闭),内容已写剪贴板")
            return
        }

        // 关键:显式激活目标 App,让它成为 key 窗口,CGEvent 才能送达。
        // 只 deactivate 自己不够——必须主动 activate 目标 App,
        // 否则 ⌘V 事件会被 Echo 自己吞掉或无处可去(实测验证:不激活则粘贴无效)。
        if let targetApp {
            targetApp.activate(options: [.activateAllWindows])
        }

        // 激活后等待目标 App 完全成为 key 窗口,再模拟 ⌘V
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) {
            self.simulateCmdV()
        }
    }

    // MARK: - 写回剪贴板

    /// 按类型把内容写回 NSPasteboard.general。
    private func writeBack(_ entry: ClipEntry) {
        let pb = NSPasteboard.general
        pb.clearContents()

        switch entry.kind {
        case .text(let body):
            pb.setString(body, forType: .string)

        case .image(let ref):
            // 从磁盘按需读回原图(原图不常驻内存)
            guard let image = ImageCache.shared.loadOriginal(at: ref.diskPath) else {
                NSLog("[Echo] 粘贴图片失败:原图读不回(可能已被清理): \(ref.diskPath.path)")
                return
            }
            pb.writeObjects([image])

        case .files(let urls):
            // 文件零拷贝:只写 NSURL 路径,接收方 App 自行读取。
            // Foundation.URL 不直接遵循 NSPasteboardWriting,转成 NSURL。
            let nsurls = urls.map { $0 as NSURL }
            pb.writeObjects(nsurls)
        }
    }

    // MARK: - 模拟 ⌘V

    /// 用 CGEvent 模拟按下并释放 ⌘V,把剪贴板内容粘到当前 key App 的光标处。
    /// - Note: 需要 AX 权限(已在 performPaste 检查)。CGEvent 必须在主线程创建。
    /// 用 CGEvent 模拟按下并释放 ⌘V,把剪贴板内容粘到当前 key App 的光标处。
    /// - Note: 需要辅助功能权限。调用前已通过 `activate` 让目标 App 成为 key 窗口,
    ///   CGEvent 才能送达(否则事件会被 Echo 自己吞掉)。
    private func simulateCmdV() {
        let source = CGEventSource(stateID: .hidSystemState)
        // V 键 keycode = 9,Command 修饰键
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyUp?.flags = .maskCommand
        // .cgSessionEventTap:注入当前图形会话,等价于真实按键
        keyDown?.post(tap: .cgSessionEventTap)
        keyUp?.post(tap: .cgSessionEventTap)
    }
}
