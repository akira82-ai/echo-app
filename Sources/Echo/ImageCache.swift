import Foundation
import AppKit

/// 图片磁盘缓存:管理原图 PNG 的落盘、读取、删除与启动清空。
///
/// 设计依据(详见 design-plan.html 板块3「图片三态」):
/// 50 张截图原图可能几百 MB,内存扛不住。因此:
/// - **原图 PNG 落临时磁盘** `~/Library/Caches/Echo/images/`
/// - **内存只持缩略图**(~128px,几十 KB)
/// - **粘贴时按需读回原图**(`NSImage(contentsOf:)`)
/// - **App 启动清空整个目录**(符合"每次启动即初始化"约束)
/// - **历史淘汰时同步删盘**(挤出 50 名的图片不堆积垃圾)
///
/// 线程安全:`store` 涉及磁盘写,调用方应在后台队列;`purge` 同理。
/// 单例,生命周期与 App 相同。
final class ImageCache {
    static let shared = ImageCache()

    /// 图片缓存根目录:`~/Library/Caches/Echo/images/`
    /// 用系统的 cachesDirectory,macOS 会在低磁盘空间时自动清理。
    let directoryURL: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        self.directoryURL = caches
            .appendingPathComponent("Echo", isDirectory: true)
            .appendingPathComponent("images", isDirectory: true)
    }

    // MARK: - 启动清空

    /// 清空整个 images 目录(每次 App 启动时调用一次)。
    /// 符合"App 重启即初始化"约束:历史本就纯内存不持久化,
    /// 遗留的图片盘文件是上次运行的残留,无价值,直接清掉避免膨胀。
    /// - Note: 目录不存在不算错误。
    func purgeAll() {
        do {
            // 若目录存在则整体删除,下次 store 时会自动重建
            if FileManager.default.fileExists(atPath: directoryURL.path) {
                try FileManager.default.removeItem(at: directoryURL)
            }
        } catch {
            // 清空失败不应阻断启动,仅记日志
            NSLog("[Echo] ImageCache.purgeAll 失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 存原图

    /// 把原始 PNG 数据落盘,并构造一个内存引用(含缩略图与去重哈希)。
    /// - Parameter pngData: 原图 PNG 编码数据
    /// - Returns: 内存引用;落盘或解码失败返回 nil(调用方应跳过此条)
    /// - Note: 涉及磁盘写,调用方应在后台队列执行。
    func store(pngData: Data) -> ImageRef? {
        do {
            try ensureDirectoryExists()

            // 用 UUID 当文件名,避免并发或同名冲突
            let fileName = "\(UUID().uuidString).png"
            let fileURL = directoryURL.appendingPathComponent(fileName)
            try pngData.write(to: fileURL, options: .atomic)

            // 构造内存引用(含缩略图 + SHA256),原图数据不再持有
            return ImageRef.make(pngData: pngData, diskPath: fileURL)
        } catch {
            NSLog("[Echo] ImageCache.store 失败: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - 读原图

    /// 按需从磁盘读回原图(粘贴时用)。失败返回 nil,Paster 会静默降级。
    /// - Note: 涉及磁盘读,调用方应在后台或主线程均可(单次读很快)。
    func loadOriginal(at path: URL) -> NSImage? {
        NSImage(contentsOf: path)
    }

    // MARK: - 删原图

    /// 删除单个原图文件(历史条目被淘汰或清空时调用)。
    /// 文件不存在不算错误(可能已被 purge 清掉)。
    func remove(at path: URL) {
        try? FileManager.default.removeItem(at: path)
    }

    // MARK: - Private

    /// 确保缓存目录存在(惰性创建)。store 前调用。
    private func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }
}
