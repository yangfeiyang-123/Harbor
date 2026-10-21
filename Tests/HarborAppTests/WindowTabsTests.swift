import XCTest
import AppKit
import HarborCore
@testable import HarborSSH

/// Several workbench windows, usually gathered as tabs: the room the tab bar needs, what each
/// window is called, and switching servers in one window without involving another.
final class WindowTabsTests: XCTestCase {
    @MainActor private func fixture() throws -> (AppStore, UserDefaults, URL) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-tabs-" + UUID().uuidString)
        let suite = "app.harbor.tabs." + UUID().uuidString, prefs = TestDefaults.suite(suite)!
        addTeardownBlock { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = AppStore(historyRoot: root.appendingPathComponent("data"), workspaceDefaults: prefs)
        try store.history.prepare(); store.loading = false
        return (store, prefs, root)
    }
    @MainActor private func window() -> NSWindow {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; return window
    }
    /// A folder of a server, shown in a window without connecting to anything.
    @MainActor @discardableResult private func show(_ path: String, on profile: ServerProfile, in store: AppStore) -> FileWorkspace {
        let files = store.directoryWorkspaceForPath(path, profile: profile)
        files.root = path; files.persist()
        store.selectDirectoryWorkspace(files)
        store.updateWorkspaceClaim()
        return files
    }

    func testTheTabBarGetsItsOwnRoomAtTheTopOfTheWindow() {
        // One window: Harbor's bar fills the title row and nothing else is in the way.
        let alone = WindowTop(covered: 32, titlebar: 32, tabs: false, fullScreen: false)
        XCTAssertEqual([alone.aboveBar, alone.barHeight, alone.belowBar, alone.contentTop, alone.covered], [0, 32, 0, 32, 0])
        XCTAssertEqual(WindowTop().contentTop, 32)
        // Tabs in a window: the tab bar comes under the title row, so the bar keeps the row and the page starts below both.
        let tabbed = WindowTop(covered: 68, titlebar: 32, tabs: true, fullScreen: false)
        XCTAssertEqual([tabbed.aboveBar, tabbed.barHeight, tabbed.belowBar, tabbed.contentTop, tabbed.covered], [0, 32, 36, 68, 68])
        // Tabs in full screen: no title row, the tab bar is at the very top, and the bar that
        // switches server and folder used to sit under it, out of sight.
        let full = WindowTop(covered: 36, titlebar: 32, tabs: true, fullScreen: true)
        XCTAssertEqual([full.aboveBar, full.barHeight, full.belowBar, full.contentTop, full.covered], [36, 32, 0, 68, 36])
        // Under the tab bar there are no window buttons to keep clear of.
        XCTAssertEqual([alone.barLeading, tabbed.barLeading, full.barLeading], [84, 84, 12])
        let fullAlone = WindowTop(covered: 0, titlebar: 32, tabs: false, fullScreen: true)
        XCTAssertEqual([fullAlone.aboveBar, fullAlone.barHeight, fullAlone.belowBar, fullAlone.contentTop], [0, 32, 0, 32])
        XCTAssertEqual(fullAlone.barLeading, 12, "full screen has no window buttons, with or without a tab bar")
        // A tab bar that is put away takes no room, in a window or in full screen; while the pointer
        // has brought it, it lies over the page and still takes none.
        var peeking = WindowTop(covered: 32, titlebar: 32, tabs: false, fullScreen: false)
        peeking.peek = 36
        XCTAssertEqual([peeking.aboveBar, peeking.barHeight, peeking.belowBar, peeking.contentTop, peeking.covered], [0, 32, 0, 32, 0])
        XCTAssertNotEqual(peeking, alone)
        let fullAway = WindowTop(covered: 0, titlebar: 32, tabs: true, fullScreen: true)
        XCTAssertEqual([fullAway.aboveBar, fullAway.contentTop, fullAway.barLeading], [0, 32, 12])
        // A system with a shorter title row: the bar takes that height while the tab bar is under it.
        let shorter = WindowTop(covered: 56, titlebar: 28, tabs: true, fullScreen: false)
        XCTAssertEqual([shorter.barHeight, shorter.belowBar, shorter.contentTop], [28, 28, 56])
        XCTAssertEqual(WindowTop(covered: 28, titlebar: 28, tabs: false, fullScreen: false).barHeight, 32)
    }

