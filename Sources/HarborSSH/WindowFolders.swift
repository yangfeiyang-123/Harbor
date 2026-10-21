import SwiftUI
import AppKit
import HarborCore

extension Notification.Name {
    /// A folder joined or left a window.
    static let harborWindowFoldersChanged = Notification.Name("harbor.window.folders.changed")
}

/// A folder as the organizer and the switcher name it.
struct WindowFolder: Identifiable, Equatable {
    /// Server and folder: the same identity the windows claim workspaces by.
    let id: String
    let profileID: UUID?
    let directoryID: UUID?
    let server: String
    let icon: String
    let title: String
    let path: String
    /// The folder itself, however a window spells its path: on this Mac a path through a link
    /// ("/tmp/x") and the one it leads to ("/private/tmp/x") are one folder.
    var match: String { Self.match(profileID: profileID, path: path) }
    static func match(profileID: UUID?, path: String) -> String {
        let spelled = RecentWorkspace.normalize(path) ?? path
        return (profileID?.uuidString ?? "local") + "\n" + (profileID == nil ? URL(fileURLWithPath: spelled).resolvingSymlinksInPath().path : spelled)
    }
}

/// A window planned in the organizer: a column that is given folders before there is a window.
/// It opens when the organizer closes, if it was given any.
struct WindowDraft: Identifiable, Equatable {
    let id: UUID
    var name = ""
    var folders: [String] = []
    /// The closed window it brings back, if it is one.
    var origin: String?
    init(id: UUID = UUID(), name: String = "", folders: [String] = []) { self.id = id; self.name = name; self.folders = folders }
    var title: String { name.trimmingCharacters(in: .whitespaces).isEmpty ? "New Window" : name }
}
/// What a window opened from the organizer starts with: its name, and the folders it keeps, the first of them on screen.
struct WindowPlan: Equatable {
    var name: String?
    var folders: [String]
}
/// A window that was closed with folders in it: its name and what it kept, to open it again.
struct RecentWindow: Equatable, Identifiable {
    var name: String
    /// The name was given by the user; otherwise it only lists what the window kept.
    var named: Bool
    /// Its folders, as the window that asks names them.
    var folders: [String]
    /// The folders themselves, however a window spells their paths: what the window is saved under.
    var id = ""
    static func == (a: RecentWindow, b: RecentWindow) -> Bool { a.name == b.name && a.named == b.named && a.folders == b.folders }
}
/// A closed window as it is saved.
private struct SavedWindow: Codable {
    var name: String
    var named: Bool
    /// `WindowFolder.match` of each folder.
    var folders: [String]
    var id: String { folders.joined(separator: "\n") }
}
/// A server in the library, with the folders that were opened on it.
struct LibraryServer: Identifiable {
    let id: String
    let profile: ServerProfile?
    let name: String
    let icon: String
    let folders: [WindowFolder]
}

/// Which folders are kept in which window. A folder is in one window at a time: the one it was
/// opened in, until it is moved. Opening it puts it there; the organizer moves it, to another
/// window, to a new one, or out of every window. The first window's folders are remembered
/// while Harbor is open (and become a closed window the next time it starts); a further window's
/// last as long as the window does.
@MainActor extension AppStore {
    /// Every folder Harbor knows, this Mac first and then the servers in sidebar order.
    func knownFolders() -> [WindowFolder] {
        var seen = Set<String>(), result: [WindowFolder] = []
        for profile in [ServerProfile?.none] + profiles.map(Optional.some) {
            for files in directoryWorkspaces(for: profile) where !files.root.isEmpty {
                let id = WorkspaceSwitcher.identity(profileID: profile?.id, root: files.root, fallback: files.key)
                guard seen.insert(id).inserted else { continue }
                result.append(WindowFolder(id: id, profileID: profile?.id, directoryID: files.directoryID, server: profile?.name ?? LocalMachine.name,
                                           icon: profile?.displayIcon ?? "laptopcomputer", title: files.directoryTitle, path: files.root))
            }
        }
        return result
    }
    /// The windows on screen, this one first.
    var windowStores: [AppStore] { [self] + Self.all.filter { $0 !== self && $0.window != nil }.sorted { $0.windowTitle < $1.windowTitle } }
    /// A window that keeps no folder and was given no name is not a workspace yet: Harbor as it
    /// starts, or a window opened to look around. The organizer has no column for it, and it
    /// becomes the first window that is planned there rather than staying empty beside it.
    var isBlank: Bool { windowName == nil && windowPlan == nil && keptFolders.isEmpty }
    /// The folders kept in this window, as this window names them.
    var keptFolders: [WindowFolder] {
        let known = knownFolders()
        return members.compactMap { id in known.first { $0.id == id } }
    }
    static func holder(of folder: WindowFolder) -> AppStore? {
        all.first { $0.window != nil && $0.keptFolders.contains { $0.match == folder.match } }
    }
    /// A folder by its identity, in whichever window spells it that way.
    static func folder(_ identity: String) -> WindowFolder? {
        all.lazy.compactMap { $0.knownFolders().first { $0.id == identity } }.first
    }
    func files(of folder: WindowFolder) -> FileWorkspace? {
        let profile = profiles.first { $0.id == folder.profileID }
        guard folder.profileID == nil || profile != nil else { return nil }
        return files(for: profile, directoryID: folder.directoryID)
    }

