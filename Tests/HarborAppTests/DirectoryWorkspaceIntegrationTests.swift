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
        store.openWorkspaceTerminal(); let firstSession = try XCTUnwrap(store.activeSession)
        let second = try await open(store, root.appendingPathComponent("任务 B").path)
        store.openWorkspaceTerminal(); let survivor = try XCTUnwrap(store.activeSession)
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
        let suite = "app.harbor.directories." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
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
    @MainActor func testDirectorySwitchKeepsDraftsProcessesAndIndependentSplitGroups() async throws {
        let (store, root, prefs) = try fixture(); defer { store.shutdown() }
        let first = try await open(store, root.appendingPathComponent("任务 A").path)
        await first.open(try XCTUnwrap(first.entries[first.root]?.first))
        let draft = try XCTUnwrap(first.currentDocument); draft.text = "unsaved A"
        store.openWorkspaceTerminal(); store.splitTerminal(.columns)
        let sessionsA = store.workspaceSessions, layoutA = store.arrangement(in: store.currentTerminalScope)
        let idsA = sessionsA.map(\.id), pids = sessionsA.map { $0.terminal.process.shellPid }
        let second = try await open(store, root.appendingPathComponent("任务 B").path)
        XCTAssertNotEqual(first.directoryID, second.directoryID)
        XCTAssertTrue(store.workspaceSessions.isEmpty)
        await second.open(try XCTUnwrap(second.entries[second.root]?.first))
        store.openWorkspaceTerminal(); let terminalB = try XCTUnwrap(store.activeSession)
        XCTAssertEqual(terminalB.workingDirectory, second.root)
        XCTAssertEqual(store.workspaceSessions.count, 1)
        store.splitTerminal(.rows)
        XCTAssertEqual(store.arrangement(in: store.currentTerminalScope).groups.count, 1)
        XCTAssertEqual(store.workspaceSessions.count, 2)
        store.selectDirectoryWorkspace(first)
        XCTAssertEqual(store.workspaceSessions.map(\.id), idsA)
        XCTAssertEqual(store.arrangement(in: store.currentTerminalScope), layoutA)
        XCTAssertTrue(first.currentDocument === draft); XCTAssertEqual(draft.text, "unsaved A")
        XCTAssertEqual(sessionsA.map { $0.terminal.process.shellPid }, pids)
        XCTAssertTrue(sessionsA.allSatisfy { $0.terminal.process.running })
        store.toggleFiles(); store.toggleFiles()
        XCTAssertEqual(store.arrangement(in: store.currentTerminalScope), layoutA)
        let count = store.sessions.count
        store.openRecent(RecentWorkspace(serverID: nil, serverName: "本机", directory: second.root))
        XCTAssertTrue(store.currentFiles === second); XCTAssertEqual(store.sessions.count, count)
        XCTAssertTrue(store.activeSession === terminalB)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView().environmentObject(store).defaultAppStorage(prefs))
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(nanoseconds: 500_000_000); window.contentView?.layoutSubtreeIfNeeded()
        if let output = ProcessInfo.processInfo.environment["HARBOR_QA_OUTPUT"], let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output).appendingPathComponent("directory-workspaces.png"))
        }
        store.closeDirectoryWorkspace(second, ask: false)
        XCTAssertTrue(store.currentFiles === first)
        XCTAssertEqual(store.workspaceSessions.map(\.id), idsA)
        XCTAssertTrue(draft.dirty)
    }
    @MainActor func testCatalogRestoresTabsLazilyAndFailedDirectoryDoesNotChangeWorkspace() async throws {
        let (store, root, prefs) = try fixture(); defer { store.shutdown() }
        let first = try await open(store, root.appendingPathComponent("任务 A").path)
        await first.open(try XCTUnwrap(first.entries[first.root]?.first))
        let second = try await open(store, root.appendingPathComponent("任务 B").path)
        await second.open(try XCTUnwrap(second.entries[second.root]?.first))
        let id = try XCTUnwrap(second.directoryID)
        let missing = await store.openDirectoryWorkspace(root.appendingPathComponent("does-not-exist").path, profile: nil)
        XCTAssertNil(missing); XCTAssertTrue(store.currentFiles === second)
        XCTAssertEqual(store.directoryWorkspaces(for: nil).count, 2)
        let restored = AppStore(historyRoot: store.history.root, workspaceDefaults: prefs); restored.loading = false
        defer { restored.shutdown() }
        restored.selectWorkspace(nil)
        XCTAssertEqual(restored.selectedDirectoryID, id)
        XCTAssertEqual(restored.currentFiles.root, second.root)
        XCTAssertTrue(restored.currentFiles.documents.isEmpty)
        let reopened = try await open(restored, second.root)
        await reopened.activate(store: restored)
        XCTAssertEqual(reopened.currentDocument?.text, "# 任务 B")
        restored.selectDirectory(profileID: nil, directoryID: nil)
        await restored.currentFiles.activate(store: restored)
        XCTAssertEqual(restored.currentFiles.currentDocument?.text, "# 任务 A")
        XCTAssertTrue(restored.sessions.isEmpty, "Restoring folders must never reconnect terminals automatically")
        store.selectDirectoryWorkspace(second)
        second.currentDocument?.text = "unsaved B"
        store.closeDirectoryWorkspace(second, ask: false)
        XCTAssertTrue(store.currentFiles === second); XCTAssertNotNil(store.errorMessage)
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
        await first.open(try XCTUnwrap(first.entries[first.root]?.first))
        let path = first.root, document = first.currentDocument
        let terminalID = store.openTerminal(nil, workingDirectory: root.appendingPathComponent("任务 B").path)
        store.openRecent(RecentWorkspace(serverID: nil, serverName: "本机", directory: root.appendingPathComponent("任务 B").path))
        XCTAssertEqual(store.activeSession?.id, terminalID)
        XCTAssertTrue(store.currentFiles === first)
        XCTAssertEqual(first.root, path); XCTAssertTrue(first.currentDocument === document)
    }
}
