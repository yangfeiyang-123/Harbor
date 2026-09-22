import SwiftUI
import HarborCore

extension AppStore {
    func directoryCatalogKey(_ profileID: UUID?) -> String { "directories." + (profileID?.uuidString ?? "local") }
    func selectedDirectoryID(for profileID: UUID?) -> UUID? {
        let key = directoryCatalogKey(profileID)
        guard let value = workspaceDefaults.string(forKey: key + ".selected"), directoryIDs(for: profileID).contains(value) else { return nil }
        return UUID(uuidString: value)
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
            all.count == 1 || files.directoryID != nil || !files.root.isEmpty || !files.documents.isEmpty || !files.savedOpenPaths.isEmpty ||
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
        if current.root.isEmpty && current.documents.isEmpty && !hasTerminals { return current }
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
            if destination.entries[listing.path] == nil { destination.adoptRootListing(listing) }
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
    func closeDirectoryWorkspace(_ files: FileWorkspace, ask: Bool = true) {
        let id = files.directoryID
        let wasSelected = selectedProfileID == files.profile?.id && selectedDirectoryID == id
        let wasRemembered = selectedDirectoryID(for: files.profile?.id) == id
        guard !files.hasUnsavedChanges else { errorMessage = "Save the changes in this workspace before closing it."; return }
        let members = attachedSessions.filter { $0.profile?.id == files.profile?.id && $0.directoryWorkspaceID == id }
        if ask && members.contains(where: { !$0.ended }) {
            let alert = NSAlert(); alert.messageText = "Close this folder workspace?"
            alert.informativeText = "This also closes \(members.count) terminals in the folder. Their foreground commands may end. Files on disk will remain untouched."
            alert.addButton(withTitle: "Close Workspace"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        members.forEach { close($0, ask: false) }
        files.cleanCache()
        for suffix in [".root", ".tabs", ".recent", ".enabled"] { workspaceDefaults.removeObject(forKey: files.key + suffix) }
        let key = directoryCatalogKey(files.profile?.id)
        workspaceDefaults.set(directoryIDs(for: files.profile?.id).filter { $0 != "default" && $0 != id?.uuidString }, forKey: key)
        fileWorkspaces = fileWorkspaces.filter { $0.value !== files }
        terminalLayouts[id.map { .directory(files.profile?.id, $0) } ?? .workspace(files.profile?.id)] = nil
        if wasSelected || wasRemembered {
            let next = directoryWorkspaces(for: files.profile).first
            workspaceDefaults.set(next?.directoryID?.uuidString ?? "default", forKey: key + ".selected")
            if wasSelected { selectDirectory(profileID: files.profile?.id, directoryID: next?.directoryID) }
        }
        objectWillChange.send()
    }
}

extension FileWorkspace {
    var directoryTitle: String {
        let name = (root as NSString).lastPathComponent
        return root == "/" ? "/" : name.isEmpty ? "Login Directory" : name
    }
}

struct DirectoryWorkspaceMenu: View {
    @EnvironmentObject var store: AppStore
    @State private var expanded = false
    var body: some View {
        HStack(spacing: 3) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 5) {
                    HarborSymbol(systemName: "folder")
                    Text(store.currentFiles.directoryTitle).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }.padding(.horizontal, 8).frame(height: 26).contentShape(Rectangle())
            }.buttonStyle(HarborGlassButtonStyle()).frame(maxWidth: 200).fixedSize(horizontal: false, vertical: true)
                .harborFont(11).accessibilityLabel("Switch folder workspace").accessibilityIdentifier("directory-workspaces")
                .popover(isPresented: $expanded) {
                    DirectoryWorkspaceList(profile: store.selectedProfile) { expanded = false }.environmentObject(store)
                }
                .contextMenu { WorkspaceFinderAction(workspace: store.currentFiles) }
            Button { store.chooseDirectoryWorkspace() } label: {
                HarborSymbol(systemName: "plus").frame(width: 26, height: 26).contentShape(Rectangle())
            }.buttonStyle(HarborGlassButtonStyle()).accessibilityLabel("Add folder workspace").accessibilityIdentifier("add-directory-workspace")
                .compactHint("Add folder workspace", edge: .minY)
        }
    }
}

struct DirectoryWorkspaceList: View {
    @EnvironmentObject var store: AppStore
    let profile: ServerProfile?
    let didSelect: () -> Void
    var body: some View {
        let workspaces = store.directoryWorkspaces(for: profile)
        ScrollView {
            VStack(spacing: 3) {
                ForEach(workspaces, id: \.key) { files in
                    DirectoryWorkspaceRow(files: files, didSelect: didSelect)
                }
            }.padding(6)
        }.frame(width: 330, height: min(350, CGFloat(workspaces.count) * 51 + 12))
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
