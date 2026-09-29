import AppKit
import ApplicationServices

/// Best-effort provenance via Accessibility; never reads page text or changes focus.
final class BrowserSourceReader {
    static let shared = BrowserSourceReader()
    private let queue = DispatchQueue(label: "com.akira82.echo.browser-source", qos: .utility)
    private var busy = false
    private let browsers: Set<String> = ["com.apple.Safari", "com.google.Chrome",
        "com.microsoft.edgemac", "com.citrolabs.ego.lite"]

    func capture(app: NSRunningApplication?, changeCount: Int, completion: @escaping (BrowserSource?) -> Void) {
        guard !busy, AXIsProcessTrusted(), let app,
              browsers.contains(app.bundleIdentifier ?? "") else { completion(nil); return }
        busy = true
        let pid = app.processIdentifier
        let name = app.localizedName ?? "Browser"
        queue.async {
            let source = Self.read(pid: pid, name: name)
            DispatchQueue.main.async {
                self.busy = false
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      NSPasteboard.general.changeCount == changeCount else { completion(nil); return }
                completion(source)
            }
        }
    }

    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }

    private static func webURL(_ value: CFTypeRef?) -> URL? {
        let text: String
        if let url = value as? URL { text = url.absoluteString }
        else if let string = value as? String { text = string }
        else { return nil }
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }

    private static func read(pid: pid_t, name: String) -> BrowserSource? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        guard let value = attribute(app, kAXFocusedWindowAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let window = unsafeBitCast(value, to: AXUIElement.self)
        let title = attribute(window, kAXTitleAttribute) as? String ?? ""
        func source(_ url: URL) -> BrowserSource { BrowserSource(browserName: name, url: url, title: title) }
        if let url = webURL(attribute(window, kAXDocumentAttribute)) { return source(url) }
        var elements = [window]
        var index = 0
        let deadline = Date().addingTimeInterval(0.5)
        var addressURL: URL?
        while index < elements.count && index < 160 && Date() < deadline {
            let element = elements[index]
            index += 1
            let role = attribute(element, kAXRoleAttribute) as? String ?? ""
            if role == "AXWebArea" {
                if let url = webURL(attribute(element, "AXURL")) { return source(url) }
                continue
            }
            if role == "AXTextField", (attribute(element, kAXFocusedAttribute) as? Bool) != true {
                let hint = ((attribute(element, "AXIdentifier") as? String ?? "") + " " +
                    (attribute(element, kAXDescriptionAttribute) as? String ?? "")).lowercased()
                if ["address", "location", "url", "地址", "网址"].contains(where: hint.contains) {
                    addressURL = webURL(attribute(element, kAXValueAttribute))
                }
            }
            if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                elements.append(contentsOf: children.prefix(max(0, 160 - elements.count)))
            }
        }
        return addressURL.map(source)
    }
}