    /// The folder is this window's from now on, and no other window's.
    func join(_ folder: WindowFolder) {
        // Under this window's own spelling of it.
        let known = knownFolders()
        let own = known.first { $0.match == folder.match } ?? folder
        guard !members.contains(own.id) else { return }
        // A window that cannot let go of it (unsaved changes) keeps it; it is never in two lists.
        for other in Self.all where other !== self { guard other.release(folder, quietly: true) else { return } }
        // What no longer names a folder (it was closed, or its path is spelled differently now) goes.
        members = members.filter { id in known.contains { $0.id == id } } + [own.id]
        for other in Self.all where other !== self { other.adoptSavedRoots() }
        NotificationCenter.default.post(name: .harborWindowFoldersChanged, object: nil)
    }
    /// Another window may have given a folder to a slot of the saved list that this window has
    /// only looked at (the first folder on a server). It is one slot, so this window names it the
    /// same way: its library lists the folder, and it does not give the slot a folder of its own.
    func adoptSavedRoots() {
        for files in fileWorkspaces.values where files.root.isEmpty {
            guard !(page == .workspace && currentFiles === files), !codeWorkbench.runs(files),
                  !attachedSessions.contains(where: { $0.profile?.id == files.profile?.id && $0.directoryWorkspaceID == files.directoryID }),
                  let saved = workspaceDefaults.string(forKey: files.key + ".root"), !saved.isEmpty else { continue }
            files.root = saved
        }
    }
    func join(_ identity: String) {
        guard !members.contains(identity), let folder = knownFolders().first(where: { $0.id == identity }) else { return }
        join(folder)
    }
    /// Takes the folder out of this window: its editor here is closed (the folder, its files and
    /// what runs in its terminals are untouched), and if it was on screen the window goes to the
    /// folder it showed before, or to its start page. Refused while the editor has unsaved changes.
    @discardableResult func release(_ folder: WindowFolder, quietly: Bool = false) -> Bool {
        guard let own = keptFolders.first(where: { $0.match == folder.match }) else { return true }
        if let files = files(of: own) {
            if codeWorkbench.existing(for: files)?.dirtyPaths.isEmpty == false {
                if !quietly { errorMessage = "Save the changes in “\(own.title)” before it leaves this window." }
                return false
            }
            if page == .workspace, currentFiles === files {
                let kept = keptFolders
                if let next = ownRecency.lazy.compactMap({ key in kept.first { $0.id == key && $0.match != own.match } }).first,
                   let other = self.files(of: next) { other.enabled = true; selectDirectoryWorkspace(other) }
                else { page = .recent }
            }
            codeWorkbench.close(files)
        }
        members.removeAll { $0 == own.id }
        NotificationCenter.default.post(name: .harborWindowFoldersChanged, object: nil)
        return true
    }
    /// Moves a folder to `target`, or out of every window when there is none.
    @discardableResult static func move(_ folder: WindowFolder, to target: AppStore?) -> Bool {
        if let target, target.keptFolders.contains(where: { $0.match == folder.match }) { return true }
        if let source = holder(of: folder), source !== target, !source.release(folder) { return false }
        target?.join(folder)
        return true
    }
    @discardableResult static func move(_ identity: String, to target: AppStore?) -> Bool {
        guard let folder = folder(identity) else { return false }
        return move(folder, to: target)
    }
    /// The library: every server (this Mac first, then the sidebar's order), each with the folders
    /// that were opened on it, the most recently shown first.
    func library() -> [LibraryServer] {
        let known = knownFolders()
        return ([ServerProfile?.none] + profiles.map(Optional.some)).map { profile in
            let folders = known.filter { $0.profileID == profile?.id }.enumerated().sorted { a, b in
                let left = recencyRank(a.element.id), right = recencyRank(b.element.id)
                return left != right ? left < right : a.offset < b.offset
            }.map(\.element)
            return LibraryServer(id: profile?.id.uuidString ?? "local", profile: profile, name: profile?.name ?? LocalMachine.name,
                                 icon: profile?.displayIcon ?? "laptopcomputer", folders: folders)
        }
    }
    /// Puts a folder into the library without opening it. The path is one the server has listed.
    @discardableResult func addToLibrary(_ path: String, profile: ServerProfile?) -> WindowFolder? {
        guard let normalized = RecentWorkspace.normalize(path) else { return nil }
        let files = directoryWorkspaceForPath(normalized, profile: profile)
        if files.root.isEmpty { files.root = normalized }
        files.persist()
        // The other windows read the same list.
        for other in Self.all where other !== self { other.adoptSavedRoots(); other.objectWillChange.send() }
        NotificationCenter.default.post(name: .harborWindowFoldersChanged, object: nil)
        return knownFolders().first { $0.match == WindowFolder.match(profileID: profile?.id, path: normalized) }
    }
    /// Asks for a folder to add to the library: on this Mac with the system's panel, on a server
    /// with Harbor's own browser, which lists what the path typed so far leads to.
    func chooseLibraryFolder(on profile: ServerProfile?, systemPanel: Bool = true) {
        if profile == nil, systemPanel {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
            panel.prompt = "Add"; panel.message = "Choose folders to add to the library."
            guard panel.runModal() == .OK else { return }
            panel.urls.forEach { addToLibrary($0.path, profile: nil) }
            return
        }
        let origin = files(for: profile)
        directoryBrowser = DirectoryBrowser(profile: profile, path: "~", adding: true) { [weak self] path in
            guard let self else { throw CancellationError() }
            await origin.prepare(store: self)
            try Task.checkCancellation()
            guard let service = origin.service else { throw WorkspaceError.message(origin.error ?? "Unable to connect to the server.") }
            return try await service.list(path, showHidden: true)
        }
    }

