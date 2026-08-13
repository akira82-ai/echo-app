import Foundation

/// 剪贴板历史的内存环形队列:采集链路的存储核心。
///
/// 设计要点(详见 design-plan.html 板块2、3):
/// - **纯内存,不持久化**:App 重启即清空(符合"每次启动即初始化"约束)
/// - **共享名额**:文本/图片/文件共用一个上限(默认 50,可配置)
/// - **去重**:文本/文件在全历史中去重,保留最新复制;图片只做连续重复去重
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

    /// 上一次入队条目的 key,用于图片的连续重复处理
    private var lastDeduplicationKey: String?

    private init() {}

    // MARK: - 入队

    /// 入队一条新内容。
    ///
    /// 去重策略:文本/文件扫描全历史并移除相同旧条目;图片仅在连续重复时更新时间戳并置顶;
    /// 非重复内容插入队首,超出上限则淘汰队尾(若是图片则删盘)。
    ///
    /// - Parameter entry: 新读取的条目
    func append(_ entry: ClipEntry) {
        queue.async { [weak self] in
            guard let self else { return }

            let key = entry.deduplicationKey

            // 文本和文件地址全历史去重:移除所有旧副本,再保留本次最新条目。
            // 该操作与插入处于同一串行队列内,UI 只收到一次变更通知。
            if let historicalKey = entry.historicalDeduplicationKey {
                let wasDuplicate = self.entries.contains { $0.historicalDeduplicationKey == historicalKey }
                self.entries.removeAll { $0.historicalDeduplicationKey == historicalKey }
                self.lastDeduplicationKey = historicalKey
                self.entries.insert(entry, at: 0)
                self.evictIfNeeded()
                if wasDuplicate { AchievementStore.shared.recordDuplicateHit() }
                self.notifyChange()
                return
            }

            if key == self.lastDeduplicationKey {
                // 图片保持旧策略:连续重复时保留原 id,更新时间戳并置顶。
                if let idx = self.entries.firstIndex(where: { $0.deduplicationKey == key }) {
                    let existing = self.entries.remove(at: idx)
                    // 保留原 id(稳定身份),只更新时间戳到最新
                    let refreshed = ClipEntry(kind: existing.kind, timestamp: entry.timestamp, id: existing.id)
                    self.entries.insert(refreshed, at: 0)
                    AchievementStore.shared.recordDuplicateHit()
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

    // MARK: - 删除单条

    /// 删除指定 id 的条目;图片条目同步删盘文件。
    /// 走与 append/clearAll 相同的串行队列,保证线程安全。
    func remove(id: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let idx = self.entries.firstIndex(where: { $0.id == id }) else { return }
            let removed = self.entries.remove(at: idx)
            AchievementStore.shared.recordDelete()
            // 图片被删 → 删盘文件(照搬 evictIfNeeded / clearAll 的模式)
            if case .image(let ref) = removed.kind {
                ImageCache.shared.remove(at: ref.diskPath)
            }
            // 若删的恰好是队首(最近一条),清掉去重锚点,
            // 否则下一条与已删条目内容相同时会被误判为连续重复而跳过采集
            if idx == 0 {
                self.lastDeduplicationKey = nil
            }
            self.notifyChange()
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
