import AppKit

/// 剪贴板读取器:从 NSPasteboard 读取当前内容并分类为 ClipEntry.Kind。
///
/// 这是采集链路的"分类器"。ClipboardWatcher 在检测到 changeCount 变化后调用本类。
///
/// 分类顺序很关键(避免误判,详见 design-plan.html 板块4):
/// 1. **文件 URL 优先**:Finder 复制的 .png 文件也带图片数据,
///    若不优先判 URL,会把文件误当像素图片抓。
/// 2. **图片像素数据**:截图、浏览器右键复制图片(.tiff / .png)。
/// 3. **文本表示**:保存纯文本、HTML、RTF、URL等标准表示,供后续按模式粘贴。
///
/// 安全过滤:带 `org.nspasteboard.ConcealedType` 标记的敏感项(密码管理器)
/// 一律跳过,不入历史。
///
/// - Note: `NSPasteboard` 是主线程 API,本类的所有方法必须在主线程调用。
final class ClipboardReader {
    static let shared = ClipboardReader()

    private init() {}

    /// 读取当前剪贴板内容并分类。
    ///
    /// 流程:敏感项过滤 → 文件 URL → 图片 → 文本。
    /// - Returns: 分类后的 entry;剪贴板为空 / 敏感内容 / 不支持的类型时返回 nil。
    /// - Note: 必须在主线程调用。
    func read() -> ClipEntry? {
        let pb = NSPasteboard.general

        // 1. 敏感内容过滤:密码管理器(1Password 等)会标记 ConcealedType,
        //    这类内容绝不应被记录进历史。
        if isConcealed(pb) { return nil }

        // 2. 文件 URL 优先(Finder 复制的本地文件,零拷贝)
        if let filesEntry = readFileURLsIfPresent(pb) {
            return filesEntry
        }

        // 3. 图片像素数据(截图、浏览器复制图片)
        if let imageEntry = readImageIfPresent(pb) {
            return imageEntry
        }

        // 4. 文本表示(保存纯文本、HTML、RTF、URL等标准格式)
        if let textEntry = readTextIfPresent(pb) {
            return textEntry
        }

        return nil
    }

    // MARK: - 敏感内容过滤

    /// 检查剪贴板是否被标记为敏感(如密码管理器临时写入的内容)。
    /// 用 `org.nspasteboard.ConcealedType` 与 `org.nspasteboard.TransientType` 判断:
    /// - ConcealedType:内容应被隐藏,不记录
    /// - TransientType:内容是临时的(如密码管理器设定几秒后自动清空),也不记录
    private func isConcealed(_ pb: NSPasteboard) -> Bool {
        guard let types = pb.types else { return false }
        let concealed = NSPasteboard.PasteboardType(rawValue: "org.nspasteboard.ConcealedType")
        let transient = NSPasteboard.PasteboardType(rawValue: "org.nspasteboard.TransientType")
        return types.contains(concealed) || types.contains(transient)
    }

    // MARK: - 文件 URL

    /// 尝试读取剪贴板中的本地文件 URL。
    private func readFileURLsIfPresent(_ pb: NSPasteboard) -> ClipEntry? {
        guard let objects = pb.readObjects(forClasses: [NSURL.self], options: nil) else {
            return nil
        }
        let fileURLs = objects
            .compactMap { $0 as? URL }
            .filter(\.isFileURL)
        guard !fileURLs.isEmpty else { return nil }
        return ClipEntry(kind: .files(fileURLs))
    }

    // MARK: - 图片

    /// 尝试读取剪贴板中的图片像素数据(.tiff / .png)。
    /// 仅当剪贴板含图片数据类型时才读;文件 URL 已在上一步处理。
    private func readImageIfPresent(_ pb: NSPasteboard) -> ClipEntry? {
        // 判断是否含图片像素数据类型(非文件)
        guard let types = pb.types else { return nil }
        let hasImage = types.contains(.tiff) || types.contains(.png)
        guard hasImage else { return nil }

        // 读出 NSImage,转成 PNG 数据落盘 + 生成缩略图引用
        guard let image = pb.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage else {
            return nil
        }

        // NSImage → PNG 数据(用 tiffRepresentation 再转 png,保证拿到像素数据)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let pngData = rep.representation(using: .png, properties: [:]) else {
            return nil
        }

        // 落盘 + 构造引用;失败则跳过(不让单张图片失败拖垮采集)
        guard let ref = ImageCache.shared.store(pngData: pngData) else {
            return nil
        }
        return ClipEntry(kind: .image(ref))
    }

    // MARK: - 文本与格式

    /// 尝试读取剪贴板中的文本,同时保存标准格式表示。
    /// `rawText` 保留原始空格、换行和缩进;规范化文本只用于展示和去重。
    private func readTextIfPresent(_ pb: NSPasteboard) -> ClipEntry? {
        guard let raw = pb.string(forType: .string) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let representations = captureTextRepresentations(from: pb, rawText: raw)
        return ClipEntry(
            kind: .text(
                TextPayload(
                    rawText: raw,
                    representations: representations
                )
            )
        )
    }

    /// 只保存常见标准表示,不扩大到应用私有类型。
    /// 这些类型覆盖富文本、网页链接、表格结构和代码原文场景。
    private func captureTextRepresentations(from pb: NSPasteboard, rawText: String) -> [PasteboardRepresentation] {
        let supportedTypes = [
            NSPasteboard.PasteboardType.string.rawValue,
            "public.utf16-plain-text",
            "public.rtf",
            "public.html",
            "public.url"
        ]

        guard let item = pb.pasteboardItems?.first else {
            return [PasteboardRepresentation(
                typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
                data: Data(rawText.utf8)
            )]
        }

        var representations = supportedTypes.compactMap { typeIdentifier -> PasteboardRepresentation? in
            let type = NSPasteboard.PasteboardType(rawValue: typeIdentifier)
            guard let data = item.data(forType: type) else { return nil }
            return PasteboardRepresentation(typeIdentifier: typeIdentifier, data: data)
        }

        // 某些来源只提供 string API,但没有暴露对应的 pasteboard item 数据。
        // 始终保留纯文本兜底,保证历史条目仍可粘贴。
        if !representations.contains(where: { $0.typeIdentifier == NSPasteboard.PasteboardType.string.rawValue }) {
            representations.insert(
                PasteboardRepresentation(
                    typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
                    data: Data(rawText.utf8)
                ),
                at: 0
            )
        }
        return representations
    }
}
