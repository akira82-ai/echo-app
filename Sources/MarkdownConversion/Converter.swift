import AppKit
import WebKit

public enum ProbeError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

public struct Input {
    public let path: String
    public let source: String
    public let html: String?

    public init(path: String, source: String, html: String?) { self.path = path; self.source = source; self.html = html }

    public static func stored(rawText: String, representations: [String: Data]) throws -> Input {
        if let data = representations[NSPasteboard.PasteboardType.html.rawValue] {
            // NSPasteboardItem applies the same string decoding used by clipboard().
            let item = NSPasteboardItem()
            item.setData(data, forType: .html)
            guard let html = item.string(forType: .html), !html.isEmpty else {
                throw ProbeError.message("无法读取保存的 HTML。")
            }
            return Input(path: "HTML", source: html, html: html)
        }
        for (type, format) in [(NSPasteboard.PasteboardType.rtfd, NSAttributedString.DocumentType.rtfd), (.rtf, .rtf)] {
            if let data = representations[type.rawValue] {
                let value = try NSAttributedString(data: data, options: [.documentType: format], documentAttributes: nil)
                guard !value.containsAttachments else { throw ProbeError.message("图片附件尚不支持 Markdown 转换，请使用原格式粘贴。") }
                let data = try value.data(from: NSRange(location: 0, length: value.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue])
                guard let html = String(data: data, encoding: .utf8) else { throw ProbeError.message("无法读取富文本导出的 HTML。") }
                return Input(path: type.rawValue, source: html, html: html)
            }
        }
        return Input(path: "Text", source: rawText, html: nil)
    }

    public static func clipboard() throws -> Input {
        let pb = NSPasteboard.general
        let types = pb.types ?? []
        guard !types.contains(where: {
            ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"].contains($0.rawValue)
        }) else { throw ProbeError.message("剪贴板标记为敏感或临时内容，未读取。") }
        let supported: [NSPasteboard.PasteboardType] = [.html, .rtfd, .rtf]
        let representations = Dictionary(uniqueKeysWithValues: supported.compactMap { type in
            pb.data(forType: type).map { (type.rawValue, $0) }
        })
        if pb.string(forType: .string) != nil || !representations.isEmpty {
            return try stored(rawText: pb.string(forType: .string) ?? "", representations: representations)
        }
        throw ProbeError.message("未找到支持的文本格式。图片与文件不在本次验证范围。")
    }
}

@MainActor
public final class Converter: NSObject, WKNavigationDelegate {
    private var webView: WKWebView!
    private var loading: CheckedContinuation<Void, Error>?
    private var ready = false
    private var busy = false
    private var loadTimeout: Task<Void, Never>?

    private var resources: Bundle {
        if let url = Bundle.main.url(forResource: "Echo_MarkdownConversion", withExtension: "bundle"), let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }

    public override init() {
        super.init()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
    }

    private func prepare() async throws {
        if ready { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loading = continuation
            loadTimeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.loading?.resume(throwing: ProbeError.message("转换器初始化超时，请重试。"))
                self.loading = nil
                self.webView.stopLoading()
            }
            // Clipboard HTML is parsed in a detached document, never navigated to or executed.
            webView.loadHTMLString("<html><head><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'unsafe-eval'\"></head><body></body></html>", baseURL: nil)
        }
        for name in ["turndown-7.2.0", "turndown-gfm-1.0.2", "convert"] {
            guard let url = resources.url(forResource: name, withExtension: "js") else {
                throw ProbeError.message("缺少转换资源：\(name)")
            }
            _ = try await execute(String(contentsOf: url, encoding: .utf8))
        }
        ready = true
    }

    public func convert(_ input: Input) async throws -> String {
        try Task.checkCancellation()
        guard let html = input.html else { return input.source }
        guard !busy else { throw ProbeError.message("转换器正在处理上一项，请稍后重试。") }
        busy = true
        defer { busy = false }
        try await prepare()
        try Task.checkCancellation()
        let result: Any?
        do {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: [html]), as: UTF8.self)
            result = try await execute("convertClipboardHTML(\(json)[0]);")
        } catch {
            let detail = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
            throw ProbeError.message(detail ?? error.localizedDescription)
        }
        guard let markdown = result as? String else { throw ProbeError.message("转换器没有返回文本。") }
        try Task.checkCancellation()
        return markdown
    }

    private func execute(_ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            var completed = false
            let timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled, !completed else { return }
                completed = true
                self?.ready = false
                continuation.resume(throwing: ProbeError.message("转换超时，请缩小内容后重试。"))
            }
            webView.evaluateJavaScript(script) { result, error in
                guard !completed else { return }
                completed = true
                timeout.cancel()
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: result) }
            }
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadTimeout?.cancel()
        loading?.resume(); loading = nil
    }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadTimeout?.cancel()
        loading?.resume(throwing: error); loading = nil
    }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadTimeout?.cancel()
        loading?.resume(throwing: error); loading = nil
    }
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
        loadTimeout?.cancel()
        loading?.resume(throwing: ProbeError.message("转换进程已退出，请重试。")); loading = nil
    }
}