    /// The windows that were closed with folders in them, the last one first. A further window's
    /// folders last as long as the window does; this is how such a window is had again.
    func recentWindows() -> [RecentWindow] {
        // Without what has left the library since, and without a window whose folders are all gone.
        let known = knownFolders()
        return savedWindows().compactMap { window in
            let folders = window.folders.compactMap { match in known.first { $0.match == match }?.id }
            return folders.isEmpty ? nil : RecentWindow(name: window.name, named: window.named, folders: folders, id: window.id)
        }
    }
    private static let recentWindowsKey = "recentWindows"
    private func savedWindows() -> [SavedWindow] {
        workspaceDefaults.data(forKey: Self.recentWindowsKey).flatMap { try? JSONDecoder().decode([SavedWindow].self, from: $0) } ?? []
    }
    private func save(_ windows: [SavedWindow]) {
        workspaceDefaults.set(try? JSONEncoder().encode(Array(windows.prefix(8))), forKey: Self.recentWindowsKey)
        NotificationCenter.default.post(name: .harborWindowFoldersChanged, object: nil)
    }
    /// Harbor starts with a window that keeps nothing and has no name. What the first window kept
    /// when Harbor was last open (saved as it went, so a crash loses nothing) goes to the closed
    /// windows, under the name it had, and comes back from there with one click.
    func retireLastWindow() {
        guard isPrimary else { return }
        let name = workspaceDefaults.string(forKey: "windowName"), kept = workspaceDefaults.stringArray(forKey: "windowFolders") ?? []
        workspaceDefaults.removeObject(forKey: "windowName"); workspaceDefaults.removeObject(forKey: "windowFolders")
        // A folder is saved as its server and path; the servers themselves have not been read yet.
        let folders = kept.compactMap { identity -> (match: String, title: String)? in
            let parts = identity.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, !parts[1].isEmpty, parts[0] == "local" || UUID(uuidString: parts[0]) != nil else { return nil }
            return (WindowFolder.match(profileID: UUID(uuidString: parts[0]), path: parts[1]), parts[1] == "/" ? "/" : (parts[1] as NSString).lastPathComponent)
        }
        guard !folders.isEmpty else { return }
        let window = SavedWindow(name: name ?? folders.map(\.title).prefix(3).joined(separator: ", "), named: name != nil, folders: folders.map(\.match))
        save([window] + savedWindows().filter { $0.id != window.id && !(window.named && $0.named && $0.name == window.name) })
    }
    /// A further window is closing: what it kept is remembered under its name.
    func rememberWindow() {
        let kept = keptFolders
        guard !isPrimary, !kept.isEmpty else { return }
        let window = SavedWindow(name: windowName ?? kept.map(\.title).prefix(3).joined(separator: ", "), named: windowName != nil, folders: kept.map(\.match))
        save([window] + savedWindows().filter { $0.id != window.id && !(window.named && $0.named && $0.name == window.name) })
    }
    func forget(_ window: RecentWindow) { save(savedWindows().filter { $0.id != window.id }) }
    /// The closed windows that can be asked for: one that is planned again in the organizer is a
    /// column there, and is back in this list if that column is taken away.
    func closedWindows() -> [RecentWindow] {
        let planned = Set(windowDrafts.compactMap(\.origin))
        return recentWindows().filter { !planned.contains($0.id) }
    }
    /// A closed window comes back as a planned one, with the folders it had: every one of them the
    /// same way, as a column of its own. Asked for twice, it is the column it already has.
    @discardableResult func reopen(_ window: RecentWindow) -> UUID {
        if let planned = windowDrafts.first(where: { $0.origin == window.id }) { return planned.id }
        let id = addDraft()
        if let index = windowDrafts.firstIndex(where: { $0.id == id }) { windowDrafts[index].origin = window.id; if window.named { windowDrafts[index].name = window.name } }
        window.folders.forEach { place($0, inDraft: id) }
        return id
    }
    /// Opens a closed window again at once (from the start page): in this window if it is no
    /// workspace yet, else as a further one beside it.
    func reopenNow(_ window: RecentWindow) {
        reopen(window); realizeDrafts()
    }

    /// Windows that were planned and are waiting to be opened, one for each new window.
    static var pendingPlans: [WindowPlan] = []
    /// A new column in the organizer, empty or with one folder.
    @discardableResult func addDraft(with identity: String? = nil) -> UUID {
        let draft = WindowDraft()
        windowDrafts.append(draft)
        if let identity { place(identity, inDraft: draft.id) }
        return draft.id
    }
    /// The folder is planned for that window, and for no other planned one.
    func place(_ identity: String, inDraft id: UUID) {
        guard windowDrafts.contains(where: { $0.id == id }), let found = Self.folder(identity) else { return }
        let own = knownFolders().first { $0.match == found.match } ?? found
        unplace(own.id)
        if let index = windowDrafts.firstIndex(where: { $0.id == id }) { windowDrafts[index].folders.append(own.id) }
    }
    func unplace(_ identity: String) {
        guard windowDrafts.contains(where: { $0.folders.contains(identity) }) else { return }
        for index in windowDrafts.indices { windowDrafts[index].folders.removeAll { $0 == identity } }
    }
    func discardDraft(_ id: UUID) { windowDrafts.removeAll { $0.id == id } }
    /// The planned window a folder is in, if any.
    func draft(of folder: WindowFolder) -> WindowDraft? { windowDrafts.first { $0.folders.contains(folder.id) } }
    /// Opens the planned windows that were given folders; the folders leave the windows they were
    /// in (one with unsaved changes stays where it is). A planned window without folders is dropped.
    func realizeDrafts() {
        guard !windowDrafts.isEmpty else { return }
        let drafts = windowDrafts; windowDrafts = []
        var plans: [WindowPlan] = [], reopened = Set<String>()
        for draft in drafts {
            var kept: [String] = []
            for identity in draft.folders {
                guard let folder = Self.folder(identity) else { continue }
                if let source = Self.holder(of: folder), !source.release(folder) { continue }
                kept.append(folder.id)
            }
            let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !kept.isEmpty else { continue }
            plans.append(WindowPlan(name: name.isEmpty ? nil : String(name.prefix(80)), folders: kept))
            if let origin = draft.origin { reopened.insert(origin) }
            reopened.insert(kept.compactMap { Self.folder($0)?.match }.joined(separator: "\n"))
        }
        // A window that is open again is not a closed one.
        if savedWindows().contains(where: { reopened.contains($0.id) }) { save(savedWindows().filter { !reopened.contains($0.id) }) }
        // Opening Harbor is not making a workspace: a window that is none yet is the first planned
        // one itself, and only the others are further windows.
        if isBlank, let first = plans.first { plans.removeFirst(); take(first) }
        guard !plans.isEmpty else { return }
        Self.pendingPlans += plans; Self.tabHost = self
        workbenchUIRequest = "newWindow"
    }
    /// This window is what was planned: under that name, with those folders, the first on screen.
    private func take(_ plan: WindowPlan) {
        if let name = plan.name { windowName = name }
        // By the folder itself: this window may spell a path differently from the one that planned it.
        let folders = plan.folders.compactMap { Self.folder($0) }
        folders.forEach { join($0) }
        if let first = folders.first, let own = knownFolders().first(where: { $0.match == first.match }) { show(own) }
    }
    /// A window opened for a plan keeps its folders and shows the first; the next plan follows.
    func adoptWindowPlan() async {
        guard let plan = windowPlan else { return }
        windowPlan = nil
        take(plan)
        // Its window may only have come on screen now. Like any new tab, it is the one in front.
        joinTabs()
        if NSApp.isActive, let window, window.tabGroup?.selectedWindow !== window { window.makeKeyAndOrderFront(nil) }
        await retireArrival()
        if !Self.pendingPlans.isEmpty { workbenchUIRequest = "newWindow" }
    }
    /// Opens a new window on the folder, which then belongs to that window.
    func moveToNewWindow(_ identity: String) {
        guard let folder = Self.folder(identity) else { return }
        if let source = Self.holder(of: folder), !source.release(folder) { return }
        let profile = profiles.first { $0.id == folder.profileID }
        organizerVisible = false
        Task { await openFolderWorkspace(folder.path, profile: profile, newWindow: true) }
    }
    /// Stops a folder that is opening (it was the wrong one, or not worth the wait). The window
    /// goes back to the folder it showed before, or to its start page, and no longer keeps this one.
    func stopOpening(_ files: FileWorkspace) {
        codeWorkbench.existing(for: files)?.disconnect()
        let match = WindowFolder.match(profileID: files.profile?.id, path: files.root)
        if let folder = keptFolders.first(where: { $0.match == match }) { release(folder, quietly: true) }
        else {
            // Not a folder with a path yet (a server's login directory): only the page changes.
            codeWorkbench.close(files)
            if page == .workspace, currentFiles === files { page = .recent }
        }
    }
    /// The editor of a folder is starting in this window.
    func isOpening(_ folder: WindowFolder) -> Bool {
        guard let files = files(of: folder), let session = codeWorkbench.existing(for: files) else { return false }
        return session.running && !session.ready && !session.revealed && session.error == nil
    }
    /// Shows a folder of this window in it.
    func show(_ folder: WindowFolder) {
        guard let files = files(of: folder) else { return }
        files.enabled = true; selectDirectoryWorkspace(files)
    }
}

