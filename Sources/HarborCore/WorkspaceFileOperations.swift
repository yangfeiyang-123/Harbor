import Foundation

extension WorkspaceFileService {
    public func operate(_ operation: String, path: String, parent: String? = nil, name: String? = nil) async throws -> String {
        guard ["copy", "move", "rename", "trash"].contains(operation) else { throw WorkspaceError.message("Unknown file operation.") }
        if profile != nil {
            var request: [String: Any] = ["op": operation, "path": path]
            if let parent { request["parent"] = parent }; if let name { request["name"] = name }
            return try JSONDecoder().decode([String: String].self, from: await remote(request))["path"] ?? path
        }
        return try await Task.detached(priority: .userInitiated) {
            let source = WorkspacePath.local(path), fm = FileManager.default
            guard source.path != "/", source != fm.homeDirectoryForCurrentUser else { throw WorkspaceError.message("This operation is not available for the entire login directory.") }
            if operation == "trash" {
                var result: NSURL?; try fm.trashItem(at: source, resultingItemURL: &result)
                return result?.path ?? "Trash"
            }
            guard let parent else { throw WorkspaceError.message("Select a destination folder.") }
            let parentURL = WorkspacePath.local(parent)
            let sourceReal = source.resolvingSymlinksInPath().path, parentReal = parentURL.resolvingSymlinksInPath().path
            let isDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            guard !isDirectory || (parentReal != sourceReal && !parentReal.hasPrefix(sourceReal + "/")) else { throw WorkspaceError.message("A folder cannot be moved into itself or one of its subfolders.") }
            let destination = try WorkspaceTransfer.destination(name: name ?? source.lastPathComponent, parent: parentURL.path, copy: operation == "copy")
            if operation == "copy" {
                let staging = parentURL.appendingPathComponent(".harbor-copy-" + UUID().uuidString)
                try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); defer { try? fm.removeItem(at: staging) }
                let item = staging.appendingPathComponent("item")
                try fm.copyItem(at: source, to: item); try WorkspaceTransfer.moveWithoutReplacing(item, to: destination)
            } else { try WorkspaceTransfer.moveWithoutReplacing(source, to: destination) }
            return destination.path
        }.value
    }
    public func exportItem(_ path: String, progress: WorkspaceTransferReporter? = nil) async throws -> URL {
        progress?(WorkspaceTransferProgress(profile == nil ? .preparing : .transferring))
        let archive = cache.appendingPathComponent("transfer-" + UUID().uuidString)
        do {
            if profile != nil { _ = try await remote(["op": "export", "path": path], destination: archive, timeout: 3600, bulk: true, progress: {
                progress?(WorkspaceTransferProgress(.transferring, bytes: $0.outputBytes))
            }) }
            else { try await Task.detached { try WorkspaceTransfer.export(WorkspacePath.local(path), to: archive) }.value }
            return archive
        } catch { try? FileManager.default.removeItem(at: archive); throw error }
    }
    public func importItem(_ archive: URL, name: String, parent: String, progress: WorkspaceTransferReporter? = nil) async throws -> String {
        let bytes = (try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)?.int64Value ?? 0
        _ = try WorkspacePath.child(name, in: parent)
        if let profile, let socket {
            progress?(WorkspaceTransferProgress(.transferring, total: bytes))
            let request = try JSONSerialization.data(withJSONObject: ["op": "import", "path": parent, "name": name]).base64EncodedString()
            let command = "python3 -c " + SSHArguments.quote(script) + " " + SSHArguments.quote(request)
            let output = cache.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: output) }
            let port = await relay?()
            try await FileProcess.run("/usr/bin/ssh", arguments: SSHArguments.probe(profile, socket: socket, command: command), input: Data(), output: output,
                                      timeout: port == nil ? 3600 : Self.pacedLimit, inputFile: archive,
                                      pacer: port.map { TransferPacer(port: $0) }, stallTimeout: port == nil ? nil : Self.pacedStall, progress: {
                                          progress?(WorkspaceTransferProgress($0.inputBytes >= bytes ? .finalizing : .transferring,
                                                                              bytes: min(bytes, $0.inputBytes), total: bytes))
                                      })
            return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: output))["path"] ?? parent
        }
        progress?(WorkspaceTransferProgress(.finalizing, bytes: bytes, total: bytes))
        return try await Task.detached {
            let staging = WorkspacePath.local(parent).appendingPathComponent(".harbor-transfer-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: staging) }
            let item = try WorkspaceTransfer.extract(archive, into: staging)
            let destination = try WorkspaceTransfer.destination(name: name, parent: WorkspacePath.local(parent).path, copy: true)
            try WorkspaceTransfer.moveWithoutReplacing(item, to: destination); return destination.path
        }.value
    }
    public func terminalDirectories(_ sessions: [(pid: Int32, token: String)]) async throws -> [String: String] {
        guard profile != nil else { return [:] }
        return try JSONDecoder().decode([String: String].self, from: await remote(["op": "cwd", "sessions": sessions.map { ["pid": $0.pid, "token": $0.token] as [String: Any] }], timeout: 8))
    }
}
