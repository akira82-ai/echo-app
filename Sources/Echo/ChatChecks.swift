import Foundation
import OpenAI
import AppKit

@MainActor
func runPromptRequestChecks(port: Int) async -> Bool {
    var configured = "First custom prompt"
    var reads = 0
    let state = ChatState(makeClient: {
        OpenAI(configuration: .init(token: nil, host: "127.0.0.1", port: port,
            scheme: "http", basePath: "/v1", timeoutInterval: 5, parsingOptions: .relaxed))
    }, modelName: { "mock" }, makeWeb: { nil }, readPrompt: {
        reads += 1
        return configured
    })
    for (question, expected) in [("first", "First custom prompt"), ("second", "Next custom prompt")] {
        state.send(question)
        configured = "Next custom prompt"
        for _ in 0..<100 {
            if !state.busy { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard !state.busy, state.errorKey == nil, state.answer == expected else {
            print("FAIL prompt request snapshot: \(state.errorKey ?? state.answer)")
            return false
        }
    }
    guard reads == 2 else { return false }
    print("PASS actual system/user requests, per-question snapshot and next-question update")
    return true
}

func runPromptChecks() -> Bool {
    let domain = "Echo.PromptChecks.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: domain) else { return false }
    defer { defaults.removePersistentDomain(forName: domain) }
    do {
        let settings = ChatPrompt(defaults: defaults)
        let original = try ChatPrompt.defaultText()
        guard try settings.effectiveText() == original else { return false }
        let custom = "  Custom instructions\nPreserve this newline.  "
        try settings.save(custom)
        guard try ChatPrompt(defaults: defaults).effectiveText() == custom else { return false }
        for invalid in [" \n\t", String(repeating: "x", count: ChatPrompt.limit + 1)] {
            do { try settings.save(invalid); return false }
            catch ChatFailure.promptInvalid { }
            guard try settings.effectiveText() == custom else { return false }
        }
        let zone = TimeZone(secondsFromGMT: 0)!
        let system = ChatPrompt.systemMessage(custom, date: Date(timeIntervalSince1970: 0), timeZone: zone, webAvailable: false)
        guard system.hasPrefix(custom), system.contains("1970-01-01"),
              system.contains("No web access"), system.contains("untrusted data") else { return false }
        let online = ChatPrompt.systemMessage(custom, date: Date(), timeZone: zone, webAvailable: true)
        guard online.contains("web_search"), !online.contains("No web access") else { return false }
        let reading = ChatPrompt.systemMessage(custom, date: Date(), timeZone: zone, webAvailable: false, urlReading: true)
        guard reading.contains("must call deepseek_read_url"), reading.contains("never ask for another permission"),
              !reading.contains("No web access is available") else { return false }
        try settings.save(original)
        guard defaults.object(forKey: ChatPrompt.key) == nil,
              try settings.effectiveText() == original else { return false }
        defaults.set("", forKey: ChatPrompt.key)
        do { _ = try settings.effectiveText(); return false }
        catch ChatFailure.promptInvalid { }
        let referenceMessages = ChatState.userMessages("Translate", reference: "Only selected text")
        let payload = try JSONEncoder().encode(ChatQuery(messages: referenceMessages, model: "mock"))
        guard let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let messages = json["messages"] as? [[String: Any]], messages.count == 1,
              (messages[0]["content"] as? String)?.contains("Only selected text") == true,
              (messages[0]["content"] as? String)?.hasSuffix("User instruction:\nTranslate") == true,
              messages.allSatisfy({ $0["role"] as? String == "user" }),
              ChatState.userMessages("ordinary", reference: nil).count == 1 else { return false }
        let state = ChatState()
        state.send("Translate", reference: String(repeating: "x", count: 16000))
        guard state.errorKey == "chat.tooLong", !state.busy else { return false }
        print("PASS reference request serialization, isolated instruction, ordinary question and combined input limit")
        print("PASS prompt resource, persistence, restore, validation and runtime context")
        return true
    } catch { print("FAIL prompt checks: \(error)"); return false }
}

@MainActor
func runChatChecks(port: Int) async -> Bool {
    func client() -> OpenAI {
        OpenAI(configuration: .init(token: nil, host: "127.0.0.1", port: port,
            scheme: "http", basePath: "/v1", timeoutInterval: 5, parsingOptions: .relaxed))
    }
    let state = ChatState(makeClient: client, modelName: { "mock" }, makeWeb: { nil })
    func wait() async {
        for _ in 0..<100 {
            if !state.busy { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
    do {
        let panel = QuickPanelViewModel()
        panel.query = "@ hello"
        panel.chat.send(String(repeating: "a", count: 16001))
        let unchanged = panel.query
        panel.query = unchanged
        guard panel.chat.errorKey == "chat.tooLong" else { return false }
        panel.query = "@ changed"
        guard panel.chat.errorKey == nil else { return false }
        _ = try ChatSettings.validatedURL("https://example.com/v1")
        for invalid in ["http://example.com/v1", "https://user:secret@example.com/v1", "https://example.com/v1/chat/completions"] {
            if (try? ChatSettings.validatedURL(invalid)) != nil { return false }
        }
        state.send("stream")
        await wait()
        guard !state.busy, state.answer == "你好", state.errorKey == nil else { return false }
        state.send("error")
        await wait()
        guard state.errorKey == "chat.requestError" else { return false }
        state.send("empty")
        await wait()
        guard state.errorKey == "chat.emptyResponse" else { return false }
        state.send("slow")
        try? await Task.sleep(nanoseconds: 100_000_000)
        state.send("stream")
        await wait()
        guard state.answer == "你好", state.errorKey == nil else { return false }
        state.send("slow")
        state.reset()
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard state.answer.isEmpty, !state.busy, state.errorKey == nil else { return false }
        state.send(String(repeating: "a", count: 16001))
        guard state.errorKey == "chat.tooLong" else { return false }
        let web = WebTools(baseURL: URL(string: "http://127.0.0.1:\(port)")!, key: "mock-key")
        for call in [WebTools.Call(id: "x", name: "shell", arguments: "{}"),
                     WebTools.Call(id: "x", name: "web_fetch", arguments: "{\"url\":\"http://127.0.0.1/secret\"}"),
                     WebTools.Call(id: "x", name: "web_search", arguments: "{\"query\":\"\"}")] {
            do { _ = try await web.execute(call); return false }
            catch WebTools.Failure.invalid { }
        }
        guard !WebTools.isPublicURL("http://127.0.0.1/private"),
              !WebTools.isPublicURL("https://user:secret@example.com"),
              WebTools.isPublicURL("https://example.com/article") else { return false }
        let online = ChatState(makeClient: client, modelName: { "mock" }, makeWeb: { web })
        for (question, expectedError) in [("web", Optional<String>.none), ("loop", "chat.webLimit"), ("web-error", "chat.webError")] {
            online.send(question)
            for _ in 0..<600 {
                if !online.busy { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard !online.busy, online.errorKey == expectedError else {
                print("FAIL web \(question): \(online.errorKey ?? "none")")
                return false
            }
            if expectedError == nil && online.answer != "Verified https://example.com/article" { return false }
        }
        online.send("web")
        try? await Task.sleep(nanoseconds: 20_000_000)
        online.reset()
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard online.answer.isEmpty, online.errorKey == nil, !online.busy else { return false }
        print("PASS web fragmented tool calls, search/fetch, reasoning replay, loop limit and HTTP errors")
        print("PASS chat streaming, errors, empty response, replacement, cancellation, input limits and URL validation")
        return true
    } catch { return false }
}

/// Verifies model discovery without contacting a provider or using a real key.
private final class SettingsModelProtocol: URLProtocol {
    static var status = 200
    static var payload = Data()
    static var sawExpectedRequest = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.sawExpectedRequest = request.url?.absoluteString == ChatSettings.endpoint + "/models"
            && request.value(forHTTPHeaderField: "Authorization") == "Bearer settings-test"
            && request.httpBody == nil && request.httpMethod == "GET"
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@MainActor
func runSettingsModelChecks() async -> Bool {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [SettingsModelProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    do {
        SettingsModelProtocol.payload = Data(#"{"data":[{"id":"model-b"},{"id":"model-a"},{"id":"model-b"}]}"#.utf8)
        let models = try await ChatSettings.availableModels(key: "settings-test", session: session)
        guard models == ["model-a", "model-b"], SettingsModelProtocol.sawExpectedRequest else { return false }
        for (status, payload) in [(401, #"{"error":"secret must never surface"}"#), (200, #"{"data":[]}"#), (200, "invalid")] {
            SettingsModelProtocol.status = status
            SettingsModelProtocol.payload = Data(payload.utf8)
            do { _ = try await ChatSettings.availableModels(key: "settings-test", session: session); return false }
            catch { }
        }
        do { _ = try await ChatSettings.availableModels(key: " ", session: session); return false }
        catch ChatFailure.configuration { }
        print("PASS model discovery, authorization, deduplication, empty/malformed responses and authentication failure")
        return true
    } catch { print("FAIL settings model checks"); return false }
}


/// Native URL extension regression checks use a local SSE fixture, never a real key.
@MainActor
func runURLChecks(port: Int) async -> Bool {
    do {
        guard URLReader.links(in: "总结 https://example.com/文章").count == 1,
              URLReader.links(in: "普通问题").isEmpty else { return false }
        var parser = URLReader.Parser()
        func chunk(_ choice: [String: Any]) throws -> String {
            String(data: try JSONSerialization.data(withJSONObject: ["choices": [choice]]), encoding: .utf8)!
        }
        let call: [String: Any] = ["status": "completed", "page": ["url": "https://example.com/article", "title": "来源"]]
        _ = try parser.consume(chunk(["server_tool_event": ["type": "call_completed", "call": call]]))
        let events = try parser.consume(chunk(["delta": ["content": "中文回答", "annotations": [["type": "url_citation", "url_citation": ["url": "https://example.com/article", "title": "来源"]]]], "finish_reason": "stop"]))
        guard events.count == 1 else { return false } // Citation already seen in completion event.
        try parser.validateEnd()
        var truncated = URLReader.Parser()
        _ = try truncated.consume(chunk(["delta": ["content": "partial"]]))
        do { try truncated.validateEnd(); return false } catch WebTools.Failure.incomplete { }
        var failed = URLReader.Parser()
        _ = try failed.consume(chunk(["server_tool_event": ["type": "call_completed", "call": ["status": "failed"]], "delta": ["content": "unverified"], "finish_reason": "stop"]))
        do { try failed.validateEnd(); return false } catch ChatFailure.urlRead { }
        var filtered = URLReader.Parser()
        do { _ = try filtered.consume(chunk(["finish_reason": "content_filter"])); return false } catch WebTools.Failure.incomplete { }
        var unsafe = URLReader.Parser()
        guard try unsafe.consume(chunk(["delta": ["annotations": [["type": "url_citation", "url_citation": ["url": "file:///etc/passwd"]]]]])).isEmpty else { return false }
        print("PASS URL detection, Unicode, source deduplication, unsafe citations, failed/truncated/refused streams")
        let reader = URLReader(endpoint: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!, key: "local-test")
        let state = ChatState(modelName: { "deepseek-flash" },
            makeWeb: { WebTools(baseURL: URL(string: "http://127.0.0.1:\(port)")!, key: "mock") }, makeReader: { reader })
        func wait() async {
            for _ in 0..<100 {
                if !state.busy { return }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        state.send("总结", reference: "https://example.com/article")
        await wait()
        guard !state.busy, state.errorKey == nil, state.answer == "中文回答", state.sources.count == 1 else {
            print("FAIL native success: \(state.errorKey ?? state.answer)"); return false
        }
        for reference in ["http://CheaperInference.com。", "前文 https://example.com/文章 后文", "https://example.com/a https://example.com/a https://example.com/b"] {
            state.send("总结", reference: reference)
            await wait()
            guard state.errorKey == nil, !state.sources.isEmpty else { return false }
        }
        state.send("比较", reference: "https://example.com/a https://example.com/unreadable")
        await wait()
        guard state.errorKey == nil, state.sources.count == 1, state.failedURLs.count == 1 else { return false }
        state.send("总结", reference: "https://example.com/unreadable")
        await wait()
        guard state.errorKey == "chat.urlRead", state.answer.isEmpty else { return false }
        state.send("翻译原文", reference: "你好 https://example.com/a")
        await wait()
        guard state.errorKey == nil, state.sources.isEmpty else { return false }
        state.send("第二条", reference: "https://example.com/a https://example.com/b")
        await wait()
        guard state.errorKey == nil, state.sources.map(\.url.absoluteString) == ["https://example.com/b"] else { return false }
        state.send("比较", reference: "https://example.com/a https://example.com/b https://example.com/c https://example.com/d")
        await wait()
        guard state.errorKey == "chat.urlLimit", state.sources.isEmpty else { return false }
        guard URLReader.links(in: "https://EXAMPLE.com/a https://example.com/a#x").count == 1 else { return false }
        do { _ = try URLReader.parseTargets("[99]", links: [URL(string: "https://example.com")!]); return false } catch { }
        let sample = [URL(string: "https://example.com/a")!]
        for invalid in ["[0]", "[2]", "[-1]", "[1.2]", "[true]", "not JSON"] {
            do { _ = try URLReader.parseTargets(invalid, links: sample); return false } catch { }
        }
        guard try URLReader.parseTargets("[1,1]", links: sample).count == 1,
              try URLReader.parseTargets("[]", links: sample).isEmpty else { return false }
        print("PASS embedded/punctuated/Unicode URLs, deduplication, text-only intent, target subset, partial failure and URL limit")
        state.send("failed https://example.com/article")
        await wait()
        guard !state.busy, state.errorKey == "chat.urlRead", state.answer.isEmpty, state.sources.isEmpty else { return false }
        state.send("truncated https://example.com/article")
        await wait()
        guard !state.busy, state.errorKey != nil, state.answer.isEmpty else { return false }
        state.send("cancel https://example.com/article")
        try? await Task.sleep(nanoseconds: 100_000_000)
        state.reset()
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !state.busy, state.answer.isEmpty, state.sources.isEmpty, state.errorKey == nil else { return false }
        let unsupported = ChatState(modelName: { "unsupported" }, makeReader: { fatalError("must not read key") })
        unsupported.send("https://example.com/article")
        for _ in 0..<100 {
            if !unsupported.busy { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard unsupported.errorKey == "chat.urlModel" else { return false }
        print("PASS native request, clipboard URL, failure cleanup, cancellation, model guard and single-turn isolation")
        return true
    } catch { print("FAIL URL checks: \(error)"); return false }
}


@MainActor
func runImageChecks(port: Int, live: Bool = false) async -> Bool {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("echo-image-check-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: path) }
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 160, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.red.setFill()
    NSRect(x: 0, y: 0, width: 320, height: 160).fill()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]),
          let image = ImageRef.make(pngData: data, diskPath: path) else { return false }
    do {
        try data.write(to: path)
        let panel = QuickPanelViewModel()
        panel.configure(entries: [ClipEntry(kind: .image(image))])
        panel.inputMode = .chat
        panel.query = ""
        panel.selectChatReference(1)
        guard panel.chatReference != nil, panel.chatReferenceNotice == nil else { return false }
        panel.cancelChatReference()
        let message = try ChatState.imageMessage("Describe the color", path: path)
        let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ChatQuery(messages: [message], model: "deepseek-flash"))) as! [String: Any]
        let content = (payload["messages"] as! [[String: Any]])[0]["content"] as! [[String: Any]]
        guard content.count == 2, content[0]["text"] as? String == "Describe the color",
              (content[1]["image_url"] as? [String: Any])?["url"] as? String == "data:image/png;base64," + data.base64EncodedString() else { return false }
        let state = ChatState(makeClient: {
            if live { return try ChatSettings.client() }
            return OpenAI(configuration: .init(token: nil, host: "127.0.0.1", port: port, scheme: "http", basePath: "/v1", timeoutInterval: 5, parsingOptions: .relaxed))
        }, modelName: { "deepseek-flash" }, makeWeb: { fatalError("Image must not invoke web tools") }, readPrompt: {
            live ? "请识别图片主要颜色，回答必须以 VISION_OK 开头，只用一句中文。" : "Custom image system prompt"
        })
        state.send("Describe the color", image: image)
        for _ in 0..<1800 {
            if !state.busy { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard !state.busy, state.errorKey == nil, !state.answer.isEmpty else { print("FAIL image: \(state.errorKey ?? "timeout")"); return false }
        if live {
            print("LIVE image answer: \(state.answer)")
            guard state.answer.contains("VISION_OK"), state.answer.contains("红") else { return false }
        } else {
            guard state.answer == "你好" else { return false }
            let unsupported = ChatState(modelName: { "unsupported" }, makeWeb: { nil })
            unsupported.send("describe", image: image)
            while unsupported.busy { try? await Task.sleep(nanoseconds: 10_000_000) }
            guard unsupported.errorKey == "chat.imageModel" else { return false }
            let missing = path.appendingPathExtension("missing")
            do { _ = try ChatState.imageMessage("test", path: missing); return false } catch ChatFailure.imageRead { }
            try Data("invalid".utf8).write(to: path)
            do { _ = try ChatState.imageMessage("test", path: path); return false } catch ChatFailure.imageRead { }
        }
        print("PASS image request, PNG MIME, custom system prompt and streamed answer")
        return true
    } catch { print("FAIL image checks: \(type(of: error))"); return false }
}
