import XCTest
import AppKit
import HarborCore
@testable import HarborSSH

/// Which folders are kept in which window, and the Option+Tab list that follows from it.
final class WindowFoldersTests: XCTestCase {
    @MainActor private func fixture() throws -> (AppStore, UserDefaults) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-folders-" + UUID().uuidString)
        let suite = "app.harbor.folders." + UUID().uuidString, prefs = TestDefaults.suite(suite)!
        addTeardownBlock { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = AppStore(historyRoot: root.appendingPathComponent("data"), workspaceDefaults: prefs)
        try store.history.prepare(); store.loading = false
        return (store, prefs)
    }
    @MainActor private func window() -> NSWindow {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; return window
    }
    @MainActor @discardableResult private func show(_ path: String, on profile: ServerProfile, in store: AppStore) -> String {
        let files = store.directoryWorkspaceForPath(path, profile: profile)
        files.root = path; files.persist()
        store.selectDirectoryWorkspace(files)
        store.updateWorkspaceClaim()
        return WorkspaceSwitcher.identity(profileID: profile.id, root: path, fallback: files.key)
    }

    @MainActor func testAFolderIsKeptInTheWindowItIsShownInUntilItIsMoved() async throws {
        let (primary, prefs) = try fixture(); defer { primary.shutdown() }
        let alpha = ServerProfile(name: "Alpha", host: "alpha.invalid")
        primary.profiles = [alpha]
        let first = window(); primary.attach(window: first); defer { first.close() }
        let second = AppStore(workspaceDefaults: prefs, primary: primary); defer { second.shutdown() }
        second.adoptCatalog(from: primary); second.loading = false
        let other = window(); second.attach(window: other); defer { other.close() }
        second.renameWindow(to: "Training")

        // Showing a folder puts it in that window; the first window's folders are saved.
        let one = show("/srv/one", on: alpha, in: primary), two = show("/srv/two", on: alpha, in: second)
        XCTAssertEqual(primary.members, [one]); XCTAssertEqual(second.members, [two])
        XCTAssertEqual(prefs.stringArray(forKey: "windowFolders") ?? [], [one])
        XCTAssertEqual(primary.knownFolders().map(\.title), ["one", "two"])
        XCTAssertTrue(AppStore.holder(of: try XCTUnwrap(AppStore.folder(two))) === second)

        // The list of each window: its own folders are here, the other window's are named.
        func group(_ store: AppStore) -> WorkspaceSwitcher.Group? { WorkspaceSwitcher.groups(for: store).first { $0.name == "Alpha" } }
        XCTAssertEqual(group(primary)?.placement, .here)
        XCTAssertEqual(group(primary)?.entries.map { $0.title + ($0.member ? " (kept)" : "") + ($0.window.map { " in " + $0 } ?? "") }, ["one (kept)", "two in Training"])
        XCTAssertEqual(group(second)?.entries.map { $0.title + ($0.member ? " (kept)" : "") + ($0.window.map { " in " + $0 } ?? "") }.first, "two (kept)")

        // Moved to the other window: it leaves this one, which was showing it and goes to its start page.
        XCTAssertTrue(AppStore.move(one, to: second))
        XCTAssertEqual(primary.members, []); XCTAssertEqual(second.members, [two, one])
        XCTAssertEqual(primary.page, .recent); XCTAssertEqual(second.page, .workspace, "the window it joins stays on what it shows")
        XCTAssertEqual(group(primary)?.placement, .elsewhere("Training"))
        XCTAssertEqual(group(second)?.entries.filter(\.member).map(\.title).sorted(), ["one", "two"])
        XCTAssertEqual(prefs.stringArray(forKey: "windowFolders") ?? ["?"], [])
        XCTAssertTrue(AppStore.move(one, to: second), "already there")

        // Shown in the first window again, it is that window's again and no longer the other's.
        show("/srv/one", on: alpha, in: primary)
        XCTAssertEqual(primary.members, [one]); XCTAssertEqual(second.members, [two])
        // With a second folder of its own, the window falls back on it when the one on screen leaves.
        let three = show("/srv/three", on: alpha, in: primary)
        XCTAssertEqual(primary.members, [one, three])
        XCTAssertTrue(AppStore.move(three, to: nil), "out of every window")
        XCTAssertEqual(primary.members, [one]); XCTAssertEqual(primary.page, .workspace)
        XCTAssertEqual(primary.currentFiles.root, "/srv/one")
        XCTAssertNil(AppStore.holder(of: try XCTUnwrap(AppStore.folder(three))))
        XCTAssertEqual(group(primary)?.entries.first { $0.title == "three" }?.member, false)

        // A folder that is opening by mistake is stopped: the window goes back to the one before
        // and no longer keeps it; the folder itself is still known.
        let wrong = show("/srv/wrong", on: alpha, in: primary)
        XCTAssertEqual(primary.members, [one, wrong]); XCTAssertEqual(primary.currentFiles.root, "/srv/wrong")
        primary.stopOpening(primary.currentFiles)
        XCTAssertEqual(primary.members, [one]); XCTAssertEqual(primary.page, .workspace); XCTAssertEqual(primary.currentFiles.root, "/srv/one")
        XCTAssertTrue(primary.knownFolders().contains { $0.id == wrong })
        // The library lists every server, each with every folder opened on it, the most recently shown first.
        let servers = primary.library()
        XCTAssertEqual(servers.map(\.name), [LocalMachine.name, "Alpha"]); XCTAssertEqual(servers.last?.folders.map(\.title), ["one", "wrong", "three", "two"])

        // A folder another window is showing now is not taken from it by asking for it here.
        show("/srv/two", on: alpha, in: primary)
        XCTAssertNotNil(primary.workspaceOwner); XCTAssertEqual(second.members, [two]); XCTAssertFalse(primary.members.contains(two))
    }

