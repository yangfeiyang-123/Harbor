import XCTest
import AppKit
import HarborCore
@testable import HarborSSH

final class WorkbenchNavigationTests: XCTestCase {
    @MainActor private func fixture() throws -> (AppStore, UserDefaults) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-navigation-" + UUID().uuidString)
        let suite = "app.harbor.navigation." + UUID().uuidString
        let prefs = try XCTUnwrap(TestDefaults.suite(suite))
        let store = AppStore(historyRoot: root, workspaceDefaults: prefs)
        try store.history.prepare(); store.loading = false; store.selectWorkspace(nil)
        addTeardownBlock { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        return (store, prefs)
    }

    @MainActor func testNavigationStateExposesLabelsAndIDsWithoutConnectionSecretsOrPaths() throws {
        let (store, _) = try fixture(); defer { store.shutdown() }
        let profile = ServerProfile(name: "Research GPU", host: "private-host.example.invalid", user: "private-account", port: 2222,
                                    identityFile: "/private/keys/secret-key", group: "private-catalog-group")
        store.profiles = [profile]; store.connectionStates[profile.id] = "Connected"
        let first = store.files(for: profile, directoryID: nil)
        first.root = "/private/research/First"
        let second = store.directoryWorkspaceForPath("/private/research/Second", profile: profile)
        second.enabled = true; store.selectDirectoryWorkspace(second)
        let state = store.workbenchNavigationState()
        let servers = try XCTUnwrap(state["servers"] as? [[String: Any]])
        XCTAssertEqual(servers.count, 2)
        let remote = try XCTUnwrap(servers.first { $0["id"] as? String == profile.id.uuidString })
        XCTAssertEqual(remote["name"] as? String, "Research GPU")
        XCTAssertEqual(remote["connected"] as? Bool, true)
        XCTAssertEqual(remote["active"] as? Bool, true)
        let local = try XCTUnwrap(servers.first { $0["id"] as? String == "local" })
        XCTAssertEqual(local["active"] as? Bool, false)
        let directories = try XCTUnwrap(remote["directories"] as? [[String: Any]])
        XCTAssertEqual(directories.compactMap { $0["name"] as? String }, ["First", "Second"])
        XCTAssertEqual(directories.compactMap { $0["active"] as? Bool }, [false, true])
        XCTAssertEqual(directories.first?["id"] as? String, "default")
        let json = String(decoding: try JSONSerialization.data(withJSONObject: state), as: UTF8.self)
        for forbidden in [profile.host, profile.user, profile.identityFile, profile.group, first.root, second.root] {
            XCTAssertFalse(json.contains(forbidden), "The extension needs display labels, not native connection data: \(forbidden)")
        }
        XCTAssertEqual(Set(remote.keys), Set(["id", "name", "connected", "active", "count", "directories"]))
        for directory in directories { XCTAssertEqual(Set(directory.keys), Set(["id", "name", "active"])) }
    }

