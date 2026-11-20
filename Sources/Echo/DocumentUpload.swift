import Foundation

/// Uploads one explicitly submitted document, with bounded remote retention.
struct DocumentUpload {
    let endpoint: URL
    let key: String

    static func purpose(for path: URL) -> String? {
        switch path.pathExtension.lowercased() {
        case "pdf", "doc", "docx", "ppt", "pptx": return "rich_layout_recognition"
        case "txt", "md", "csv", "xlsx", "xls": return "user_data"
        default: return nil
        }
    }

    static func configured() throws -> Self {
        let key = try ChatSettings.readKey()
        guard !key.isEmpty else { throw ChatFailure.configuration }
        return Self(endpoint: URL(string: "https://api.deepseek.com/files")!, key: key)
    }

    func upload(_ path: URL) async throws -> String {
        guard path.isFileURL, let purpose = Self.purpose(for: path),
              let values = try? path.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, let size = values.fileSize else { throw ChatFailure.documentRead }
        guard size > 0, size <= 10_000_000 else { throw ChatFailure.documentLimit }
        let data: Data
        do { data = try Data(contentsOf: path) } catch { throw ChatFailure.documentRead }
        guard data.count <= 10_000_000 else { throw ChatFailure.documentLimit }
        let boundary = "Echo-" + UUID().uuidString
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        for (name, value) in [("purpose", purpose), ("expires_after[anchor]", "created_at"), ("expires_after[seconds]", "3600")] {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        // A generated filename avoids header injection and unnecessary disclosure of local names.
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"document.\(path.pathExtension.lowercased())\"\r\nContent-Type: application/octet-stream\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 260
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 280
        let session = URLSession(configuration: config, delegate: DocumentNoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (responseData, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              responseData.count <= 100_000,
              let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              json["error"] == nil, let id = json["id"] as? String,
              id.hasPrefix("file-api-"), id.count <= 200 else { throw ChatFailure.documentRead }
        return id
    }
}

private final class DocumentNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
