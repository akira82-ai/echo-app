import Foundation

/// In-memory Markdown sidecars. Preparation never reads or writes the clipboard.
@MainActor
public final class MarkdownCache {
    public static let shared = MarkdownCache()

    public struct Request {
        public let id: UUID
        public let rawText: String
        public let representations: [String: Data]

        public init(id: UUID, rawText: String, representations: [String: Data]) {
            self.id = id
            self.rawText = rawText
            self.representations = representations
        }
    }

    private var tasks: [UUID: Task<String, Error>] = [:]
    private var tail: Task<String, Error>?
    private var tailID: UUID?
    private lazy var converter = Converter()
    private let operation: ((Request) async throws -> String)?

    public init(operation: ((Request) async throws -> String)? = nil) {
        self.operation = operation
    }

    /// Requests are supplied oldest-first so rapid copies are prepared in copy order.
    /// Existing tasks (including failures) are reused until their history row disappears.
    public func synchronize(_ requests: [Request]) {
        let retained = Set(requests.map(\.id))
        for id in Array(tasks.keys) where !retained.contains(id) {
            tasks.removeValue(forKey: id)?.cancel()
        }
        // Keep the cancelled tail as a barrier until its WebKit callback completes.
        // A new copy must not race the old conversion after clearing history.
        if requests.isEmpty { tail?.cancel() }
        for request in requests where tasks[request.id] == nil {
            let richTypes = ["public.html", "public.rtf", "com.apple.flat-rtfd"]
            if !request.representations.keys.contains(where: { richTypes.contains($0) }) {
                tasks[request.id] = Task { request.rawText }
                continue
            }
            let previous = tail
            let task = Task { @MainActor [weak self] () throws -> String in
                defer {
                    if self?.tailID == request.id { self?.tail = nil; self?.tailID = nil }
                }
                // WKWebView conversions are serialized, including after an earlier failure.
                _ = await previous?.result
                try Task.checkCancellation()
                guard let self else { throw CancellationError() }
                if let operation = self.operation { return try await operation(request) }
                let input = try Input.stored(rawText: request.rawText, representations: request.representations)
                return try await self.converter.convert(input)
            }
            tasks[request.id] = task
            tail = task
            tailID = request.id
        }
    }

    /// Waiting for a copy-time task does not start a second conversion. Cancelling the
    /// panel's waiter leaves the sidecar available for a later paste attempt.
    public func value(for id: UUID) async throws -> String {
        try Task.checkCancellation()
        guard let task = tasks[id] else {
            throw ProbeError.message("该历史记录已移除，请重新选择。")
        }
        let result = try await task.value
        try Task.checkCancellation()
        guard tasks[id] != nil else { throw CancellationError() }
        return result
    }
}
