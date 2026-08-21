import Foundation

public enum LogseqPendingSyncHTTPTransport {
    public static func send(_ pending: LogseqPendingSyncRequest) async -> LogseqPendingSyncResult {
        #if SKIP
        return await AndroidPendingSyncTransport.send(request: pending)
        #else
        do {
            guard let url = URL(string: pending.url) else {
                return LogseqPendingSyncResult(status: nil, body: nil, error: "Invalid pending sync URL")
            }
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.httpMethod = pending.method
            request.setValue("Bearer \(pending.token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(pending.contentType, forHTTPHeaderField: "Content-Type")
            let data: Data
            let response: URLResponse
            if let filePath = pending.filePath {
                (data, response) = try await URLSession.shared.upload(
                    for: request,
                    fromFile: URL(fileURLWithPath: filePath)
                )
            } else {
                request.httpBody = pending.body.map { Data($0.utf8) }
                (data, response) = try await URLSession.shared.data(for: request)
            }
            guard let http = response as? HTTPURLResponse else {
                return LogseqPendingSyncResult(status: nil, body: nil, error: "Pending sync response was not HTTP")
            }
            return LogseqPendingSyncResult(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? "",
                error: nil
            )
        } catch {
            return LogseqPendingSyncResult(status: nil, body: nil, error: "\(error)")
        }
        #endif
    }
}