    @MainActor func testSwitchingComesUpOnWhatTheWindowAlreadyHasOpen() async throws {
        let (primary, prefs) = try fixture(); defer { primary.shutdown() }
        let alpha = ServerProfile(name: "Alpha", host: "alpha.invalid"), beta = ServerProfile(name: "Beta", host: "beta.invalid")
        let gamma = ServerProfile(name: "Gamma", host: "gamma.invalid")
        primary.profiles = [alpha, beta, gamma]
        let host = window(); primary.attach(window: host); defer { host.close() }
        // Folders known from before; none of them has been shown since Harbor started.
        func known(_ path: String, on profile: ServerProfile) -> FileWorkspace {
            let files = primary.directoryWorkspaceForPath(path, profile: profile); files.root = path; files.persist()
            _ = primary.directoryWorkspaces(for: profile); return files
        }
        func identity(_ files: FileWorkspace) -> String { WorkspaceSwitcher.identity(profileID: files.profile?.id, root: files.root, fallback: files.key) }
        let one = known("/srv/one", on: alpha), two = known("/srv/two", on: alpha), three = known("/srv/three", on: alpha)
        let key = primary.directoryCatalogKey(alpha.id)
        func listed() -> [String] { WorkspaceSwitcher.groups(for: primary).first { $0.name == "Alpha" }?.entries.map(\.title) ?? [] }
        func arrival() -> String { primary.files(for: alpha, directoryID: primary.arrivalDirectoryID(for: alpha.id)).directoryTitle }

        // With nothing open in the window, the server comes up on the folder chosen there last.
        prefs.set(three.directoryID?.uuidString ?? "default", forKey: key + ".selected")
        XCTAssertEqual(listed().first, "three"); XCTAssertEqual(arrival(), "three")
        // A folder this window keeps comes before one that would have to be opened anew.
        primary.join(identity(two))
        XCTAssertEqual(listed(), ["two", "three", "one"]); XCTAssertEqual(arrival(), "two")
        // One with an editor running here comes before that, whatever was shown last.
        primary.codeWorkbench.session(for: one).starting = true
        XCTAssertEqual(listed(), ["one", "two", "three"]); XCTAssertEqual(arrival(), "one")
        primary.ownDirectories[key] = two.directoryID?.uuidString ?? "default"
        XCTAssertEqual(listed(), ["one", "two", "three"]); XCTAssertEqual(arrival(), "one")
        // Among the running ones, the folder the window showed there last.
        primary.codeWorkbench.session(for: two).starting = true
        XCTAssertEqual(listed(), ["two", "one", "three"]); XCTAssertEqual(arrival(), "two")
        primary.ownDirectories[key] = three.directoryID?.uuidString ?? "default"
        XCTAssertEqual(Array(listed().suffix(1)), ["three"], "an unopened folder is last even when it was the last one shown")
        XCTAssertNotEqual(arrival(), "three")

        // Choosing the server lands on an open folder, and the list starts on it.
        primary.ownDirectories[key] = two.directoryID?.uuidString ?? "default"
        primary.selectWorkspace(alpha.id); primary.updateWorkspaceClaim()
        XCTAssertEqual(primary.currentFiles.root, "/srv/two")
        XCTAssertEqual(listed(), ["two", "one", "three"])
        // Option+Tab lists the window's own folders, the one on screen first; the unopened one is not among them.
        XCTAssertEqual(WorkspaceSwitcher.folders(for: primary).mine.map(\.title), ["two", "one"])
        XCTAssertEqual(WorkspaceSwitcher.folders(for: primary).others.filter { $0.icon == "folder" }.map(\.title), ["three"])
        // Servers: the one on screen, then those with an editor running here, then those the window only keeps a folder of.
        primary.join(identity(known("/data/b", on: beta)))
        primary.codeWorkbench.session(for: known("/data/g", on: gamma)).starting = true
        XCTAssertEqual(Array(WorkspaceSwitcher.groups(for: primary).map(\.name).prefix(3)), ["Alpha", "Gamma", "Beta"])
    }

