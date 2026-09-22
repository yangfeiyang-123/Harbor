import Foundation

public struct WorkspaceSearchHit: Codable, Sendable, Identifiable {
    public let entry: WorkspaceEntry
    public let relative: String
    public let line: Int?
    public let column: Int?
    public let preview: String?
    public var id: String { entry.path + ":" + String(line ?? 0) }
}
public struct WorkspaceSearchResult: Codable, Sendable {
    public let hits: [WorkspaceSearchHit]
    public let scanned: Int
    public let skipped: Int
    public let truncated: Bool
}

extension WorkspaceFileService {
    public func search(_ query: String, root: String, content: Bool, caseSensitive: Bool = false, hidden: Bool = false) async throws -> WorkspaceSearchResult {
        let request: [String: Any] = ["op": "search", "path": root, "query": query, "content": content, "caseSensitive": caseSensitive, "hidden": hidden]
        let data: Data
        if profile != nil { data = try await remote(request, timeout: 12) }
        else {
            let output = cache.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: output) }
            try await FileProcess.run("/usr/bin/python3", arguments: ["-c", script], input: JSONSerialization.data(withJSONObject: request), output: output, timeout: 12)
            data = try Data(contentsOf: output)
        }
        return try JSONDecoder().decode(WorkspaceSearchResult.self, from: data)
    }
}
