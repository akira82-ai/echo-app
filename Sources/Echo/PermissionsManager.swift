import AppKit
import ApplicationServices

/// 管理 macOS「辅助功能（Accessibility）」权限的检测与引导。
final class PermissionsManager {
    static let shared = PermissionsManager()

    /// 权限状态变化时的回调
    var onStatusChange: ((Bool) -> Void)?

    /// 轮询定时器
    private var pollTimer: Timer?

    /// 上一次的状态，避免重复回调
    private var lastStatus: Bool = false

    private init() {}

    /// 当前是否已获得辅助功能权限
    var isGranted: Bool {
        AXIsProcessTrusted()
    }

    /// 弹出系统授权弹窗（带「打开系统设置」按钮），引导用户授权。
    /// 若已授权则直接返回。
    func requestIfNeeded() {
        guard !isGranted else { return }
        // kAXTrustedCheckOptionPrompt = true 会让系统弹出授权引导弹窗
        let options: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ]
        _ = AXIsProcessTrustedWithOptions(options)
        startPolling()
    }

    /// 开始轮询权限状态（每 2 秒）。授权后停止轮询并回调。
    func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let current = self.isGranted
            if current != self.lastStatus {
                self.lastStatus = current
                self.onStatusChange?(current)
                if current {
                    self.stopPolling()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// 停止轮询
    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// 在系统设置中打开「隐私与安全性 → 辅助功能」面板
    func openSystemSettings() {
        // macOS 13+ 的路径
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
