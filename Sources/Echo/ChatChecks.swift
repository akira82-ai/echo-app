import Foundation
import OpenAI

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
