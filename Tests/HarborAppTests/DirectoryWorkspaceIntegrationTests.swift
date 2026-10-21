import XCTest
import AppKit
import SwiftUI
import HarborCore
@testable import HarborSSH

final class DirectoryWorkspaceIntegrationTests: XCTestCase {
    @MainActor func testCloseLegacyAndInactiveWorkspacesKeepsOtherSessionsAndFolders() async throws {
        let (store, root, prefs) = try fixture(); defer { store.shutdown() }
        let first = try await open(store, root.appendingPathComponent("任务 A").path)
        XCTAssertNil(first.directoryID)
        store.openTerminal(store.selectedProfile); let firstSession = try XCTUnwrap(store.activeSession)
        let second = try await open(store, root.appendingPathComponent("任务 B").path)
        store.openTerminal(store.selectedProfile); let survivor = try XCTUnwrap(store.activeSession)
        store.closeDirectoryWorkspace(first, ask: false)
        XCTAssertTrue(store.currentFiles === second)
        XCTAssertTrue(firstSession.ended); XCTAssertFalse(survivor.ended)
        XCTAssertEqual(store.directoryWorkspaces(for: nil).map(\.root), [second.root])
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.root + "/main.py"))
        XCTAssertNil(prefs.string(forKey: first.key + ".root"))
        store.closeDirectoryWorkspace(second, ask: false)
        XCTAssertTrue(survivor.ended); XCTAssertTrue(store.currentFiles.root.isEmpty)
        XCTAssertEqual(store.directoryWorkspaces(for: nil).count, 1)
        let reopened = try await open(store, first.root)
        XCTAssertEqual(reopened.root, first.root); XCTAssertTrue(store.sessions.isEmpty)
    }
    @MainActor private func open(_ store: AppStore, _ path: String) async throws -> FileWorkspace {
        let workspace = await store.openDirectoryWorkspace(path, profile: nil)
        return try XCTUnwrap(workspace)
    }
    @MainActor private func fixture() throws -> (AppStore, URL, UserDefaults) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-multiple-directories-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "app.harbor.directories." + UUID().uuidString, prefs = TestDefaults.suite(suite)!
        addTeardownBlock { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = AppStore(historyRoot: root.appendingPathComponent("data"), workspaceDefaults: prefs)
        try store.history.prepare(); store.loading = false; store.selectWorkspace(nil)
        for name in ["任务 A", "任务 B"] {
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try ("# " + name).write(to: directory.appendingPathComponent("main.py"), atomically: true, encoding: .utf8)
        }
        return (store, root, prefs)
    }
    @MainActor func testServerSelectionsAndDirectoryIdentitiesAreIndependent() throws {
        let (store, _, _) = try fixture(); defer { store.shutdown() }
        let a = ServerProfile(name: "A", host: "a.example.invalid"), b = ServerProfile(name: "B", host: "b.example.invalid")
        store.profiles = [a, b]
        store.files(for: a).root = "/first"
        let a2 = store.directoryWorkspaceForPath("/second", profile: a)
        store.files(for: b).root = "/first"
        let b2 = store.directoryWorkspaceForPath("/second", profile: b)
        XCTAssertNotEqual(a2.directoryID, b2.directoryID)
        store.selectDirectoryWorkspace(a2); store.selectWorkspace(b.id)
        XCTAssertNil(store.selectedDirectoryID)
        store.selectDirectoryWorkspace(b2); store.selectWorkspace(a.id)
        XCTAssertTrue(store.currentFiles === a2)
        XCTAssertTrue(store.directoryWorkspaceForPath("/second/", profile: a) === a2)
    }
    @MainActor func testRecentTerminalInAnotherFolderDoesNotRetargetItsWorkspace() async throws {
        let (store, root, _) = try fixture(); defer { store.shutdown() }
        let first = try await open(store, root.appendingPathComponent("任务 A").path)
        let path = first.root
        let terminalID = store.openTerminal(nil, workingDirectory: root.appendingPathComponent("任务 B").path)
        store.openRecent(RecentWorkspace(serverID: nil, serverName: "本机", directory: root.appendingPathComponent("任务 B").path))
        XCTAssertEqual(store.activeSession?.id, terminalID)
        XCTAssertTrue(store.currentFiles === first)
        XCTAssertEqual(first.root, path)
    }
}
