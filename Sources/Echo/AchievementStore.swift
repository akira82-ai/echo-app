import Foundation

/// 本地长期使用统计。只保存行为计数和日期，不保存剪贴板正文、文件路径或图片数据。
final class AchievementStore {
    static let shared = AchievementStore()

    static let didChangeNotification = Notification.Name("EchoAchievementStoreDidChange")

    struct Snapshot: Equatable {
        let successfulPastes: Int
        let directPastes: Int
        let searchPastes: Int
        let hotkeyShows: Int
        let keyboardOnlyStreak: Int
        let pagedPastes: Int
        let manualDeletes: Int
        let deletedEntries: Int
        let duplicateHits: Int
        let activeDays: Set<String>
        let activeQuarters: Set<String>

        var activeDayCount: Int { activeDays.count }
        var activeQuarterCount: Int { activeQuarters.count }
    }

    struct Medal: Identifiable {
        enum Tone {
            case accent, green, yellow, purple
        }

        let id: String
        let icon: String
        let name: String
        let tone: Tone
        let progress: String?
        let unlocked: Bool
    }

    private struct StoredStats: Codable {
        var successfulPastes = 0
        var directPastes = 0
        var searchPastes = 0
        var hotkeyShows = 0
        var keyboardOnlyStreak = 0
        var pagedPastes = 0
        var manualDeletes = 0
        var deletedEntries = 0
        var duplicateHits = 0
        var activeDays: Set<String> = []
        var activeQuarters: Set<String> = []
    }

    private enum Key {
        static let stats = "achievementStats"
    }

    private let defaults = UserDefaults.standard
    private let queue = DispatchQueue(label: "com.akira82.echo.achievements")
    private var stored: StoredStats

    private init() {
        if let data = defaults.data(forKey: Key.stats),
           let decoded = try? JSONDecoder().decode(StoredStats.self, from: data) {
            stored = decoded
        } else {
            stored = StoredStats()
        }
    }

    func snapshot() -> Snapshot {
        queue.sync { makeSnapshot(stored) }
    }

    func medals() -> [Medal] {
        let stats = snapshot()
        return [
            Medal(id: "first-paste", icon: "↩", name: "初次回声", tone: .accent,
                  progress: stats.successfulPastes == 0 ? nil : "\(min(stats.successfulPastes, 1)) / 1",
                  unlocked: stats.successfulPastes >= 1),
            Medal(id: "direct", icon: "1-5", name: "数字直达", tone: .green,
                  progress: "\(min(stats.directPastes, 20)) / 20", unlocked: stats.directPastes >= 20),
            Medal(id: "search", icon: "⌕", name: "搜索命中", tone: .yellow,
                  progress: "\(min(stats.searchPastes, 10)) / 10", unlocked: stats.searchPastes >= 10),
            Medal(id: "hotkey", icon: "⌘", name: "快捷上手", tone: .purple,
                  progress: "\(min(stats.hotkeyShows, 3)) / 3", unlocked: stats.hotkeyShows >= 3),
            Medal(id: "keyboard", icon: "⌨", name: "键盘熟练", tone: .accent,
                  progress: "\(min(stats.keyboardOnlyStreak, 3)) / 3", unlocked: stats.keyboardOnlyStreak >= 3),
            Medal(id: "paging", icon: "↔", name: "翻页探索", tone: .green,
                  progress: "\(min(stats.pagedPastes, 10)) / 10", unlocked: stats.pagedPastes >= 10),
            Medal(id: "first-delete", icon: "⌫", name: "首次整理", tone: .yellow,
                  progress: nil, unlocked: stats.manualDeletes >= 1),
            Medal(id: "clean-space", icon: "✦", name: "清爽空间", tone: .purple,
                  progress: "\(min(stats.deletedEntries, 20)) / 20", unlocked: stats.deletedEntries >= 20),
            Medal(id: "dedup", icon: "◎", name: "去重助手", tone: .accent,
                  progress: "\(min(stats.duplicateHits, 20)) / 20", unlocked: stats.duplicateHits >= 20),
            Medal(id: "steady", icon: "30", name: "稳定使用", tone: .green,
                  progress: "\(min(stats.activeDayCount, 30)) / 30 天", unlocked: stats.activeDayCount >= 30),
            Medal(id: "seasons", icon: "4Q", name: "四季回声", tone: .yellow,
                  progress: "\(min(stats.activeQuarterCount, 4)) / 4 季", unlocked: stats.activeQuarterCount >= 4),
            Medal(id: "long-term", icon: "365", name: "长久回声", tone: .purple,
                  progress: "\(min(stats.activeDayCount, 365)) / 365 天", unlocked: stats.activeDayCount >= 365)
        ]
    }

    func recordPanelShown() {
        mutate { stats in
            stats.activeDays.insert(Self.dayKey(for: Date()))
            stats.activeQuarters.insert(Self.quarterKey(for: Date()))
        }
    }

    func recordHotkeyShow() {
        mutate { stats in
            stats.hotkeyShows += 1
        }
    }

    func recordPaste(mode: PasteMode, source: SelectionSource, paged: Bool) {
        mutate { stats in
            stats.successfulPastes += 1
            if mode == .direct { stats.directPastes += 1 }
            if mode == .search { stats.searchPastes += 1 }
            if source == .keyboard {
                stats.keyboardOnlyStreak += 1
            } else {
                stats.keyboardOnlyStreak = 0
            }
            if paged { stats.pagedPastes += 1 }
            stats.activeDays.insert(Self.dayKey(for: Date()))
            stats.activeQuarters.insert(Self.quarterKey(for: Date()))
        }
    }

    func recordDelete() {
        mutate { stats in
            stats.manualDeletes += 1
            stats.deletedEntries += 1
        }
    }

    func recordDuplicateHit() {
        mutate { stats in
            stats.duplicateHits += 1
        }
    }

    func reset() {
        queue.sync {
            stored = StoredStats()
            persist(stored)
        }
        notifyChange()
    }

    enum PasteMode: Equatable {
        case browse, direct, search
    }

    enum SelectionSource: Equatable {
        case mouse, keyboard
    }

    struct SelectionContext {
        let mode: PasteMode
        let source: SelectionSource
        let paged: Bool
    }

    private func mutate(_ mutation: @escaping (inout StoredStats) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            mutation(&self.stored)
            self.persist(self.stored)
            self.notifyChange()
        }
    }

    private func persist(_ stats: StoredStats) {
        guard let data = try? JSONEncoder().encode(stats) else { return }
        defaults.set(data, forKey: Key.stats)
    }

    private func notifyChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    private func makeSnapshot(_ stats: StoredStats) -> Snapshot {
        Snapshot(
            successfulPastes: stats.successfulPastes,
            directPastes: stats.directPastes,
            searchPastes: stats.searchPastes,
            hotkeyShows: stats.hotkeyShows,
            keyboardOnlyStreak: stats.keyboardOnlyStreak,
            pagedPastes: stats.pagedPastes,
            manualDeletes: stats.manualDeletes,
            deletedEntries: stats.deletedEntries,
            duplicateHits: stats.duplicateHits,
            activeDays: stats.activeDays,
            activeQuarters: stats.activeQuarters
        )
    }

    private static func dayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func quarterKey(for date: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        let quarter = ((month - 1) / 3) + 1
        return "\(year)-Q\(quarter)"
    }
}
