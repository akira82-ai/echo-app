import AppKit

/// 从系统剪贴板读取选中文本，并对连续相同内容做去重。
final class ClipboardManager {
    static let shared = ClipboardManager()

    /// 上一次记录的内容，用于去重
    private var lastContent: String = ""

    private init() {}

    /// 读取剪贴板当前文本。
    /// 若剪贴板为空、或与上次记录完全相同，则返回 nil（表示应跳过本次）。
    /// - Returns: 去重后的文本内容，或 nil
    func readAndDeduplicate() -> String? {
        guard let raw = NSPasteboard.general.string(forType: .string) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 去重：与上一条相同则跳过
        if trimmed == lastContent {
            return nil
        }
        lastContent = trimmed
        return trimmed
    }

    /// 重置去重缓存（例如应用重启后或手动触发）。
    func resetDeduplication() {
        lastContent = ""
    }
}