    @MainActor func testAPlannedWindowOpensWithItsFoldersWhenTheOrganizerCloses() async throws {
        let (primary, prefs) = try fixture(); defer { primary.shutdown(); AppStore.pendingPlans = [] }
        let alpha = ServerProfile(name: "Alpha", host: "alpha.invalid")
        primary.profiles = [alpha]
        let first = window(); primary.attach(window: first); defer { first.close() }
        let one = show("/srv/one", on: alpha, in: primary), two = show("/srv/two", on: alpha, in: primary)

        // A folder is added to the library without being opened or put in a window.
        let three = try XCTUnwrap(primary.addToLibrary("/srv/three/", profile: alpha))
        XCTAssertEqual(three.path, "/srv/three"); XCTAssertEqual(primary.members, [one, two]); XCTAssertEqual(primary.currentFiles.root, "/srv/two")
        XCTAssertEqual(primary.addToLibrary("/srv/three", profile: alpha)?.id, three.id, "a folder is in the library once")
        XCTAssertEqual(primary.library().map(\.name), [LocalMachine.name, "Alpha"], "every server, with or without folders")
        XCTAssertEqual(primary.library().last?.folders.map(\.title), ["two", "one", "three"], "the most recently shown first")
        XCTAssertFalse(primary.codeWorkbench.runs(profileID: alpha.id), "adding starts no editor")

        // Windows are planned in the organizer: columns that are given folders.
        primary.organizerVisible = true
        let training = primary.addDraft(), empty = primary.addDraft()
        primary.windowDrafts[0].name = " Training "
        primary.place(three.id, inDraft: training); primary.place(one, inDraft: empty); primary.place(one, inDraft: training)
        XCTAssertEqual(primary.windowDrafts.map(\.folders), [[three.id, one], []], "a folder is planned for one window")
        XCTAssertEqual(primary.draft(of: three)?.title, " Training "); XCTAssertEqual(primary.windowDrafts[1].title, "New Window")
        XCTAssertEqual(primary.members, [one, two], "nothing moves while it is planned")
        primary.place(two, inDraft: empty); primary.unplace(two)
        XCTAssertEqual(primary.windowDrafts[1].folders, [])

        // The columns are as wide as they are side by side (and centered as one group) until the room is used up.
        XCTAssertEqual(WindowOrganizer.width(columns: 2, room: 852), 524); XCTAssertEqual(WindowOrganizer.width(columns: 3, room: 852), 792)
        XCTAssertEqual(WindowOrganizer.width(columns: 4, room: 852), 852, "more than fit: they scroll beside the library")
        // Closing the organizer opens the planned windows that have folders; an empty one is dropped.
        primary.organizerVisible = false
        XCTAssertEqual(primary.windowDrafts, []); XCTAssertEqual(AppStore.pendingPlans, [WindowPlan(name: "Training", folders: [three.id, one])])
        XCTAssertEqual(primary.members, [two], "the folder leaves the window it was in"); XCTAssertEqual(primary.workbenchUIRequest, "newWindow")
        let second = AppStore(workspaceDefaults: prefs, primary: primary); defer { second.shutdown() }
        XCTAssertEqual(AppStore.pendingPlans, []); XCTAssertEqual(second.windowName, "Training")
        XCTAssertEqual(second.arriving?.folder, "three", "the window says what it opens from its first frame")
        let other = window(); second.attach(window: other); defer { other.close() }
        await second.load(); second.updateWorkspaceClaim()
        XCTAssertEqual(second.members, [three.id, one]); XCTAssertEqual(second.page, .workspace); XCTAssertEqual(second.currentFiles.root, "/srv/three")
        XCTAssertNil(second.arriving); XCTAssertNil(second.workbenchUIRequest, "no further window is waiting")
        // Each window steps through its own folders.
        XCTAssertEqual(WorkspaceSwitcher.folders(for: second).mine.map(\.title), ["three", "one"])
        XCTAssertEqual(WorkspaceSwitcher.folders(for: primary).mine.map(\.title), ["two"])
        // Closing the organizer with nothing planned opens nothing.
        primary.workbenchUIRequest = nil; primary.organizerVisible = true; primary.addDraft(); primary.organizerVisible = false
        XCTAssertEqual(AppStore.pendingPlans, []); XCTAssertNil(primary.workbenchUIRequest); XCTAssertEqual(primary.windowDrafts, [])

        // A window that is closed is remembered with its folders, and comes back as a planned window.
        XCTAssertEqual(primary.recentWindows(), [])
        second.windowWillClose()
        XCTAssertEqual(primary.recentWindows(), [RecentWindow(name: "Training", named: true, folders: [three.id, one])])
        XCTAssertNil(AppStore.holder(of: three), "its folders are in no window now")
        primary.organizerVisible = true
        primary.reopen(try XCTUnwrap(primary.recentWindows().first))
        XCTAssertEqual(primary.windowDrafts.map(\.name), ["Training"]); XCTAssertEqual(primary.windowDrafts.first?.folders, [three.id, one])
        primary.organizerVisible = false
        XCTAssertEqual(AppStore.pendingPlans, [WindowPlan(name: "Training", folders: [three.id, one])])
        XCTAssertEqual(primary.recentWindows(), [], "open again, it is not a closed window any more")
        // A folder that left the library is not brought back with the window.
        AppStore.pendingPlans = []
        let third = AppStore(workspaceDefaults: prefs, primary: primary); third.adoptCatalog(from: primary); third.loading = false
        let last = window(); third.attach(window: last); defer { last.close() }
        third.join(three); third.join(two)
        XCTAssertEqual(primary.members, [], "the folder left the first window for this one")
        third.windowWillClose()
        XCTAssertEqual(primary.recentWindows().map(\.name), ["three, two"]); XCTAssertEqual(primary.recentWindows().first?.named, false)
        primary.closeDirectoryWorkspace(try XCTUnwrap(primary.files(of: three)), ask: false, checkEditor: false)
        XCTAssertEqual(primary.recentWindows().first?.folders, [two])
        primary.forget(try XCTUnwrap(primary.recentWindows().first))
        XCTAssertEqual(primary.recentWindows(), [])
    }

