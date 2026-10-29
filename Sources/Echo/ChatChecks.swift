import Foundation
import OpenAI

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
        try settings.save(original)
        guard defaults.object(forKey: ChatPrompt.key) == nil,
              try settings.effectiveText() == original else { return false }
        defaults.set("", forKey: ChatPrompt.key)
        do { _ = try settings.effectiveText(); return false }
        catch ChatFailure.promptInvalid { }
        let referenceMessages = ChatState.userMessages("Translate", reference: "Only selected text")
        let payload = try JSONEncoder().encode(ChatQuery(messages: referenceMessages, model: "mock"))
        guard let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let messages = json["messages"] as? [[String: Any]], messages.count == 2,
              (messages[0]["content"] as? String)?.contains("Only selected text") == true,
              messages[1]["content"] as? String == "Translate",
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