/// The organizer. On the left the library: every server with the folders that were opened on
/// it, and a way to add one. Beside it every window as a column with the folders it keeps, and
/// at the end "New Window", which adds a column for a window that does not exist yet. A folder is
/// dragged from the library (or from another column) into the window it should be in; planned
/// windows open when the organizer closes.
struct WindowOrganizer: View {
    @EnvironmentObject var store: AppStore
    @State private var revision = 0
    @State private var target: String?
    /// The servers of the library that are opened out. Kept between showings.
    @State private var opened: Set<String>?
    @State private var renaming: Int?
    @State private var name = ""
    @FocusState private var nameFocused: Bool
    @FocusState private var draftFocused: UUID?
    private static let openedKey = "libraryOpenServers"

    #if DEBUG
    /// How often the organizer and its rows were laid out again, for the probe.
    nonisolated(unsafe) static var evaluations = 0, rowEvaluations = 0
    #endif
    var body: some View {
        let _ = revision
        #if DEBUG
        let _ = { Self.evaluations += 1 }()
        #endif
        GeometryReader { geometry in
            let top = store.windowTop.contentTop
            // Each window names its own folders. A window that keeps none and has no name is not a
            // workspace, and has no column: Harbor as it starts shows the library and "New Window".
            let stores = store.windowStores.map { ($0, $0.keptFolders) }.filter { !($0.1.isEmpty && $0.0.windowName == nil && $0.0.windowPlan == nil) }
            let windows = stores.map(\.0), kept = stores.map(\.1)
            let keeper = Dictionary(zip(windows, kept).flatMap { window, folders in folders.map { ($0.match, window) } }, uniquingKeysWith: { first, _ in first })
            let library = store.library()
            let known = library.flatMap(\.folders)
            // A folder planned for a new window is shown there, and no longer in the window it will leave.
            let planned = Set(store.windowDrafts.flatMap(\.folders))
            let height = min(600, geometry.size.height - top - 40)
            let panel = min(1180, geometry.size.width - 56)
            // The windows, the planned ones, and "New Window".
            let columns = windows.count + store.windowDrafts.count + 1
            ZStack(alignment: .top) {
                Color.black.opacity(0.32).contentShape(Rectangle()).onTapGesture { store.organizerVisible = false }
                    .accessibilityLabel("Close").accessibilityAddTraits(.isButton)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Folders in Windows").harborFont(15, weight: .semibold)
                            Text("Drag a folder from the library into a window. Option+Tab switches between a window's folders; the windows are tabs of one, and ⌘1…9 switches between them.")
                                .harborFont(11).foregroundStyle(Color.harborMuted)
                        }
                        Spacer()
                        Button("Done") { store.organizerVisible = false }.keyboardShortcut(.cancelAction)
                    }.padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)
                    Rectangle().fill(Color.harborBorder).frame(height: 1)
                    // The columns are centered as one group, however many there are: a column that is
                    // added fades in while the ones that are there move apart to make room for it.
                    // Only when they no longer fit do the windows scroll beside the library.
                    HStack(alignment: .top, spacing: Self.gap) {
                        libraryColumn(library, keeper: keeper, windows: windows)
                        ScrollViewReader { reader in
                            ScrollView(.horizontal) {
                                HStack(alignment: .top, spacing: Self.gap) {
                                    ForEach(Array(windows.enumerated()), id: \.offset) { index, window in
                                        let folders = kept[index].filter { !planned.contains($0.id) }
                                        column(id: "window-\(index)", drop: { id in store.unplace(id); AppStore.move(id, to: window) }) {
                                            windowHeader(index, window, count: folders.count)
                                        } rows: {
                                            if folders.isEmpty { note("Drag folders here from the library.") }
                                            ForEach(folders) { folder in
                                                WindowFolderRow(folder: folder, place: .window(window), holder: window, draft: nil, windows: windows)
                                            }
                                        }
                                    }
                                    ForEach(store.windowDrafts) { draft in
                                        column(id: "draft-" + draft.id.uuidString, drop: { id in store.place(id, inDraft: draft.id) }) {
                                            draftHeader(draft)
                                        } rows: {
                                            if draft.folders.isEmpty { note("Drag folders here from the library. The window opens when you click Done.") }
                                            ForEach(draft.folders.compactMap { id in known.first { $0.id == id } }) { folder in
                                                WindowFolderRow(folder: folder, place: .draft(draft.id), holder: keeper[folder.match], draft: draft, windows: windows)
                                            }
                                        }
                                        .id("draft-" + draft.id.uuidString)
                                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                                    }
                                    column(id: "new", dashed: true, drop: { id in add(with: id) }) {
                                        header(symbol: "macwindow.badge.plus", title: "New Window")
                                    } rows: {
                                        Button { add(with: nil) } label: {
                                            Label("New Window", systemImage: "plus").harborFont(12, weight: .medium).frame(maxWidth: .infinity).frame(height: 30)
                                                .background(Color.harborHover, in: RoundedRectangle(cornerRadius: 7, style: .continuous)).contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain).padding(.horizontal, 6).padding(.top, 4).accessibilityIdentifier("organizer-new-window")
                                        note("Adds a window here to fill from the library. A folder can also be dropped on this column.")
                                    }.id("new")
                                }
                                .animation(Self.motion, value: store.windowDrafts.map(\.id))
                            }
                            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                            // A column that is added (a new window, a closed one brought back) is at the end:
                            // it comes into view as it fades in, with "New Window" after it.
                            .onChange(of: store.windowDrafts.count) { before, now in
                                guard now > before else { return }
                                // Once the row is laid out with the new column in it: asked for at once, the
                                // end it scrolls to is where the end was before.
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { withAnimation(Self.motion) { reader.scrollTo("new", anchor: .trailing) } }
                            }
                        }
                        .frame(width: Self.width(columns: columns, room: panel - 32 - Self.libraryWidth - Self.gap))
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .animation(Self.motion, value: columns)
                }
                .frame(width: panel, height: height)
                // The shadow is cast from the panel's outline (HarborPanelShadow). Cast by SwiftUI,
                // it was worked out again for every frame in which a list inside scrolled.
                .harborPanelGround(Color.harborBackground, cornerRadius: 12, shadow: 0.3, radius: 24, y: 10)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.harborBorder, lineWidth: 1))
                .padding(.top, top + max(0, (geometry.size.height - top - height) / 2 - 6))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .harborWindowFoldersChanged)) { _ in revision += 1 }
        .onReceive(NotificationCenter.default.publisher(for: .harborServersChanged)) { _ in revision += 1 }
        .onAppear { OrganizerScroll.watch() }.onDisappear { OrganizerScroll.stop() }
        .accessibilityIdentifier("window-organizer")
    }

    static let columnWidth: CGFloat = 256, libraryWidth: CGFloat = 284, gap: CGFloat = 12
    /// One pace for the column that fades in and the columns that move over for it.
    static var motion: Animation? { HarborMotion.animation(0.46) }
    /// How wide the windows are side by side, up to the room there is beside the library.
    static func width(columns: Int, room: CGFloat) -> CGFloat {
        min(CGFloat(columns) * columnWidth + CGFloat(max(columns - 1, 0)) * gap, max(columnWidth, room))
    }
    /// A new column. One that is empty is named first.
    private func add(with identity: String?) {
        let id = withAnimation(Self.motion) { store.addDraft(with: identity) }
        draftFocused = identity == nil ? id : nil
    }
    /// The servers that are opened out: what was chosen last time, and before any choice the
    /// servers this window has folders on (or, with none, the first server that has folders).
    private func openServers(_ library: [LibraryServer]) -> Set<String> {
        if let opened { return opened }
        if let saved = store.workspaceDefaults.stringArray(forKey: Self.openedKey) { return Set(saved) }
        let mine = Set(store.keptFolders.map { $0.profileID?.uuidString ?? "local" })
        return mine.isEmpty ? Set(library.first { !$0.folders.isEmpty }.map { [$0.id] } ?? []) : mine
    }
    private func setOpen(_ id: String, _ open: Bool, _ library: [LibraryServer]) {
        var next = openServers(library)
        if open { next.insert(id) } else { next.remove(id) }
        opened = next; store.workspaceDefaults.set(Array(next).sorted(), forKey: Self.openedKey)
    }

    private func libraryColumn(_ library: [LibraryServer], keeper: [String: AppStore], windows: [AppStore]) -> some View {
        let open = openServers(library), known = library.flatMap(\.folders)
        return column(id: "library", width: Self.libraryWidth, drop: { id in store.unplace(id); AppStore.move(id, to: nil) }) {
            HStack(spacing: 7) {
                Image(systemName: "books.vertical").font(.system(size: 12)).foregroundStyle(Color.harborIcon)
                Text("Library").harborFont(12, weight: .semibold)
                Spacer(minLength: 0)
                Menu {
                    ForEach(library) { server in
                        Button { setOpen(server.id, true, library); store.chooseLibraryFolder(on: server.profile) } label: { Label(server.name, systemImage: server.icon) }
                    }
                } label: { Image(systemName: "plus").font(.system(size: 11, weight: .medium)).frame(width: 22, height: 22).contentShape(Rectangle()) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Add a folder on a server").accessibilityLabel("Add folder")
            }
        } rows: {
            ForEach(library) { server in
                let shown = open.contains(server.id)
                LibraryServerHeader(server: server, open: shown, toggle: { setOpen(server.id, !shown, library) },
                                    add: { setOpen(server.id, true, library); store.chooseLibraryFolder(on: server.profile) })
                if shown {
                    if server.folders.isEmpty { note("No folder yet. Add one with +.").padding(.leading, 14).padding(.bottom, 4) }
                    ForEach(server.folders) { folder in
                        WindowFolderRow(folder: folder, place: .library, holder: keeper[folder.match], draft: store.draft(of: folder), windows: windows)
                    }
                }
            }
        } footer: {
            // The windows that were closed stay in view under the servers, however long that list is.
            let recent = store.closedWindows()
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Rectangle().fill(Color.harborBorder).frame(height: 1)
                    Text("RECENT WINDOWS").harborFont(10, weight: .semibold).kerning(0.6).foregroundStyle(Color.harborMuted)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).frame(height: 26, alignment: .bottom).padding(.bottom, 2)
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(recent) { window in
                                RecentWindowRow(window: window, titles: window.folders.compactMap { id in known.first { $0.id == id }?.title }) {
                                    // It leaves this list as its column fades in beside the others.
                                    withAnimation(Self.motion) { _ = store.reopen(window) }
                                }
                            }
                        }.padding(.horizontal, 4).padding(.bottom, 6)
                    }.frame(height: min(3, CGFloat(recent.count)) * 38 + 6)
                }
            }
        }
    }

    private func header(symbol: String, title: String, count: Int = 0) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Color.harborIcon)
            Text(title).harborFont(12, weight: .semibold).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            if count > 0 { Text("\(count)").harborFont(10, design: .monospaced).foregroundStyle(Color.harborMuted) }
        }
    }
    /// A window's name, which can be changed here; an empty one goes back to what the window shows.
    @ViewBuilder private func windowHeader(_ index: Int, _ window: AppStore, count: Int) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "macwindow").font(.system(size: 12)).foregroundStyle(Color.harborIcon)
            if renaming == index {
                TextField(window.automaticWindowTitle, text: $name).textFieldStyle(.plain).harborFont(12, weight: .semibold).focused($nameFocused)
                    .onSubmit { window.renameWindow(to: name); renaming = nil; revision += 1 }
                    .onExitCommand { renaming = nil }
                    .onAppear { nameFocused = true }
            } else {
                Text(window.windowTitle).harborFont(12, weight: .semibold).lineLimit(1).truncationMode(.middle)
                if window === store { capsule("This window") }
                if window.separate { capsule("Separate") }
                Spacer(minLength: 0)
                Menu {
                    Button("Rename Window…") { name = window.windowName ?? ""; renaming = index }
                    // The windows are tabs of one window; this one can stand on its own.
                    Toggle("Keep as a Separate Window", isOn: Binding(get: { window.separate }, set: { window.setSeparate($0); revision += 1 }))
                } label: { Image(systemName: "ellipsis").font(.system(size: 11)).frame(width: 20, height: 20).contentShape(Rectangle()) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(Color.harborMuted)
                    .help("Rename this window, or keep it as a window of its own").accessibilityLabel("Window options")
                if count > 0 { Text("\(count)").harborFont(10, design: .monospaced).foregroundStyle(Color.harborMuted) }
            }
        }
    }
    /// A planned window is named in place, and taken away again with the cross.
    private func draftHeader(_ draft: WindowDraft) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "macwindow.badge.plus").font(.system(size: 12)).foregroundStyle(Color.harborAccent)
            TextField("New Window", text: Binding(get: { store.windowDrafts.first { $0.id == draft.id }?.name ?? "" },
                                                  set: { value in if let index = store.windowDrafts.firstIndex(where: { $0.id == draft.id }) { store.windowDrafts[index].name = value } }))
                .textFieldStyle(.plain).harborFont(12, weight: .semibold).focused($draftFocused, equals: draft.id).onSubmit { draftFocused = nil }
                .help("Name the new window").accessibilityLabel("Name of the new window")
            capsule("New")
            Button { withAnimation(Self.motion) { store.discardDraft(draft.id) } } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).frame(width: 20, height: 20).contentShape(Rectangle()) }
                .buttonStyle(.plain).foregroundStyle(Color.harborMuted).help("Take this new window away; its folders stay where they are").accessibilityLabel("Discard new window")
        }
    }
    private func capsule(_ text: String) -> some View {
        Text(text).harborFont(10).foregroundStyle(Color.harborMuted).padding(.horizontal, 6).padding(.vertical, 1).overlay(Capsule().stroke(Color.harborBorder)).fixedSize()
    }
    private func note(_ text: String) -> some View {
        Text(text).harborFont(11).foregroundStyle(Color.harborMuted).multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6).padding(.top, 6)
    }
    private func column<Header: View, Rows: View>(id: String, width: CGFloat = WindowOrganizer.columnWidth, dashed: Bool = false, drop: @escaping (String) -> Void,
                                                 @ViewBuilder header: () -> Header, @ViewBuilder rows: () -> Rows) -> some View {
        column(id: id, width: width, dashed: dashed, drop: drop, header: header, rows: rows, footer: { EmptyView() })
    }
    private func column<Header: View, Rows: View, Footer: View>(id: String, width: CGFloat = WindowOrganizer.columnWidth, dashed: Bool = false, drop: @escaping (String) -> Void,
                                                               @ViewBuilder header: () -> Header, @ViewBuilder rows: () -> Rows, @ViewBuilder footer: () -> Footer) -> some View {
        let targeted = target == id
        return VStack(alignment: .leading, spacing: 4) {
            header().padding(.horizontal, 10).frame(height: 32)
            ScrollView { VStack(alignment: .leading, spacing: 2) { rows() }.padding(.horizontal, 4).padding(.bottom, 6) }
            footer()
        }
        .frame(width: width).frame(maxHeight: .infinity, alignment: .top)
        .background(targeted ? Color.harborAccent.opacity(0.10) : Color.harborEditor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(targeted ? Color.harborAccent : Color.harborBorder, style: StrokeStyle(lineWidth: targeted ? 1.5 : 1, dash: dashed ? [6, 5] : [])))
        .dropDestination(for: String.self) { items, _ in
            items.forEach(drop); return !items.isEmpty
        } isTargeted: { inside in
            if inside { target = id } else if target == id { target = nil }
        }
        .animation(HarborMotion.feedback(.crossfade), value: targeted)
    }
}