    @MainActor func testAWindowThatIsNoWorkspaceYetBecomesTheFirstPlannedWindow() async throws {
        let (primary, prefs) = try fixture(); defer { primary.shutdown(); AppStore.pendingPlans = [] }
        let alpha = ServerProfile(name: "Alpha", host: "alpha.invalid")
        primary.profiles = [alpha]
        let first = window(); primary.attach(window: first); defer { first.close() }
        let one = try XCTUnwrap(primary.addToLibrary("/srv/one", profile: alpha)), two = try XCTUnwrap(primary.addToLibrary("/srv/two", profile: alpha))
        let three = try XCTUnwrap(primary.addToLibrary("/srv/three", profile: alpha))
        // Harbor as it starts: a window, and no workspace.
        XCTAssertTrue(primary.isBlank); XCTAssertEqual(primary.page, .recent)
        primary.organizerVisible = true
        let bench = primary.addDraft(with: one.id); primary.addDraft(with: two.id)
        primary.windowDrafts[0].name = "Bench"; primary.place(three.id, inDraft: bench)
        XCTAssertTrue(primary.isBlank, "planning changes nothing yet"); XCTAssertEqual(primary.members, [])
        primary.organizerVisible = false
        // The first planned window is this one; the second is a further window.
        XCTAssertEqual(primary.windowName, "Bench"); XCTAssertEqual(primary.members, [one.id, three.id]); XCTAssertFalse(primary.isBlank)
        XCTAssertEqual(primary.page, .workspace); XCTAssertEqual(primary.currentFiles.root, "/srv/one")
        XCTAssertEqual(AppStore.pendingPlans, [WindowPlan(name: nil, folders: [two.id])]); XCTAssertEqual(primary.workbenchUIRequest, "newWindow")
        let second = AppStore(workspaceDefaults: prefs, primary: primary); defer { second.shutdown() }
        XCTAssertFalse(second.isBlank, "a window that is opening for a plan is spoken for")
        let other = window(); second.attach(window: other); defer { other.close() }
        await second.load()
        XCTAssertEqual(second.members, [two.id]); XCTAssertNil(second.windowName)

        // A window that was given a name is a workspace even before it keeps a folder.
        primary.workbenchUIRequest = nil
        let third = AppStore(workspaceDefaults: prefs, primary: primary); third.adoptCatalog(from: primary); third.loading = false; defer { third.shutdown() }
        XCTAssertTrue(third.isBlank); third.renameWindow(to: "Notes"); XCTAssertFalse(third.isBlank)

        // From the start page a closed window opens at once: beside a window that is a workspace.
        second.windowWillClose()
        let closed = try XCTUnwrap(primary.closedWindows().first)
        XCTAssertEqual(closed.folders, [two.id])
        primary.reopenNow(closed)
        XCTAssertEqual(AppStore.pendingPlans, [WindowPlan(name: nil, folders: [two.id])]); XCTAssertEqual(primary.workbenchUIRequest, "newWindow")
        XCTAssertEqual(primary.members, [one.id, three.id]); XCTAssertEqual(primary.closedWindows(), []); XCTAssertEqual(primary.windowDrafts, [])
    }

