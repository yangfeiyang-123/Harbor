import XCTest
import AppKit
import HarborCore
@testable import HarborSSH

final class TerminalDirectoryIntegrationTests: XCTestCase {
    @MainActor private func fixture() throws -> (AppStore, URL, UserDefaults) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-terminal-directory-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "app.harbor.tests." + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        addTeardownBlock { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = AppStore(historyRoot: root.appendingPathComponent("app-data"), workspaceDefaults: prefs)
        try store.history.prepare(); store.loading = false
        return (store, root, prefs)
    }

    @MainActor private func assertProcessDirectory(_ session: TerminalSession, _ directory: URL, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(5)
        while session.terminal.process.shellPid == 0 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let pid = session.terminal.process.shellPid
        guard pid > 0 else { XCTFail("Local terminal process did not start", file: file, line: line); return }
        let result = await ProcessRunner.run("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"], timeout: 5)
        XCTAssertTrue(result.succeeded, result.output, file: file, line: line)
        let reportedPath = result.output.split(separator: "\n").first { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
        XCTAssertEqual(reportedPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }, directory.resolvingSymlinksInPath().path, result.output, file: file, line: line)
    }

    @MainActor func testHiddenWorkspaceAppliesToTabsWindowsAndRestoredLocalWorkspace() async throws {
        let (store, root, prefs) = try fixture()
        defer { store.shutdown() }
        let directory = root.appendingPathComponent("项目 folder ' quote")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let files = store.currentFiles
        files.enabled = true
        await files.prepare(store: store); await files.navigate(directory.path)
        XCTAssertNil(files.error)
        store.toggleFiles()
        XCTAssertFalse(files.enabled)

        store.openWorkspaceTerminal()
        let tab = try XCTUnwrap(store.activeSession)
        XCTAssertEqual(tab.workingDirectory, directory.path)
        XCTAssertEqual(tab.tabTitle, directory.lastPathComponent)
        await assertProcessDirectory(tab, directory)
        let windowID = try XCTUnwrap(store.openTerminal(nil, detached: true))
        let window = try XCTUnwrap(store.sessions.first { $0.id == windowID })
        XCTAssertEqual(window.workingDirectory, directory.path)
        XCTAssertEqual(window.tabTitle, directory.lastPathComponent)
        await assertProcessDirectory(window, directory)

        let restored = AppStore(historyRoot: store.history.root, workspaceDefaults: prefs)
        restored.loading = false
        defer { restored.shutdown() }
        XCTAssertFalse(restored.currentFiles.enabled)
        let restoredID = try XCTUnwrap(restored.openTerminal(nil))
        let restoredSession = try XCTUnwrap(restored.sessions.first { $0.id == restoredID })
        XCTAssertEqual(restoredSession.workingDirectory, directory.path)
        XCTAssertEqual(restoredSession.tabTitle, directory.lastPathComponent)
        await assertProcessDirectory(restoredSession, directory)
    }

    @MainActor func testServerEntryUsesItsOwnDirectoryAndExplicitFolderOverridesIt() throws {
        let (store, _, _) = try fixture()
        defer { store.shutdown() }
        let a = ServerProfile(name: "A", host: "a.example.invalid")
        let b = ServerProfile(name: "B", host: "b.example.invalid")
        let c = ServerProfile(name: "C", host: "c.example.invalid")
        store.profiles = [a, b, c]
        store.files(for: a).root = "/work/a"
        store.files(for: b).root = "/work/项目 b"
        store.selectWorkspace(a.id)
        let targetID = try XCTUnwrap(store.openTerminal(b, detached: true))
        let target = try XCTUnwrap(store.sessions.first { $0.id == targetID })
        XCTAssertEqual(target.workingDirectory, "/work/项目 b")
        XCTAssertEqual(target.tabTitle, "项目 b")
        XCTAssertEqual(store.selectedProfileID, a.id)

        let overrideID = try XCTUnwrap(store.openTerminal(b, workingDirectory: "/another/folder"))
        XCTAssertEqual(store.sessions.first { $0.id == overrideID }?.workingDirectory, "/another/folder")
        XCTAssertEqual(store.sessions.first { $0.id == overrideID }?.tabTitle, "folder")
        store.files(for: b).root = "/work/changed"
        XCTAssertEqual(target.workingDirectory, "/work/项目 b")
        let newID = try XCTUnwrap(store.openTerminal(b))
        XCTAssertEqual(store.sessions.first { $0.id == newID }?.workingDirectory, "/work/changed")
        XCTAssertEqual(store.sessions.first { $0.id == newID }?.tabTitle, "changed")
        let defaultID = try XCTUnwrap(store.openTerminal(c))
        XCTAssertNil(store.sessions.first { $0.id == defaultID }?.workingDirectory)
        // Stop the model sessions before their queued connection tasks execute.
    }

    @MainActor func testExplicitLoginRecentAndReconnectKeepTheirOriginalDestination() throws {
        let (store, _, _) = try fixture()
        defer { store.shutdown() }
        let profile = ServerProfile(name: "A", host: "a.example.invalid")
        store.profiles = [profile]
        store.files(for: profile).root = "/work/selected"
        store.openRecent(RecentWorkspace(serverID: profile.id, serverName: profile.name))
        let session = try XCTUnwrap(store.activeSession)
        XCTAssertNil(session.workingDirectory)
        session.stop()
        store.reconnect(session)
        let replacement = try XCTUnwrap(store.activeSession)
        XCTAssertNotEqual(session.id, replacement.id)
        XCTAssertNil(replacement.workingDirectory)
    }

    @MainActor func testMissingSelectedLocalDirectoryDoesNotSilentlyOpenHome() throws {
        let (store, root, _) = try fixture()
        store.currentFiles.root = root.appendingPathComponent("removed").path
        XCTAssertNil(store.openTerminal(nil))
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertNotNil(store.errorMessage)
    }

    @MainActor func testStartupDirectoryNamesStayStableAndCustomNamesCanReset() throws {
        let (store, _, _) = try fixture()
        let profile = ServerProfile(name: "Server", host: "server.invalid")
        let session = try TerminalSession(profile: profile, title: "Server · 1", history: store.history, workingDirectory: "/work/Project A/")
        XCTAssertEqual(session.tabTitle, "Project A")
        session.acceptDirectory("/work/subfolder")
        XCTAssertEqual(session.tabTitle, "Project A", "Changing directory must not rename an existing terminal")
        session.rename(to: "Training")
        XCTAssertEqual(session.tabTitle, "Training")
        session.rename(to: " ")
        XCTAssertEqual(session.tabTitle, "Project A")
        let login = try TerminalSession(profile: profile, title: "Server · 2", history: store.history)
        XCTAssertEqual(login.tabTitle, "Terminal 2", "The remote login directory is not known until the server reports it")
        login.acceptDirectory("file:///home/demo/Research%20Files")
        XCTAssertEqual(login.tabTitle, "Research Files")
        login.acceptDirectory("/work/another")
        XCTAssertEqual(login.tabTitle, "Research Files")
        let root = try TerminalSession(profile: profile, title: "Server · 3", history: store.history, workingDirectory: "/")
        XCTAssertEqual(root.tabTitle, "/")
        let local = try TerminalSession(profile: nil, title: "Local · 1", history: store.history)
        XCTAssertEqual(local.tabTitle, FileManager.default.homeDirectoryForCurrentUser.lastPathComponent)
    }
}
