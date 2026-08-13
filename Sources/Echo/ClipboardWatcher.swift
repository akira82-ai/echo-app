import Foundation
import AppKit

/// 剪贴板变化监听器:轮询 NSPasteboard.general.changeCount,变化时触发采集。
///
/// 设计依据(详见 design-plan.html 板块3「changeCount 轮询」):
/// - 监听「剪贴板本身」而非「按键」,覆盖所有复制来源(右键/剪切/拖拽/快捷键)
/// - **零权限**:只用 NSPasteboard 公开 API + Timer
/// - 0.5s 延迟肉眼几乎无感,换来全覆盖 + 稳定(不会像 CGEventTap 被系统禁用)
/// - 这是 Maccy / Flycut / Paste 等所有同类工具的标准方案
///
/// 工作流:
/// 1. Timer 每 0.5s 在主线程触发(主线程访问 NSPasteboard 最安全)
/// 2. 比较 changeCount:变了 → 延迟一小段读剪贴板 → 分类 → 入历史
/// 3. 延迟读取是为了等系统把内容完整写入剪贴板(尤其图片)
///
/// 注意:我们自己写回剪贴板(Paster)也会触发 changeCount 变化,
/// 需要在写入前后做标记,避免把自己的"粘贴写回"误判为新复制。
final class ClipboardWatcher {
    static let shared = ClipboardWatcher()

    /// 轮询间隔(秒)。0.5s 是体验与电量的平衡点。
    static let pollInterval: TimeInterval = 0.5

    /// 读剪贴板前的短延迟(毫秒),等系统把内容写完整(图片尤其需要)。
    static let readDelayMs: Int = 80

    /// 上一次观测到的 changeCount
    private var lastChangeCount: Int

    /// 轮询定时器
    private var timer: Timer?

    /// 标记:Paster 写回剪贴板期间置 true,跳过这次 changeCount 变化的采集,
    /// 避免把自己粘出去的内容又记一遍。
    /// - Note: 用简单布尔而非 changeCount 比对,因为写回可能引发多次 changeCount 跳变。
    private var suppressNextChange = false

    private init() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    // MARK: - 生命周期

    /// 启动监听。在 AppDelegate 启动时调用一次。
    func start() {
        guard timer == nil else { return }
        // 记录启动时的 changeCount 基线,避免把启动前的旧内容误采
        lastChangeCount = NSPasteboard.general.changeCount

        let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // common 模式确保菜单打开、拖拽等场景下定时器仍触发
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 停止监听。
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - 采集抑制(供 Paster 调用)

    /// 在写回剪贴板前调用:抑制接下来这一次 changeCount 变化的采集。
    /// Paster 写入前调一次,防止把"粘贴写回"误记为新复制。
    func suppressNext() {
        suppressNextChange = true
    }

    /// 写回失败时撤销抑制,避免下一次真实复制被误跳过。
    func cancelSuppression() {
        suppressNextChange = false
    }

    // MARK: - 轮询

    /// 定时器回调:比较 changeCount,变化则触发采集。
    private func tick() {
        let current = NSPasteboard.general.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        // Paster 写回触发的变化 → 跳过
        if suppressNextChange {
            suppressNextChange = false
            return
        }

        // 延迟一小段再读,等系统把内容写完整
        let delay = Self.readDelayMs
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
            self?.captureCurrent()
        }
    }

    /// 读取当前剪贴板并入库。
    private func captureCurrent() {
        guard let entry = ClipboardReader.shared.read() else { return }
        HistoryStore.shared.append(entry)
    }
}
