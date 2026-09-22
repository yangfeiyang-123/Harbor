import SwiftUI
import AppKit
import CryptoKit
import HarborCore
import Darwin

enum AppPage: String, CaseIterable { case workspace = "Workbench", proxy = "Reverse Proxy", recent = "Recents", display = "Remote Display" }

@MainActor
final class AppStore: ObservableObject {
    @Published var profiles: [ServerProfile] = []
    @Published var rules: [ForwardRule] = []
    @Published var records: [SessionRecord] = []
    @Published var recents: [RecentWorkspace] = []
    @Published var sessions: [TerminalSession] = []
    @Published var terminalLayouts: [TerminalScope: TerminalArrangement] = [:]
    let dragOwnerID = UUID()
    @Published var activeDrag: HarborDragItem?
    var dragEndMonitor: Any?
    var dragEndTimer: Timer?
    @Published private var workspace = WorkspaceSelection()
    @Published var page = AppPage.recent
    @Published var errorMessage: String?
    @Published var directoryBrowser: DirectoryBrowser?
    @Published var importing = false
    @Published var catalogNotice: String?
    @Published var loading = true
    @Published var connectionStates: [UUID: String] = [:]
    let history: HistoryStore
    let proxy = ProxyController()
    lazy var remoteDisplays = RemoteDisplayController(root: history.root)
    private var connecting = Set<String>()
    private var plans: [UUID: String] = [:]
    private var timer: Timer?
    var directoryTrackingTask: Task<Void, Never>?
    private var persistenceAvailable = true
    private var refreshing = false
    private var didLoad = false
    var recoveryTimer: Timer?
    var recoveryWritable = true
    var shuttingDown = false
    lazy var recoveryStore = TerminalRecoveryStore(root: history.root.appendingPathComponent("TerminalRecovery"))
    var fileWorkspaces: [String: FileWorkspace] = [:]
    let workspaceDefaults: UserDefaults
    var currentFiles: FileWorkspace { files(for: selectedProfile) }
    var hasUnsavedFiles: Bool { fileWorkspaces.values.contains { $0.hasUnsavedChanges } }
    func files(for profile: ServerProfile?) -> FileWorkspace {
        files(for: profile, directoryID: selectedDirectoryID(for: profile?.id))
    }
    func files(for profile: ServerProfile?, directoryID: UUID?) -> FileWorkspace {
        let key = (profile?.id.uuidString ?? "local") + (directoryID.map { ".directory." + $0.uuidString } ?? "")
        if let current = fileWorkspaces[key] { return current }
        let files = FileWorkspace(profile: profile, defaults: workspaceDefaults, directoryID: directoryID)
        files.onDocumentChange = { [weak self] in self?.objectWillChange.send() }
        files.onNavigate = { [weak self] path in self?.remember(profile: profile, directory: path) }
        fileWorkspaces[key] = files
        return files
    }
    func toggleFiles() {
        currentFiles.enabled.toggle(); objectWillChange.send()
        currentFiles.requestFocus(currentFiles.enabled ? .editor : .terminal)
    }
    func toggleTerminalMaximized() {
        guard !loading, page == .workspace, currentFiles.enabled else { return }
        currentFiles.setTerminalMaximized(!currentFiles.terminalMaximized)
        objectWillChange.send()
    }
    func toggleTerminalPanel() {
        guard page == .workspace, currentFiles.enabled else { return }
        let files = currentFiles
        files.terminalVisible.toggle()
        files.requestFocus(files.terminalVisible ? .terminal : .editor)
        objectWillChange.send()
    }
    func toggleWorkspaceFocus() {
        page = .workspace
        let files = currentFiles
        let responder = NSApp.keyWindow?.firstResponder as? NSView
        let terminalFocused = activeSession.map { session in
            responder === session.terminal || responder?.isDescendant(of: session.terminal) == true
        } ?? false
        if terminalFocused || !files.enabled {
            files.enabled = true; files.requestFocus(.editor)
        } else {
            files.terminalVisible = true
            if let activeSession, activeSession.ended { reconnect(activeSession) }
            else if activeSession == nil { openWorkspaceTerminal() }
            files.requestFocus(.terminal)
        }
        objectWillChange.send()
    }
    func openWorkspaceTerminal() {
        let files = currentFiles
        openTerminal(selectedProfile)
        files.terminalVisible = true
    }
    func openDroppedWorkspace(_ plan: WorkspaceDropPlan, target: FileWorkspace? = nil) async {
        let profile = profiles.first { $0.id == plan.profileID }
        guard plan.profileID == nil || profile != nil else { errorMessage = "This server has been removed. Add it again before opening the folder."; return }
        if !plan.hasDirectories, let target, target.profile?.id == plan.profileID {
            await target.prepare(store: self)
            for entry in plan.files { await target.open(entry) }
            return
        }
        for root in plan.directoryRoots {
            _ = await openDirectoryWorkspace(root, profile: profile)
        }
        if !plan.files.isEmpty {
            let files = plan.hasDirectories ? self.files(for: profile) : await openDirectoryWorkspace(plan.root, profile: profile)
            if let files { for entry in plan.files { await files.open(entry) } }
        }
    }
    var socketRoot: URL
    var attachedSessions: [TerminalSession] { sessions.filter { !$0.detached } }
    var workspaceSessions: [TerminalSession] { attachedSessions.filter { $0.profile?.id == selectedProfileID && $0.directoryWorkspaceID == selectedDirectoryID } }
    var selectedProfileID: UUID? { workspace.profileID }
    var selectedDirectoryID: UUID? { workspace.directoryID }
    var selectedSessionID: UUID? { workspace.sessionID }
    var selectedProfile: ServerProfile? { profiles.first { $0.id == selectedProfileID } }
    var activeSession: TerminalSession? { workspaceSessions.first { $0.id == selectedSessionID } }
    var activeCount: Int { sessions.filter { !$0.ended }.count }
    init(historyRoot: URL? = nil, workspaceDefaults: UserDefaults = .standard) {
        WorkspaceShortcut.migratePreference(in: workspaceDefaults)
        self.workspaceDefaults = workspaceDefaults
        let env = ProcessInfo.processInfo.environment
        let previewRoot = Bundle.main.bundleIdentifier?.hasSuffix(".preview") == true ? Bundle.main.object(forInfoDictionaryKey: "HarborPreviewDataDirectory") as? String : nil
        let root = historyRoot ?? (env["HARBOR_DATA_DIR"] ?? previewRoot).map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/HarborSSH", isDirectory: true)
        history = HistoryStore(location: root)
        socketRoot = URL(fileURLWithPath: "/tmp/harbor-\(getuid())", isDirectory: true)
    }
    func load() async {
        guard !didLoad else { return }; didLoad = true
        defer { loading = false }
        let history = self.history
        do {
            try prepareSocketDirectory()
            let loaded = try await Task.detached(priority: .userInitiated) {
                try history.prepare()
                return (try history.read("servers.json", as: [ServerProfile].self) ?? [],
                        try history.read("forwards.json", as: [ForwardRule].self) ?? [],
                        try history.read("history.json", as: [SessionRecord].self) ?? [],
                        try history.read("recent-workspaces.json", as: [RecentWorkspace].self))
            }.value
            profiles = loaded.0; rules = loaded.1; records = loaded.2
            recents = loaded.3 ?? RecentWorkspace.migrate(records, available: Set(profiles.map(\.id)))
            for i in profiles.indices { profiles[i].recordOutput = false }
        } catch { persistenceAvailable = false; recoveryWritable = false; errorMessage = "Unable to read local data: \(error.localizedDescription). Saving is paused and the original files are intact. Open the data folder in Settings, repair it, then restart Harbor." }
        if persistenceAvailable {
            await consolidateServers()
            ServerIcons.assignMissing(in: &profiles)
            // New terminals use Harbor's PTY host. Existing tmux IDs remain recoverable.
            for i in profiles.indices { profiles[i].useTmux = false }
            save()
        }
        selectWorkspace(profiles.first?.id)
        timer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in Task { @MainActor in if NSApp.isActive { await self?.refreshConnections() } } }
        if persistenceAvailable && profiles.isEmpty && ProcessInfo.processInfo.environment["HARBOR_NO_IMPORT"] != "1" { await importSSHConfig() }
        await restoreTerminals()
        startRecoveryCheckpoints()
        page = sessions.isEmpty ? .recent : .workspace
    }
    func selectWorkspace(_ profileID: UUID?) {
        selectDirectory(profileID: profileID, directoryID: selectedDirectoryID(for: profileID))
    }
    func selectDirectory(profileID: UUID?, directoryID: UUID?) {
        workspace.selectWorkspace(profileID, available: attachedSessions.filter { $0.profile?.id == profileID && $0.directoryWorkspaceID == directoryID }.map(\.id), directoryID: directoryID)
        workspaceDefaults.set(directoryID?.uuidString ?? "default", forKey: directoryCatalogKey(profileID) + ".selected")
        if let activeSession { selectInArrangement(activeSession) }
        page = .workspace
    }
    func selectSession(_ session: TerminalSession, requestFocus: Bool = true) {
        guard !session.detached else { return }
        workspace.selectSession(session.id, profileID: session.profile?.id, directoryID: session.directoryWorkspaceID); page = .workspace
        workspaceDefaults.set(session.directoryWorkspaceID?.uuidString ?? "default", forKey: directoryCatalogKey(session.profile?.id) + ".selected")
        selectInArrangement(session)
        if requestFocus { currentFiles.terminalVisible = true; currentFiles.requestFocus(.terminal) }
    }
    func remember(profile: ServerProfile?, directory: String?, tmuxName: String? = nil) {
        var item = RecentWorkspace(serverID: profile?.id, serverName: profile?.name ?? "Local", directory: directory, tmuxName: tmuxName)
        if item.tmuxName == nil { item.tmuxName = recents.first(where: { $0.id == item.id })?.tmuxName }
        recents = RecentWorkspace.merged([item] + recents, available: Set(profiles.map(\.id)))
        save()
    }
    func removeRecent(_ item: RecentWorkspace) { recents.removeAll { $0.id == item.id }; save() }
    func openRecent(_ item: RecentWorkspace) {
        let profile = profiles.first { $0.id == item.serverID }
        guard item.serverID == nil || profile != nil else { errorMessage = "This server has been removed. Add it again to connect."; return }
        let existing = attachedSessions.first { $0.profile?.id == item.serverID && RecentWorkspace.normalize($0.workingDirectory) == item.directory }
        let files = existing.map { self.files(for: profile, directoryID: $0.directoryWorkspaceID) } ?? directoryWorkspaceForPath(item.directory, profile: profile)
        if let directory = item.directory {
            // A terminal may have been opened in a child folder from the file
            // tree. Returning to it must not retarget its parent workspace.
            if existing == nil || files.root.isEmpty { files.root = directory }
            files.enabled = true; files.persist()
        }
        selectDirectoryWorkspace(files)
        if let active = workspaceSessions.first(where: { RecentWorkspace.normalize($0.workingDirectory) == item.directory }) {
            selectSession(active); remember(profile: profile, directory: item.directory, tmuxName: active.tmuxName)
            if files.enabled { Task { await files.activate(store: self) } }
        } else { openTerminal(profile, workingDirectory: item.directory, useWorkspaceDirectory: false) }
    }
    private func connected(_ session: TerminalSession) async {
        session.terminal.fileDropAllowed = true
        if session.initialDirectoryTitle == nil { await refreshTerminalDirectories([session]) }
        remember(profile: session.profile, directory: session.workingDirectory, tmuxName: session.tmuxName)
        let files = files(for: session.profile, directoryID: session.directoryWorkspaceID)
        if files.enabled {
            if files.error != nil { files.entries[files.root] = nil }
            await files.activate(store: self)
        }
    }
    private func prepareSocketDirectory() throws {
        var info = stat()
        if lstat(socketRoot.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else { throw CocoaError(.fileWriteNoPermission) }
        } else { try FileManager.default.createDirectory(at: socketRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: socketRoot.path)
    }
    func save() {
        guard persistenceAvailable else { errorMessage = "Saving is paused because the data files could not be read. Repair them and restart Harbor."; return }
        do {
            try history.write(profiles, name: "servers.json"); try history.write(rules, name: "forwards.json"); try history.write(recents, name: "recent-workspaces.json")
        } catch { errorMessage = "Unable to save: \(error.localizedDescription)" }
    }
    func importSSHConfig() async {
        guard !importing else { return }; importing = true; defer { importing = false }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        for entry in SSHConfig.entries(at: url) {
            let alias = entry.primary
            guard !alias.lowercased().contains("tunnel"), !alias.lowercased().contains("transport"), !profiles.contains(where: { entry.aliases.contains($0.host) || !Set($0.aliases ?? []).isDisjoint(with: entry.aliases) }) else { continue }
            let result = await ProcessRunner.run("/usr/bin/ssh", ["-G", "--", alias], timeout: 8)
            guard result.succeeded else { continue }
            let c = SSHConfig.effective(result.output)
            profiles.append(ServerProfile(name: alias, host: alias, user: c["user"] ?? "", port: Int(c["port"] ?? "22") ?? 22, imported: true, group: "SSH Config", useTmux: false))
        }
        await consolidateServers(); ServerIcons.assignMissing(in: &profiles); save()
    }
    func consolidateServers() async {
        let snapshot = profiles
        var canonical: [String: UUID] = [:], remap: [UUID: UUID] = [:]
        // Existing active sessions retain their profile identity.
        let activeIDs = Set(sessions.filter { !$0.ended }.compactMap { $0.profile?.id })
        let ordered = snapshot.sorted { activeIDs.contains($0.id) && !activeIDs.contains($1.id) }
        for p in ordered {
            let result = await ProcessRunner.run("/usr/bin/ssh", SSHArguments.connection(p) + ["-G", "--", p.host], timeout: 8)
            guard result.succeeded, let key = ServerIdentity.key(effective: SSHConfig.effective(result.output)) else { continue }
            if let id = canonical[key], !activeIDs.contains(p.id) { remap[p.id] = id }
            else if canonical[key] == nil { canonical[key] = p.id }
        }
        guard profiles == snapshot else { return }
        guard !remap.isEmpty else { catalogNotice = "\(profiles.count) servers · Checked for duplicates"; return }
        do {
            // Preserve all associations before a one-time migration.
            let stamp = UUID().uuidString
            try history.write(profiles, name: "servers-before-merge-\(stamp).json")
            try history.write(records, name: "history-before-merge-\(stamp).json")
            try history.write(rules, name: "forwards-before-merge-\(stamp).json")
            for (old, new) in remap {
                guard let oldProfile = profiles.first(where: { $0.id == old }), let i = profiles.firstIndex(where: { $0.id == new }) else { continue }
                profiles[i].aliases = Array(Set((profiles[i].aliases ?? []) + (oldProfile.aliases ?? []) + [oldProfile.host, oldProfile.name])).sorted()
                profiles[i].recordOutput = profiles[i].recordOutput && oldProfile.recordOutput
                profiles[i].useTmux = profiles[i].useTmux || oldProfile.useTmux
                for j in records.indices where records[j].serverID == old {
                    records[j].serverID = new; records[j].serverName = profiles[i].name
                    if records[j].title.hasPrefix(oldProfile.name + " · ") { records[j].title = profiles[i].name + records[j].title.dropFirst(oldProfile.name.count) }
                }
                for j in rules.indices where rules[j].serverID == old { rules[j].serverID = new }
                for j in recents.indices where recents[j].serverID == old { recents[j].serverID = new; recents[j].serverName = profiles[i].name }
            }
            profiles.removeAll { remap[$0.id] != nil }
            recents = RecentWorkspace.merged(recents, available: Set(profiles.map(\.id)))
            if let selectedProfileID, let replacement = remap[selectedProfileID] { selectWorkspace(replacement) }
            catalogNotice = "Merged \(remap.count) duplicate configurations and updated Recents"; save()
        } catch { errorMessage = "Backup failed. The original configuration was kept: \(error.localizedDescription)" }
    }
    func upsert(_ profile: ServerProfile) {
        if fileWorkspaces.values.contains(where: { $0.profile?.id == profile.id && $0.hasUnsavedChanges }) {
            errorMessage = "Save your code changes on this server before changing its connection settings."; return
        }
        fileWorkspaces = fileWorkspaces.filter { $0.value.profile?.id != profile.id }
        if let i = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[i] = profile; plans[profile.id] = nil }
        else { profiles.append(profile) }
        ServerIcons.assignMissing(in: &profiles)
        selectWorkspace(profile.id); save()
        Task { await consolidateServers() }
    }
    func remove(_ profile: ServerProfile) {
        guard !fileWorkspaces.values.contains(where: { $0.profile?.id == profile.id && $0.hasUnsavedChanges }) else { errorMessage = "Save your code changes on this server first."; return }
        guard !sessions.contains(where: { $0.profile?.id == profile.id && !$0.ended }) else { errorMessage = "Close this server’s active terminals first."; return }
        guard !rules.contains(where: { $0.serverID == profile.id }) else { errorMessage = "Delete this server’s forwarding rules first."; return }
        profiles.removeAll { $0.id == profile.id }; recents.removeAll { $0.serverID == profile.id }; selectWorkspace(profiles.first?.id); save()
    }
    func resolveSocket(_ p: ServerProfile) async throws -> String {
        if let cached = plans[p.id] { return cached }
        guard p.validationError == nil else { throw NSError(domain: "Harbor", code: 1, userInfo: [NSLocalizedDescriptionKey: p.validationError!]) }
        let result = await ProcessRunner.run("/usr/bin/ssh", SSHArguments.connection(p) + ["-G", "--", p.host], timeout: 10)
        guard result.succeeded else { throw NSError(domain: "Harbor", code: 2, userInfo: [NSLocalizedDescriptionKey: result.output]) }
        let c = SSHConfig.effective(result.output), configured = c["controlpath"].map { NSString(string: $0).expandingTildeInPath }
        let socket: String
        if let configured, configured != "none", configured.hasPrefix("/"), configured.utf8.count < 100, !configured.contains("%") { socket = configured }
        else {
            let identity = [c["hostname"], c["user"], c["port"], c["proxyjump"], c["proxycommand"], c["identityfile"]].map { $0 ?? "" }.joined(separator: "|")
            let hash = SHA256.hash(data: Data(identity.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
            socket = socketRoot.appendingPathComponent(hash).path
        }
        plans[p.id] = socket; return socket
    }
    @discardableResult
    func openTerminal(_ profile: ServerProfile?, detached: Bool = false, resumeTmux: String? = nil, workingDirectory: String? = nil, useWorkspaceDirectory: Bool = true, windowID: UUID? = nil, directoryWorkspace: FileWorkspace? = nil, recoveredOutput: String? = nil, remotePTYID: UUID? = nil, remotePTYReconnect: Bool = false) -> UUID? {
        guard !loading else { return nil }
        guard persistenceAvailable else { errorMessage = "The data files could not be read. Repair them and restart Harbor."; return nil }
        // A workspace belongs to its server even while its file browser is hidden.
        // Explicit recent/reconnect destinations may intentionally use the login directory.
        let files = directoryWorkspace ?? self.files(for: profile)
        let directory = workingDirectory ?? (useWorkspaceDirectory ? RecentWorkspace.normalize(files.root) : nil)
        if let directory, profile == nil {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
                errorMessage = "The working directory no longer exists. Refresh the folder and try again."; return nil
            }
        }
        let existingTitles = Set(sessions.filter { $0.profile?.id == profile?.id }.map(\.title))
        var index = 1
        while existingTitles.contains("\(profile?.name ?? "Local") · \(index)") { index += 1 }
        do {
            let s = try TerminalSession(profile: profile, title: "\(profile?.name ?? "Local") · \(index)", detached: detached, history: history, tmuxName: resumeTmux, workingDirectory: directory, remotePTYID: remotePTYID)
            s.remotePTYReconnect = remotePTYReconnect
            if let recoveredOutput { s.restoreOutput(recoveredOutput) }
            s.directoryWorkspaceID = files.directoryID
            if detached, let windowID { s.windowID = windowID }
            s.onEnd = { [weak self] s, code in self?.finish(s, code: code) }
            s.terminal.onDropError = { [weak self] message in self?.errorMessage = message }
            sessions.append(s)
            startDirectoryTracking(); startRecoveryCheckpoints()
            registerTerminal(s)
            if !detached { selectSession(s) }
            save()
            if let profile { Task { await connect(s, profile: profile) } }
            else { s.start(executable: "/bin/zsh", arguments: ["-l"]); remember(profile: nil, directory: directory) }
            return s.id
        } catch { errorMessage = "Unable to create a terminal: \(error.localizedDescription)"; return nil }
    }
    private func connect(_ session: TerminalSession, profile: ServerProfile) async {
        do {
            let socket = try await resolveSocket(profile); session.socket = socket
            if connecting.contains(socket) {
                session.status = "Waiting for initial connection"
                while connecting.contains(socket) && !session.ended { try? await Task.sleep(nanoseconds: 500_000_000) }
                guard !session.ended else { return }
                let check = await ProcessRunner.run("/usr/bin/ssh", SSHArguments.probe(profile, socket: socket), timeout: 20)
                guard !session.ended else { return }
                guard check.succeeded && check.output.contains("HARBOR_SSH_READY") else {
                    session.status = "Initial connection incomplete · Reconnect"; session.ended = true
                    session.show("The initial connection did not complete. Finish authentication, then click Reconnect."); finish(session, code: nil); return
                }
                session.start(executable: "/usr/bin/ssh", arguments: try RemoteTerminalHost.arguments(session, profile: profile, socket: socket, requireMaster: true))
                try await waitForRemotePTY(session)
                session.ready = true; session.status = "Using shared connection"; await connected(session); return
            }
            connecting.insert(socket); defer { connecting.remove(socket) }
            guard !session.ended else { return }
            session.start(executable: "/usr/bin/ssh", arguments: try RemoteTerminalHost.arguments(session, profile: profile, socket: socket))
            connectionStates[profile.id] = "Connecting"
            for _ in 0..<150 {
                guard !session.ended else { connectionStates[profile.id] = "Disconnected"; return }
                if FileManager.default.fileExists(atPath: socket) {
                    let check = await ProcessRunner.run("/usr/bin/ssh", SSHArguments.probe(profile, socket: socket), timeout: 20)
                    guard !session.ended else { return }
                    if check.succeeded && check.output.contains("HARBOR_SSH_READY") {
                        try await waitForRemotePTY(session)
                        session.ready = true; session.status = "Connected · Shared with new terminals"; connectionStates[profile.id] = "Connected"; await connected(session); return
                    }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            session.status = "Connection unverified · Authenticate or reconnect"; connectionStates[profile.id] = "Unverified"
        } catch { session.stop(); session.show(error.localizedDescription); session.status = "Connection failed"; finish(session, code: nil) }
    }
    private func waitForRemotePTY(_ session: TerminalSession) async throws {
        guard session.remotePTYID != nil else { return }
        for _ in 0..<200 {
            if session.remoteShellPID != nil { return }
            if session.ended { throw CocoaError(.executableLoad) }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw NSError(domain: "Harbor", code: 1, userInfo: [NSLocalizedDescriptionKey: "The remote terminal did not become ready. Reconnect to retry; saved output is kept."])
    }
    func finish(_ session: TerminalSession, code: Int32?) {
        if !shuttingDown { checkpointTerminals() }
        objectWillChange.send()
    }
    func close(_ session: TerminalSession, ask: Bool = true, endRemoteProcess: Bool = true) {
        if ask && !session.ended {
            let alert = NSAlert(); alert.messageText = "Close this terminal?"
            alert.informativeText = session.remotePTYID != nil ? "Closing ends this remote terminal. Quit Harbor or reconnect to keep the session instead." : session.tmuxName == nil ? "Foreground commands in this terminal may end. The shared SSH connection will remain open." : "The existing tmux session stays on the server."
            alert.addButton(withTitle: "Close Terminal"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        if endRemoteProcess, let id = session.remotePTYID, let profile = session.profile {
            Task {
                do {
                    let socket = try await resolveSocket(profile)
                    let command = try RemoteTerminalHost.command(id: id, mode: "close", directory: nil)
                    let result = await ProcessRunner.run("/usr/bin/ssh", SSHArguments.probe(profile, socket: socket, command: command), timeout: 10)
                    if !result.succeeded { errorMessage = "The terminal was removed locally. The remote process could not be closed while offline; it expires after 24 hours disconnected." }
                } catch { errorMessage = error.localizedDescription }
            }
        }
        let responder = session.terminal.window?.firstResponder as? NSView
        let wasFocused = responder === session.terminal || responder?.isDescendant(of: session.terminal) == true
        let scope = terminalScope(of: session)
        var layout = arrangement(in: scope); layout.remove(session.id); terminalLayouts[scope] = layout
        session.stop(); finish(session, code: nil); sessions.removeAll { $0.id == session.id }
        workspace.removeSession(session.id, profileID: session.profile?.id, remaining: terminalSessions(in: scope).map(\.id), preferred: layout.selectedID, directoryID: session.directoryWorkspaceID)
        checkpointTerminals()
        if wasFocused && !session.detached && currentTerminalScope == scope { currentFiles.requestFocus(.terminal) }
    }
    func reconnect(_ session: TerminalSession) {
        guard sessions.contains(where: { $0 === session }) else { return }
        if !session.ended {
            let alert = NSAlert(); alert.messageText = "Reconnect this terminal?"
            alert.informativeText = session.remotePTYID != nil ? "Reconnect to the same remote process. Disconnected terminals on this server will reconnect together." : session.tmuxName == nil ? "The current foreground command may end. Disconnected terminals on this server will reconnect together." : "Keep the tmux session and reconnect disconnected terminals on this server."
            alert.addButton(withTitle: "Reconnect"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let members = sessions.filter { $0 === session || (session.profile != nil && $0.profile?.id == session.profile?.id && $0.ended) }
        reconnectSessions(members, selected: session)
    }
    func reconnectSessions(_ members: [TerminalSession], selected: TerminalSession?) {
        let members = members.filter { candidate in sessions.contains { $0 === candidate } }
        guard !members.isEmpty else { return }
        let originalProfile = selectedProfileID, originalDirectory = selectedDirectoryID, originalSession = selectedSessionID
        let scopes = Set(members.map { terminalScope(of: $0) })
        let layouts = Dictionary(uniqueKeysWithValues: scopes.map { ($0, arrangement(in: $0)) })
        var replacements = [UUID: UUID]()
        for old in members {
            let directory = old.effectiveDirectory
            let output = old.recoveryOutput()
            guard let id = openTerminal(old.profile, detached: old.detached, resumeTmux: old.tmuxName,
                workingDirectory: directory, useWorkspaceDirectory: false, windowID: old.windowID,
                directoryWorkspace: files(for: old.profile, directoryID: old.directoryWorkspaceID), recoveredOutput: output,
                remotePTYID: old.remotePTYID, remotePTYReconnect: old.remotePTYReconnect),
                  let new = sessions.first(where: { $0.id == id }) else { continue }
            close(old, ask: false, endRemoteProcess: false)
            new.customTitle = old.customTitle; new.tabWidth = old.tabWidth; new.currentDirectory = directory
            new.initialDirectoryTitle = old.initialDirectoryTitle ?? new.initialDirectoryTitle
            replacements[old.id] = id
        }
        for (scope, original) in layouts {
            var layout = original
            for old in members where terminalScope(of: old) == scope {
                if let new = replacements[old.id] { layout.replace(old.id, with: new) } else { layout.remove(old.id) }
            }
            terminalLayouts[scope] = layout
        }
        selectDirectory(profileID: originalProfile, directoryID: originalDirectory)
        let preferred = selected.flatMap { replacements[$0.id] } ?? originalSession.flatMap { replacements[$0] ?? $0 }
        if let id = preferred, let chosen = sessions.first(where: { $0.id == id }) { activateTerminal(chosen) }
        checkpointTerminals()
        objectWillChange.send()
    }
    func refreshConnections() async {
        guard !refreshing else { return }; refreshing = true; defer { refreshing = false }
        for (id, socket) in plans {
            guard !connecting.contains(socket), let p = profiles.first(where: { $0.id == id }) else { continue }
            let check = await ProcessRunner.run("/usr/bin/ssh", SSHArguments.probe(p, socket: socket), timeout: 25)
            connectionStates[id] = check.succeeded && check.output.contains("HARBOR_SSH_READY") ? "Connected" : "Connection unavailable"
        }
    }
    func shutdown() {
        guard !shuttingDown else { return }
        checkpointTerminals(synchronously: true)
        shuttingDown = true; recoveryTimer?.invalidate(); recoveryTimer = nil
        directoryBrowser?.cancel(); directoryBrowser = nil
        timer?.invalidate(); timer = nil
        directoryTrackingTask?.cancel(); directoryTrackingTask = nil; endDrag()
        for session in sessions { session.stop(); finish(session, code: nil) }
        for workspace in fileWorkspaces.values { workspace.cleanCache() }
        remoteDisplays.stopAll()
        proxy.stopAll(); save()
    }
}