    @MainActor func testHarborStartsWithNoWorkspaceAndTheLastOneIsAClosedWindow() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-fresh-" + UUID().uuidString)
        let suite = "app.harbor.fresh." + UUID().uuidString, prefs = TestDefaults.suite(suite)!
        addTeardownBlock { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let alpha = ServerProfile(name: "Alpha", host: "alpha.invalid")
        // What the first window had when Harbor was last open: a name and two folders, one of them on this Mac.
        let remote = alpha.id.uuidString + "\n/srv/train", local = "local\n" + root.appendingPathComponent("notes").path
        prefs.set("RLptBench", forKey: "windowName"); prefs.set([remote, local, "broken"], forKey: "windowFolders")

        let store = AppStore(historyRoot: root.appendingPathComponent("data"), workspaceDefaults: prefs); defer { store.shutdown() }
        try store.history.prepare(); store.loading = false
        XCTAssertNil(store.windowName); XCTAssertEqual(store.members, [], "Harbor opens with a window that keeps nothing")
        XCTAssertNil(prefs.string(forKey: "windowName")); XCTAssertNil(prefs.stringArray(forKey: "windowFolders"))
        XCTAssertEqual(store.windowTitle, "Harbor")
        // Once the servers and folders are read, that window is among the closed ones, under its name.
        store.profiles = [alpha]
        for (path, profile) in [("/srv/train", Optional(alpha)), (root.appendingPathComponent("notes").path, nil)] {
            let files = store.directoryWorkspaceForPath(path, profile: profile); files.root = path; files.persist()
        }
        let recent = try XCTUnwrap(store.recentWindows().first)
        XCTAssertEqual(store.recentWindows().count, 1); XCTAssertEqual(recent.name, "RLptBench"); XCTAssertTrue(recent.named)
        XCTAssertEqual(recent.folders.compactMap { AppStore.folder($0)?.title }, ["train", "notes"])
        // Opening Harbor made no workspace: the organizer has no column for this window.
        XCTAssertTrue(store.isBlank)
        let host = window(); store.attach(window: host); defer { host.close() }
        store.organizerVisible = true
        // Brought back, the closed window is a column like any planned window, and no longer on offer
        // among the closed ones. Nothing has happened to this window yet.
        let column = store.reopen(recent)
        XCTAssertEqual(store.windowDrafts.map(\.name), ["RLptBench"])
        XCTAssertEqual(store.windowDrafts.first?.folders.compactMap { AppStore.folder($0)?.title }, ["train", "notes"])
        XCTAssertEqual(store.closedWindows(), []); XCTAssertEqual(store.recentWindows().count, 1, "it is saved until it is open")
        XCTAssertEqual(store.reopen(recent), column, "asked for twice, it is the column it has"); XCTAssertEqual(store.windowDrafts.count, 1)
        XCTAssertNil(store.windowName); XCTAssertEqual(store.members, []); XCTAssertEqual(store.page, .recent)
        // Its column taken away, it is a closed window again.
        store.discardDraft(column)
        XCTAssertEqual(store.closedWindows().map(\.name), ["RLptBench"])
        store.reopen(recent)
        // When the organizer closes, this window is that window (not a second one beside an empty
        // first), on its first folder.
        store.organizerVisible = false
        XCTAssertEqual(store.windowName, "RLptBench"); XCTAssertEqual(store.keptFolders.map(\.title), ["train", "notes"]); XCTAssertEqual(store.windowDrafts, [])
        XCTAssertEqual(store.recentWindows(), []); XCTAssertFalse(store.isBlank)
        XCTAssertEqual(store.page, .workspace); XCTAssertEqual(store.currentFiles.root, "/srv/train")
        XCTAssertEqual(AppStore.pendingPlans, []); XCTAssertNil(store.workbenchUIRequest, "no further window opens")
        // The next start retires it again, once: the same window is not listed twice.
        let again = AppStore(historyRoot: root.appendingPathComponent("data2"), workspaceDefaults: prefs); defer { again.shutdown() }
        again.profiles = [alpha]
        XCTAssertEqual(again.members, []); XCTAssertEqual(again.recentWindows().map(\.name), ["RLptBench"])
        // A window without a name is listed by its folders; one that kept nothing leaves no trace.
        prefs.set([remote], forKey: "windowFolders")
        let third = AppStore(historyRoot: root.appendingPathComponent("data3"), workspaceDefaults: prefs); defer { third.shutdown() }
        third.profiles = [alpha]
        XCTAssertEqual(third.recentWindows().map(\.name), ["train", "RLptBench"]); XCTAssertEqual(third.recentWindows().first?.named, false)
        prefs.set("Empty", forKey: "windowName")
        let fourth = AppStore(historyRoot: root.appendingPathComponent("data4"), workspaceDefaults: prefs); defer { fourth.shutdown() }
        fourth.profiles = [alpha]
        XCTAssertNil(fourth.windowName); XCTAssertEqual(fourth.recentWindows().map(\.name), ["train", "RLptBench"])
        // From the start page a closed window opens at once: as this window, while it is no workspace.
        let page = window(); fourth.attach(window: page); defer { page.close() }
        fourth.reopenNow(try XCTUnwrap(fourth.closedWindows().last))
        XCTAssertEqual(fourth.windowName, "RLptBench"); XCTAssertEqual(fourth.keptFolders.map(\.title), ["train", "notes"]); XCTAssertEqual(fourth.page, .workspace)
        XCTAssertEqual(fourth.closedWindows().map(\.name), ["train"]); XCTAssertEqual(AppStore.pendingPlans, [])
    }

