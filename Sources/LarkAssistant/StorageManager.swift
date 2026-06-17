import Foundation

/// 负责把剪贴内容追加写入到 ~/Downloads/clippings_YYYY-MM-DD.md
/// 每天一个文件，每次插入一条带时间戳的记录。
final class StorageManager {
    static let shared = StorageManager()

    /// 存放目录，默认 ~/Downloads
    let directoryURL: URL

    private init(directoryURL: URL? = nil) {
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.directoryURL = home.appendingPathComponent("Downloads")
        }
    }

    /// 根据给定日期生成当天文件 URL
    /// - Parameter date: 日期（默认当前）
    /// - Returns: 如 ~/Downloads/clippings_2026-06-17.md
    func fileURL(for date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let fileName = "clippings_\(formatter.string(from: date)).md"
        return directoryURL.appendingPathComponent(fileName)
    }

    /// 追加一条记录到当天文件
    /// - Parameters:
    ///   - content: 剪贴文本内容
    ///   - date: 时间戳（默认当前）
    /// - Throws: 文件写入失败时抛错
    func append(content: String, at date: Date = Date()) throws {
        // 确保目录存在
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let url = fileURL(for: date)
        let entry = formatEntry(content: content, at: date)

        // 追加写入；文件不存在时自动创建
        let handle: FileHandle
        if FileManager.default.fileExists(atPath: url.path) {
            handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
        } else {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try FileHandle(forWritingTo: url)
        }
        defer { try? handle.close() }

        guard let data = entry.data(using: .utf8) else { return }
        try handle.write(contentsOf: data)
    }

    /// 格式化单条 Markdown 记录
    private func formatEntry(content: String, at date: Date) -> String {
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.timeZone = TimeZone.current
        let timestamp = timeFormatter.string(from: date)

        let body = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        ---
        🕐 \(timestamp)

        \(body)

        """
    }
}
