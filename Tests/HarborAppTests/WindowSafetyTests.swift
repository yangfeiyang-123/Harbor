import XCTest
import AppKit
import WebKit
import HarborCore
@testable import HarborSSH

/// What a window may do to the page it is on, to the other windows, and to what runs in it:
/// the cases an audit of 0.33.3 found going wrong.
final class WindowSafetyTests: XCTestCase {
    @MainActor private func fixture() throws -> (AppStore, UserDefaults, URL) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-safety-" + UUID().uuidString)
        let suite = "app.harbor.safety." + UUID().uuidString, prefs = TestDefaults.suite(suite)!
        addTeardownBlock { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = AppStore(historyRoot: root.appendingPathComponent("data"), workspaceDefaults: prefs)
        try store.history.prepare(); store.loading = false
        return (store, prefs, root)
    }
    @MainActor private func further(_ primary: AppStore, _ prefs: UserDefaults) -> AppStore {
        let store = AppStore(workspaceDefaults: prefs, primary: primary)
        store.adoptCatalog(from: primary); store.loading = false
        return store
    }
    @MainActor private func window() -> NSWindow {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; return window
    }
    /// A terminal that counts as running, without a process behind it.
    @MainActor private func running(_ profile: ServerProfile?, in store: AppStore) throws -> TerminalSession {
        let session = try TerminalSession(profile: profile, title: "T", detached: true, history: store.history)
        store.sessions.append(session); store.registerTerminal(session)
        return session
    }