    @MainActor func testAWindowIsNamedAfterWhatItShowsUntilItIsRenamed() async throws {
        let (primary, prefs, root) = try fixture(); defer { primary.shutdown() }
        let alpha = ServerProfile(name: "Alpha", host: "alpha.invalid")
        primary.profiles = [alpha]
        XCTAssertEqual(primary.windowTitle, "Harbor", "the start page")
        show("/srv/project", on: alpha, in: primary)
        XCTAssertEqual(primary.windowTitle, "Alpha · project")
        primary.page = .proxy
        XCTAssertEqual(primary.windowTitle, "Reverse Proxy")
        primary.page = .workspace
        primary.renameWindow(to: "  训练  ")
        XCTAssertEqual(primary.windowName, "训练"); XCTAssertEqual(primary.windowTitle, "训练")
        primary.page = .recent
        XCTAssertEqual(primary.windowTitle, "训练", "a given name stays with the window, whatever it shows")
        // The first window's name is kept for the next launch; further windows are not restored, so theirs is not.
        XCTAssertEqual(prefs.string(forKey: "windowName"), "训练")
        let second = AppStore(workspaceDefaults: prefs, primary: primary); await second.load()
        XCTAssertNil(second.windowName); XCTAssertEqual(second.windowTitle, "Harbor")
        second.renameWindow(to: "Notes")
        XCTAssertEqual(second.windowTitle, "Notes"); XCTAssertEqual(prefs.string(forKey: "windowName"), "训练")
        // A blank name goes back to the server and folder.
        primary.page = .workspace
        primary.renameWindow(to: " \n")
        XCTAssertNil(primary.windowName); XCTAssertEqual(primary.windowTitle, "Alpha · project"); XCTAssertNil(prefs.string(forKey: "windowName"))
        primary.renameWindow(to: String(repeating: "x", count: 200))
        XCTAssertEqual(primary.windowName?.count, 80)
        second.shutdown()
        // The next launch starts with a window that has no name of its own: Harbor opens without a workspace.
        primary.renameWindow(to: "训练")
        let relaunched = AppStore(historyRoot: root.appendingPathComponent("again"), workspaceDefaults: prefs)
        XCTAssertNil(relaunched.windowName); XCTAssertNil(prefs.string(forKey: "windowName")); relaunched.shutdown()
    }

