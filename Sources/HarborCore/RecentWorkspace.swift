import Foundation

public struct RecentWorkspace: Codable, Identifiable, Equatable, Sendable {
    public var serverID: UUID?
    public var serverName: String
    public var directory: String?
    public var openedAt: Date
    public var tmuxName: String?
    public var id: String { (serverID?.uuidString ?? "local") + "\n" + (directory ?? "") }
    public var title: String {
        guard let directory, directory != "/", directory != "~" else { return serverName }
        return (directory as NSString).lastPathComponent
    }
    public init(serverID: UUID?, serverName: String, directory: String? = nil, openedAt: Date = Date(), tmuxName: String? = nil) {
        self.serverID = serverID; self.serverName = serverName
        self.directory = Self.normalize(directory); self.openedAt = openedAt; self.tmuxName = tmuxName
    }
    public static func normalize(_ value: String?) -> String? {
        guard var value, !value.isEmpty else { return nil }
        while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
        return value
    }
    public static func merged(_ entries: [Self], available: Set<UUID>, limit: Int = 12) -> [Self] {
        var seen = Set<String>()
        return Array(entries.sorted { $0.openedAt > $1.openedAt }.filter {
            ($0.serverID == nil || available.contains($0.serverID!)) && seen.insert($0.id).inserted
        }.prefix(max(0, limit)))
    }
    public static func migrate(_ records: [SessionRecord], available: Set<UUID>) -> [Self] {
        merged(records.filter { $0.exitCode == nil || $0.exitCode == 0 }.map {
            Self(serverID: $0.serverID, serverName: $0.serverName, directory: $0.workingDirectory, openedAt: $0.startedAt, tmuxName: $0.tmuxName)
        }, available: available)
    }
}

public struct RecentWorkspaceGroup: Identifiable, Sendable {
    public let serverID: UUID?
    public let name: String
    public let entries: [RecentWorkspace]
    public var id: String { serverID?.uuidString ?? "local" }

    /// Follow the user's server order and keep each server's newest entries first.
    public static func make(_ entries: [RecentWorkspace], profiles: [ServerProfile], query: String = "") -> [Self] {
        let servers: [(UUID?, String)] = profiles.map { ($0.id, $0.name) } + [(nil, "Local")]
        return servers.compactMap { id, name in
            let matches = entries.filter { item in
                item.serverID == id && (query.isEmpty || (item.title + " " + name + " " + (item.directory ?? "")).localizedCaseInsensitiveContains(query))
            }.sorted { $0.openedAt > $1.openedAt }
            return matches.isEmpty ? nil : Self(serverID: id, name: name, entries: matches)
        }
    }
}