    @MainActor func testARecentFolderOpensItsEditorAndNoTerminalOfHarborsOwn() throws {
        let (store, _, root) = try fixture(); defer { store.shutdown() }
        let folder = root.appendingPathComponent("project"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store.openRecent(RecentWorkspace(serverID: nil, serverName: LocalMachine.name, directory: folder.path))
        XCTAssertEqual(store.page, .workspace); XCTAssertEqual(store.currentFiles.root, folder.path)
        XCTAssertTrue(store.sessions.isEmpty, "nothing runs that no page shows")
        XCTAssertEqual(store.activeCount, 0, "so quitting has nothing to ask about")
        XCTAssertEqual(store.recents.first?.directory, folder.path)
    }

    @MainActor func testKeysForTerminalsStartNothingWhereThereIsNoWorkspace() throws {
        let (store, _, _) = try fixture(); defer { store.shutdown() }
        store.profiles = [ServerProfile(name: "Alpha", host: "alpha.invalid")]
        store.selectWorkspace(store.profiles[0].id, show: false)
        XCTAssertEqual(store.page, .recent, "selecting a server without showing it leaves the page")
        for page in [AppPage.recent, .proxy, .display] {
            store.page = page
            // ⌘D and ⌘H from the menu, with no terminal in reach.
            store.splitTerminal(.columns, session: nil); store.splitTerminal(.rows, session: nil)
            XCTAssertEqual(store.page, page)
            XCTAssertNil(store.codeWorkbench.existing(for: store.currentFiles), "no editor is started in the background on \(page)")
            XCTAssertTrue(store.sessions.isEmpty)
        }
        // ⌃⇧` on a side page asks for nothing; on the start page it is the start page's New Terminal.
        store.page = .proxy; store.openIndependentTerminal()
        XCTAssertEqual(store.page, .proxy); XCTAssertNil(store.codeWorkbench.existing(for: store.currentFiles)); XCTAssertTrue(store.sessions.isEmpty)
        store.page = .recent; store.openIndependentTerminal()
        XCTAssertEqual(store.page, .terminal); XCTAssertNil(store.homeTerminal?.profile)
        XCTAssertNil(store.codeWorkbench.existing(for: store.currentFiles))
        if let shell = store.homeTerminal { store.close(shell, ask: false) }
    }

    @MainActor func testReconnectingAPlainTerminalStaysOnItsPage() async throws {
        let (store, _, _) = try fixture(); defer { store.shutdown() }
        store.openHomeTerminal(nil)
        let shell = try XCTUnwrap(store.homeTerminal)
        shell.stop()
        store.reconnect(shell)
        XCTAssertEqual(store.page, .terminal, "it used to take the window to a workspace and start that workspace's editor")
        let again = try XCTUnwrap(store.homeTerminal)
        XCTAssertFalse(again === shell); XCTAssertEqual(store.sessions.count, 1); XCTAssertFalse(again.ended)
        XCTAssertNil(store.codeWorkbench.existing(for: store.currentFiles))
        store.close(again, ask: false)
    }

    @MainActor func testAPaneThatLostItsConnectionKeepsThePageWhenAnotherIsClosed() async throws {
        let (store, _, _) = try fixture(); defer { store.shutdown() }
        store.openHomeTerminal(nil)
        let first = try XCTUnwrap(store.homeTerminal), scope = store.currentTerminalScope
        store.openIndependentTerminal(in: scope)
        let second = try XCTUnwrap(store.homeTerminal); XCTAssertFalse(second === first)
        // The first pane's shell has ended and says so; the second is closed.
        first.stop()
        store.close(second, ask: false)
        XCTAssertEqual(store.page, .terminal, "the page is not taken away under the pane that is left")
        XCTAssertTrue(store.homeTerminal === first); XCTAssertEqual(store.sessions.count, 1)
        XCTAssertTrue(store.isHomeTerminal(first), "and that pane is not left running where nothing shows it")
        store.close(first, ask: false)
        XCTAssertEqual(store.page, .recent); XCTAssertTrue(store.sessions.isEmpty)
    }

    @MainActor func testAServersPlainTerminalIsSavedAndReturnedToOnItsPage() async throws {
        let (store, prefs, root) = try fixture()
        let alpha = ServerProfile(name: "Alpha", host: "alpha.invalid")
        store.profiles = [alpha]
        store.openHomeTerminal(alpha)
        let shell = try XCTUnwrap(store.homeTerminal)
        // Before its connection is attempted. Its shell is taken to be on the server.
        shell.stop(); shell.remotePTYReconnect = true
        let scope = try XCTUnwrap(shell.windowID), remote = try XCTUnwrap(shell.remotePTYID)
        XCTAssertTrue(shell.resumable)
        XCTAssertTrue(store.checkpointTerminals(synchronously: true))
        let saved = try XCTUnwrap(try store.recoveryStore.load().0)
        XCTAssertEqual(saved.terminals.map(\.home), [alpha.id.uuidString]); XCTAssertEqual(saved.terminals.first?.remotePTYID, remote)
        XCTAssertEqual(saved.layouts.count, 1)
        store.shutdown()

        // Harbor starts again: the terminal is there, not as a window of its own, and New Terminal for the server returns to it.
        let next = AppStore(historyRoot: root.appendingPathComponent("data"), workspaceDefaults: prefs); defer { next.shutdown() }
        next.profiles = [alpha]; next.loading = false
        await next.restoreTerminals()
        XCTAssertEqual(next.sessions.count, 1); XCTAssertEqual(next.homeTerminalScopes[alpha.id.uuidString], scope)
        XCTAssertTrue(Set(next.sessions.compactMap(\.windowID)).subtracting(next.homeTerminalScopes.values).isEmpty, "no terminal window is opened for it")
        XCTAssertEqual(next.page, .recent)
        next.openHomeTerminal(alpha)
        XCTAssertEqual(next.page, .terminal)
        let back = try XCTUnwrap(next.homeTerminal)
        back.stop()
        XCTAssertEqual(back.remotePTYID, remote, "the same shell is asked for"); XCTAssertTrue(back.remotePTYReconnect)
        XCTAssertEqual(next.sessions.count, 1)

        // The server says that shell is gone (its host's own exit status): the next request is for a new one.
        let lost = try TerminalSession(profile: alpha, title: "Lost", detached: true, history: next.history, remotePTYID: remote)
        lost.remotePTYReconnect = true
        // Ended by signal 3 is not that status: its shell is still there to return to.
        let quit = try TerminalSession(profile: alpha, title: "Quit", detached: true, history: next.history, remotePTYID: remote)
        quit.remotePTYReconnect = true
        quit.processTerminated(source: quit.terminal, exitCode: TerminalSession.goneStatus)
        XCTAssertFalse(quit.remotePTYGone); XCTAssertTrue(quit.resumable)
        lost.processTerminated(source: lost.terminal, exitCode: TerminalSession.goneStatus << 8)
        XCTAssertTrue(lost.remotePTYGone); XCTAssertFalse(lost.resumable)
        back.remotePTYGone = true; back.remotePTYReconnect = false
        next.openHomeTerminal(alpha)
        let fresh = try XCTUnwrap(next.homeTerminal)
        fresh.stop()
        XCTAssertNotEqual(fresh.remotePTYID, remote); XCTAssertFalse(fresh.remotePTYReconnect); XCTAssertEqual(next.sessions.count, 1)
    }

    @MainActor func testServersAreEveryWindowsWhenOneIsEditedOrRemoved() async throws {
        let (primary, prefs, _) = try fixture(); defer { primary.shutdown() }
        let alpha = ServerProfile(name: "Alpha", host: "alpha.invalid"), beta = ServerProfile(name: "Beta", host: "beta.invalid")
        primary.profiles = [alpha, beta]
        let second = further(primary, prefs); defer { second.shutdown() }
        let first = window(), other = window(); defer { first.close(); other.close() }
        primary.attach(window: first); second.attach(window: other)

        // Edited in the first window: a folder the second window has on that server goes on, with the new settings.
        let files = second.files(for: beta)
        var edited = beta; edited.port = 2222; edited.name = "Beta 2"
        primary.upsert(edited)
        XCTAssertEqual(primary.page, .recent, "editing a server does not send the window anywhere")
        XCTAssertTrue(second.files(for: edited) === files); XCTAssertEqual(files.profile?.port, 2222); XCTAssertEqual(files.profile?.name, "Beta 2")
        XCTAssertEqual(second.profiles.first { $0.id == beta.id }?.port, 2222)

        // Removed in the first window while the second has a terminal running there and the server
        // has a forwarding rule: asked first, with both counted. Cancelled, nothing changes.
        let terminal = try running(edited, in: second)
        let rule = ForwardRule(serverID: beta.id), kept = ForwardRule(serverID: alpha.id)
        primary.rules = [rule, kept]; second.adoptCatalog(from: primary)
        var asked = [String]()
        primary.confirmRemoval = { profile, terminals, forwards in asked.append("\(profile.name) \(terminals) \(forwards)"); return false }
        primary.remove(edited)
        XCTAssertEqual(asked, ["Beta 2 1 1"]); XCTAssertNil(primary.errorMessage)
        XCTAssertEqual(primary.profiles.count, 2); XCTAssertEqual(primary.rules.count, 2)
        XCTAssertTrue(second.sessions.contains { $0 === terminal })

        // Confirmed: the terminal and the rule go with it. The second window, which was on one of
        // its folders, goes to its start page and keeps no trace of the server; the first window
        // stays where it is.
        files.root = "/srv/beta"; files.persist(); second.selectDirectoryWorkspace(files)
        XCTAssertEqual(second.page, .workspace); XCTAssertEqual(second.selectedProfileID, beta.id)
        primary.confirmRemoval = { _, _, _ in true }
        primary.remove(edited)
        XCTAssertNil(primary.errorMessage)
        XCTAssertFalse(second.sessions.contains { $0 === terminal })
        XCTAssertEqual(primary.rules.map(\.id), [kept.id]); XCTAssertEqual(second.rules.map(\.id), [kept.id])
        XCTAssertEqual(primary.profiles.map(\.id), [alpha.id]); XCTAssertEqual(second.profiles.map(\.id), [alpha.id])
        XCTAssertEqual(primary.page, .recent, "removing a server from the start page stays on the start page")
        XCTAssertEqual(second.page, .recent); XCTAssertEqual(second.selectedProfileID, alpha.id)
        XCTAssertFalse(second.fileWorkspaces.values.contains { $0.profile?.id == beta.id })
    }

    @MainActor func testAFurtherWindowAsksBeforeItClosesWithSomethingRunning() throws {
        let (primary, prefs, _) = try fixture(); defer { primary.shutdown() }
        let second = further(primary, prefs)
        var asked = 0, answer = false
        second.confirmWindowClose = { _ in asked += 1; return answer }
        primary.confirmWindowClose = { _ in asked += 100; return false }
        XCTAssertTrue(second.mayCloseWindow()); XCTAssertEqual(asked, 0, "with nothing in it, it just closes")
        let terminal = try running(nil, in: second)
        XCTAssertFalse(second.mayCloseWindow()); XCTAssertEqual(asked, 1)
        answer = true
        XCTAssertTrue(second.mayCloseWindow()); XCTAssertEqual(asked, 2)
        terminal.stop()
        XCTAssertTrue(second.mayCloseWindow()); XCTAssertEqual(asked, 2, "a terminal that has ended is nothing to ask about")
        // One on a server that has only lost its connection still runs there, and would end with the window.
        let lost = try running(ServerProfile(name: "Alpha", host: "alpha.invalid"), in: second)
        lost.remotePTYID = UUID(); lost.remotePTYReconnect = true; lost.ended = true
        answer = false
        XCTAssertFalse(second.mayCloseWindow()); XCTAssertEqual(asked, 3)
        lost.remotePTYGone = true; lost.remotePTYReconnect = false
        XCTAssertTrue(second.mayCloseWindow()); XCTAssertEqual(asked, 3, "a shell the server no longer has is nothing to ask about")
        second.sessions.removeAll { $0 === lost }
        // The first window keeps what it has when it is closed.
        _ = try running(nil, in: primary)
        XCTAssertTrue(primary.mayCloseWindow()); XCTAssertEqual(asked, 3)
        // A window that is not Harbor's own workbench window is never held back.
        let plain = window(); defer { plain.close() }
        XCTAssertTrue(AppStore.mayClose(plain))
        second.windowWillClose()
        XCTAssertTrue(second.shuttingDown)
    }

    @MainActor func testAFolderThatAnotherWindowLeavesBecomesThisWindows() async throws {
        let (primary, prefs, _) = try fixture(); defer { primary.shutdown() }
        let alpha = ServerProfile(name: "Alpha", host: "alpha.invalid")
        primary.profiles = [alpha]
        let second = further(primary, prefs); defer { second.shutdown() }
        let first = window(), other = window(); defer { first.close(); other.close() }
        primary.attach(window: first); second.attach(window: other)
        func show(_ path: String, in store: AppStore) -> String {
            let files = store.directoryWorkspaceForPath(path, profile: alpha)
            files.root = path; files.persist(); store.selectDirectoryWorkspace(files); store.updateWorkspaceClaim()
            return files.claimKey
        }
        let one = show("/srv/one", in: primary)
        XCTAssertEqual(show("/srv/one", in: second), one)
        XCTAssertTrue(second.workspaceOwner === primary); XCTAssertEqual(primary.members, [one]); XCTAssertEqual(second.members, [])
        // The first window goes on to another folder. The second, which shows the folder now, takes it.
        let two = show("/srv/two", in: primary)
        for _ in 0..<50 where second.members.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNil(second.workspaceOwner)
        XCTAssertEqual(second.members, [one], "it is the second window's folder, not shown here and kept there")
        XCTAssertEqual(primary.members, [two])
    }

    @MainActor func testAFolderStaysItsWindowsOnASidePageAndAfterItsChangesAreSaved() async throws {
        let (primary, prefs, _) = try fixture(); defer { primary.shutdown() }
        let alpha = ServerProfile(name: "Alpha", host: "alpha.invalid")
        primary.profiles = [alpha]
        let second = further(primary, prefs); defer { second.shutdown() }
        let first = window(), other = window(); defer { first.close(); other.close() }
        primary.attach(window: first); second.attach(window: other)
        func show(_ path: String, in store: AppStore) -> FileWorkspace {
            let files = store.directoryWorkspaceForPath(path, profile: alpha)
            files.root = path; files.persist(); store.selectDirectoryWorkspace(files); store.updateWorkspaceClaim()
            return files
        }
        let one = show("/srv/one", in: primary).claimKey
        _ = show("/srv/one", in: second)
        XCTAssertTrue(second.workspaceOwner === primary)
        // Reverse Proxy is looked at and left again: the folder is the first window's all the while.
        primary.page = .proxy
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(second.workspaceOwner === primary); XCTAssertEqual(primary.members, [one]); XCTAssertEqual(second.members, [])
        primary.page = .workspace
        XCTAssertNil(primary.workspaceOwner)
        // On its start page it has left the folder, and the window that shows it takes it.
        primary.page = .recent
        for _ in 0..<50 where second.members.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNil(second.workspaceOwner); XCTAssertEqual(second.members, [one]); XCTAssertEqual(primary.members, [])

        // Unsaved changes: the second window has them in the folder and looks at another one. The
        // first window, which comes to the folder meanwhile, is told that it is open elsewhere.
        let files = second.currentFiles, editor = second.codeWorkbench.session(for: files)
        editor.apply(status: ["dirty": ["/srv/one/notes.txt"]])
        _ = show("/srv/two", in: second)
        _ = show("/srv/one", in: primary)
        XCTAssertTrue(primary.workspaceOwner === second)
        second.selectDirectoryWorkspace(files); second.updateWorkspaceClaim()
        XCTAssertNil(second.workspaceOwner)
        // Saved: it stays where it is. It used to go over to the window that only showed the notice.
        editor.apply(status: ["dirty": [String]()])
        XCTAssertNil(second.workspaceOwner); XCTAssertTrue(primary.workspaceOwner === second)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(second.members.filter { $0 == one }, [one]); XCTAssertFalse(primary.members.contains(one))
    }

    @MainActor func testEditorsOffTheScreenStayLoadedUpToTheNumberKept() throws {
        let (store, _, _) = try fixture(); defer { store.shutdown() }
        let alpha = ServerProfile(name: "Alpha", host: "alpha.invalid")
        store.profiles = [alpha]
        let editors = (0..<4).map { index -> CodeWorkbenchSession in
            let files = store.directoryWorkspaceForPath("/srv/\(index)", profile: alpha)
            // The first folder of a server is its window's current one, whose root is set here.
            files.root = "/srv/\(index)"; files.persist()
            let editor = store.codeWorkbench.session(for: files)
            editor.web = WKWebView(); editor.foreground = true
            return editor
        }
        XCTAssertEqual(Set(editors.map(ObjectIdentifier.init)).count, 4)
        // Left one after the other, as the folders of a window are worked on in turn: within the
        // number kept, each stays loaded, to be gone back to at once.
        for editor in editors.prefix(3) { editor.foreground = false; Thread.sleep(forTimeInterval: 0.01) }
        CodeWorkbenchSession.releaseHidden(keeping: 3, among: editors)
        XCTAssertTrue(editors.allSatisfy { $0.web != nil })
        XCTAssertNotNil(editors[0].hiddenSince); XCTAssertNil(editors[3].hiddenSince)
        // Beyond it, the one that left the screen longest ago goes; unsaved changes keep one in its place.
        editors[0].apply(status: ["dirty": ["/srv/0/notes.txt"]])
        editors[3].foreground = false
        CodeWorkbenchSession.releaseHidden(keeping: 3, among: editors)
        XCTAssertNotNil(editors[0].web, "unsaved changes keep it"); XCTAssertNil(editors[1].web); XCTAssertNotNil(editors[2].web); XCTAssertNotNil(editors[3].web)
        // One on the screen is never counted, and never let go of.
        editors[2].foreground = true
        CodeWorkbenchSession.releaseHidden(keeping: 0, among: editors)
        XCTAssertNotNil(editors[0].web); XCTAssertNotNil(editors[2].web, "on the screen"); XCTAssertNil(editors[3].web)
        XCTAssertNil(editors[2].hiddenSince)
    }

    @MainActor func testAFolderRowsMenuIsOneListForTheDotsAndTheRightClick() {
        var chosen: [String] = []
        let entries: [FolderRowEntry] = [.item(title: "Show", destructive: false) { chosen.append("show") }, .divider,
                                         .item(title: "Remove…", destructive: true) { chosen.append("remove") }]
        XCTAssertEqual(entries.map(\.title), ["Show", nil, "Remove…"])
        let menu = FolderRowMenu.menu(entries)
        XCTAssertEqual(menu.items.map { $0.isSeparatorItem ? "-" : $0.title }, ["Show", "-", "Remove…"])
        // An entry chosen runs what the list says for it.
        for index in [2, 0] { let item = menu.items[index]; _ = (item.target as? NSObject)?.perform(item.action, with: item) }
        XCTAssertEqual(chosen, ["remove", "show"])
    }

    @MainActor func testAFolderRowsDragIsAppKitsAndTakesOnlyAPress() {
        let view = FolderDragView(frame: NSRect(x: 0, y: 0, width: 200, height: 36))
        view.id = "server/folder"; view.title = "folder"; view.controls = 26
        // With no press under way (the tests send no events), the view is not there for hit testing:
        // hover, the wheel and a right click reach the row.
        XCTAssertNil(view.hitTest(NSPoint(x: 20, y: 18)))
        // The id travels as the plain text a String drop destination reads.
        XCTAssertEqual(FolderDragView.type, .string)
        let image = FolderDragView.image(for: "folder")
        XCTAssertGreaterThan(image.size.width, 20); XCTAssertGreaterThan(image.size.height, 10)
    }

    @MainActor func testKeysThatComeBeforeTheTerminalsGoByTheLetterToo() throws {
        let (store, _, _) = try fixture(); defer { store.shutdown() }
        func key(_ code: UInt16, _ typed: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: typed, charactersIgnoringModifiers: typed, isARepeat: false, keyCode: code)!
        }
        // Dvorak: W is on the key in the place of a US comma, D on the one in the place of a US H.
        XCTAssertFalse(store.handleSettingsKey(key(43, "w", .command)), "⌘W is the pane's, not Settings")
        XCTAssertFalse(store.settingsVisible)
        XCTAssertTrue(store.handleSettingsKey(key(13, ",", .command))); XCTAssertTrue(store.settingsVisible)
        store.settingsVisible = false
        store.page = .terminal
        XCTAssertFalse(store.handleWindowKey(key(4, "D", [.command, .shift])), "⇧⌘D is a split, not the start page")
        XCTAssertEqual(store.page, .terminal)
        XCTAssertTrue(store.handleWindowKey(key(38, "H", [.command, .shift]))); XCTAssertEqual(store.page, .recent)
        // A layout without Latin letters goes by the key's place.
        store.page = .terminal
        XCTAssertTrue(store.handleWindowKey(key(4, "Р", [.command, .shift]))); XCTAssertEqual(store.page, .recent)
        XCTAssertTrue(store.handleSettingsKey(key(43, "б", .command)))
    }