    /// A new window has opened no server. The switcher lists what this window has open (lit), then
    /// what the other windows have open, then the rest, and follows the other windows as they change.
    @MainActor func testTheSwitcherGroupsServersByTheWindowThatHasThemOpen() async throws {
        let (first, prefs, _) = try fixture(); defer { first.shutdown() }
        let alpha = ServerProfile(name: "Alpha", host: "alpha.invalid"), beta = ServerProfile(name: "Beta", host: "beta.invalid"), gamma = ServerProfile(name: "Gamma", host: "gamma.invalid")
        first.profiles = [alpha, beta, gamma]
        let second = AppStore(workspaceDefaults: prefs, primary: first); await second.load(); defer { second.shutdown() }
        let windows = [window(), window()]
        first.attach(window: windows[0]); second.attach(window: windows[1])
        first.renameWindow(to: "Training")
        show("/srv/x", on: alpha, in: first)
        XCTAssertTrue(first.hasOpen(alpha.id)); XCTAssertFalse(first.hasOpen(beta.id))
        XCTAssertFalse(second.hasOpen(alpha.id)); XCTAssertFalse(second.hasOpen(nil), "a new window has nothing open")

        func placements(_ store: AppStore) -> [String] {
            WorkspaceSwitcher.groups(for: store).map { group in
                switch group.placement {
                case .here: return group.name + " here"
                case .elsewhere(let name): return group.name + " in " + name
                case .closed: return group.name
                }
            }
        }
        XCTAssertEqual(placements(second), ["Alpha in Training", LocalMachine.name, "Beta", "Gamma"])
        XCTAssertEqual(placements(first), ["Alpha here", LocalMachine.name, "Beta", "Gamma"])
        // B opens Beta: its own group comes first, and A sees it at once.
        show("/srv/b", on: beta, in: second)
        XCTAssertEqual(placements(second), ["Beta here", "Alpha in Training", LocalMachine.name, "Gamma"])
        XCTAssertEqual(placements(first), ["Alpha here", "Beta in Beta · b", LocalMachine.name, "Gamma"])
        // The panel lists the folders of the window it is asked in, and nothing of another window's.
        let switcher = WorkspaceSwitcher.shared; defer { switcher.dismiss() }
        switcher.present(sticky: true, window: windows[1])
        XCTAssertEqual(switcher.entries.map { $0.server + "/" + $0.title }, ["Beta/b"]); XCTAssertNil(switcher.firstOther)
        XCTAssertEqual(switcher.windowTitle, second.windowTitle)
        // A window that goes to its start page still keeps its folders.
        first.page = .recent
        XCTAssertEqual(WorkspaceSwitcher.folders(for: first).mine.map(\.title), ["x"])
        XCTAssertEqual(WorkspaceSwitcher.folders(for: first).others.filter { $0.icon == "folder" }.map { $0.title + ($0.window.map { " in " + $0 } ?? "") }, ["b in Beta · b"])
        // One it lets go of is in no window, and the other window finds it by typing.
        XCTAssertTrue(AppStore.move(try XCTUnwrap(first.members.first), to: nil))
        XCTAssertEqual(WorkspaceSwitcher.folders(for: first).mine, [])
        switcher.refresh()
        XCTAssertEqual(switcher.entries.map(\.title), ["b"]); XCTAssertEqual(switcher.selectedID, switcher.entries.first?.id, "what was selected stays selected")
        // A server open in both windows is in this window's group, and so is one whose folder it keeps.
        show("/srv/x", on: alpha, in: first)
        second.selectWorkspace(alpha.id)
        XCTAssertEqual(placements(second).prefix(2), ["Alpha here", "Beta here"]); XCTAssertEqual(placements(first).first, "Alpha here")
    }

    /// The dot beside a server says whether Harbor holds a connection to it, the same in every window.
    @MainActor func testConnectionStatesComeFromTheControlSocketsAndReachEveryWindow() async throws {
        // Asked only where a socket file exists; either socket answering is a connection.
        var asked: [String] = []
        func alive(_ sockets: [String], files: Set<String>, masters: Set<String>) async -> Bool {
            await AppStore.connectionAlive(sockets: sockets, exists: { files.contains($0) }, check: { asked.append($0); return masters.contains($0) })
        }
        var result = await alive(["/s/shared", "/s/files"], files: [], masters: [])
        XCTAssertFalse(result); XCTAssertEqual(asked, [], "no socket file: nothing is run")
        result = await alive(["/s/shared", "/s/files"], files: ["/s/shared", "/s/files"], masters: ["/s/files"])
        XCTAssertTrue(result, "an editor's own connection counts"); XCTAssertEqual(asked, ["/s/shared", "/s/files"])
        asked = []
        result = await alive(["/s/shared", "/s/files"], files: ["/s/shared"], masters: [])
        XCTAssertFalse(result, "a socket file left behind is not a connection"); XCTAssertEqual(asked, ["/s/shared"])
        asked = []
        result = await alive(["/s/shared", "/s/files"], files: ["/s/shared", "/s/files"], masters: ["/s/shared"])
        XCTAssertTrue(result); XCTAssertEqual(asked, ["/s/shared"], "one answer is enough")

        let (first, prefs, _) = try fixture(); defer { first.shutdown() }
        let alpha = ServerProfile(name: "Alpha", host: "alpha.invalid")
        first.profiles = [alpha]
        let second = AppStore(workspaceDefaults: prefs, primary: first); await second.load(); defer { second.shutdown() }
        // A state one window holds from earlier is replaced by what the sockets say, in both windows,
        // whichever window asks.
        first.connectionStates[alpha.id] = "Connected"
        await second.refreshConnections()
        XCTAssertEqual(first.connectionStates[alpha.id], "Connection unavailable"); XCTAssertEqual(second.connectionStates[alpha.id], "Connection unavailable")
        // A server that is removed takes its state with it.
        first.profiles = []
        await first.refreshConnections()
        XCTAssertNil(first.connectionStates[alpha.id]); XCTAssertNil(second.connectionStates[alpha.id])
    }