/// A server of the library: opened out or folded away, and a folder is added with its plus.
private struct LibraryServerHeader: View {
    let server: LibraryServer
    let open: Bool
    let toggle: () -> Void
    let add: () -> Void
    @State private var hovered = false
    var body: some View {
        HStack(spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(open ? 90 : 0)).frame(width: 12)
                    Image(systemName: server.icon).font(.system(size: 11)).frame(width: 16)
                    Text(server.name).harborFont(11, weight: .semibold).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(server.folders.count)").harborFont(10, design: .monospaced).foregroundStyle(Color.harborMuted)
                }.padding(.leading, 6).frame(height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain).animation(HarborMotion.feedback(.select), value: open)
            .accessibilityLabel(server.name + (open ? ", shown" : ", hidden")).help(open ? "Hide this server's folders" : "Show the folders opened on this server")
            Button(action: add) { Image(systemName: "plus").font(.system(size: 10, weight: .medium)).frame(width: 24, height: 24).contentShape(Rectangle()) }
                .buttonStyle(.plain).foregroundStyle(Color.harborMuted).opacity(hovered ? 1 : 0.45)
                .help("Add a folder on " + server.name).accessibilityLabel("Add a folder on " + server.name)
        }
        .foregroundStyle(server.folders.isEmpty ? Color.harborMuted : Color.harborForeground)
        .background(hovered ? Color.harborHover.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onContinuousHover { phase in
            switch phase {
            case .active: if !hovered, !OrganizerScroll.active { hovered = true }
            case .ended: if hovered { hovered = false }
            }
        }
    }
}

