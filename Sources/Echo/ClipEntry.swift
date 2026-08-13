import Foundation
import AppKit
import CryptoKit

/// 剪贴板历史项的统一模型。
///
/// 三种来源用枚举贯穿整条链路(读取 → 存储 → 粘贴),避免在各处用字符串判断类型:
/// - `.text`   普通 App 中选中的文本(统一纯文本,主动丢弃 RTF/HTML)
/// - `.image`  截图、浏览器复制的图片像素数据(原图落盘,内存只持缩略图引用)
/// - `.files`  Finder 中复制的本地文件(零拷贝,只存 URL 路径)
///
/// 设计要点:
/// - `id` 用 UUID,作为 SwiftUI 列表的稳定身份
/// - 文本/文件使用精确内容标识进行全历史去重;图片只在连续重复时去重
/// - `ImageRef` 只是「磁盘引用 + 内存缩略图」,不持有原图数据,内存占用恒定
struct ClipEntry: Identifiable {
    let id: UUID
    let kind: Kind
    let timestamp: Date

    init(kind: Kind, timestamp: Date = Date(), id: UUID = UUID()) {
        self.kind = kind
        self.timestamp = timestamp
        self.id = id
    }

    enum Kind {
        /// 纯文本(已 trim)
        case text(String)
        /// 图片(原图 PNG 在磁盘,内存只持缩略图)
        case image(ImageRef)
        /// 本地文件 URL(一个或多个,零拷贝)
        case files([URL])
    }

    /// 用于现有连续重复判断的 key。图片也使用这个 key。
    var deduplicationKey: String {
        switch kind {
        case .text(let body):
            // 文本去重 key 用内容前缀 + 长度,避免超长文本拼 key 浪费内存
            // (剪贴板文本通常不会到需要哈希的程度,直接用内容即可;
            //  但为防御极端长文本,取前 4096 字符 + 全长作为指纹)
            let prefix = body.prefix(4096)
            return "text:\(prefix)|len:\(body.count)"
        case .image(let ref):
            // 图片用 SHA256(像素完全一致才算重复)
            return "image:\(ref.contentHash)"
        case .files(let urls):
            // 排序后拼接路径,保证不同选中顺序但相同的一批文件能正确去重
            let paths = urls.map(\.path).sorted().joined(separator: "\n")
            return "files:\(paths)"
        }
    }

    /// 文本和文件参与全历史去重的精确 key;图片返回 nil,保持原有策略。
    /// 文本使用完整内容哈希,避免仅比较前缀导致不同内容误判为重复。
    var historicalDeduplicationKey: String? {
        switch kind {
        case .text(let body):
            let hash = SHA256.hash(data: Data(body.utf8))
            let hex = hash.map { String(format: "%02x", $0) }.joined()
            return "text:\(hex)"
        case .files(let urls):
            let paths = urls
                .map { $0.standardizedFileURL.path }
                .sorted()
                .joined(separator: "\n")
            return "files:\(paths)"
        case .image:
            return nil
        }
    }
}

/// 图片的磁盘引用 + 内存缩略图。
///
/// 原图 PNG 落在 `~/Library/Caches/Echo/images/{uuid}.png`,由 `ImageCache` 管理。
/// 本类型只持有「指回去的路径」和「UI 显示用的缩略图」,因此 50 条全图片也不会爆内存。
/// 粘贴时由 Paster 通过 `NSImage(contentsOf:)` 按需读回原图。
struct ImageRef: Equatable {
    /// 原图 PNG 在磁盘的绝对路径
    let diskPath: URL
    /// 用于 UI 列表预览的缩略图(~128px)
    let thumbnail: NSImage
    /// 原图内容的 SHA256 十六进制(去重 key)
    let contentHash: String
    /// 人类可读的尺寸描述,如 "1024 × 768"
    let sizeText: String

    /// Equatable 只比较稳定字段(thumbnail 的 NSImage 比较无意义且可能误判)
    static func == (lhs: ImageRef, rhs: ImageRef) -> Bool {
        lhs.contentHash == rhs.contentHash && lhs.diskPath == rhs.diskPath
    }
}

// MARK: - ImageRef 构造(由 ImageCache 调用)

extension ImageRef {
    /// 从 PNG 数据构造引用:计算哈希、生成尺寸文本、生成缩略图。
    /// 原图落盘由 ImageCache 负责,这里只产出引用所需的内存部分。
    /// - Parameters:
    ///   - pngData: 原始 PNG 编码数据
    ///   - diskPath: 已落盘的原图路径
    static func make(pngData: Data, diskPath: URL) -> ImageRef? {
        // SHA256 作为去重 key(像素完全一致才算重复)
        let hash = SHA256.hash(data: pngData)
        let hashHex = hash.map { String(format: "%02x", $0) }.joined()

        // 从 PNG 数据解码出 NSImage,取像素尺寸并生成缩略图
        guard let fullImage = NSImage(data: pngData) else { return nil }
        let sizeText = Self.formatPixelSize(fullImage)
        let thumbnail = Self.makeThumbnail(from: fullImage)

        return ImageRef(
            diskPath: diskPath,
            thumbnail: thumbnail,
            contentHash: hashHex,
            sizeText: sizeText
        )
    }

    /// 把 NSImage 的像素尺寸格式化为 "W × H"
    private static func formatPixelSize(_ image: NSImage) -> String {
        // NSImage.representations 里取像素尺寸最准
        let rep = image.representations.first
        let w = rep?.pixelsWide ?? Int(image.size.width)
        let h = rep?.pixelsHigh ?? Int(image.size.height)
        return "\(w) × \(h)"
    }

    /// 生成 ~128px 的缩略图(保持比例,长边缩到 128)。
    /// 缩略图放内存供列表显示,避免列表加载几十张原图卡顿。
    private static func makeThumbnail(from image: NSImage) -> NSImage {
        let maxSize: CGFloat = 128
        let originalSize = image.size
        // 已是小图则不放大
        guard max(originalSize.width, originalSize.height) > maxSize else { return image }

        let scale = maxSize / max(originalSize.width, originalSize.height)
        let newSize = NSSize(
            width: max(1, (originalSize.width * scale).rounded()),
            height: max(1, (originalSize.height * scale).rounded())
        )

        let thumb = NSImage(size: newSize)
        thumb.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: newSize),
            from: NSRect(origin: .zero, size: originalSize),
            operation: .copy,
            fraction: 1.0
        )
        thumb.unlockFocus()
        return thumb
    }
}
