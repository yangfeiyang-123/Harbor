import SwiftUI
import HarborCore

extension AppStore {
    func directoryCatalogKey(_ profileID: UUID?) -> String { "directories." + (profileID?.uuidString ?? "local") }
    func selectedDirectoryID(for profileID: UUID?) -> UUID? {
        let key = directoryCatalogKey(profileID), ids = directoryIDs(for: profileID)
        // The folder this window last showed there; what any window chose last is the starting point.
        if let own = ownDirectories[key], ids.contains(own) { return UUID(uuidString: own) }
        guard let value = workspaceDefaults.string(forKey: key + ".selected"), ids.contains(value) else { return nil }
        return UUID(uuidString: value)
    }
    /// The folder a window comes up on when it switches to a server: one it already has open there,
    /// else its own last folder there, unless another window is showing that folder now. Then it is
    /// the most recent folder of the server that is free, so switching in one window never depends
    /// on what another one shows.
    func arrivalDirectoryID(for profileID: UUID?) -> UUID? {
        let remembered = selectedDirectoryID(for: profileID)
        let shown = Set(Self.all.filter { $0 !== self && $0.window != nil }.compactMap { $0.workspaceClaim?.key })
        let profile = profiles.first { $0.id == profileID }
        guard profileID == nil || profile != nil else { return remembered }
        func identity(_ files: FileWorkspace) -> String { WorkspaceSwitcher.identity(profileID: profileID, root: files.root, fallback: files.key) }
        // What this window already has open on the server comes before anything that would have to
        // be opened: a folder with an editor running, then one it keeps. Among those, the one it
        // showed there last, then the most recent. Only then what any window chose last. This is
        // the order of the Option+Tab list, so a server comes up on the folder that list starts on.
        let kept = Set(keptFolders.map(\.match)), catalog = directoryCatalogKey(profileID)
        let own = ownDirectories[catalog] ?? workspaceDefaults.string(forKey: catalog + ".selected")
        func running(_ files: FileWorkspace) -> Bool { codeWorkbench.runs(files) }
        func last(_ files: FileWorkspace) -> Bool { (files.directoryID?.uuidString ?? "default") == own }
        let opened = directoryWorkspaces(for: profile).filter {
            !$0.root.isEmpty && !shown.contains(identity($0)) && (running($0) || kept.contains(WindowFolder.match(profileID: profileID, path: $0.root)))
        }
        if let best = opened.min(by: { a, b in
            if running(a) != running(b) { return running(a) }
            if last(a) != last(b) { return last(a) }
            return recencyRank(identity(a)) < recencyRank(identity(b))
        }) { return best.directoryID }
        guard !shown.isEmpty else { return remembered }
        guard shown.contains(identity(files(for: profile, directoryID: remembered))) else { return remembered }
        let free = directoryWorkspaces(for: profile).filter { !$0.root.isEmpty && !shown.contains(identity($0)) }
        // The first slot of a server has no identifier of its own, so "none free" is asked separately.
        guard let best = free.min(by: { recencyRank(identity($0)) < recencyRank(identity($1)) }) else { return remembered }
        return best.directoryID
    }
    /// How recently a workspace was shown: in this window first, then in any window.
    func recencyRank(_ identity: String) -> Int {
        if let index = ownRecency.firstIndex(of: identity) { return index }
        return WorkspaceSwitcher.recency.firstIndex(of: identity).map { 1_000 + $0 } ?? Int.max
    }
    func directoryIDs(for profileID: UUID?) -> [String] {
        var seen = Set<String>()
        return ["default"] + (workspaceDefaults.stringArray(forKey: directoryCatalogKey(profileID)) ?? []).filter { UUID(uuidString: $0) != nil && seen.insert($0).inserted }
    }
    func directoryWorkspaces(for profile: ServerProfile?) -> [FileWorkspace] {
        let all = directoryIDs(for: profile?.id).map { files(for: profile, directoryID: UUID(uuidString: $0)) }
        // Closing the legacy slot resets it. Keep that empty slot out of the
        // switcher while other directories exist, without changing saved IDs.
        return all.filter { files in
            all.count == 1 || files.directoryID != nil || !files.root.isEmpty ||
                attachedSessions.contains { $0.profile?.id == profile?.id && $0.directoryWorkspaceID == nil }
        }
    }
    func selectDirectoryWorkspace(_ files: FileWorkspace) {
        selectDirectory(profileID: files.profile?.id, directoryID: files.directoryID)
        files.requestFocus(files.enabled && !files.terminalMaximized ? .editor : .terminal)
    }
    /// A directory's identity is independent of its current terminal selection.
    /// The legacy workspace remains the first slot, retaining existing settings.
    func directoryWorkspaceForPath(_ path: String?, profile: ServerProfile?) -> FileWorkspace {
        let normalized = RecentWorkspace.normalize(path)
        if let existing = directoryWorkspaces(for: profile).first(where: { RecentWorkspace.normalize($0.root) == normalized }) { return existing }
        let current = files(for: profile)
        let hasTerminals = attachedSessions.contains { $0.profile?.id == profile?.id && $0.directoryWorkspaceID == current.directoryID }
        if current.root.isEmpty && !hasTerminals { return current }
        let id = UUID(), key = directoryCatalogKey(profile?.id)
        let ids = workspaceDefaults.stringArray(forKey: key) ?? []
        workspaceDefaults.set(ids + [id.uuidString], forKey: key)
        let created = files(for: profile, directoryID: id)
        created.root = normalized ?? ""; created.persist()
        return created
    }
    @discardableResult
    func openDirectoryWorkspace(_ path: String, profile: ServerProfile?) async -> FileWorkspace? {
        let origin = files(for: profile)
        await origin.prepare(store: self)
        guard let service = origin.service else { errorMessage = origin.error; return nil }
        do {
            let listing = try await service.list(path, showHidden: origin.showHidden)
            let destination = directoryWorkspaceForPath(listing.path, profile: profile)
            destination.showHidden = origin.showHidden
            destination.adoptRootListing(listing)
            destination.enabled = true
            selectDirectoryWorkspace(destination)
            await destination.prepare(store: self)
            return destination
        } catch { errorMessage = "Unable to open folder workspace: " + error.localizedDescription; return nil }
    }
    func chooseDirectoryWorkspace(from origin: FileWorkspace? = nil) {
        let origin = origin ?? currentFiles
        directoryBrowser = DirectoryBrowser(profile: origin.profile, path: origin.root.isEmpty ? "~" : origin.root) { [weak self] path in
            guard let self else { throw CancellationError() }
            await origin.prepare(store: self)
            try Task.checkCancellation()
            guard let service = origin.service else { throw WorkspaceError.message(origin.error ?? "Unable to connect to the server.") }
            return try await service.list(path, showHidden: true)
        }
    }
    func closeDirectoryWorkspace(_ files: FileWorkspace, ask: Bool = true, checkEditor: Bool = true) {
        if checkEditor, let editor = codeWorkbench.existing(for: files), editor.commandsReady {
            Task {
                do { _ = try await editor.request("status"); closeDirectoryWorkspace(files, ask: ask, checkEditor: false) }
                catch { errorMessage = "Reconnect the editor and save your changes before closing this workspace." }
            }
            return
        }
        let id = files.directoryID
        let wasSelected = selectedProfileID == files.profile?.id && selectedDirectoryID == id
        let wasRemembered = selectedDirectoryID(for: files.profile?.id) == id
        guard codeWorkbench.existing(for: files)?.dirtyPaths.isEmpty != false else { errorMessage = "Save the changes in this workspace before closing it."; return }
        let members = attachedSessions.filter { $0.profile?.id == files.profile?.id && $0.directoryWorkspaceID == id }
        if ask && members.contains(where: { !$0.ended }) {
            let alert = NSAlert(); alert.messageText = "Close this folder workspace?"
            alert.informativeText = "This also closes \(members.count) terminals in the folder. Their foreground commands may end. Files on disk will remain untouched."
            alert.addButton(withTitle: "Close Workspace"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        members.forEach { close($0, ask: false) }
        codeWorkbench.close(files)
        files.cleanCache()
        for suffix in [".root", ".tabs", ".recent", ".enabled"] { workspaceDefaults.removeObject(forKey: files.key + suffix) }
        let key = directoryCatalogKey(files.profile?.id)
        workspaceDefaults.set(directoryIDs(for: files.profile?.id).filter { $0 != "default" && $0 != id?.uuidString }, forKey: key)
        fileWorkspaces = fileWorkspaces.filter { $0.value !== files }
        // Every window has its own record of the slot. One that is not using it forgets it too:
        // its copy still named the folder, listed it, and wrote it back the next time it was touched.
        for other in family where other !== self { other.forgetClosedSlot(files.key) }
        terminalLayouts[id.map { .directory(files.profile?.id, $0) } ?? .workspace(files.profile?.id)] = nil
        if wasSelected || wasRemembered {
            let next = directoryWorkspaces(for: files.profile).first
            ownDirectories[key] = nil
            workspaceDefaults.set(next?.directoryID?.uuidString ?? "default", forKey: key + ".selected")
            // Only a window that was showing the folder goes on to the next one. From the start
            // page (or the organizer) the selection moves and the page stays.
            if wasSelected { selectDirectory(profileID: files.profile?.id, directoryID: next?.directoryID, show: page == .workspace) }
        }
        objectWillChange.send()
        NotificationCenter.default.post(name: .harborWindowFoldersChanged, object: nil)
    }
}

extension AppStore {
    /// Another window closed a folder: this window's record of that slot goes, unless it is in use here.
    func forgetClosedSlot(_ key: String) {
        guard let mine = fileWorkspaces.values.first(where: { $0.key == key }) else { return }
        guard !(page == .workspace && currentFiles === mine), !codeWorkbench.runs(mine) else { return }
        codeWorkbench.close(mine); mine.cleanCache()
        fileWorkspaces = fileWorkspaces.filter { $0.value !== mine }
        objectWillChange.send()
    }
}

extension FileWorkspace {
    var directoryTitle: String {
        let name = (root as NSString).lastPathComponent
        return root == "/" ? "/" : name.isEmpty ? "Login Directory" : name
    }
}

struct DirectoryWorkspaceList: View {
    @EnvironmentObject var store: AppStore
    let profile: ServerProfile?
    let didSelect: () -> Void
    var body: some View {
        let workspaces = store.directoryWorkspaces(for: profile)
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(workspaces, id: \.key) { files in
                        DirectoryWorkspaceRow(files: files, didSelect: didSelect)
                    }
                }.padding(6)
            }.frame(height: min(350, CGFloat(workspaces.count) * 51 + 12))
            Rectangle().fill(Color.harborBorder).frame(height: 1)
            // Which window a folder is kept in is arranged in one place, for all windows.
            Button { didSelect(); store.organizerVisible = true } label: {
                HStack(spacing: 8) { HarborSymbol(systemName: "rectangle.3.group").frame(width: 18); Text("Folders in Windows…"); Spacer(minLength: 0) }
                    .padding(.horizontal, 16).frame(height: 34).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(Color.harborMuted)
        }.frame(width: 330)
            .harborFont(12).foregroundStyle(Color.harborForeground).background(Color.harborBackground)
    }
}