/// Whether a list is being scrolled right now (the wheel or the trackpad, its coasting included).
@MainActor enum OrganizerScroll {
    private static var last = 0.0
    private static var monitor: Any?
    private static var users = 0
    static var active: Bool { ProcessInfo.processInfo.systemUptime - last < 0.14 }
    static func watch() {
        users += 1
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            MainActor.assumeIsolated { last = event.timestamp }
            return event
        }
    }
    static func stop() {
        users = max(0, users - 1)
        if users == 0, let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
}

/// A window that was closed, in the library: a click plans it again with the folders it had.
private struct RecentWindowRow: View {
    @EnvironmentObject var store: AppStore
    let window: RecentWindow
    let titles: [String]
    let reopen: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: reopen) {
            HStack(spacing: 8) {
                Image(systemName: "macwindow").font(.system(size: 12)).foregroundStyle(Color.harborIcon).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(window.name).harborFont(12, weight: .medium).lineLimit(1).truncationMode(.middle)
                    Text(window.named ? titles.joined(separator: ", ") : titles.count == 1 ? "1 folder" : "\(titles.count) folders")
                        .harborFont(10).foregroundStyle(Color.harborMuted).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 4)
                if hovered { Text("Reopen").harborFont(10).foregroundStyle(Color.harborAccent) }
            }
            .padding(.leading, 8).padding(.trailing, 8).frame(height: 36).contentShape(Rectangle())
            .background(hovered ? Color.harborHover : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
        .contextMenu {
            Button("Reopen", action: reopen)
            Button("Forget This Window", role: .destructive) { withAnimation(WindowOrganizer.motion) { store.forget(window) } }
        }
        .help("Open this window again with its folders: " + titles.joined(separator: ", "))
        .accessibilityLabel("Reopen window " + window.name)
    }
}