    @MainActor func testTheLetterOfAShortcutIsTheOneOnTheKey() throws {
        func command(_ code: UInt16, _ typed: String, _ flags: NSEvent.ModifierFlags) -> TerminalKeyboardCommand? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: typed, charactersIgnoringModifiers: typed, isARepeat: false, keyCode: code)
                .flatMap(TerminalKeyboardCommand.matching)
        }
        // AZERTY: the key at the place of a US W types Z, and W is where a US Z is.
        XCTAssertNil(command(13, "z", .command), "⌘Z must not close the pane")
        XCTAssertEqual(command(6, "w", .command), .closePane)
        // Dvorak: D is at the place of a US H, T at the place of a US K.
        XCTAssertEqual(command(4, "d", .command), .split(.columns)); XCTAssertEqual(command(4, "D", [.command, .shift]), .split(.rows))
        XCTAssertEqual(command(40, "t", .command), .newTab); XCTAssertNil(command(2, "e", .command))
        // A layout without Latin letters goes by the key's place.
        XCTAssertEqual(command(13, "ц", .command), .closePane); XCTAssertEqual(command(2, "в", .command), .split(.columns))
    }

    func testAModeSwitchKeyThatAnotherCommandHasIsNotAccepted() {
        func shortcut(_ key: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags) -> WorkspaceShortcut { WorkspaceShortcut(key: key, keyCode: code, modifiers: flags.rawValue) }
        XCTAssertNotNil(shortcut("o", 31, .command).validationError, "⌘O is Open File")
        XCTAssertNotNil(shortcut("n", 45, [.command, .shift]).validationError, "⇧⌘N is New Window")
        XCTAssertNotNil(shortcut("d", 2, [.command, .shift]).validationError, "⇧⌘D splits the plain terminal")
        XCTAssertNotNil(shortcut("x", 7, [.command, .shift]).validationError)
        XCTAssertNil(shortcut("z", 6, .option).validationError); XCTAssertNil(shortcut("y", 16, [.command, .option]).validationError)
    }

    @MainActor func testARequestToARunningConnectionLeavesTheAliasesOwnForwardsAlone() {
        let alias = ServerProfile(name: "Alpha", host: "alpha", imported: true)
        let forward = CodeWorkbenchSession.control(alias, socket: "/tmp/s", "forward", "127.0.0.1:1:127.0.0.1:2")
        XCTAssertEqual(forward, ["-F", "none", "-S", "/tmp/s", "-O", "forward", "-o", "ExitOnForwardFailure=yes", "-L", "127.0.0.1:1:127.0.0.1:2", "--", "alpha"])
        XCTAssertEqual(CodeWorkbenchSession.control(alias, socket: "/tmp/s", "cancel", "127.0.0.1:1:127.0.0.1:2"), ["-F", "none", "-S", "/tmp/s", "-O", "cancel", "-L", "127.0.0.1:1:127.0.0.1:2", "--", "alpha"])
        XCTAssertEqual(CodeWorkbenchSession.control(alias, socket: "/tmp/s", "check"), ["-F", "none", "-S", "/tmp/s", "-O", "check", "--", "alpha"])
    }

    func testAPlusInAFoldersPathStaysAPlus() throws {
        var components = URLComponents(string: "http://127.0.0.1:1234")!
        components.queryItems = [URLQueryItem(name: "folder", value: "/home/me/c++ & more")]
        XCTAssertTrue(components.percentEncodedQuery?.contains("+") == true, "URLComponents leaves it, and the page reads it as a space")
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        let read = URLComponents(url: try XCTUnwrap(components.url), resolvingAgainstBaseURL: false)?.queryItems?.first?.value
        XCTAssertEqual(read, "/home/me/c++ & more"); XCTAssertFalse(try XCTUnwrap(components.url).absoluteString.contains("+"))
    }

    func testOutputToATerminalThatIsNotBeingReadIsWaitedFor() throws {
        // A pipe that takes nothing more for a moment, as the terminal does during a burst.
        var ends = [Int32](repeating: 0, count: 2)
        XCTAssertEqual(pipe(&ends), 0)
        defer { close(ends[0]); close(ends[1]) }
        _ = fcntl(ends[1], F_SETFL, fcntl(ends[1], F_GETFL) | O_NONBLOCK)
        let data = Data(repeating: 0x78, count: 600_000)
        let reader = ends[0]
        let done = expectation(description: "read")
        DispatchQueue.global().async {
            usleep(300_000)
            var total = 0, buffer = [UInt8](repeating: 0, count: 65_536)
            while total < data.count { let count = read(reader, &buffer, buffer.count); if count <= 0 { break }; total += count }
            XCTAssertEqual(total, data.count); done.fulfill()
        }
        XCTAssertNoThrow(try TerminalTransport.writeOutput(data, to: ends[1]))
        wait(for: [done], timeout: 10)
    }
}