    @MainActor func testWindowsAreTabsOfOneWindowUnlessKeptSeparate() async throws {
        let (primary, prefs) = try fixture(); defer { primary.shutdown() }
        let first = window(); primary.attach(window: first); defer { first.close() }
        let second = AppStore(workspaceDefaults: prefs, primary: primary); second.loading = false; defer { second.shutdown() }
        let third = AppStore(workspaceDefaults: prefs, primary: primary); third.loading = false; defer { third.shutdown() }
        let other = window(), last = window(); second.attach(window: other); third.attach(window: last); defer { other.close(); last.close() }
        func tabs(_ window: NSWindow) -> Int { window.tabbedWindows?.count ?? 1 }
        XCTAssertEqual([first, other, last].map(tabs), [1, 1, 1], "three windows of their own")
        // Closing the organizer gathers them as tabs of the window it was closed in.
        primary.organizerVisible = true; primary.organizerVisible = false
        XCTAssertEqual([first, other, last].map(tabs), [3, 3, 3]); XCTAssertTrue(first.tabbedWindows?.first === first)
        // One of them is kept as a window of its own, and is left alone from then on.
        second.setSeparate(true)
        XCTAssertEqual([first, other, last].map(tabs), [2, 1, 2])
        primary.organizerVisible = true; primary.organizerVisible = false
        XCTAssertEqual([first, other, last].map(tabs), [2, 1, 2])
        second.setSeparate(false)
        XCTAssertEqual([first, other, last].map(tabs), [3, 3, 3])
        // A window planned in the organizer is a tab beside the window it was planned in.
        AppStore.tabHost = primary
        let fourth = AppStore(workspaceDefaults: prefs, primary: primary); fourth.loading = false; defer { fourth.shutdown() }
        fourth.planned = true
        let planned = window(); fourth.attach(window: planned); defer { planned.close() }
        XCTAssertEqual(tabs(first), 4); XCTAssertTrue(first.tabbedWindows?.last === planned, "after the last tab")
    }