/// One folder in a column: in the library, in a window, or in a planned window.
private struct WindowFolderRow: View {
    enum Place { case library, window(AppStore), draft(UUID) }
    @EnvironmentObject var store: AppStore
    let folder: WindowFolder
    let place: Place
    /// The window that keeps the folder, if any.
    let holder: AppStore?
    /// The planned window it is in, if any.
    let draft: WindowDraft?
    let windows: [AppStore]
    @State private var hovered = false
    private var dots: some View { Image(systemName: "ellipsis").font(.system(size: 11)).frame(width: 20, height: 20).contentShape(Rectangle()) }
    private var inLibrary: Bool { if case .library = place { return true }; return false }
    /// The width at the row's trailing edge that its own controls take: the dots, and in a window
    /// the cross before them. A press there is theirs, not the start of a drag.
    private var controlsWidth: CGFloat { inLibrary ? 26 : 52 }
    /// The window that keeps it is showing it now.
    private var shown: Bool { holder.map { $0.page == .workspace && $0.workspaceClaim?.key == folder.id } ?? false }
    private var opening: Bool { holder?.isOpening(folder) ?? false }
    /// Where it is, for the library: the planned window it will be in, else the window that keeps it.
    private var whereabouts: String? { draft?.title ?? holder.map { $0 === store ? "This window" : $0.windowTitle } }
    var body: some View {
        #if DEBUG
        let _ = { WindowOrganizer.rowEvaluations += 1 }()
        #endif
        HStack(spacing: 8) {
            Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(Color.harborIcon).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(folder.title).harborFont(12, weight: .medium).lineLimit(1).truncationMode(.middle)
                Text(opening ? "Opening…" : inLibrary ? folder.path : folder.server)
                    .harborFont(10).foregroundStyle(Color.harborMuted).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 4)
            if inLibrary, let whereabouts {
                Text(whereabouts).harborFont(9.5).foregroundStyle(Color.harborMuted).lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 6).padding(.vertical, 1.5).overlay(Capsule().stroke(Color.harborBorder)).frame(maxWidth: 92, alignment: .trailing)
                    .help("In “" + whereabouts + "”")
            }
            if !inLibrary, shown, draft == nil { Circle().fill(Color.harborSuccess).frame(width: 6, height: 6).help("On screen in that window") }
            if !inLibrary, hovered {
                Button(action: remove) { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).frame(width: 18, height: 20).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(Color.harborMuted).help("Take it out of this window").accessibilityLabel("Remove " + folder.title + " from this window")
            }
            // The row draws its dots itself, and a click on them puts up the row's menu, the one a
            // right click gives. There is no menu button in the row: a menu button is an AppKit view,
            // and a list of them has to be moved one by one on the main thread for every frame of a
            // scroll.
            dots.opacity(hovered ? 1 : 0.35).onTapGesture { FolderRowMenu.popUp(entries) }
                .accessibilityLabel("More for " + folder.title).accessibilityAddTraits(.isButton)
        }
        .padding(.leading, inLibrary ? 22 : 8).padding(.trailing, 6).frame(height: 36).contentShape(Rectangle())
        .background(hovered ? Color.harborHover : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        // The drag is AppKit's: a press on the row that moves begins a dragging session with the
        // folder's id, which the columns take as the String they are drop destinations for. SwiftUI's
        // own draggable never began one here. Everything but that press (hover, scrolling, a right
        // click, the row's controls at its trailing edge) goes to the row as before.
        .overlay(FolderDragSource(id: folder.id, title: folder.title, controls: controlsWidth) { hovered = false })
        // Rows that pass under a pointer at rest while the list scrolls are not each lit and laid out
        // again; the one the pointer is on is lit as soon as the pointer moves.
        .onContinuousHover { phase in
            switch phase {
            case .active: if !hovered, !OrganizerScroll.active { hovered = true }
            case .ended: if hovered { hovered = false }
            }
        }
        .contextMenu { menu }
        .help(folder.path + " · " + folder.server)
        .accessibilityElement(children: .contain).accessibilityLabel(folder.title + ", " + folder.server)
    }
    /// Out of the column it is in: a planned window forgets it, a window lets go of it.
    private func remove() {
        if draft != nil { store.unplace(folder.id) } else { AppStore.move(folder, to: nil) }
    }
    private func move(to window: AppStore) { store.unplace(folder.id); AppStore.move(folder, to: window) }
    private static func entry(_ title: String, destructive: Bool = false, _ run: @escaping @MainActor () -> Void) -> FolderRowEntry {
        .item(title: title, destructive: destructive, run: run)
    }
    /// What can be done with the folder, in the order of its menu; a section ends with .divider.
    private var entries: [FolderRowEntry] {
        var entries: [FolderRowEntry] = []
        if let holder, draft == nil {
            if opening { entries.append(Self.entry("Stop Opening") { if let files = holder.files(of: folder) { holder.stopOpening(files) } }) }
            entries.append(Self.entry("Show in " + (holder === store ? "This Window" : "“" + holder.windowTitle + "”")) {
                store.organizerVisible = false; holder.show(folder); holder.bringForward()
            })
            entries.append(.divider)
        }
        for window in windows where window !== holder || draft != nil {
            entries.append(Self.entry("Move to " + (window === store ? "This Window" : "“" + window.windowTitle + "”")) { move(to: window) })
        }
        for other in store.windowDrafts where other.id != draft?.id {
            entries.append(Self.entry("Move to “" + other.title + "”") { store.place(folder.id, inDraft: other.id) })
        }
        entries.append(Self.entry("Move to New Window") { withAnimation(WindowOrganizer.motion) { _ = store.addDraft(with: folder.id) } })
        if holder != nil || draft != nil { entries.append(Self.entry("Remove from Window") { remove() }) }
        entries.append(.divider)
        // Out of Harbor's list altogether. The files on disk stay.
        entries.append(Self.entry("Remove from Library…", destructive: true) {
            store.unplace(folder.id)
            let owner = holder ?? store
            if let files = owner.files(of: folder) { owner.closeDirectoryWorkspace(files) }
        })
        return entries
    }
    /// The same entries as the menu of a right click.
    @ViewBuilder private var menu: some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            switch entry {
            case .divider: Divider()
            case .item(let title, let destructive, let run): Button(title, role: destructive ? .destructive : nil, action: run)
            }
        }
    }
}

