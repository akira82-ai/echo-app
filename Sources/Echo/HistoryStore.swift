import Foundation

/// 剪贴板历史的内存环形队列:采集链路的存储核心。
///
/// 设计要点(详见 design-plan.html 板块2、3):
/// - **纯内存,不持久化**:App 重启即清空(符合"每次启动即初始化"约束)
/// - **共享名额**:文本/图片/文件共用一个上限(默认 50,可配置)
/// - **去重**:连续两次相同 deduplicationKey → 不新增,但更新时间戳置顶
/// - **淘汰删盘**:被挤出上限的图片条目,同步删掉 ImageCache 盘文件,避免膨胀
/// - **线程安全**:所有状态访问走串行队列,UI 读快照用 sync
///
/// 新条目插在**队首**(index 0),列表显示按"最近在前"。
/// 这样数字直达语义自然:第 1 条 = 最近复制的。
final class HistoryStore {
    static let shared = HistoryStore()

    /// 状态变化通知名:HistoryStore 内容变化后发出,UI 订阅刷新。
    static let didChangeNotification = Notification.Name("EchoHistoryStoreDidChange")

    /// 保护共享状态的串行队列
    private let queue = DispatchQueue(label: "com.akira82.echo.history")

    /// 实际存储(队首 = 最近)。初始空。
    private var entries: [ClipEntry] = []

    /// 上一次入队条目的去重 key,用于跳过连续重复
    private var lastDeduplicationKey: String?

    private init() {}

    // MARK: - 入队

    /// 入队一条新内容。
    ///
    /// 去重策略:与最近一条 deduplicationKey 相同 → 不新增,但更新该条时间戳并置顶;
    /// 不同 → 插入队首,超出上限则淘汰队尾(若是图片则删盘)。
    ///
    /// - Parameter entry: 新读取的条目
    func append(_ entry: ClipEntry) {
        queue.async { [weak self] in
            guard let self else { return }

            let key = entry.deduplicationKey

            if key == self.lastDeduplicationKey {
                // 连续重复:把已有那条移到队首并更新时间戳(用户期望"最近"在最上)
                if let idx = self.entries.firstIndex(where: { $0.deduplicationKey == key }) {
                    let existing = self.entries.remove(at: idx)
                    // 保留原 id(稳定身份),只更新时间戳到最新
                    let refreshed = ClipEntry(kind: existing.kind, timestamp: entry.timestamp, id: existing.id)
                    self.entries.insert(refreshed, at: 0)
                    self.notifyChange()
                }
                return
            }

            // 新内容:插入队首
            self.lastDeduplicationKey = key
            self.entries.insert(entry, at: 0)

            // 超出上限:从队尾淘汰(最旧的)
            self.evictIfNeeded()

            self.notifyChange()
        }
    }

    /// 超过上限时,从队尾(最旧)淘汰,并删除被淘汰图片的盘文件。
    private func evictIfNeeded() {
        let limit = AppSettings.shared.historyLimit
        while entries.count > limit {
            let removed = entries.removeLast()
            // 图片被淘汰 → 删盘文件,避免磁盘膨胀
            if case .image(let ref) = removed.kind {
                ImageCache.shared.remove(at: ref.diskPath)
            }
        }
    }

    // MARK: - 读快照

    /// 返回当前历史的快照(队首 = 最近)。UI 列表用。
    /// 用 sync 保证读到一致状态;调用方可在任意线程。
    func snapshot() -> [ClipEntry] {
        queue.sync { entries }
    }

    /// 当前条数。
    var count: Int {
        queue.sync { entries.count }
    }

    /// 取第 N 条(1-based;1 = 最近一条)。越界返回 nil。
    /// 数字直达粘贴用。
    func entry(atOneBased index: Int) -> ClipEntry? {
        queue.sync {
            // 用户语义:第 1 条 = 队首(最近)
            let zero = index - 1
            guard zero >= 0, zero < entries.count else { return nil }
            return entries[zero]
        }
    }

    // MARK: - 清空

    /// 清空所有历史,并删除所有图片盘文件。
    func clearAll() {
        queue.async { [weak self] in
            guard let self else { return }
            // 先删所有图片盘文件
            for entry in self.entries {
                if case .image(let ref) = entry.kind {
                    ImageCache.shared.remove(at: ref.diskPath)
                }
            }
            self.entries.removeAll()
            self.lastDeduplicationKey = nil
            self.notifyChange()
        }
    }

    // MARK: - 通知

    /// 在主线程发出内容变化通知(UI 订阅刷新)。
    private func notifyChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }
}