    @MainActor func testAKeyTheSwitcherTakesStopsThere() throws {
        let (primary, _) = try fixture(); defer { primary.shutdown() }
        let host = window(); primary.attach(window: host); defer { host.close() }
        let alpha = ServerProfile(name: "Alpha", host: "alpha.invalid"); primary.profiles = [alpha]
        let known = try XCTUnwrap(primary.addToLibrary("/srv/known", profile: alpha))
        let switcher = WorkspaceSwitcher.shared; defer { switcher.dismiss() }
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags, _ text: String) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.windowNumber,
                                           context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        }
        let plain = try key(0, [], "a")
        XCTAssertTrue(WorkspaceSwitcher.monitored(plain, by: switcher) === plain, "typing is left alone while the list is closed")
        XCTAssertTrue(WorkspaceSwitcher.monitored(plain, by: nil) === plain)
        // Option+Tab opens the list and must not go on to the terminal as a tab.
        XCTAssertNil(WorkspaceSwitcher.monitored(try key(48, .option, "\t"), by: switcher))
        XCTAssertTrue(switcher.visible)
        // The window keeps no folder yet: the library is listed, and letting go of Option opens nothing.
        XCTAssertEqual(switcher.entries.map(\.id), [known.id]); XCTAssertEqual(switcher.firstOther, known.id)
        _ = WorkspaceSwitcher.monitored(try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                                     windowNumber: host.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)), by: switcher)
        XCTAssertTrue(switcher.visible); XCTAssertEqual(primary.page, .recent); XCTAssertEqual(primary.members, [])
        // Option+Q is not Harbor's any more.
        let q = try key(12, .option, "œ")
        switcher.dismiss(); XCTAssertTrue(WorkspaceSwitcher.monitored(q, by: switcher) === q); XCTAssertFalse(switcher.visible)
        XCTAssertNil(WorkspaceSwitcher.monitored(try key(48, .option, "\t"), by: switcher))
        XCTAssertNil(WorkspaceSwitcher.monitored(try key(0, [], "a"), by: switcher), "what is typed into the open list filters it and goes nowhere else")
        XCTAssertEqual(switcher.query, "a")
    }
}