/// One line of a folder row's menu. The right click's menu and the one under the row's dots are
/// built from the same list.
enum FolderRowEntry {
    case item(title: String, destructive: Bool, run: @MainActor () -> Void)
    case divider
    var title: String? { if case .item(let title, _, _) = self { return title }; return nil }
}

/// The menu under a folder row's dots: AppKit's own, put up at the pointer, so that the row holds
/// no menu button. The entry chosen runs once the menu has gone.
@MainActor final class FolderRowMenu: NSObject {
    private var runs: [@MainActor () -> Void] = []
    /// A menu item's target is not retained by the item. The last menu's owner is kept until the next.
    private static var shown: FolderRowMenu?
    static func menu(_ entries: [FolderRowEntry]) -> NSMenu {
        let owner = FolderRowMenu(), list = NSMenu()
        list.autoenablesItems = false
        for entry in entries {
            switch entry {
            case .divider: list.addItem(.separator())
            case .item(let title, _, let run):
                let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
                item.target = owner; item.tag = owner.runs.count; owner.runs.append(run)
                list.addItem(item)
            }
        }
        shown = owner
        return list
    }
    static func popUp(_ entries: [FolderRowEntry]) {
        let list = menu(entries), pointer = NSEvent.mouseLocation
        // After the click that asked for it is over, so that the click cannot land on an entry.
        Task { @MainActor in list.popUp(positioning: nil, at: NSPoint(x: pointer.x - 12, y: pointer.y - 8), in: nil) }
    }
    @objc private func choose(_ item: NSMenuItem) { if runs.indices.contains(item.tag) { runs[item.tag]() } }
}

/// The drag of a folder row, as AppKit does it. A press that moves (by a few points) begins a
/// dragging session carrying the folder's id as plain text; the organizer's columns are SwiftUI
/// drop destinations for String, and take it from there. Only that press is taken: hover, scrolling,
/// a right click, and the row's own controls at its trailing edge all pass through to the row.
private struct FolderDragSource: NSViewRepresentable {
    let id: String
    let title: String
    /// The width at the trailing edge left to the row's controls.
    let controls: CGFloat
    /// The drag has begun; the row is no longer the one under the pointer.
    let began: () -> Void
    func makeNSView(context: Context) -> FolderDragView { FolderDragView() }
    func updateNSView(_ view: FolderDragView, context: Context) {
        view.id = id; view.title = title; view.controls = controls; view.began = began
    }
}

final class FolderDragView: NSView, NSDraggingSource {
    var id = "", title = ""
    var controls: CGFloat = 0
    var began: () -> Void = {}
    /// Where the left button went down, while it is down and no drag has begun.
    private var pressed: NSPoint?
    /// How far a press moves before it is a drag.
    static let slack: CGFloat = 4
    /// The pasteboard type the folder's id travels as; what a String drop destination reads.
    static let type = NSPasteboard.PasteboardType.string

    /// Only a press of the left button, outside the row's controls, is this view's. Everything else
    /// (the pointer moving, the wheel, a right click or a Control-click for the row's menu) finds the
    /// row underneath, as if this view were not here.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp?.currentEvent, event.type == .leftMouseDown, !event.modifierFlags.contains(.control) else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local), local.x < bounds.width - controls else { return nil }
        return self
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { pressed = convert(event.locationInWindow, from: nil) }
    override func mouseUp(with event: NSEvent) { pressed = nil }
    override func mouseDragged(with event: NSEvent) {
        guard let pressed else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - pressed.x, point.y - pressed.y) >= Self.slack else { return }
        self.pressed = nil
        let item = NSPasteboardItem()
        item.setString(id, forType: Self.type)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let image = Self.image(for: title)
        dragging.setDraggingFrame(NSRect(x: point.x - 14, y: point.y - image.size.height / 2, width: image.size.width, height: image.size.height), contents: image)
        began()
        _ = beginDraggingSession(with: [dragging], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // A folder goes into a column of the organizer, and nowhere outside Harbor.
        context == .withinApplication ? [.move, .copy, .generic] : []
    }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    /// What travels with the pointer: the folder's name on a small card.
    @MainActor static func image(for title: String) -> NSImage {
        let card = Label(title, systemImage: "folder").harborFont(12).foregroundStyle(Color.harborForeground)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.harborWidget, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.harborBorder))
        let host = NSHostingView(rootView: card)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let image = NSImage(size: host.bounds.size)
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            image.addRepresentation(bitmap)
        }
        return image
    }
}
