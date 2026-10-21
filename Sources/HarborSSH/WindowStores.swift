import SwiftUI
import AppKit
import HarborCore

/// Harbor opens any number of workbench windows. The first window uses the
/// application's primary store, which owns saved terminals, forwarding and
/// timers. Every further window gets a light store of its own: an independent
/// page, server/folder selection, editor sessions and terminals, sharing the
/// primary store's server catalog, recents and services.
@MainActor extension AppStore {
    private static let registry = NSHashTable<AppStore>.weakObjects()
    private static var claimOrder = 0
    /// The store of the window that was key most recently.
    static weak var lastActive: AppStore?
    /// A folder to open in the next window that is created.
    static var pendingWindowFolder: (path: String, profileID: UUID?)?
    /// The window the organizer was closed in: the windows it planned become tabs beside it.
    static weak var tabHost: AppStore?

    static var all: [AppStore] { registry.allObjects }
    /// The windows of one Harbor: the first window's store and every further window's. They
    /// share the servers, so what one of them has open on a server concerns all of them.
    var family: [AppStore] {
        let first = primary ?? self
        return [first] + Self.all.filter { $0.primary === first }
    }
    static func register(_ store: AppStore) { registry.add(store) }
    static func owner(ofTerminalWindow id: UUID) -> AppStore? {
        all.first { store in store.sessions.contains { $0.windowID == id } }
    }

    /// Servers, forwarding rules and recents are one catalog for every window.
    func adoptCatalog(from other: AppStore) {
        if profiles != other.profiles { profiles = other.profiles }
        if rules != other.rules { rules = other.rules }
        if recents != other.recents { recents = other.recents }
    }

    /// One folder workspace is shown by one window at a time: two editors on
    /// the same folder would share a command bridge and terminals. The window
    /// that showed it first keeps it; a later window offers to switch instead.
    func updateWorkspaceClaim() {
        // Identity is the server plus the folder itself: the same path can sit
        // in different folder slots of two windows.
        // Reading the saved data passes through the first server before it settles on the start
        // page. That is not a workspace anyone was shown, and must not count as the last one used.
        // Reverse Proxy and Remote Display are looked at and left again, back to the folder: it is
        // still this window's meanwhile. (It used to be given up, and a window waiting for it took
        // it and closed this window's editor.)
        let shown = page == .workspace || (Self.sidePages.contains(page) && pageReturn == .workspace)
        let files = shown && window != nil && !loading ? currentFiles : nil
        let key = files.map(\.claimKey)
        guard key != workspaceClaim?.key else { return }
        if let key {
            Self.claimOrder += 1; workspaceClaim = (key, Self.claimOrder); WorkspaceSwitcher.touch(key)
            // With unsaved changes in it the folder is this window's whichever window showed it
            // first (`workspaceOwner`). The windows that came to it meanwhile stay behind this one
            // once the changes are saved; by the order alone the folder went over to one of them
            // then, into a second editor.
            if codeWorkbench.hasUnsavedFiles(claimKey: key) {
                for other in Self.all where other !== self && other.workspaceClaim?.key == key {
                    Self.claimOrder += 1; other.workspaceClaim?.order = Self.claimOrder
                }
            }
            ownRecency.removeAll { $0 == key }; ownRecency.insert(key, at: 0)
            if ownRecency.count > 64 { ownRecency.removeLast(ownRecency.count - 64) }
            // A folder that is shown in a window is that window's, until it is moved.
            if workspaceOwner == nil, let files, !files.root.isEmpty { join(key) }
        } else { workspaceClaim = nil }
        // A released or newly taken workspace changes what other windows may show.
        // Deliver after this store's own change so no view updates re-entrantly.
        let peers = Self.all.filter { $0 !== self }
        if !peers.isEmpty { DispatchQueue.main.async { peers.forEach { $0.objectWillChange.send(); $0.takeFreedWorkspace() } } }
    }
    /// The window that showed this window's folder first has gone on to another one: the folder
    /// is shown here now, so it becomes this window's (and stops being the other's, whose editor
    /// for it is closed). Without this the other window kept its editor while this one started a second.
    func takeFreedWorkspace() {
        guard page == .workspace, window != nil, !loading, let claim = workspaceClaim, workspaceOwner == nil, !currentFiles.root.isEmpty else { return }
        join(claim.key)
    }
    var workspaceOwner: AppStore? {
        guard let claim = workspaceClaim else { return nil }
        // Unsaved changes decide first: the window whose editor has them cannot let the folder go,
        // so it is that window's wherever it is on screen, and no second editor is started on it.
        if codeWorkbench.hasUnsavedFiles(claimKey: claim.key) { return nil }
        let others = Self.all.filter { $0 !== self && $0.window != nil }
        if let holder = others.first(where: { $0.codeWorkbench.hasUnsavedFiles(claimKey: claim.key) }) { return holder }
        return others.first { other in
            guard let theirs = other.workspaceClaim else { return false }
            return theirs.key == claim.key && theirs.order < claim.order
        }
    }
    /// Brings this window forward on the folder another window asked about.
    func showClaimed(_ key: String, _ openWindow: OpenWindowAction) {
        if workspaceClaim?.key != key, let folder = knownFolders().first(where: { $0.id == key }) { show(folder) }
        showWindow(openWindow)
    }