    @MainActor func testServerAndDirectoryActionsResolveOnlyKnownCatalogIDs() throws {
        let (store, _) = try fixture(); defer { store.shutdown() }
        let a = ServerProfile(name: "A", host: "a.invalid"), b = ServerProfile(name: "B", host: "b.invalid")
        store.profiles = [a, b]
        store.files(for: a, directoryID: nil).root = "/a/first"
        store.files(for: b, directoryID: nil).root = "/b/first"
        let aSecond = store.directoryWorkspaceForPath("/a/second", profile: a)
        let bSecond = store.directoryWorkspaceForPath("/b/second", profile: b)
        store.handleWorkbenchAction(["action": "server", "id": a.id.uuidString])
        XCTAssertEqual(store.selectedProfileID, a.id); XCTAssertTrue(store.currentFiles.enabled)
        let count = store.fileWorkspaces.count
        for invalid in [
            ["action": "server", "id": UUID().uuidString],
            ["action": "server", "id": "ssh arbitrary.invalid"],
            ["action": "directory", "id": a.id.uuidString, "directory": bSecond.directoryID!.uuidString],
            ["action": "directory", "id": a.id.uuidString, "directory": "../../outside"],
            ["action": "directory", "id": a.id.uuidString]
        ] {
            store.handleWorkbenchAction(invalid)
            XCTAssertEqual(store.selectedProfileID, a.id); XCTAssertNil(store.selectedDirectoryID)
            XCTAssertEqual(store.fileWorkspaces.count, count, "Rejected navigation cannot create workspaces")
        }
        store.handleWorkbenchAction(["action": "directory", "id": a.id.uuidString, "directory": aSecond.directoryID!.uuidString])
        XCTAssertTrue(store.currentFiles === aSecond); XCTAssertTrue(aSecond.enabled)
        store.handleWorkbenchAction(["action": "directory", "id": a.id.uuidString, "directory": "default"])
        XCTAssertEqual(store.selectedProfileID, a.id); XCTAssertNil(store.selectedDirectoryID)
        store.handleWorkbenchAction(["action": "server", "id": "local"])
        XCTAssertNil(store.selectedProfileID); XCTAssertTrue(store.currentFiles.enabled)
    }

