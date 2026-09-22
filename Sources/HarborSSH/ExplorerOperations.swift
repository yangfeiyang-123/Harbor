import AppKit
import HarborCore

extension AppStore {
    func copyEntryPath(_ entry: WorkspaceEntry) {
        copyEntryPaths([entry])
    }
    func copyEntryPaths(_ entries: [WorkspaceEntry], clipboard: NSPasteboard = .general) {
        guard !entries.isEmpty else { return }
        clipboard.clearContents(); clipboard.setString(entries.map(\.path).joined(separator: "\n"), forType: .string)
    }
    func copyEntry(_ entry: WorkspaceEntry, in files: FileWorkspace) {
        copyEntries([entry], in: files)
    }
    func copyEntries(_ entries: [WorkspaceEntry], in files: FileWorkspace, clipboard: NSPasteboard = .general) {
        guard !entries.isEmpty else { return }
        let items = entries.map { WorkspaceDropItem(profileID: files.profile?.id, entry: $0) }
        clipboard.clearContents()
        let representations = entries.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            if files.profile == nil { item.setString(URL(fileURLWithPath: entry.path).absoluteString, forType: .fileURL) }
            item.setString(entry.path, forType: .string)
            return item
        }
        if let data = try? JSONEncoder().encode(items) { representations[0].setData(data, forType: .init(WorkspaceDropItem.typeIdentifier)) }
        clipboard.writeObjects(representations)
    }
    func clipboardEntries(_ clipboard: NSPasteboard = .general) throws -> [WorkspaceDropItem] {
        if let data = clipboard.data(forType: .init(WorkspaceDropItem.typeIdentifier)), data.count < 1_048_576 {
            return try JSONDecoder().decode([WorkspaceDropItem].self, from: data)
        }
        let urls = clipboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { throw WorkspaceError.message("Copy a file or folder before pasting it into the destination folder.") }
        return try WorkspaceDropPlan.localItems(urls: urls)
    }
    func pasteEntries(in files: FileWorkspace, parent: String? = nil) {
        let target = parent ?? (files.selectedEntry?.directory == true ? files.selectedEntry!.path : files.root)
        do { let items = try clipboardEntries(); Task { await transferEntries(items, to: target, in: files, move: false) } }
        catch { errorMessage = error.localizedDescription }
    }
    func promptRenameEntry(_ entry: WorkspaceEntry, in files: FileWorkspace) {
        guard !files.fileOperation else { return }
        files.selectedEntryPath = entry.path
        let alert = NSAlert(); alert.messageText = entry.directory ? "Rename Folder" : "Rename File"
        let field = NSTextField(string: entry.name); field.frame = NSRect(x: 0, y: 0, width: 360, height: 26)
        alert.accessoryView = field; alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel"); alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn, field.stringValue != entry.name {
            let name = field.stringValue
            Task { await mutateEntry(entry, in: files, operation: "rename", name: name) }
        }
    }
    func deleteEntry(_ entry: WorkspaceEntry, in files: FileWorkspace) {
        deleteEntries([entry], in: files)
    }
    func deleteEntries(_ entries: [WorkspaceEntry], in files: FileWorkspace) {
        guard !files.fileOperation, !entries.isEmpty else { return }
        let entries = Self.topLevelEntries(entries)
        let alert = NSAlert(); alert.messageText = entries.count == 1 ? "Delete “\(entries[0].name)”?" : "Delete \(entries.count) items?"
        alert.informativeText = files.profile == nil ? "Move the selected items to the Trash." : "Move the selected items to the server’s Harbor trash folder. Recovery locations will be shown."
        if entries.count > 1 { alert.informativeText += "\n\n" + entries.prefix(8).map(\.name).joined(separator: "\n") + (entries.count > 8 ? "\n…" : "") }
        alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { Task { await trashEntries(entries, in: files) } }
    }
    func trashEntries(_ entries: [WorkspaceEntry], in files: FileWorkspace) async {
        guard !files.fileOperation, !entries.isEmpty else { return }
        files.fileOperation = true; defer { files.fileOperation = false }
        var destinations: [String] = []
        do {
            let entries = Self.topLevelEntries(entries)
            // Check the entire selection before moving anything, including open
            // drafts in other workspaces on this server.
            try requireDeletable(entries, profileID: files.profile?.id)
            await files.prepare(store: self)
            guard let service = files.service else { throw WorkspaceError.message("The file connection is not ready.") }
            for entry in entries {
                try requireDeletable([entry], profileID: files.profile?.id)
                let path = try await service.operate("trash", path: entry.path, parent: (entry.path as NSString).deletingLastPathComponent)
                destinations.append(path)
                await synchronizeMutation(profileID: files.profile?.id, from: entry.path, to: nil)
            }
            files.notice = "Moved to:\n" + destinations.joined(separator: "\n")
        } catch {
            if !destinations.isEmpty { files.notice = "Moved to:\n" + destinations.joined(separator: "\n") }
            errorMessage = error.localizedDescription
        }
    }
    func requireDeletable(_ entries: [WorkspaceEntry], profileID: UUID?) throws {
        for entry in entries {
            try requireFilesNotSaving(profileID: profileID, under: entry.path)
            if fileWorkspaces.values.contains(where: { $0.profile?.id == profileID && $0.documents.contains { $0.dirty && Self.path($0.entry.path, belongsTo: entry.path) } }) {
                throw WorkspaceError.message("“\(entry.name)” has unsaved changes. Save or close its files first.")
            }
        }
    }
    static func topLevelEntries(_ entries: [WorkspaceEntry]) -> [WorkspaceEntry] {
        var seen = Set<String>()
        return entries.filter { entry in
            seen.insert(entry.path).inserted && !entries.contains { $0.directory && $0.path != entry.path && Self.path(entry.path, belongsTo: $0.path) }
        }
    }
    func mutateEntry(_ entry: WorkspaceEntry, in files: FileWorkspace, operation: String, name: String? = nil) async {
        if operation == "trash" { await trashEntries([entry], in: files); return }
        guard !files.fileOperation else { return }
        files.fileOperation = true; defer { files.fileOperation = false }
        do {
            try requireFilesNotSaving(profileID: files.profile?.id, under: entry.path)
            await files.prepare(store: self)
            guard let service = files.service else { throw WorkspaceError.message("The file connection is not ready.") }
            let destination = try await service.operate(operation, path: entry.path, parent: (entry.path as NSString).deletingLastPathComponent, name: name)
            await synchronizeMutation(profileID: files.profile?.id, from: entry.path, to: operation == "trash" ? nil : destination)
            files.notice = operation == "trash" ? "Moved to: " + destination : "Renamed to " + (destination as NSString).lastPathComponent
        } catch { errorMessage = error.localizedDescription }
    }
    static func path(_ path: String, belongsTo root: String) -> Bool { path == root || path.hasPrefix(root + "/") }
    func requireFilesNotSaving(profileID: UUID?, under path: String) throws {
        if fileWorkspaces.values.contains(where: { $0.profile?.id == profileID && $0.documents.contains { $0.saving && Self.path($0.entry.path, belongsTo: path) } }) {
            throw WorkspaceError.message("Wait for the file to finish saving before moving or renaming it.")
        }
    }
    func synchronizeMutation(profileID: UUID?, from old: String, to new: String?) async {
        let affected = fileWorkspaces.values.filter { $0.profile?.id == profileID }
        func rewrite(_ path: String) -> String { Self.path(path, belongsTo: old) ? new! + path.dropFirst(old.count) : path }
        for files in affected {
            if let _ = new {
                files.root = rewrite(files.root)
                files.expanded = Set(files.expanded.map(rewrite))
                let cached = files.entries
                var remapped = [String: [WorkspaceEntry]]()
                // A destination removed by another process may still be cached.
                // Prefer the moved subtree over that stale snapshot.
                for moving in [false, true] {
                    for (key, entries) in cached where Self.path(key, belongsTo: old) == moving {
                        remapped[rewrite(key)] = entries.map { entry in
                            var value = entry; value.path = rewrite(value.path)
                            value.name = (value.path as NSString).lastPathComponent; return value
                        }
                    }
                }
                files.entries = remapped
                for doc in files.documents where Self.path(doc.entry.path, belongsTo: old) {
                    doc.entry.path = rewrite(doc.entry.path); doc.entry.name = (doc.entry.path as NSString).lastPathComponent
                }
                files.explorerSelection.remap(rewrite)
            } else {
                for doc in files.documents where Self.path(doc.entry.path, belongsTo: old) { files.close(doc) }
                files.expanded = files.expanded.filter { !Self.path($0, belongsTo: old) }
                files.entries = files.entries.filter { !Self.path($0.key, belongsTo: old) }.mapValues { $0.filter { !Self.path($0.path, belongsTo: old) } }
                files.explorerSelection.remap { Self.path($0, belongsTo: old) ? nil : $0 }
            }
            files.directoryStamps.removeAll(); files.persist()
            if files === currentFiles { await files.refreshExpanded(force: true) }
            files.reconcileExplorerSelection()
        }
        objectWillChange.send()
    }
    func transferEntries(_ items: [WorkspaceDropItem], to parent: String, in files: FileWorkspace, move: Bool, receive: (() async throws -> [WorkspaceDropItem])? = nil) async {
        guard !files.fileOperation else { errorMessage = "Wait for the current file operation to finish, then try again."; return }
        files.fileOperation = true; files.notice = nil
        files.transfer = FileTransferStatus(action: receive == nil ? "Preparing" : "Receiving", destination: parent)
        defer { files.fileOperation = false }
        do {
            let items = try await receive?() ?? items
            guard !items.isEmpty else { throw WorkspaceError.message("No files were received.") }
            await files.prepare(store: self)
            guard let destination = files.service else { throw WorkspaceError.message("The file connection is not ready.") }
            var seen = Set<String>()
            let unique = items.filter { item in seen.insert((item.profileID?.uuidString ?? "local") + ":" + item.entry.path).inserted && !items.contains { $0.entry.directory && $0.entry.path != item.entry.path && $0.profileID == item.profileID && Self.path(item.entry.path, belongsTo: $0.entry.path) } }
            if move {
                for item in unique where item.profileID == files.profile?.id { try requireFilesNotSaving(profileID: item.profileID, under: item.entry.path) }
            }
            var transferred: [String] = []
            files.transfer?.count = unique.count
            for (index, item) in unique.enumerated() {
                let entry = item.entry
                files.transfer?.itemID = UUID(); files.transfer?.index = index + 1; files.transfer?.name = entry.name
                files.transfer?.action = item.profileID == files.profile?.id ? (move ? "Moving" : "Copying") : (files.profile == nil ? "Downloading" : "Uploading")
                files.transfer?.progress = WorkspaceTransferProgress(.preparing)
                let state = files.transfer!
                let reporter = files.transferReporter(id: state.id, itemID: state.itemID)
                if item.profileID == files.profile?.id {
                    if move && (entry.path as NSString).deletingLastPathComponent == parent { transferred.append(entry.path); continue }
                    if move { try requireFilesNotSaving(profileID: item.profileID, under: entry.path) }
                    let path = try await destination.operate(move ? "move" : "copy", path: entry.path, parent: parent)
                    if move { await synchronizeMutation(profileID: item.profileID, from: entry.path, to: path) }
                    transferred.append(path)
                } else {
                    let profile = profiles.first { $0.id == item.profileID }
                    guard item.profileID == nil || profile != nil else { throw WorkspaceError.message("The source server has been removed.") }
                    let sourceFiles = self.files(for: profile); await sourceFiles.prepare(store: self)
                    guard let source = sourceFiles.service else { throw WorkspaceError.message("The source file connection is not ready.") }
                    let archive = try await source.exportItem(entry.path, progress: reporter); defer { try? FileManager.default.removeItem(at: archive) }
                    transferred.append(try await destination.importItem(archive, name: entry.name, parent: parent, progress: reporter))
                }
            }
            files.expanded.insert(parent); await files.loadChildren(parent); await files.refreshExpanded(force: true)
            files.explorerSelection.selectAll(transferred); files.reconcileExplorerSelection()
            let moved = move && unique.allSatisfy { $0.profileID == files.profile?.id }
            files.notice = (moved ? "Moved to " : "Copied to ") + parent
            files.transfer?.completed = true
        } catch { files.transfer?.failure = error.localizedDescription; files.notice = nil; errorMessage = error.localizedDescription }
    }
    func downloadEntry(_ entry: WorkspaceEntry, in files: FileWorkspace) {
        downloadEntries([entry], in: files)
    }
    func downloadEntries(_ entries: [WorkspaceEntry], in files: FileWorkspace) {
        guard !files.fileOperation, !entries.isEmpty else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "Download Here"; panel.message = entries.count == 1 ? "Choose a local destination for “\(entries[0].name)”" : "Choose a local destination for \(entries.count) items"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task {
            do {
                let urls = try await downloadEntries(entries, to: folder, in: files)
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            } catch { files.notice = nil; errorMessage = error.localizedDescription }
        }
    }
    func downloadEntries(_ entries: [WorkspaceEntry], to folder: URL, in files: FileWorkspace) async throws -> [URL] {
        guard !files.fileOperation, !entries.isEmpty else { return [] }
        files.fileOperation = true; files.notice = nil
        files.transfer = FileTransferStatus(action: "Downloading", destination: folder.path)
        defer { files.fileOperation = false }
        do {
            await files.prepare(store: self)
            guard let source = files.service else { throw WorkspaceError.message("The file connection is not ready.") }
            let local = self.files(for: nil); await local.prepare(store: self)
            guard let target = local.service else { throw WorkspaceError.message("Unable to open the local folder.") }
            var urls: [URL] = []
            let entries = Self.topLevelEntries(entries)
            files.transfer?.count = entries.count
            for (index, entry) in entries.enumerated() {
                files.transfer?.itemID = UUID(); files.transfer?.index = index + 1; files.transfer?.name = entry.name
                files.transfer?.progress = WorkspaceTransferProgress(.preparing)
                let state = files.transfer!
                let reporter = files.transferReporter(id: state.id, itemID: state.itemID)
                let archive = try await source.exportItem(entry.path, progress: reporter); defer { try? FileManager.default.removeItem(at: archive) }
                let path = try await target.importItem(archive, name: entry.name, parent: folder.path, progress: reporter)
                urls.append(URL(fileURLWithPath: path))
            }
            files.notice = "Downloaded to " + folder.path
            files.transfer?.completed = true
            return urls
        } catch { files.transfer?.failure = error.localizedDescription; throw error }
    }
}
