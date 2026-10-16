import AppKit
import MarkdownConversion

/// Executable checks avoid requiring XCTest, which is absent from CLT-only installs.
func checkStoredInputs() -> Bool {
    var success = true
    func check(_ name: String, _ assertion: () throws -> Bool) {
        do {
            let passed = try assertion()
            print("\(passed ? "PASS" : "FAIL") \(name)")
            success = success && passed
        } catch { print("FAIL \(name): \(error)"); success = false }
    }
    check("保存的纯文本保留空白和 Markdown") {
        let text = "  # markdown\n\tcode\n"
        let input = try Input.stored(rawText: text, representations: [:])
        return input.html == nil && input.source == text
    }
    check("历史 HTML 优先于 RTF，独立于当前剪贴板") {
        let html = "<h2>Historical selection</h2>"
        return try Input.stored(rawText: "fallback", representations: [
            NSPasteboard.PasteboardType.html.rawValue: Data(html.utf8),
            NSPasteboard.PasteboardType.rtf.rawValue: Data("invalid RTF".utf8)
        ]).html == html
    }
    check("损坏富文本明确报错") {
        do {
            _ = try Input.stored(rawText: "fallback", representations: [NSPasteboard.PasteboardType.rtf.rawValue: Data()])
            return false
        } catch { return true }
    }
    check("保存的 RTF 经系统导出 HTML") {
        let value = NSAttributedString(string: "Saved text", attributes: [.link: URL(string: "https://example.com")!])
        let data = try value.data(from: NSRange(location: 0, length: value.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let input = try Input.stored(rawText: value.string, representations: [NSPasteboard.PasteboardType.rtf.rawValue: data])
        return input.html?.contains("https://example.com") == true && input.html?.contains("Saved text") == true
    }
    return success
}