    /// What the window is called in its tab, the Window menu and Mission Control.
    var windowTitle: String { windowName ?? automaticWindowTitle }
    var automaticWindowTitle: String {
        switch page {
        case .workspace: return (selectedProfile?.name ?? LocalMachine.name) + " · " + currentFiles.directoryTitle
        case .recent: return "Harbor"
        case .terminal: return (homeTerminal?.profile?.name ?? LocalMachine.name) + " · Terminal"
        case .proxy, .display: return page.rawValue
        }
    }
    /// An empty name goes back to the server and folder.
    func renameWindow(to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = trimmed.isEmpty ? nil : String(trimmed.prefix(80))
        if windowName != next { windowName = next }
    }
    func promptForWindowName() {
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert(); alert.messageText = "Rename Window"
        alert.informativeText = "Leave blank to name it after its server and folder."
        let field = NSTextField(string: windowName ?? "")
        field.placeholderString = automaticWindowTitle
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.renameWindow(to: field.stringValue) }
        }
    }
    /// A double click on a window's tab renames that window.
    static func installTabRename() {
        _ = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            MainActor.assumeIsolated {
                guard event.clickCount == 2, let host = event.window, let root = host.contentView?.superview else { return }
                var view = root.hitTest(event.locationInWindow)
                while let current = view, !String(describing: type(of: current)).hasPrefix("NSTabButton") { view = current.superview }
                guard view != nil else { return }
                // The first click selected the tab. In full screen the tab bar is in a window of its own.
                let candidates = [host.tabGroup?.selectedWindow, host, NSApp.mainWindow?.tabGroup?.selectedWindow, NSApp.mainWindow, NSApp.keyWindow]
                guard let store = candidates.lazy.compactMap({ window in window.flatMap { window in all.first { $0.window === window } } }).first else { return }
                // The tab follows the pointer until the button is let go; ask after that.
                Task { @MainActor in
                    for _ in 0..<100 where NSEvent.pressedMouseButtons != 0 { try? await Task.sleep(nanoseconds: 30_000_000) }
                    store.promptForWindowName()
                }
            }
            return event
        }
    }

    func attach(window: NSWindow?) {
        guard self.window !== window else { return }
        self.window = window
        if let window { windowAttached = true; Self.lastActive = self; Self.installCloseQuestion(for: window) }
        // A window opened from the organizer is a tab beside the others from its first frame.
        if planned { joinTabs() }
        updateWorkspaceClaim()
    }

    /// The windows are tabs of one window unless they are kept separate: Command+1…9 switches
    /// between them, and the tab bar stays put away until the pointer goes up to it. This gathers
    /// the ones that are apart into the largest group there is (this window's, when it is as
    /// large), and leaves this window in front.
    func gatherWindows() {
        let stores = windowStores.filter { !$0.separate && $0.window != nil }
        guard stores.count > 1 else { return }
        var host = stores[0]
        for other in stores.dropFirst() where (other.window?.tabbedWindows?.count ?? 1) > (host.window?.tabbedWindows?.count ?? 1) { host = other }
        guard let hostWindow = host.window else { return }
        var moved = false
        for other in stores where other !== host {
            guard let window = other.window, hostWindow.tabbedWindows?.contains(window) != true else { continue }
            // A window in a full screen of its own stays there; it would take the others with it.
            if window.styleMask.contains(.fullScreen), !hostWindow.styleMask.contains(.fullScreen) { continue }
            if window.isMiniaturized { window.deminiaturize(nil) }
            (hostWindow.tabbedWindows?.last ?? hostWindow).addTabbedWindow(window, ordered: .above); moved = true
        }
        if moved, !separate, let window, window.tabGroup?.selectedWindow !== window { window.makeKeyAndOrderFront(nil) }
    }
    /// This window becomes a tab of the others' window, after the last one.
    func joinTabs() {
        // Beside the window it was planned in; if that one stands on its own, beside the others.
        let others = Self.all.filter { $0 !== self && !$0.separate && $0.window != nil }
        guard !separate, let window, let host = others.first(where: { $0 === Self.tabHost }) ?? others.max(by: { ($0.window?.tabbedWindows?.count ?? 1) < ($1.window?.tabbedWindows?.count ?? 1) }),
              let hostWindow = host.window, hostWindow.tabbedWindows?.contains(window) != true else { return }
        (hostWindow.tabbedWindows?.last ?? hostWindow).addTabbedWindow(window, ordered: .above)
    }
    /// Takes the window out of the tabs to stand on its own, or puts it back among them.
    func setSeparate(_ value: Bool) {
        guard separate != value else { return }
        separate = value
        if value { if let window, (window.tabbedWindows?.count ?? 1) > 1 { window.moveTabToNewWindow(nil) } }
        else { gatherWindows() }
        NotificationCenter.default.post(name: .harborWindowFoldersChanged, object: nil)
    }
    /// Bring this store's window forward, or create one for the primary store.
    func showWindow(_ openWindow: OpenWindowAction) {
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        } else { openWindow(id: "main") }
    }
    /// Asked before a further window closes with something in it that closing ends: the window's
    /// editors with unsaved changes, and its plain terminals. (The first window keeps what it
    /// has when it is closed, and is not asked about.) A test answers instead of a person.
    func mayCloseWindow() -> Bool {
        // A shell on a server that has only lost its connection is still running there, and ends
        // with the window like the others: it is asked about too.
        guard !isPrimary, !shuttingDown, hasUnsavedFiles || sessions.contains(where: { !$0.ended || $0.resumable }) else { return true }
        return confirmWindowClose(self)
    }
    static func askToCloseWindow(_ store: AppStore) -> Bool {
        let alert = NSAlert(), terminals = store.sessions.filter { !$0.ended || $0.resumable }.count
        alert.messageText = store.hasUnsavedFiles ? "Close this window with unsaved changes?" : "Close this window?"
        var parts: [String] = []
        if store.hasUnsavedFiles { parts.append("Files in this window’s editor have changes that are not saved; they may be lost. Cancel and save them with ⌘S.") }
        if terminals > 0 { parts.append(terminals == 1 ? "Its terminal closes with it, and what runs there ends." : "Its \(terminals) terminals close with it, and what runs in them ends.") }
        alert.informativeText = parts.joined(separator: " ")
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Close Window")
        return alert.runModal() == .alertSecondButtonReturn
    }
    /// The store whose window this is, if it is one that asks before closing.
    static func mayClose(_ window: NSWindow) -> Bool {
        all.first { $0.window === window }?.mayCloseWindow() ?? true
    }
    private static var closeQuestionClasses = Set<ObjectIdentifier>()
    /// Whether a window may close is asked of its delegate, and SwiftUI owns the delegate of the
    /// windows it makes. Its answer is kept, with Harbor's question put in front of it: the close
    /// button, the one on the window's tab and File ▸ Close all end up there. Done once for the
    /// delegate's class; if that is ever not as expected, windows simply close as they did before.
    static func installCloseQuestion(for window: NSWindow) {
        let selector = #selector(NSWindowDelegate.windowShouldClose(_:))
        guard let delegate = window.delegate, let kind = object_getClass(delegate), !closeQuestionClasses.contains(ObjectIdentifier(kind)),
              let method = class_getInstanceMethod(kind, selector) else { return }
        closeQuestionClasses.insert(ObjectIdentifier(kind))
        typealias Answer = @convention(c) (AnyObject, Selector, NSWindow) -> Bool
        let systems = unsafeBitCast(method_getImplementation(method), to: Answer.self)
        let asked: @convention(block) (AnyObject, NSWindow) -> Bool = { receiver, sender in
            guard MainActor.assumeIsolated({ AppStore.mayClose(sender) }) else { return false }
            return systems(receiver, selector, sender)
        }
        method_setImplementation(method, imp_implementationWithBlock(asked))
    }
    /// A folder or a planned window handed to "the next window" (`pendingWindowFolder`,
    /// `pendingPlans`) is taken up by the store that window gets. With the first window closed
    /// that is the first window's store again, which has long since loaded and used to ignore
    /// them: the window came up on its old page, and the next unrelated new window got the folder.
    func takeHandOver() async {
        guard isPrimary, !loading else { return }
        if let request = Self.pendingWindowFolder {
            Self.pendingWindowFolder = nil
            let profile = profiles.first { $0.id == request.profileID }
            if request.profileID == nil || profile != nil {
                arriving = WorkspaceArrivalNote(path: request.path, server: profile?.name ?? LocalMachine.name, fresh: false)
                _ = await openDirectoryWorkspace(request.path, profile: profile)
            }
            await retireArrival()
        } else if windowPlan == nil, !Self.pendingPlans.isEmpty {
            windowPlan = Self.pendingPlans.removeFirst(); planned = true
            await adoptWindowPlan()
        }
    }
    func windowWillClose() {
        window = nil; windowAttached = false; updateWorkspaceClaim()
        if Self.lastActive === self { Self.lastActive = Self.all.first { $0.window != nil } }
        if !isPrimary { closeWindowStore() }
    }
    /// Releases an additional window's editors and terminals. Shared services
    /// (forwarding, remote displays, saved terminals) stay with the primary store.
    /// At quit its shells on servers were written down by the first window's store and are
    /// returned to after the restart. When only the window is closed there is no way back to
    /// them, so they end with it instead of running on unseen for a day.
    func closeWindowStore(quitting: Bool = false) {
        guard !isPrimary, !shuttingDown else { return }
        rememberWindow()
        shuttingDown = true
        directoryBrowser?.cancel(); directoryBrowser = nil
        directoryTrackingTask?.cancel(); directoryTrackingTask = nil; endDrag()
        recoveryTimer?.invalidate(); recoveryTimer = nil
        for session in sessions {
            if !quitting, !session.remotePTYGone, !session.ended || session.remotePTYReconnect, let id = session.remotePTYID, let profile = session.profile, let primary {
                Task { _ = try? await primary.endRemoteShell(id, on: profile) }
            }
            session.stop()
        }
        for workspace in fileWorkspaces.values { workspace.cleanCache() }
        codeWorkbench.shutdown()
        Self.registry.remove(self)
    }
}

