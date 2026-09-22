import AppKit
import HarborCore

/// Watch only the directories the user has expanded, never an entire tree.
final class WorkspaceDirectoryWatcher {
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    func update(paths: [String], changed: @escaping () -> Void) {
        let wanted = Set(paths.prefix(64))
        for key in Array(sources.keys) where !wanted.contains(key) { sources.removeValue(forKey: key)?.cancel() }
        for path in wanted where sources[path] == nil {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .extend, .attrib], queue: .main)
            source.setEventHandler(handler: changed)
            source.setCancelHandler { close(descriptor) }
            sources[path] = source; source.resume()
        }
    }
    func stop() { sources.values.forEach { $0.cancel() }; sources.removeAll() }
    deinit { stop() }
}

extension FileWorkspace {
    var watchedDirectoryPaths: [String] {
        guard !root.isEmpty else { return [] }
        var paths = [root] + expanded.sorted()
        if let currentDocument {
            let parent = (currentDocument.entry.path as NSString).deletingLastPathComponent
            if !paths.contains(parent) { paths.append(parent) }
        }
        return paths
    }
    func trimDirectoryCache() {
        let keep = Set(watchedDirectoryPaths)
        entries = entries.filter { keep.contains($0.key) }
        directoryStamps = directoryStamps.filter { keep.contains($0.key) }
    }
    func updateDirectoryWatchers() {
        guard monitorID != nil, profile == nil else { return }
        if localWatcher == nil { localWatcher = WorkspaceDirectoryWatcher() }
        localWatcher?.update(paths: watchedDirectoryPaths) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.monitorID != nil else { return }
                self.localRefreshTask?.cancel()
                self.localRefreshTask = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
                    await self?.refreshExpanded()
                }
            }
        }
    }
    func stopMonitoring() {
        monitorID = nil; localWatcher?.stop(); localWatcher = nil
        localRefreshTask?.cancel(); localRefreshTask = nil
    }
    /// The view owns this task. Switching workspace/mode or leaving the app
    /// cancels it; becoming active starts with an immediate refresh.
    func monitorDirectoryChanges() async {
        let id = UUID(); monitorID = id; updateDirectoryWatchers()
        defer { if monitorID == id { stopMonitoring() } }
        var failures = 0
        while !Task.isCancelled && monitorID == id {
            let success = await refreshExpanded()
            failures = success ? 0 : min(failures + 1, 4)
            do { try await Task.sleep(nanoseconds: UInt64(failures == 0 ? 2 : min(30, 2 << failures)) * 1_000_000_000) }
            catch { return }
        }
    }
    @discardableResult
    func refreshExpanded(force: Bool = false) async -> Bool {
        guard let service, !busy, !root.isEmpty, !Task.isCancelled else { return false }
        guard !refreshInProgress else { if force { refreshAgain = true }; return true }
        refreshInProgress = true
        if force { refreshingFiles = true }
        defer {
            refreshInProgress = false; refreshingFiles = false
            if refreshAgain { refreshAgain = false; Task { [weak self] in await self?.refreshExpanded(force: true) } }
        }
        let generation = syncGeneration, currentRoot = root, hidden = showHidden
        let paths = watchedDirectoryPaths
        do {
            for offset in stride(from: 0, to: paths.count, by: 32) {
                try Task.checkCancellation()
                let batch = paths.dropFirst(offset).prefix(32).map { WorkspaceDirectoryRequest(path: $0, stamp: force ? nil : directoryStamps[$0]) }
                let watchedFiles = offset == 0 ? currentDocument.map { [$0.entry.path] } ?? [] : []
                let result = try await service.refresh(batch, files: watchedFiles, showHidden: hidden)
                guard !Task.isCancelled, generation == syncGeneration, currentRoot == root, hidden == showHidden else { return false }
                for update in result.directories {
                    if let listing = update.listing {
                        if entries[update.path] != listing.entries { entries[update.path] = listing.entries }
                        directoryStamps[update.path] = listing.stamp
                        if update.path == root { error = nil }
                        if listing.truncated { notice = "Some folders show only the first 10,000 items. Open a subfolder to continue." }
                        let children = Set(listing.entries.filter(\.directory).map(\.path))
                        expanded = expanded.filter { path in
                            let prefix = update.path == "/" ? "/" : update.path + "/"
                            guard path.hasPrefix(prefix) else { return true }
                            let child = String(path.dropFirst(prefix.count).split(separator: "/").first ?? "")
                            return children.contains((update.path as NSString).appendingPathComponent(child))
                        }
                        for document in documents where (document.entry.path as NSString).deletingLastPathComponent == update.path {
                            if let entry = listing.entries.first(where: { $0.path == document.entry.path }), entry != document.entry {
                                document.entry = entry; document.externallyChanged = true
                            }
                        }
                    } else if let message = update.error {
                        directoryStamps[update.path] = nil
                        if update.path == root { if force { error = message }; return false }
                        if force { notice = "Some folders could not be refreshed: " + message }
                    }
                }
                for update in result.files {
                    guard let document = documents.first(where: { $0.entry.path == update.path }), let entry = update.entry else { continue }
                    if entry != document.entry { document.entry = entry; document.externallyChanged = true }
                    if document.externallyChanged {
                        let stable = pendingFileChanges[entry.path] == entry
                        pendingFileChanges[entry.path] = entry
                        if stable && !document.dirty && document.id == selection { await loadIfNeeded(document) }
                    } else { pendingFileChanges[entry.path] = nil }
                }
            }
            reconcileExplorerSelection(); trimDirectoryCache(); updateDirectoryWatchers()
            return true
        } catch is CancellationError { return false }
        catch { if force { notice = "Unable to refresh folder: " + error.localizedDescription }; return false }
    }
}
