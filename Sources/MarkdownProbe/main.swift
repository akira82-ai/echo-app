import AppKit
import SwiftUI
import WebKit

import MarkdownConversion
@MainActor
final class Model: ObservableObject {
    @Published var source = ""
    @Published var markdown = ""
    @Published var status = "复制网页、Word 或 Pages 的内容，再点击读取。"
    @Published var types = ""
    @Published var busy = false
    @Published var canCopy = false
    private let converter = Converter()

    func read() {
        types = (NSPasteboard.general.types ?? []).map(\.rawValue).joined(separator: ", ")
        do { run(try Input.clipboard()) }
        catch { status = error.localizedDescription; source = ""; markdown = ""; canCopy = false }
    }

    func run(_ input: Input) {
        busy = true; canCopy = false; source = input.source; markdown = ""; status = "转换中…"
        Task {
            defer { busy = false }
            do {
                markdown = try await converter.convert(input)
                status = input.path
                canCopy = true
            } catch { status = "转换失败：\(error.localizedDescription)" }
        }
    }

    func sample() {
        types = "内置 HTML 样本（不会修改剪贴板）"
        let html = "<h2>验证样本</h2><p><strong>加粗</strong>、<em>斜体</em>和<a href=\"https://example.com\">链接</a></p><ul><li>第一项<ul><li>子项</li></ul></li></ul><pre><code>let value = 42\n</code></pre><table><tr><td>名称</td><td>数量</td></tr><tr><td>苹果</td><td>3</td></tr></table>"
        run(Input(path: "内置 HTML → Turndown + GFM", source: html, html: html))
    }

    func copy() {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(markdown, forType: .string) { status = "Markdown 已复制，可切回原应用粘贴。" }
        else { status = "写入剪贴板失败。" }
    }

    func selfTest() async -> Bool {
        let cachePassed = await checkMarkdownCache()
        let cases: [(String, String, [String])] = [
            ("HTML 结构", "<h1>Hello</h1><p><strong>Bold</strong> <em>Italic</em> <a href=\"https://example.com\">Link</a></p>", ["# Hello", "**Bold**", "*Italic*", "[Link](https://example.com)"]),
            ("嵌套列表与代码", "<ul><li>one<ul><li>two</li></ul></li></ul><pre><code>x &lt; 3\n</code></pre>", ["-   one", "two", "```", "x < 3"]),
            ("无表头表格", "<table><tr><td>Name</td><td>Count</td></tr><tr><td>Apple</td><td>3</td></tr></table>", ["| Name | Count |", "| --- | --- |", "| Apple | 3 |"]),
            ("CSS 加粗与斜体", "<p><span style=\"font-weight: 700; font-style: italic\">Styled</span></p>", ["**", "*Styled*"]),
            ("CSS 类样式", "<style>.s1 { font: italic bold 14px Helvetica; }</style><p><span class=\"s1\">ClassStyle</span></p>", ["***ClassStyle***"]),
            ("不执行来源脚本", "<script>throw new Error(\"must not run\")</script><p>Safe</p>", ["Safe"])
        ]
        var success = checkStoredInputs() && cachePassed
        do {
            _ = try await converter.convert(Input(path: "merged", source: "", html: "<table><tr><td colspan=\"2\">merged</td></tr></table>"))
            print("FAIL 合并单元格应明确拒绝"); success = false
        } catch { print("PASS 合并单元格明确拒绝: \(error.localizedDescription)") }
        for (name, html, expected) in cases {
            do {
                let started = Date()
                let result = try await converter.convert(Input(path: name, source: html, html: html))
                let passed = expected.allSatisfy { result.contains($0) } && !result.contains("must not run")
                print("\(passed ? "PASS" : "FAIL") \(name) (\(Int(Date().timeIntervalSince(started) * 1000))ms)\n\(result)")
                success = success && passed
            } catch { print("FAIL \(name): \(error)"); success = false }
        }
        do {
            let original = "  keep\tspaces\n# already markdown\n"
            let result = try await converter.convert(Input(path: "text", source: original, html: nil))
            let passed = result == original
            print("\(passed ? "PASS" : "FAIL") 纯文本保真")
            success = success && passed
            let attributed = NSAttributedString(string: "Bold Link", attributes: [.font: NSFont.boldSystemFont(ofSize: 14), .link: URL(string: "https://example.com")!])
            let rtf = try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            let restored = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            let html = try restored.data(from: NSRange(location: 0, length: restored.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue])
            let resultRTF = try await converter.convert(Input(path: "RTF", source: "", html: String(decoding: html, as: UTF8.self)))
            let rtfPassed = resultRTF.contains("**") && resultRTF.contains("https://example.com") && resultRTF.contains("Bold Link")
            print("\(rtfPassed ? "PASS" : "FAIL") RTF → HTML → Markdown\n\(resultRTF)")
            success = success && rtfPassed
        } catch { print("FAIL RTF/text: \(error)"); success = false }
        let cancelled = Task { @MainActor in
            try await converter.convert(Input(path: "cancelled", source: "", html: "<p>must not paste</p>"))
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            print("FAIL 已取消的转换不应返回结果"); success = false
        } catch is CancellationError { print("PASS 已取消的转换不返回结果") }
        catch { print("FAIL 取消返回错误类型不符: \(error)"); success = false }
        return success
    }
}

struct ProbeView: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Echo · Markdown 转换验证").font(.title2)
            Text("本地转换；仅在点击“复制 Markdown”时写入剪贴板。图片附件、复杂表格和列表需人工检查。")
                .font(.callout).foregroundColor(.secondary)
            HStack {
                Button("读取剪贴板并转换") { model.read() }.keyboardShortcut("r")
                Button("加载示例") { model.sample() }
                Spacer()
                Button("复制 Markdown") { model.copy() }.disabled(!model.canCopy)
            }.disabled(model.busy)
            Text(model.status).font(.callout).textSelection(.enabled)
            Text("剪贴板格式：\(model.types)").font(.caption).foregroundColor(.secondary).lineLimit(3).textSelection(.enabled)
            HStack {
                VStack(alignment: .leading) {
                    Text("转换输入（HTML 或纯文本）")
                    TextEditor(text: .constant(model.source)).font(.system(.body, design: .monospaced))
                }
                VStack(alignment: .leading) {
                    Text("Markdown 输出")
                    TextEditor(text: .constant(model.markdown)).font(.system(.body, design: .monospaced))
                }
            }
        }.padding(20).frame(minWidth: 960, minHeight: 620)
    }
}

@MainActor
final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let model = Model()
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--self-test") {
            Task {
                let passed = await model.selfTest()
                fflush(stdout)
                exit(passed ? 0 : 1)
            }
            return
        }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Echo Markdown MVP"
        window.contentView = NSHostingView(rootView: ProbeView(model: model))
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = Delegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
