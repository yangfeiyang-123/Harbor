import Foundation

public struct WorkspaceDropItem: Codable, Equatable, Sendable {
    public static let typeIdentifier = "app.harbor.ssh.workspace-item"
    public var profileID: UUID?
    public var entry: WorkspaceEntry
    public init(profileID: UUID?, entry: WorkspaceEntry) { self.profileID = profileID; self.entry = entry }
}

public struct WorkspaceDropPlan: Sendable {
    public let profileID: UUID?
    public let directoryRoots: [String]
    public var hasDirectories: Bool { !directoryRoots.isEmpty }
    public let root: String
    public let files: [WorkspaceEntry]
    public let recentRoots: [String]

    public init(items: [WorkspaceDropItem]) throws {
        guard let first = items.first else { throw WorkspaceError.message("Drop a file or folder here.") }
        guard items.allSatisfy({ $0.profileID == first.profileID }) else {
            throw WorkspaceError.message("Open items from different servers or your Mac separately.")
        }
        guard items.allSatisfy({ $0.entry.path.hasPrefix("/") && !$0.entry.path.contains("\0") }) else {
            throw WorkspaceError.message("The dropped file path is invalid.")
        }
        profileID = first.profileID
        var paths = Set<String>()
        let entries = items.map(\.entry).filter { paths.insert($0.path).inserted }
        files = entries.filter { !$0.directory }
        directoryRoots = entries.filter(\.directory).map(\.path)
        var roots = Set<String>()
        recentRoots = entries.map { $0.directory ? $0.path : ($0.path as NSString).deletingLastPathComponent }
            .filter { roots.insert($0).inserted }
        root = recentRoots[0]
    }

    public static func localItems(urls: [URL]) throws -> [WorkspaceDropItem] {
        try urls.map { url in
            guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else {
                throw WorkspaceError.message("Drop a local file or folder, or a server file from Harbor.")
            }
            let local = url.standardizedFileURL
            // Follow symlinks for type/size, while retaining the user's original path.
            let info = try local.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard info.isDirectory == true || info.isRegularFile == true else { throw WorkspaceError.message("This item is not an accessible file or folder.") }
            return WorkspaceDropItem(profileID: nil, entry: WorkspaceEntry(path: local.path, name: local.lastPathComponent,
                directory: info.isDirectory == true, size: Int64(info.fileSize ?? 0), modified: info.contentModificationDate?.timeIntervalSince1970 ?? 0))
        }
    }
}