private struct DirectoryWorkspaceRow: View {
    @ObservedObject var files: FileWorkspace
    @EnvironmentObject var store: AppStore
    let didSelect: () -> Void
    @State private var hovered = false
    private var selected: Bool { store.selectedProfileID == files.profile?.id && store.selectedDirectoryID == files.directoryID }
    var body: some View {
        HStack(spacing: 0) {
            Button { store.selectDirectoryWorkspace(files); didSelect() } label: {
                HStack(spacing: 9) {
                    HarborSymbol(systemName: selected ? "checkmark" : "folder").frame(width: 18).foregroundStyle(Color.harborAccent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(files.directoryTitle).lineLimit(1).truncationMode(.middle)
                        Text(files.root.isEmpty ? "Default login directory" : files.root)
                            .harborFont(10).foregroundStyle(Color.harborMuted).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }.padding(.leading, 10).frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
            }.buttonStyle(.plain).help(files.root).accessibilityLabel("Open " + files.directoryTitle)
            Button { store.closeDirectoryWorkspace(files) } label: { HarborSymbol(systemName: "xmark").frame(width: 30, height: 38) }
                .buttonStyle(.plain).foregroundStyle(Color.harborMuted).opacity(hovered || selected ? 1 : 0.6)
                .accessibilityLabel("Close workspace " + files.directoryTitle).help("Close workspace; keep files on disk")
        }.background(hovered || selected ? Color.harborHover : .clear, in: RoundedRectangle(cornerRadius: 7))
            .onHover { hovered = $0 }
    }
}
