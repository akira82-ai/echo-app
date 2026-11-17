import Foundation

/// Single-turn DeepSeek extension unsupported by the current OpenAI SDK.
struct URLReader {
    struct Source: Identifiable, Equatable {
        let url: URL
        let title: String
        var id: String { url.absoluteString }
    }
    enum Event {
        case text(String), reading(String), source(Source)
    }
    let endpoint: URL
    let key: String

    static func configured() throws -> URLReader {
        let key = try ChatSettings.readKey()
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatFailure.configuration }
        return URLReader(endpoint: URL(string: ChatSettings.endpoint + "/chat/completions")!, key: key)
    }

    static func links(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard let url = $0.url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return url
        }
    }

    func run(system: String, user: String, model: String, pageFetched: Bool = false,
             receive: @escaping @MainActor (Event) -> Void) async throws {
        guard model == "deepseek-flash" else { throw ChatFailure.urlModel }
        guard Self.links(in: user).allSatisfy({ WebTools.isPublicURL($0.absoluteString) }) else {
            throw ChatFailure.urlBlocked
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "stream": true, "thinking": ["type": "disabled"],
            "tools": pageFetched ? [] : [["type": "deepseek_read_url", "name": "deepseek_read_url"]],
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]]
        ])
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 240
        let session = URLSession(configuration: config, delegate: ReaderNoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw WebTools.Failure.request }
        var parser = Parser()
        var eventData = ""
        var total = 0
        // AsyncBytes.lines omits empty lines, which are SSE event boundaries.
        // Split raw UTF-8 at LF so multi-line events and Chinese text stay intact.
        var lineBytes = Data()
        func consumeLine(_ data: Data) throws -> [Event] {
            guard var line = String(data: data, encoding: .utf8) else { throw WebTools.Failure.invalid }
            if line.hasSuffix("\r") { line.removeLast() }
            if line.isEmpty {
                guard !eventData.isEmpty else { return [] }
                defer { eventData = "" }
                return try parser.consume(eventData)
            }
            if line.hasPrefix("data:") {
                var value = String(line.dropFirst(5))
                if value.hasPrefix(" ") { value.removeFirst() }
                if !eventData.isEmpty { eventData += "\n" }
                eventData += value
            }
            return []
        }
        for try await byte in bytes {
            try Task.checkCancellation()
            total += 1
            guard total <= 2_000_000 else { throw ChatFailure.tooLong }
            if byte == 10 {
                for event in try consumeLine(lineBytes) { await receive(event) }
                lineBytes.removeAll(keepingCapacity: true)
            } else {
                lineBytes.append(byte)
                guard lineBytes.count <= 1_000_000 else { throw ChatFailure.tooLong }
            }
        }
        if !lineBytes.isEmpty {
            for event in try consumeLine(lineBytes) { await receive(event) }
        }
        if !eventData.isEmpty {
            for event in try parser.consume(eventData) { await receive(event) }
        }
        try parser.validateEnd()
    }

    struct Parser {
        private(set) var finished = false
        private(set) var textCount = 0
        private var failedRead = false
        private var seen = Set<String>()

        mutating func consume(_ data: String) throws -> [Event] {
            if data == "[DONE]" { return [] }
            guard let root = try JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
                  let choices = root["choices"] as? [[String: Any]] else { throw WebTools.Failure.invalid }
            guard let choice = choices.first else { return [] } // Usage-only chunk.
            var events: [Event] = []
            if let tool = choice["server_tool_event"] as? [String: Any],
               let call = tool["call"] as? [String: Any] {
                if tool["type"] as? String == "call_started",
                   let action = call["action"] as? [String: Any], let raw = action["url"] as? String,
                   WebTools.isPublicURL(raw), let host = URL(string: raw)?.host {
                    events.append(.reading(host))
                }
                if tool["type"] as? String == "call_completed" {
                    if call["status"] as? String == "failed" { failedRead = true }
                    if call["status"] as? String == "completed", let page = call["page"] as? [String: Any] {
                        appendSource(page, to: &events)
                    }
                }
            }
            let delta = choice["delta"] as? [String: Any] ?? [:]
            if let text = delta["content"] as? String {
                textCount += text.count
                guard textCount <= 100000 else { throw ChatFailure.tooLong }
                if !text.isEmpty { events.append(.text(text)) }
            }
            for annotation in delta["annotations"] as? [[String: Any]] ?? [] {
                if annotation["type"] as? String == "url_citation",
                   let citation = annotation["url_citation"] as? [String: Any] { appendSource(citation, to: &events) }
            }
            for step in delta["server_tool_calls"] as? [[String: Any]] ?? [] {
                for call in step["calls"] as? [[String: Any]] ?? [] {
                    if call["status"] as? String == "failed" { failedRead = true }
                    if call["status"] as? String == "completed", let page = call["page"] as? [String: Any] {
                        appendSource(page, to: &events)
                    }
                }
            }
            if let reason = choice["finish_reason"] as? String {
                guard reason == "stop" else { throw WebTools.Failure.incomplete }
                finished = true
            }
            return events
        }

        private mutating func appendSource(_ value: [String: Any], to events: inout [Event]) {
            guard let raw = value["url"] as? String, WebTools.isPublicURL(raw),
                  let url = URL(string: raw), seen.insert(raw).inserted else { return }
            let title = String((value["title"] as? String ?? url.host ?? raw).prefix(300))
            events.append(.source(Source(url: url, title: title)))
        }

        func validateEnd() throws {
            guard finished else { throw WebTools.Failure.incomplete }
            guard !failedRead else { throw ChatFailure.urlRead }
            guard textCount > 0 else { throw ChatFailure.empty }
        }
    }
}

private final class ReaderNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