    /// Window A shows a folder of a server. Switching window B to that server must change B, not bring A forward.
    @MainActor func testSwitchingServersInOneWindowStaysInThatWindow() async throws {
        let (first, prefs, _) = try fixture(); defer { first.shutdown() }
        let alpha = ServerProfile(name: "Alpha", host: "alpha.invalid"), beta = ServerProfile(name: "Beta", host: "beta.invalid"), gamma = ServerProfile(name: "Gamma", host: "gamma.invalid")
        first.profiles = [alpha, beta, gamma]
        let second = AppStore(workspaceDefaults: prefs, primary: first); await second.load(); defer { second.shutdown() }
        let windows = [window(), window()]
        first.attach(window: windows[0]); second.attach(window: windows[1])
        // A: two folders on Alpha, the second one on screen. B: a folder on Beta.
        show("/srv/y", on: alpha, in: first); show("/srv/x", on: alpha, in: first)
        show("/srv/b", on: beta, in: second)
        XCTAssertEqual(first.currentFiles.root, "/srv/x"); XCTAssertNil(first.workspaceOwner)

        // B goes to Alpha by server (the menu in the bar, or Option+Tab). The folder every window
        // chose last there is the one A is showing, so B comes up on the other one.
        second.selectWorkspace(alpha.id)
        XCTAssertEqual(second.selectedProfileID, alpha.id); XCTAssertEqual(second.currentFiles.root, "/srv/y")
        XCTAssertNil(second.workspaceOwner, "B shows a folder of its own")
        XCTAssertEqual(first.currentFiles.root, "/srv/x"); XCTAssertNil(first.workspaceOwner)

        // A window remembers its own folder on each server, whatever another window chose since.
        second.selectWorkspace(beta.id)
        XCTAssertEqual(second.currentFiles.root, "/srv/b")
        // A chooses /srv/x on Alpha once more (the last choice any window made there), then leaves for Gamma.
        first.selectDirectoryWorkspace(first.directoryWorkspaceForPath("/srv/x", profile: alpha))
        XCTAssertNotEqual(prefs.string(forKey: first.directoryCatalogKey(alpha.id) + ".selected"), "default")
        show("/srv/g", on: gamma, in: first)
        second.selectWorkspace(alpha.id)
        XCTAssertEqual(second.currentFiles.root, "/srv/y", "A last chose /srv/x on Alpha; B was on /srv/y")
        second.selectWorkspace(beta.id)

        // The switcher lists what B keeps (Beta, and Alpha for the folder it showed there), then what
        // A keeps (Gamma), then the rest; and each server comes up on B's folder.
        let groups = WorkspaceSwitcher.groups(for: second)
        XCTAssertEqual(groups.map(\.name), ["Beta", "Alpha", "Gamma", LocalMachine.name])
        XCTAssertEqual(groups.first { $0.name == "Alpha" }?.entries.map(\.path), ["/srv/y", "/srv/x"])
        XCTAssertEqual(WorkspaceSwitcher.groups(for: first).first?.name, "Gamma")

        // A returns to /srv/x. In B the folder is marked and is never what Alpha comes up on.
        first.selectWorkspace(alpha.id)
        XCTAssertEqual(first.currentFiles.root, "/srv/x")
        let marked = try XCTUnwrap(WorkspaceSwitcher.groups(for: second).first { $0.name == "Alpha" })
        XCTAssertEqual(marked.entries.map(\.path), ["/srv/y", "/srv/x"]); XCTAssertEqual(marked.entries.map(\.otherWindow), [false, true])

        // Choosing that folder in B anyway changes B: it says where the folder is, and A is not brought forward.
        let switcher = WorkspaceSwitcher.shared; defer { switcher.dismiss() }
        switcher.present(sticky: true, window: windows[1])
        XCTAssertFalse(switcher.entries.contains { $0.path == "/srv/x" }, "another window's folder is not one to step to")
        // Typed for, it is found under its own heading.
        for letter in ["s", "r", "v", "/", "x"] {
            let typed = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windows[1].windowNumber,
                                                       context: nil, characters: letter, charactersIgnoringModifiers: letter, isARepeat: false, keyCode: 0))
            XCTAssertNil(switcher.handle(typed))
        }
        XCTAssertEqual(switcher.entries.map(\.path), ["/srv/x"]); XCTAssertEqual(switcher.firstOther, switcher.entries.first?.id)
        switcher.choose(try XCTUnwrap(switcher.entries.first { $0.path == "/srv/x" }))
        XCTAssertFalse(switcher.visible)
        XCTAssertEqual(second.selectedProfileID, alpha.id); XCTAssertEqual(second.currentFiles.root, "/srv/x")
        XCTAssertTrue(second.workspaceOwner === first, "one folder has one editor: B shows the notice")
        XCTAssertFalse(windows[0].isVisible, "A's window was not ordered front"); XCTAssertNil(first.workspaceOwner)
        // Going to the server again from there lands on the folder B can show.
        second.selectWorkspace(alpha.id)
        XCTAssertEqual(second.currentFiles.root, "/srv/y"); XCTAssertNil(second.workspaceOwner)
        // Once A leaves the folder, it is B's to show.
        first.page = .recent
        second.selectDirectoryWorkspace(second.directoryWorkspaceForPath("/srv/x", profile: alpha))
        XCTAssertEqual(second.currentFiles.root, "/srv/x"); XCTAssertNil(second.workspaceOwner)
    }

    @MainActor func testAServerComesUpOnItsLastFolderInAWindowThatHasNotShownIt() async throws {
        let (primary, prefs, _) = try fixture(); defer { primary.shutdown() }
        let alpha = ServerProfile(name: "Alpha", host: "alpha.invalid")
        primary.profiles = [alpha]
        // Three folders known from before; nothing has been shown since Harbor started.
        for path in ["/srv/one", "/srv/two", "/srv/three"] {
            let files = primary.directoryWorkspaceForPath(path, profile: alpha); files.root = path; files.persist()
            // A slot only counts as taken once it has a folder, which is what makes the next one new.
            _ = primary.directoryWorkspaces(for: alpha)
        }
        let folders = primary.directoryWorkspaces(for: alpha).filter { !$0.root.isEmpty }
        XCTAssertEqual(folders.map(\.directoryTitle), ["one", "two", "three"])
        func first() -> String? { WorkspaceSwitcher.groups(for: primary).first { $0.name == "Alpha" }?.entries.first?.title }
        XCTAssertEqual(first(), "one", "with nothing remembered, the order they were added in")
        // The folder chosen there last is kept between launches, and is the one the server comes up on.
        prefs.set(folders[2].directoryID?.uuidString ?? "default", forKey: primary.directoryCatalogKey(alpha.id) + ".selected")
        XCTAssertEqual(first(), "three")
        // What this window itself showed last on the server comes before that.
        primary.ownDirectories[primary.directoryCatalogKey(alpha.id)] = folders[1].directoryID?.uuidString ?? "default"
        XCTAssertEqual(first(), "two")
    }
}
