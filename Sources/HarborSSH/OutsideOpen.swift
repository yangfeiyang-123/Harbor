import AppKit
import SwiftUI
import HarborCore

/// The folder a window is about to show, named on screen before anything about it has been read.
struct WorkspaceArrivalNote: Equatable {
    var server: String
    var folder: String
    /// The window has shown nothing else yet: the note is simply there, with nothing to fade over.
    var fresh: Bool
    init?(urls: [URL], fresh: Bool) {
        guard let first = urls.first else { return nil }
        let directory = (try? first.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let path = directory ? first.path : first.deletingLastPathComponent().path
        server = LocalMachine.name; folder = path == "/" ? "/" : (path as NSString).lastPathComponent; self.fresh = fresh
    }
    init(path: String, server: String, fresh: Bool) {
        self.server = server; folder = path == "/" ? "/" : (path as NSString).lastPathComponent; self.fresh = fresh
    }
}

/// Folders and files given to Harbor from outside it: dropped on its Dock icon or on a window,
/// or opened with it in Finder. A window on its start page takes them; a window that is busy
/// with a workspace is left alone and a new window opens, as in other editors.
@MainActor extension AppStore {
    /// Received before the saved data was read (Harbor was started by the drop itself).
    static var handedOver: [URL] = []
    /// What the next new window opens once it has loaded.
    static var pendingWindowURLs: [URL]?

    private static var routing = false

    static func openFromOutside(_ urls: [URL]) {
        let urls = urls.filter(\.isFileURL)
        guard !urls.isEmpty else { return }
        handedOver += urls
        // Harbor may have been started by this very drop. Its first window and its saved data are
        // then a moment away, and that window names the folder from its first frame.
        let starting = AppDelegate.sinceLaunch < 3
        if starting { all.first(where: \.isPrimary)?.arriving = WorkspaceArrivalNote(urls: handedOver, fresh: true) }
        guard !routing else { return }
        routing = true
        Task { @MainActor in
            defer { routing = false }
            let deadline = Date().addingTimeInterval(starting ? 2.5 : 0)
            while true {
                let primary = all.first(where: \.isPrimary)
                if let primary, !primary.loading, primary.window != nil || Date() >= deadline { break }
                if primary == nil, Date() >= deadline.addingTimeInterval(10) { handedOver = []; return }
                try? await Task.sleep(for: .milliseconds(30))
            }
            let urls = handedOver; handedOver = []
            if let primary = all.first(where: \.isPrimary), !urls.isEmpty { route(urls, primary: primary) }
        }
    }
    /// Where they go: the window that already shows the folder, else a window on its start page
    /// (the one used last first), else a new window.
    static func route(_ urls: [URL], primary: AppStore, among stores: [AppStore]? = nil) {
        let all = stores ?? self.all
        let shown = all.filter { $0.window != nil }
        // A folder that a window already shows: that window comes forward.
        if urls.count == 1, (try? urls[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
           let key = RecentWorkspace.normalize(urls[0].standardizedFileURL.path).map({ "local\n" + $0 }),
           let owner = shown.first(where: { $0.workspaceClaim?.key == key }) {
            for store in all where store.page != .workspace { store.arriving = nil }
            owner.bringForward(); return
        }
        if let target = ([lastActive].compactMap { $0 } + shown).first(where: { $0.window != nil && $0.page == .recent }) {
            target.bringForward()
            Task { await target.openOutside(urls) }
        } else if !primary.windowAttached {
            // No window at all: the next one is the first window again, and opens on the folder.
            primary.arriving = WorkspaceArrivalNote(urls: urls, fresh: true)
            Task { await primary.openOutside(urls) }
            AppDelegate.openMainWindow?(); AppDelegate.activate()
        } else {
            pendingWindowURLs = urls
            AppDelegate.openMainWindow?(); AppDelegate.activate()
        }
    }
    func bringForward() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil); AppDelegate.activate()
    }
    /// Opens local folders (and files, whose folder becomes the workspace) in this window, naming
    /// the folder on screen at once.
    func openOutside(_ urls: [URL]) async {
        if arriving == nil { arriving = WorkspaceArrivalNote(urls: urls, fresh: false) }
        do { await openDroppedWorkspace(try WorkspaceDropPlan(items: WorkspaceDropPlan.localItems(urls: urls))) }
        catch { errorMessage = error.localizedDescription }
        await retireArrival()
    }
    /// The page that opens the workspace takes the note over as it appears; after that, or with
    /// nothing opened, the note has nothing left to announce.
    func retireArrival() async {
        if page == .workspace { try? await Task.sleep(for: .milliseconds(120)) }
        arriving = nil
    }
}

/// The note itself: the page a workspace opens with, before there is a workspace.
struct WorkspaceArrival: View {
    @EnvironmentObject private var store: AppStore
    let note: WorkspaceArrivalNote
    let top: WindowTop
    @State private var shown = false
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                WorkspaceTheme.background
                WorkspaceTitle(window: store.windowName, server: note.server, folder: note.folder, progress: 0)
                    .frame(maxWidth: geometry.size.width - 220)
                    .position(x: geometry.size.width / 2, y: WorkspaceOpening.titleCenter(height: geometry.size.height, top: top))
            }
        }
        .opacity(note.fresh || shown ? 1 : 0)
        .onAppear { withAnimation(HarborMotion.animation(HarborMotion.standard)) { shown = true } }
        .accessibilityIdentifier("workspace-arrival")
    }
}