@MainActor final class WindowStoreHolder: ObservableObject {
    let store: AppStore
    init(primary: AppStore) {
        // The first window (and a window reopened after it was closed) shows the
        // primary store with its restored terminals; later windows start fresh.
        store = primary.windowAttached ? AppStore(workspaceDefaults: primary.workspaceDefaults, primary: primary) : primary
        store.windowAttached = true
    }
}

struct WindowRoot: View {
    @StateObject private var holder: WindowStoreHolder
    init(primary: AppStore) { _holder = StateObject(wrappedValue: WindowStoreHolder(primary: primary)) }
    var body: some View { WindowContent(store: holder.store) }
}

private struct WindowContent: View {
    @ObservedObject var store: AppStore
    var body: some View {
        ContentView().environmentObject(store)
            .background(WindowTracker(store: store))
            .navigationTitle(store.windowTitle)
            .task { if store.isPrimary { await store.loadForLaunch(); await store.takeHandOver() } else { await store.load() } }
            .focusedSceneValue(\.harborSession, store.page == .terminal ? store.homeTerminal : store.activeSession)
            .focusedSceneObject(store)
    }
}

/// Connects a store to its NSWindow for activation, focus order and closing.
private struct WindowTracker: NSViewRepresentable {
    let store: AppStore
    func makeNSView(context: Context) -> Anchor { Anchor(store: store) }
    func updateNSView(_ view: Anchor, context: Context) {}
    final class Anchor: NSView {
        let store: AppStore
        private var observers: [NSObjectProtocol] = []
        private var visibility: NSKeyValueObservation?
        init(store: AppStore) { self.store = store; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll(); visibility = nil
            guard let window else { return }
            let store = self.store
            MainActor.assumeIsolated { store.attach(window: window) }
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak window] _ in
                MainActor.assumeIsolated {
                    if store.window == nil, let window { store.attach(window: window) }
                    if let window { AppStore.installCloseQuestion(for: window) }
                    AppStore.lastActive = store
                    // A planned window is on screen now: it takes its place among the tabs.
                    if store.planned { store.planned = false; store.joinTabs() }
                }
            })
            // A window that is closed and shown again keeps its views (Harbor started by a folder
            // dropped on its Dock icon: the first window is closed and brought back at once).
            visibility = window.observe(\.isVisible, options: [.new]) { [weak window] _, change in
                guard change.newValue == true else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { if store.window == nil, let window, window.isVisible { store.attach(window: window) } } }
            }
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { store.windowWillClose() }
            })
        }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}

/// Shown instead of a second editor when another window already has the folder.
struct WorkspaceElsewhereView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openWindow) private var openWindow
    let owner: AppStore
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "macwindow.on.rectangle").font(.system(size: 30)).foregroundStyle(Color.harborMuted)
            Text("“\(store.currentFiles.directoryTitle)” is open in another window").harborFont(18, weight: .semibold, design: .serif)
            Text("A folder has one editor and one set of terminals. Switch to its window, or open a different folder here.")
                .harborFont(12).foregroundStyle(Color.harborMuted).multilineTextAlignment(.center).frame(maxWidth: 420)
            HStack(spacing: 10) {
                Button("Show That Window") { owner.showClaimed(store.currentFiles.claimKey, openWindow) }.buttonStyle(.borderedProminent)
                Button("Open Folder…") { store.chooseDirectoryWorkspace() }
                Button("Start Page") { store.page = .recent }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.harborEditor)
        .overlay(alignment: .top) { WindowDragArea().frame(height: WorkbenchWindowMetrics.titlebarHeight) }
        .harborReveal(distance: 8)
        .accessibilityIdentifier("workspace-elsewhere")
    }
}
