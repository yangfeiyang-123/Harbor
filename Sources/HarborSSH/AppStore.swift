import SwiftUI
import AppKit
import CryptoKit
import HarborCore
import Darwin

enum AppPage: String, CaseIterable { case workspace = "Workbench", proxy = "Reverse Proxy", recent = "Recents", display = "Remote Display", terminal = "Terminal" }

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
    @Published private var workspace = WorkspaceSelection() { didSet { updateWorkspaceClaim() } }
    @Published var page = AppPage.recent {
        didSet {
            // Reverse Proxy and Remote Display are looked at and left again: their bar leads back
            // to the page they were opened from.
            if Self.sidePages.contains(page), !Self.sidePages.contains(oldValue) { pageReturn = oldValue }
            updateWorkspaceClaim()
        }
    }
    static let sidePages: Set<AppPage> = [.proxy, .display]
    /// Where a side page was opened from: the editor, a terminal, or the start page.
    private(set) var pageReturn = AppPage.recent
    /// A folder given to this window from outside that it is about to open.
    @Published var arriving: WorkspaceArrivalNote?
    @Published var errorMessage: String?
    @Published var workbenchUIRequest: String?
    /// Settings are a panel over this window, not a window of their own.
    @Published var settingsVisible = false
    /// A filter the panel should start with, such as one extension's settings.
    @Published var settingsQuery: String?
    /// When the page last reported the editor's own Settings editor; its extension reports the same a moment later.
    var settingsEditorSeen = Date.distantPast
    @Published var directoryBrowser: DirectoryBrowser?
    @Published var importing = false
    @Published var catalogNotice: String?
    @Published var loading = true
    @Published var connectionStates: [UUID: String] = [:]
    let history: HistoryStore
    /// Forwarding and remote displays belong to the application, not a window.
    let proxy: ProxyController
    lazy var remoteDisplays: RemoteDisplayController = primary?.remoteDisplays ?? RemoteDisplayController(root: history.root)
    /// Each additional window has its own store (selection, page, editors and
    /// terminals) that shares the first window's catalog and services.
    let primary: AppStore?
    var isPrimary: Bool { primary == nil }
    weak var window: NSWindow?
    var windowAttached = false
    /// A name the user gave this window. Without one it is named after the server and folder it shows.
    @Published var windowName: String? { didSet { if isPrimary { workspaceDefaults.set(windowName, forKey: "windowName") } } }
    /// What the system draws over the top of this window: its title row and, with tabs, the tab bar.
    @Published var windowTop = WindowTop()
    /// The folder this window last showed on each server, and the workspaces it showed, most
    /// recent first. Another window's choices are only a starting point for this one.
    var ownDirectories: [String: String] = [:]
    var ownRecency: [String] = []
    /// The folders kept in this window (server and folder), in the order they joined it.
    @Published var members: [String] = [] { didSet { if isPrimary, members != oldValue { workspaceDefaults.set(members, forKey: "windowFolders") } } }
    /// The organizer, where folders are moved between windows.
    @Published var organizerVisible = false {
        didSet {
            guard oldValue != organizerVisible else { return }
            // While a window can be moved by its title row, AppKit works out again which of its views
            // lie under that row whenever one of them moves, by going through all of them: with a
            // list scrolling, on every frame. The organizer covers the window, so it stays put meanwhile.
            window?.isMovable = !organizerVisible
            if !organizerVisible {
                gatherWindows(); realizeDrafts()
            }
        }
    }
    /// Kept as a window of its own. Otherwise the windows are tabs of one window.
    @Published var separate = false
    /// Windows planned in the organizer; they open when it closes.
    @Published var windowDrafts: [WindowDraft] = []
    /// What this window was opened for from the organizer, until it has taken it up.
    var windowPlan: WindowPlan?
    /// The window was planned in the organizer: it opens as a tab beside the others.
    var planned = false
    /// The plain terminals of this window (Start page ▸ New Terminal): one for this Mac and one
    /// for each server, each under a terminal scope of its own, and the one on screen.
    var homeTerminalScopes: [String: UUID] = [:]
    /// The question before a running terminal is closed. A test answers it instead of a person.
    var confirmClose: (TerminalSession) -> Bool = { AppStore.askToClose($0) }
    /// The question before a further window closes with unsaved changes or running terminals.
    var confirmWindowClose: (AppStore) -> Bool = { AppStore.askToCloseWindow($0) }
    /// The question before a server is removed, with its open terminals and forwarding rules counted.
    var confirmRemoval: (ServerProfile, Int, Int) -> Bool = { AppStore.askToRemove($0, terminals: $1, forwards: $2) }
    @Published var homeTerminalScope: UUID?
    var workspaceClaim: (key: String, order: Int)?
    lazy var codeWorkbench = CodeWorkbenchController(root: history.root)
    private var connecting = Set<String>()
    /// Where each server's control socket is. One answer for every window: the first window keeps it.
    private var ownPlans: [UUID: String] = [:]
    private var plans: [UUID: String] {
        get { primary?.plans ?? ownPlans }
        set { if let primary { primary.plans = newValue } else { ownPlans = newValue } }
    }
    private var timer: Timer?
    private var connectionObservers: [NSObjectProtocol] = []
    private var connectionRefresh: Task<Void, Never>?
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
    /// The window's own selection decides its workspace. The remembered
    /// per-server folder in the shared defaults is only a starting point, so
    /// another window choosing a folder cannot retarget this one.
    var currentFiles: FileWorkspace { files(for: selectedProfile, directoryID: selectedDirectoryID) }
    var hasUnsavedFiles: Bool { codeWorkbench.hasUnsavedFiles }
    func files(for profile: ServerProfile?) -> FileWorkspace {
        files(for: profile, directoryID: selectedDirectoryID(for: profile?.id))
    }
    func files(for profile: ServerProfile?, directoryID: UUID?) -> FileWorkspace {
        let key = (profile?.id.uuidString ?? "local") + (directoryID.map { ".directory." + $0.uuidString } ?? "")
        if let current = fileWorkspaces[key] { return current }
        let files = FileWorkspace(profile: profile, defaults: workspaceDefaults, directoryID: directoryID)
        files.onNavigate = { [weak self, weak files] path in self?.remember(profile: files?.profile, directory: path); self?.updateWorkspaceClaim() }
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
        if let editor = codeWorkbench.existing(for: files), editor.web != nil {
            files.enabled = true
            let target = editor.terminalFocused ? "workbench.action.focusActiveEditorGroup" : "workbench.action.terminal.focus"
            editor.command(target)
            return
        }
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
        codeWorkbench.session(for: files).newTerminal(store: self)
        files.terminalVisible = true
    }
    /// Start page ▸ New Terminal: a shell and nothing else. It is Harbor's own terminal view, so
    /// there is no editor to start, no folder to trust and nothing to load: the prompt is there
    /// at once. One per window for this Mac and one for each server; asking again returns to it.
    func openHomeTerminal(_ profile: ServerProfile?) {
        guard !loading else { return }
        let key = profile?.id.uuidString ?? "local"
        if let scope = homeTerminalScopes[key] {
            let members = terminalSessions(in: .window(scope))
            if members.contains(where: { !$0.ended }) { homeTerminalScope = scope; page = .terminal; return }
            // Shells that are still there on the server (Harbor was quit, or the connection was
            // lost) are returned to, with what they showed. What is left of one that has ended
            // is replaced by a new one.
            let resumable = members.filter { $0.resumable }
            members.filter { !$0.resumable }.forEach { close($0, ask: false) }
            if !resumable.isEmpty, homeTerminalScopes[key] == scope {
                homeTerminalScope = scope; page = .terminal
                reconnectSessions(resumable, selected: selectedTerminal(in: .window(scope)))
                return
            }
        }
        let scope = UUID()
        homeTerminalScopes[key] = scope
        guard openTerminal(profile, detached: true, workingDirectory: profile == nil ? NSHomeDirectory() : nil, useWorkspaceDirectory: false, windowID: scope) != nil else {
            homeTerminalScopes[key] = nil; return
        }
        homeTerminalScope = scope; page = .terminal
    }
    /// The terminal the terminal page shows.
    var homeTerminal: TerminalSession? {
        guard let scope = homeTerminalScope else { return nil }
        return selectedTerminal(in: .window(scope)) ?? terminalSessions(in: .window(scope)).first
    }
    func isHomeTerminal(_ session: TerminalSession) -> Bool { session.windowID.map { homeTerminalScopes.values.contains($0) } ?? false }
    /// A plain terminal that is closed, or whose shell on this Mac exits, gives the window back to
    /// the start page once nothing of the page is left. A pane that has only lost its connection
    /// stays, with its way back; taking the page away under it left it running out of reach.
    private func homeTerminalEnded(_ session: TerminalSession) {
        guard let scope = session.windowID, homeTerminalScopes.values.contains(scope) else { return }
        guard terminalSessions(in: .window(scope)).allSatisfy({ $0 === session }) else { return }
        homeTerminalScopes = homeTerminalScopes.filter { $0.value != scope }
        terminalLayouts[.window(scope)] = nil
        if homeTerminalScope == scope { homeTerminalScope = nil; if page == .terminal { page = .recent } }
    }
    func openDroppedWorkspace(_ plan: WorkspaceDropPlan, target: FileWorkspace? = nil) async {
        let profile = profiles.first { $0.id == plan.profileID }
        guard plan.profileID == nil || profile != nil else { errorMessage = "This server has been removed. Add it again before opening the folder."; return }
        if !plan.hasDirectories, let target, target.profile?.id == plan.profileID {
            let editor = codeWorkbench.session(for: target)
            for entry in plan.files { editor.open(path: entry.path) }
            return
        }
        for root in plan.directoryRoots {
            _ = await openDirectoryWorkspace(root, profile: profile)
        }
        if !plan.files.isEmpty {
            let files = plan.hasDirectories ? self.files(for: profile) : await openDirectoryWorkspace(plan.root, profile: profile)
            if let files {
                let editor = codeWorkbench.session(for: files)
                for entry in plan.files { editor.open(path: entry.path) }
            }
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
    init(historyRoot: URL? = nil, workspaceDefaults: UserDefaults = .standard, primary: AppStore? = nil) {
        WorkspaceShortcut.migratePreference(in: workspaceDefaults)
        self.workspaceDefaults = workspaceDefaults
        self.primary = primary
        proxy = primary?.proxy ?? ProxyController()
        if let primary {
            history = primary.history; socketRoot = primary.socketRoot
            // Terminal recovery files have one writer: the first window's store.
            recoveryWritable = false
            Self.register(self)
            // A window opened for a folder says so from its first frame, not after a look at the start page.
            if let urls = Self.pendingWindowURLs { arriving = WorkspaceArrivalNote(urls: urls, fresh: true) }
            else if let request = Self.pendingWindowFolder {
                arriving = WorkspaceArrivalNote(path: request.path, server: primary.profiles.first { $0.id == request.profileID }?.name ?? LocalMachine.name, fresh: true)
            } else if !Self.pendingPlans.isEmpty {
                // Planned in the organizer: this window is the next of them.
                let plan = Self.pendingPlans.removeFirst(); windowPlan = plan; planned = true; windowName = plan.name
                if let first = plan.folders.lazy.compactMap({ Self.folder($0) }).first { arriving = WorkspaceArrivalNote(path: first.path, server: first.server, fresh: true) }
            }
            return
        }
        let env = ProcessInfo.processInfo.environment
        let previewRoot = Bundle.main.bundleIdentifier?.hasSuffix(".preview") == true ? Bundle.main.object(forInfoDictionaryKey: "HarborPreviewDataDirectory") as? String : nil
        let root = historyRoot ?? (env["HARBOR_DATA_DIR"] ?? previewRoot).map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/HarborSSH", isDirectory: true)
        history = HistoryStore(location: root)
        socketRoot = URL(fileURLWithPath: "/tmp/harbor-\(getuid())", isDirectory: true)
        Self.register(self)
        // Harbor opens with no workspace: what its first window kept last time is a closed window now.
        retireLastWindow()
        if !Self.handedOver.isEmpty { arriving = WorkspaceArrivalNote(urls: Self.handedOver, fresh: true) }
    }
    func load() async {
        guard !didLoad else { return }; didLoad = true
        defer { loading = false }
        if let primary {
            // Wait for the first window's catalog, then start on the start page.
            while primary.loading { try? await Task.sleep(nanoseconds: 50_000_000) }
            persistenceAvailable = primary.persistenceAvailable
            adoptCatalog(from: primary); connectionStates = primary.connectionStates
            loading = false
            if let urls = Self.pendingWindowURLs {
                Self.pendingWindowURLs = nil
                await openOutside(urls)
            } else if let request = Self.pendingWindowFolder {
                Self.pendingWindowFolder = nil
                let profile = profiles.first { $0.id == request.profileID }
                if request.profileID == nil || profile != nil { _ = await openDirectoryWorkspace(request.path, profile: profile) }
                await retireArrival()
            } else { await adoptWindowPlan() }
            return
        }
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
        watchConnections()
        if persistenceAvailable && profiles.isEmpty && ProcessInfo.processInfo.environment["HARBOR_NO_IMPORT"] != "1" { await importSSHConfig() }
        await restoreTerminals()
        startRecoveryCheckpoints()
        // Every launch begins on the start page. Restored terminals keep running; their folder is one click away under Recent.
        page = .recent
    }
    /// `show: false` only moves the selection: the window stays on the page it is on. (Going to the
    /// workspace page starts that workspace's editor, and its connection.)
    func selectWorkspace(_ profileID: UUID?, show: Bool = true) {
        selectDirectory(profileID: profileID, directoryID: arrivalDirectoryID(for: profileID), show: show)
    }
    func selectDirectory(profileID: UUID?, directoryID: UUID?, show: Bool = true) {
        ownDirectories[directoryCatalogKey(profileID)] = directoryID?.uuidString ?? "default"
        workspace.selectWorkspace(profileID, available: attachedSessions.filter { $0.profile?.id == profileID && $0.directoryWorkspaceID == directoryID }.map(\.id), directoryID: directoryID)
        workspaceDefaults.set(directoryID?.uuidString ?? "default", forKey: directoryCatalogKey(profileID) + ".selected")
        if let activeSession { selectInArrangement(activeSession) }
        if show { page = .workspace }
    }
    func selectSession(_ session: TerminalSession, requestFocus: Bool = true) {
        guard !session.detached else { return }
        workspace.selectSession(session.id, profileID: session.profile?.id, directoryID: session.directoryWorkspaceID); page = .workspace
        ownDirectories[directoryCatalogKey(session.profile?.id)] = session.directoryWorkspaceID?.uuidString ?? "default"
        let key = directoryCatalogKey(session.profile?.id) + ".selected"
        let selected = session.directoryWorkspaceID?.uuidString ?? "default"
        if workspaceDefaults.string(forKey: key) != selected { workspaceDefaults.set(selected, forKey: key) }
        selectInArrangement(session)
        if requestFocus { currentFiles.terminalVisible = true; currentFiles.requestFocus(.terminal) }
    }
    func remember(profile: ServerProfile?, directory: String?, tmuxName: String? = nil) {
        var item = RecentWorkspace(serverID: profile?.id, serverName: profile?.name ?? LocalMachine.name, directory: directory, tmuxName: tmuxName)
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
        } else {
            // Only the folder is opened. (A terminal of Harbor's own used to be started here as well:
            // no page shows one for a workspace, so it ran unseen, was asked about at quit, and
            // stood in the way of closing the folder or removing the server.)
            remember(profile: profile, directory: item.directory)
        }
    }
    private func connected(_ session: TerminalSession) async {
        session.terminal.fileDropAllowed = true
        session.terminal.scheduleDisplayRepair(restoreRemote: true)
        if session.initialDirectoryTitle == nil { await refreshTerminalDirectories([session]) }
        if !isHomeTerminal(session) { remember(profile: session.profile, directory: session.workingDirectory, tmuxName: session.tmuxName) }
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
        for peer in Self.all where peer !== self { peer.adoptCatalog(from: self) }
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
        // Every server is asked at once: one after another this was most of the wait at launch.
        let effective = await withTaskGroup(of: (UUID, CommandResult).self) { group in
            for p in ordered { group.addTask { (p.id, await ProcessRunner.run("/usr/bin/ssh", SSHArguments.connection(p) + ["-G", "--", p.host], timeout: 8)) } }
            var results: [UUID: CommandResult] = [:]
            for await (id, result) in group { results[id] = result }
            return results
        }
        for p in ordered {
            guard let result = effective[p.id], result.succeeded, let key = ServerIdentity.key(effective: SSHConfig.effective(result.output)) else { continue }
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
            if let selectedProfileID, let replacement = remap[selectedProfileID] { selectWorkspace(replacement, show: page == .workspace) }
            catalogNotice = "Merged \(remap.count) duplicate configurations and updated Recents"; save()
        } catch { errorMessage = "Backup failed. The original configuration was kept: \(error.localizedDescription)" }
    }
    func upsert(_ profile: ServerProfile) {
        let known = profiles.contains { $0.id == profile.id }
        if let i = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[i] = profile; plans[profile.id] = nil }
        else { profiles.append(profile) }
        ServerIcons.assignMissing(in: &profiles)
        // The servers are every window's. A folder that is open on this one, in whichever window,
        // goes on as it is and uses the new settings for whatever connects from now on: its
        // editor's Reconnect, a new terminal. (They used to keep the settings they were opened
        // with until Harbor was restarted, so a corrected port never reached them.)
        if known, let current = profiles.first(where: { $0.id == profile.id }) {
            for store in family { for files in store.fileWorkspaces.values { files.adopt(current) } }
        }
        // A new server is gone to at once. An edited one changes nothing about what the window shows.
        if !known { selectWorkspace(profile.id) }
        save()
        Task { await consolidateServers() }
    }
    func remove(_ profile: ServerProfile) {
        // The servers are every window's: what any of them has open on this one counts.
        let stores = family
        guard !stores.contains(where: { $0.codeWorkbench.hasUnsavedFiles(profileID: profile.id) }) else { errorMessage = "Save your code changes on this server first."; return }
        // Its terminals and forwarding rules go with it, once asked. Harbor used to refuse instead
        // ("Close this server’s active terminals first"), and a terminal that had only lost its
        // connection, or that a window kept out of sight, still counted: nothing on the start page
        // led to it, so the server could not be removed at all.
        let terminals = stores.flatMap(\.sessions).filter { $0.profile?.id == profile.id }
        let open = terminals.filter { !$0.ended || ($0.detached && $0.resumable) }.count
        let forwards = rules.filter { $0.serverID == profile.id }
        guard confirmRemoval(profile, open, forwards.count) else { return }
        // The shells Harbor's terminal host keeps for them there, ended once they are closed.
        let shells = terminals.filter { !$0.remotePTYGone }.compactMap(\.remotePTYID)
        for rule in forwards { proxy.stop(rule.id); proxy.states[rule.id] = nil; proxy.logs[rule.id] = nil }
        rules.removeAll { $0.serverID == profile.id }
        // Out of every window's list first: what a window looks up while it lets go of the server
        // must not find it again.
        profiles.removeAll { $0.id == profile.id }; recents.removeAll { $0.serverID == profile.id }; plans[profile.id] = nil
        for store in stores where store !== self { store.adoptCatalog(from: self) }
        stores.forEach { $0.forget(server: profile.id, next: profiles.first?.id) }
        save()
        let id = profile.id
        Task.detached { ServerPasswords.forget(server: id) }
        guard !shells.isEmpty else { return }
        Task {
            // Through the connection the terminals shared, which stays open a while after them, so no
            // password is needed. A server that cannot be reached keeps them until they expire
            // (24 hours without a connection); nothing is said about it, the server being gone.
            for shell in shells { _ = try? await endRemoteShell(shell, on: profile) }
            plans[id] = nil
        }
    }
    /// Asked before a server is removed, saying what goes with it.
    static func askToRemove(_ profile: ServerProfile, terminals: Int, forwards: Int) -> Bool {
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "Remove “\(profile.name)”?"
        var lines = [String]()
        if terminals == 1 { lines.append("Its open terminal will be closed, and the shell Harbor keeps for it on the server ended.") }
        if terminals > 1 { lines.append("Its \(terminals) open terminals will be closed, and the shells Harbor keeps for them on the server ended.") }
        if forwards == 1 { lines.append("Its forwarding rule will be stopped and deleted.") }
        if forwards > 1 { lines.append("Its \(forwards) forwarding rules will be stopped and deleted.") }
        lines.append("Harbor forgets its settings and any password saved for it. Files on the server are not touched.")
        alert.informativeText = lines.joined(separator: " ")
        alert.addButton(withTitle: "Remove Server"); alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }
    /// A server has left the list: this window lets go of what it had of it. A window that was
    /// on one of its folders goes to its start page; no window is moved to another server.
    private func forget(server id: UUID, next: UUID?) {
        for files in fileWorkspaces.values where files.profile?.id == id { codeWorkbench.close(files); files.cleanCache() }
        sessions.filter { $0.profile?.id == id }.forEach { close($0, ask: false, endRemoteProcess: false) }
        fileWorkspaces = fileWorkspaces.filter { $0.value.profile?.id != id }
        guard selectedProfileID == id else { return }
        if page == .workspace { page = .recent }
        // A side page that was opened from one of its folders leads back to the start page too.
        if pageReturn == .workspace { pageReturn = .recent }
        selectWorkspace(next, show: false)
    }
    func resolveSocket(_ p: ServerProfile) async throws -> String {
        // By the server's settings as they are now: a caller may still hold them as they were
        // before an edit, and would otherwise bring the old destination's socket back.
        let p = profiles.first { $0.id == p.id } ?? p
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
    func openTerminal(_ profile: ServerProfile?, detached: Bool = false, resumeTmux: String? = nil, workingDirectory: String? = nil, useWorkspaceDirectory: Bool = true, windowID: UUID? = nil, directoryWorkspace: FileWorkspace? = nil, recoveredOutput: String? = nil, remotePTYID: UUID? = nil, remotePTYReconnect: Bool = false, activate: Bool = true) -> UUID? {
        guard !loading else { return nil }
        guard persistenceAvailable else { errorMessage = "The data files could not be read. Repair them and restart Harbor."; return nil }
        // By the server's settings as they are now. A split or a new tab hands on the settings its
        // source terminal was opened with; after an edit those named the old destination, which
        // was then reached under the new one's shared connection, for every terminal after it.
        let profile = profile.map { held in profiles.first { $0.id == held.id } ?? held }
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
        while existingTitles.contains("\(profile?.name ?? LocalMachine.name) · \(index)") { index += 1 }
        do {
            let s = try TerminalSession(profile: profile, title: "\(profile?.name ?? LocalMachine.name) · \(index)", detached: detached, history: history, tmuxName: resumeTmux, workingDirectory: directory, remotePTYID: remotePTYID)
            s.remotePTYReconnect = remotePTYReconnect
            if let recoveredOutput { s.restoreOutput(recoveredOutput) }
            s.directoryWorkspaceID = files.directoryID
            if detached, let windowID { s.windowID = windowID }
            s.onEnd = { [weak self] s, code in self?.finish(s, code: code) }
            s.terminal.onDropError = { [weak self] message in self?.errorMessage = message }
            sessions.append(s)
            startDirectoryTracking(); startRecoveryCheckpoints()
            registerTerminal(s)
            if !detached && activate { selectSession(s) }
            save()
            if let profile { Task { await connect(s, profile: profile) } }
            else {
                s.start(executable: "/bin/zsh", arguments: ["-l"])
                // A plain terminal is not a folder that was opened; it leaves nothing among the recent ones.
                if !isHomeTerminal(s) { remember(profile: nil, directory: directory) }
            }
            return s.id
        } catch { errorMessage = "Unable to create a terminal: \(error.localizedDescription)"; return nil }
    }
    private func connect(_ session: TerminalSession, profile: ServerProfile) async {
        do {
            let socket = try await resolveSocket(profile); session.socket = socket
            // The control socket is every window's: a first connection that another window has
            // begun (and may be asking for a password in) is waited for, not raced.
            if Self.connectionStarting(socket) {
                session.status = "Waiting for initial connection"
                while Self.connectionStarting(socket) && !session.ended { try? await Task.sleep(nanoseconds: 500_000_000) }
                guard !session.ended else { return }
                let check = await ProcessRunner.run("/usr/bin/ssh", SSHArguments.check(profile, socket: socket), timeout: 20)
                guard !session.ended else { return }
                guard check.succeeded else {
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
            publishConnection("Connecting", for: profile.id)
            for _ in 0..<150 {
                guard !session.ended else { publishConnection("Disconnected", for: profile.id); return }
                if FileManager.default.fileExists(atPath: socket) {
                    let check = await ProcessRunner.run("/usr/bin/ssh", SSHArguments.check(profile, socket: socket), timeout: 20)
                    guard !session.ended else { return }
                    if check.succeeded {
                        // A password typed for this connection was right: from now on it is given without asking.
                        ServerPasswords.confirm(server: profile.id)
                        try await waitForRemotePTY(session)
                        session.ready = true; session.status = "Connected · Shared with new terminals"; publishConnection("Connected", for: profile.id); await connected(session); return
                    }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            session.status = "Connection unverified · Authenticate or reconnect"; publishConnection("Unverified", for: profile.id)
        } catch {
            session.stop()
            // A shell the server no longer has says so itself, in the pane; Reconnect starts a new one.
            if session.remotePTYGone { session.status = "The shell on the server has ended · Reconnect starts a new one" }
            else { session.show(error.localizedDescription); session.status = "Connection failed" }
            finish(session, code: nil)
        }
    }
    private static func connectionStarting(_ socket: String) -> Bool { all.contains { $0.connecting.contains(socket) } }

    // MARK: Servers that take a password

    /// The editor and the file browser connect without asking anything. When a server refuses that
    /// for want of a password, they ask here: the server's shared connection is made with the
    /// password Harbor keeps for it, or with one typed in a dialog (and kept once it worked).
    static func installPasswordSignIn() {
        WorkspaceSSHConnection.passwordSignIn = { profile, socket, failure in
            await AppStore.signIn(profile, socket: socket, failure: failure)
        }
    }
    private static var signingIn: [String: Task<Bool, Never>] = [:]
    /// One at a time for a server: what else needs the connection meanwhile waits for the same answer.
    static func signIn(_ profile: ServerProfile, socket: String, failure: String) async -> Bool {
        if let running = signingIn[socket] { return await running.value }
        let task = Task { await AppStore.makePasswordConnection(profile, socket: socket, failure: failure) }
        signingIn[socket] = task
        let made = await task.value
        signingIn[socket] = nil
        return made
    }
    private static func makePasswordConnection(_ profile: ServerProfile, socket: String, failure: String) async -> Bool {
        // A terminal (or another window) may have made it meanwhile.
        if await ProcessRunner.run("/usr/bin/ssh", SSHArguments.check(profile, socket: socket), timeout: 10).succeeded { return true }
        guard let account = ServerPasswords.account(refused: failure) else { return false }
        let server = profile.id
        var note: String?
        if await Task.detached(operation: { ServerPasswords.usable(server: server, account: account) }).value {
            let result = await passwordConnection(profile, socket: socket, connection: UUID().uuidString)
            if result.succeeded { return true }
            guard result.output.contains("Permission denied") else { return false }
            await Task.detached { ServerPasswords.drop(server: server, account: account) }.value
            note = "The password Harbor kept for this server was refused; it may have been changed."
        }
        for _ in 0..<3 {
            guard let password = askPassword(for: account, server: profile.name, note: note) else { return false }
            let connection = UUID().uuidString
            guard await Task.detached(operation: { ServerPasswords.offer(password, server: server, account: account, connection: connection) }).value else { return false }
            let result = await passwordConnection(profile, socket: socket, connection: connection)
            if result.succeeded { ServerPasswords.confirm(server: server); return true }
            await Task.detached { ServerPasswords.drop(server: server, account: account) }.value
            guard result.output.contains("Permission denied") else { return false }
            note = "The server refused that password."
        }
        return false
    }
    /// The server's shared connection, made by ssh with Harbor as its askpass program and no terminal:
    /// one password, the one kept for this connection, and nothing else answered.
    private static func passwordConnection(_ profile: ServerProfile, socket: String, connection: String) async -> CommandResult {
        let environment = ServerPasswords.environment(server: profile.id, executable: TerminalTransport.executable, connection: connection, background: true)
        return await ProcessRunner.run("/usr/bin/ssh", ["-o", "BatchMode=no", "-o", "NumberOfPasswordPrompts=1"] + SSHArguments.common(profile, socket: socket)
            + ["-T", "--", profile.host, "true"], timeout: 45, environment: environment)
    }
    private static func askPassword(for account: String, server: String, note: String?) -> String? {
        let alert = NSAlert()
        alert.messageText = "Password for \(account)"
        alert.informativeText = (note.map { $0 + "\n\n" } ?? "") + "\(server) asks for a password. Harbor keeps it in your login keychain and connects with it from now on, in terminals too."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "Password"
        alert.accessoryView = field
        alert.addButton(withTitle: "Connect"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return nil }
        return field.stringValue
    }
    private func waitForRemotePTY(_ session: TerminalSession) async throws {
        guard session.remotePTYID != nil else { return }
        for _ in 0..<200 {
            if session.remoteShellPID != nil { return }
            if session.ended { throw CocoaError(.executableLoad) }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw NSError(domain: "Harbor", code: 1, userInfo: [NSLocalizedDescriptionKey: "The remote terminal did not become ready. Reconnect to retry."])
    }
    func finish(_ session: TerminalSession, code: Int32?) {
        // `exit` in the plain terminal of this Mac closes it. One that failed stays, to say why.
        if code == 0, session.profile == nil, isHomeTerminal(session), !shuttingDown {
            Task { @MainActor [weak self] in
                guard let self, self.sessions.contains(where: { $0 === session }) else { return }
                self.close(session, ask: false)
            }
        }
        if !shuttingDown { checkpointTerminals() }
        objectWillChange.send()
    }
    /// Asked before a terminal that is still running is closed.
    static func askToClose(_ session: TerminalSession) -> Bool {
        let alert = NSAlert(); alert.messageText = "Close this terminal?"
        alert.informativeText = session.remotePTYID != nil ? "Closing ends this remote terminal. Quit Harbor or reconnect to keep the session instead." : session.tmuxName == nil ? "Foreground commands in this terminal may end. The shared SSH connection will remain open." : "The existing tmux session stays on the server."
        alert.addButton(withTitle: "Close Terminal"); alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    /// Ends a shell that Harbor's terminal host keeps on a server. False when the server could not be asked.
    func endRemoteShell(_ id: UUID, on profile: ServerProfile) async throws -> Bool {
        let profile = profiles.first { $0.id == profile.id } ?? profile
        let socket = try await resolveSocket(profile)
        let command = try RemoteTerminalHost.command(id: id, mode: "close", directory: nil)
        return await ProcessRunner.run("/usr/bin/ssh", SSHArguments.probe(profile, socket: socket, command: command), timeout: 10).succeeded
    }
    func close(_ session: TerminalSession, ask: Bool = true, endRemoteProcess: Bool = true) {
        if ask && !session.ended { guard confirmClose(session) else { return } }
        if endRemoteProcess, !session.remotePTYGone, let id = session.remotePTYID, let profile = session.profile {
            Task {
                do {
                    if try await !endRemoteShell(id, on: profile) { errorMessage = "The terminal was removed locally. The remote process could not be closed while offline; it expires after 24 hours disconnected." }
                } catch { errorMessage = error.localizedDescription }
            }
        }
        let responder = session.terminal.window?.firstResponder as? NSView
        let wasFocused = responder === session.terminal || responder?.isDescendant(of: session.terminal) == true
        let scope = terminalScope(of: session)
        var layout = arrangement(in: scope); layout.remove(session.id); terminalLayouts[scope] = layout
        session.stop(); finish(session, code: nil); sessions.removeAll { $0.id == session.id }
        homeTerminalEnded(session)
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
        // With it, the server's other terminals that have lost their connection: those that are on
        // a page or in a window of their own, and whose shell is still there. One that nothing
        // shows (left by an earlier version in a workspace) is not brought back to run unseen, and
        // no new shell is started for a pane nobody asked about.
        let members = sessions.filter { $0 === session || (session.profile != nil && $0.profile?.id == session.profile?.id && $0.ended && $0.detached && !$0.remotePTYGone) }
        reconnectSessions(members, selected: session)
    }
    func reconnectSessions(_ members: [TerminalSession], selected: TerminalSession?) {
        let members = members.filter { candidate in sessions.contains { $0 === candidate } }
        guard !members.isEmpty else { return }
        let originalProfile = selectedProfileID, originalDirectory = selectedDirectoryID, originalSession = selectedSessionID
        let originalPage = page
        let scopes = Set(members.map { terminalScope(of: $0) })
        let layouts = Dictionary(uniqueKeysWithValues: scopes.map { ($0, arrangement(in: $0)) })
        var replacements = [UUID: UUID]()
        for old in members {
            let directory = old.effectiveDirectory
            let output = old.recoveryOutput()
            // With the server's settings as they are now, and for a shell the server no longer has, a new one.
            let profile = old.profile.map { held in profiles.first { $0.id == held.id } ?? held }
            guard let id = openTerminal(profile, detached: old.detached, resumeTmux: old.tmuxName,
                workingDirectory: directory, useWorkspaceDirectory: false, windowID: old.windowID,
                directoryWorkspace: files(for: profile, directoryID: old.directoryWorkspaceID), recoveredOutput: output,
                remotePTYID: old.remotePTYGone ? old.nextPTYID : old.remotePTYID, remotePTYReconnect: !old.remotePTYGone && old.remotePTYReconnect),
                  let new = sessions.first(where: { $0.id == id }) else { continue }
            close(old, ask: false, endRemoteProcess: false)
            new.customTitle = old.customTitle; new.tabWidth = old.tabWidth; new.currentDirectory = directory
            new.initialDirectoryTitle = old.initialDirectoryTitle ?? new.initialDirectoryTitle
            replacements[old.id] = id
        }
        for (scope, original) in layouts {
            var layout = original
            // One that could not be opened again stays where it is, with its reason and its Reconnect.
            for old in members where terminalScope(of: old) == scope {
                if let new = replacements[old.id] { layout.replace(old.id, with: new) }
            }
            terminalLayouts[scope] = layout
        }
        // The selection is put back, and the page: reconnecting a plain terminal, or one in a window
        // of its own, used to take the main window to a workspace and start that workspace's editor.
        selectDirectory(profileID: originalProfile, directoryID: originalDirectory, show: false)
        if page != originalPage { page = originalPage }
        let preferred = selected.flatMap { replacements[$0.id] } ?? originalSession.flatMap { replacements[$0] ?? $0 }
        if let id = preferred, let chosen = sessions.first(where: { $0.id == id }) { activateTerminal(chosen) }
        checkpointTerminals()
        objectWillChange.send()
    }
    /// Whether Harbor holds a connection to each server, the same answer in every window.
    ///
    /// A server is connected while a control master answers on one of its two sockets: the one
    /// terminals share, or the one an editor opens when that is absent or full. The question goes
    /// to a socket on this Mac and never to the network, and a server without a socket file is
    /// not asked at all, so this is cheap enough to repeat every few seconds and keeps nothing running.
    func refreshConnections() async {
        if let primary { await primary.refreshConnections(); return }
        guard !refreshing else { return }; refreshing = true; defer { refreshing = false }
        var states: [UUID: String] = [:]
        for profile in profiles {
            guard let socket = try? await resolveSocket(profile) else { continue }
            if Self.all.contains(where: { $0.connecting.contains(socket) }) { states[profile.id] = connectionStates[profile.id]; continue }
            let alive = await Self.connectionAlive(sockets: [socket, WorkspaceSSHConnection(profile: profile, socket: socket).fileSocket],
                                                   exists: { FileManager.default.fileExists(atPath: $0) },
                                                   check: { await ProcessRunner.run("/usr/bin/ssh", SSHArguments.check(profile, socket: $0), timeout: 10).succeeded })
            states[profile.id] = alive ? "Connected" : "Connection unavailable"
        }
        for store in Self.all where store.connectionStates != states { store.connectionStates = states }
        WorkspaceSwitcher.shared.refresh()
    }
    static func connectionAlive(sockets: [String], exists: (String) -> Bool, check: (String) async -> Bool) async -> Bool {
        for path in sockets where exists(path) { if await check(path) { return true } }
        return false
    }
    /// A state one window learned (a terminal connecting) is every window's.
    private func publishConnection(_ state: String, for id: UUID) {
        for store in Self.all where store.connectionStates[id] != state { store.connectionStates[id] = state }
    }
    /// The first window keeps the states current: on a timer while Harbor is in front, when it
    /// comes to the front, and shortly after any window opens or closes an editor.
    private func watchConnections() {
        guard isPrimary, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in Task { @MainActor in if NSApp.isActive { await self?.refreshConnections() } } }
        connectionObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.connectionsMayHaveChanged(after: 0) }
        })
        connectionObservers.append(NotificationCenter.default.addObserver(forName: .harborServersChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { WorkspaceSwitcher.shared.refresh(); self?.connectionsMayHaveChanged(after: 1.5) }
        })
        connectionsMayHaveChanged(after: 0)
    }
    /// Several changes in a row ask once; a socket appears a moment after its editor starts.
    func connectionsMayHaveChanged(after delay: Double) {
        if let primary { primary.connectionsMayHaveChanged(after: delay); return }
        connectionRefresh?.cancel()
        connectionRefresh = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            await self?.refreshConnections()
        }
    }
    /// This window has the server open: its workspace is on screen, or one of its editors runs in the background.
    func hasOpen(_ profileID: UUID?) -> Bool {
        page == .workspace && selectedProfileID == profileID || codeWorkbench.runs(profileID: profileID)
    }
    func shutdown() {
        guard !shuttingDown else { return }
        guard isPrimary else { closeWindowStore(); return }
        checkpointTerminals(synchronously: true)
        for peer in Self.all where peer !== self { peer.closeWindowStore(quitting: true) }
        shuttingDown = true; recoveryTimer?.invalidate(); recoveryTimer = nil
        directoryBrowser?.cancel(); directoryBrowser = nil
        timer?.invalidate(); timer = nil
        connectionRefresh?.cancel(); connectionObservers.forEach(NotificationCenter.default.removeObserver); connectionObservers.removeAll()
        directoryTrackingTask?.cancel(); directoryTrackingTask = nil; endDrag()
        for session in sessions { session.stop(); finish(session, code: nil) }
        for workspace in fileWorkspaces.values { workspace.cleanCache() }
        remoteDisplays.stopAll()
        codeWorkbench.shutdown()
        proxy.stopAll(); save()
    }
}
