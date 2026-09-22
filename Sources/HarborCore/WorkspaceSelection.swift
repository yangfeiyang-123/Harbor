import Foundation

/// Local terminals use their own workspace, just like each remote server.
public struct WorkspaceSelection: Equatable, Sendable {
    public private(set) var profileID: UUID?
    public private(set) var directoryID: UUID?
    private var selections: [String: UUID] = [:]
    public init() {}
    private func key(_ id: UUID?, directory: UUID? = nil) -> String { (id?.uuidString ?? "local") + (directory.map { "." + $0.uuidString } ?? "") }
    public var sessionID: UUID? { selections[key(profileID, directory: directoryID)] }
    public mutating func selectWorkspace(_ id: UUID?, available: [UUID], directoryID: UUID? = nil) {
        profileID = id; self.directoryID = directoryID
        if let selected = sessionID, available.contains(selected) { return }
        selections[key(id, directory: directoryID)] = available.last
    }
    public mutating func selectSession(_ id: UUID, profileID: UUID?, directoryID: UUID? = nil) {
        self.profileID = profileID; self.directoryID = directoryID; selections[key(profileID, directory: directoryID)] = id
    }
    public mutating func removeSession(_ id: UUID, profileID: UUID?, remaining: [UUID], preferred: UUID? = nil, directoryID: UUID? = nil) {
        let key = key(profileID, directory: directoryID)
        if selections[key] == id { selections[key] = preferred.flatMap { remaining.contains($0) ? $0 : nil } ?? remaining.last }
    }
}

public enum ServerIdentity {
    /// Resolve ssh -G first. Keep different accounts and connection routes distinct.
    public static func key(effective: [String: String]) -> String? {
        guard let host = effective["hostname"], let user = effective["user"],
              !host.isEmpty, !user.isEmpty else { return nil }
        return [host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")), user,
                effective["port"] ?? "22", effective["proxyjump"] ?? "none",
                effective["proxycommand"] ?? "none", effective["identityfile"] ?? ""].joined(separator: "\u{0}")
    }
}