    @MainActor func testPageAndSettingsActionsPreserveWorkspaceAndDoNotExecuteUnknownActions() throws {
        let (store, prefs) = try fixture(); defer { store.shutdown() }
        let files = store.currentFiles; files.root = "/test/project"; files.enabled = true
        for (action, page) in [("proxy", AppPage.proxy), ("display", .display), ("recent", .recent)] {
            store.handleWorkbenchAction(["action": action])
            XCTAssertEqual(store.page, page); XCTAssertTrue(store.currentFiles === files)
        }
        store.page = .workspace
        store.handleWorkbenchAction(["action": "settings"])
        XCTAssertEqual(store.workbenchUIRequest, "settings"); XCTAssertEqual(store.page, .workspace)
        store.workbenchUIRequest = nil
        store.handleWorkbenchAction(["action": "addServer"])
        XCTAssertEqual(store.workbenchUIRequest, "addServer"); XCTAssertTrue(store.profiles.isEmpty)
        store.workbenchUIRequest = nil
        store.handleWorkbenchAction(["action": "shell", "command": "arbitrary"])
        XCTAssertNil(store.workbenchUIRequest); XCTAssertEqual(store.page, .workspace); XCTAssertTrue(store.sessions.isEmpty)
        store.handleWorkbenchAction(["action": "terminalMode"])
        XCTAssertFalse(files.enabled); XCTAssertFalse(prefs.bool(forKey: files.key + ".enabled"))
        XCTAssertTrue(store.currentFiles === files); XCTAssertEqual(files.root, "/test/project")
    }
    @MainActor func testASidePageLeadsBackToWhereItWasOpenedFrom() throws {
        let (store, _) = try fixture(); defer { store.shutdown() }
        store.page = .recent
        store.handleWorkbenchAction(["action": "proxy"])
        XCTAssertEqual(store.page, .proxy); XCTAssertEqual(store.pageReturn, .recent, "opened from the start page")
        store.page = .workspace
        store.handleWorkbenchAction(["action": "proxy"])
        XCTAssertEqual(store.pageReturn, .workspace, "opened from the editor")
        store.handleWorkbenchAction(["action": "display"])
        XCTAssertEqual(store.page, .display); XCTAssertEqual(store.pageReturn, .workspace, "from one side page to the other, back is still the editor")
        store.page = store.pageReturn
        XCTAssertEqual(store.page, .workspace)
        store.page = .terminal; store.page = .display
        XCTAssertEqual(store.pageReturn, .terminal)
        // The organizer is asked for by name too, from the Command Palette.
        store.page = .workspace
        store.handleWorkbenchAction(["action": "organizer"])
        XCTAssertTrue(store.organizerVisible); XCTAssertEqual(store.page, .workspace)
        store.organizerVisible = false
    }
    /// Environments, caches and installed packages are not watched for changes: a project with
    /// a few of them has more folders than the watches a server allows an account.
    @MainActor func testFoldersThatToolsFillAreLeftOutOfFileWatching() throws {
        let left = CodeWorkbenchSession.watcherExclude
        for name in [".venv", ".venvs", ".cache", "node_modules", "site-packages", "__pycache__", ".conda", "wandb"] {
            XCTAssertEqual(left["**/" + name + "/**"], true, name)
        }
        for name in ["results", "runs", "data", "src", "docs", ".git"] { XCTAssertNil(left["**/" + name + "/**"], "what a person works in stays watched: " + name) }
    }
    /// When the editor loses its server it says so itself and tries again; Harbor adds no notice of
    /// its own for the same thing, and puts the forwards back on the ports they had.
    @MainActor func testALostConnectionIsTheEditorsToAnnounceAndHarborsToRepair() throws {
        XCTAssertTrue(CodeWorkbenchSession.isTransportFailure("Editor transport status: NSURLErrorDomain (-1004) Could not connect to the server."))
        XCTAssertTrue(CodeWorkbenchSession.isTransportFailure("Editor transport terminalPanel: NSURLErrorDomain (-1001) The request timed out."))
        XCTAssertFalse(CodeWorkbenchSession.isTransportFailure("Editor command openFile: Unknown terminal"), "what is wrong with a command is still shown")
        XCTAssertFalse(CodeWorkbenchSession.isTransportFailure("Download failed: disk full"))
        XCTAssertEqual(CodeWorkbenchSession.localPort(of: "127.0.0.1:51234:127.0.0.1:8080"), 51234)
        XCTAssertNil(CodeWorkbenchSession.localPort(of: "51234:8080")); XCTAssertNil(CodeWorkbenchSession.localPort(of: "127.0.0.1:x:127.0.0.1:8080"))
    }
    /// The editor reads and writes the Mac's pasteboard through Harbor: an embedded page has no
    /// way to be given the browser's clipboard permission, and pasting into its terminal failed.
    @MainActor func testTheEditorsClipboardIsThePasteboard() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("app.harbor.test." + UUID().uuidString)); defer { board.releaseGlobally() }
        board.clearContents()
        func ask(_ request: [String: Any]) -> (value: Any?, error: String?) { WorkbenchClipboard.answer(request, pasteboard: board) }
        XCTAssertEqual(ask(["action": "read"]).value as? String, "", "nothing to paste is an empty paste, not an error")
        let text = "ls -la ~/Work\n终端 🙂\twith a tab"
        XCTAssertEqual(ask(["action": "write", "text": text]).value as? Bool, true)
        XCTAssertEqual(board.string(forType: .string), text)
        XCTAssertEqual(ask(["action": "read"]).value as? String, text)
        // Only text, and only what was asked for by name. A refused request changes nothing.
        XCTAssertEqual(ask(["action": "write", "text": 5]).error, "refused"); XCTAssertEqual(ask(["action": "write"]).error, "refused")
        XCTAssertEqual(ask(["action": "clear"]).error, "unknown"); XCTAssertEqual(ask([:]).error, "unknown")
        XCTAssertEqual(board.string(forType: .string), text)
        // The page's own reading and writing of text go to the app; pictures stay the page's.
        for name in ["harborClipboard", "'readText'", "'writeText'"] { XCTAssertTrue(WorkbenchClipboard.script.contains(name), name) }
        XCTAssertFalse(WorkbenchClipboard.script.contains("define('read',")); XCTAssertFalse(WorkbenchClipboard.script.contains("define('write',"))
    }
    @MainActor func testSettingsAndWindowKeysAreHarborsBeforeTheEditorSeesThem() throws {
        _ = NSApplication.shared
        let (store, _) = try fixture(); defer { store.shutdown() }
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags, _ characters: String, repeating: Bool = false) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                           characters: characters, charactersIgnoringModifiers: characters, isARepeat: repeating, keyCode: code))
        }
        // ⌘, opens and closes the panel without the editor loading its own Settings editor first.
        XCTAssertTrue(store.handleSettingsKey(try key(43, .command, ","))); XCTAssertTrue(store.settingsVisible)
        XCTAssertTrue(store.handleSettingsKey(try key(43, .command, ",", repeating: true))); XCTAssertTrue(store.settingsVisible, "a held key does not flicker")
        XCTAssertTrue(store.handleSettingsKey(try key(43, [.command, .capsLock], ","))); XCTAssertFalse(store.settingsVisible)
        XCTAssertFalse(store.handleSettingsKey(try key(43, [.command, .shift], "<"))); XCTAssertFalse(store.handleSettingsKey(try key(43, [], ",")))
        // ⇧⌘N asks for a Harbor window; the editor's own New Window is a browser page.
        XCTAssertTrue(store.handleWindowKey(try key(45, [.command, .shift], "N"))); XCTAssertEqual(store.workbenchUIRequest, "newWindow")
        store.workbenchUIRequest = nil
        XCTAssertFalse(store.handleWindowKey(try key(45, .command, "n"))); XCTAssertNil(store.workbenchUIRequest)
        // ⇧⌘H is Harbor's start page, and is not left to the editor (where it is Replace in Files).
        store.page = .workspace
        XCTAssertTrue(store.handleWindowKey(try key(4, [.command, .shift], "H"))); XCTAssertEqual(store.page, .recent)
        XCTAssertFalse(store.handleWindowKey(try key(4, .command, "h")), "⌘H hides the app as everywhere")
        // ⌘1… choose a tab only where windows are gathered as tabs.
        XCTAssertFalse(store.handleWindowKey(try key(18, .command, "1")))
        let first = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let second = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        first.isReleasedWhenClosed = false; second.isReleasedWhenClosed = false
        defer { first.close(); second.close() }
        first.addTabbedWindow(second, ordered: .above)
        store.attach(window: first)
        XCTAssertTrue(store.handleWindowKey(try key(19, .command, "2"))); XCTAssertTrue(first.tabGroup?.selectedWindow === second)
        XCTAssertTrue(store.handleWindowKey(try key(18, .command, "1"))); XCTAssertTrue(first.tabGroup?.selectedWindow === first)
        XCTAssertTrue(store.handleWindowKey(try key(25, .command, "9"))); XCTAssertTrue(first.tabGroup?.selectedWindow === second, "⌘9 is the last tab")
        XCTAssertTrue(store.handleWindowKey(try key(21, .command, "4"))); XCTAssertTrue(first.tabGroup?.selectedWindow === second, "no such tab: nothing happens, nothing leaks through")
    }
    @MainActor func testEditorSettingsRequestOpensThePanelOnceWithItsFilter() throws {
        let (store, _) = try fixture(); defer { store.shutdown() }
        // The page reports the editor's own Settings editor first, with the filter it was opened with.
        store.presentSettings(fromEditor: "@ext:acme.lint")
        XCTAssertTrue(store.settingsVisible); XCTAssertEqual(store.settingsQuery, "@ext:acme.lint")
        // The user closes the panel; the extension's report of the same event arrives later.
        store.settingsVisible = false
        store.handleWorkbenchAction(["action": "settings", "from": "editor"])
        XCTAssertNil(store.workbenchUIRequest, "a closed panel is not reopened")
        // Without the page's report (an editor that is not in a modal block) the extension's still counts,
        store.settingsEditorSeen = .distantPast
        store.handleWorkbenchAction(["action": "settings", "from": "editor"])
        XCTAssertEqual(store.workbenchUIRequest, "settings")
        // and an oversized filter is dropped while the panel still opens.
        store.settingsQuery = nil; store.settingsVisible = false
        store.presentSettings(fromEditor: String(repeating: "x", count: 500))
        XCTAssertTrue(store.settingsVisible); XCTAssertNil(store.settingsQuery)
    }
}
