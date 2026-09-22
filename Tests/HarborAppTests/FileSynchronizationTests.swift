import XCTest
import AppKit
import HarborCore
import Combine
@testable import HarborSSH

final class FileSynchronizationTests: XCTestCase {
    @MainActor private func fixture() async throws -> (AppStore, FileWorkspace, URL) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-file-sync-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "app.harbor.sync." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        addTeardownBlock { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = AppStore(historyRoot: root.appendingPathComponent("data"), workspaceDefaults: prefs)
        try store.history.prepare(); store.loading = false; store.selectWorkspace(nil)
        let workspace = store.currentFiles
        await workspace.prepare(store: store)
        return (store, workspace, root)
    }
    @MainActor func testGeneratedNestedVideoAppearsWithoutManualRefreshAndWatcherStops() async throws {
        let (store, workspace, root) = try await fixture(); defer { store.shutdown() }
        let logs = root.appendingPathComponent("logs"), output = logs.appendingPathComponent("new-video.mp4")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: false)
        await workspace.navigate(root.path)
        await workspace.toggle(try XCTUnwrap(workspace.entries[root.path]?.first { $0.name == "logs" }))
        workspace.query = "video"
        let monitor = Task { await workspace.monitorDirectoryChanges() }
        defer { monitor.cancel() }
        try await Task.sleep(nanoseconds: 80_000_000)
        let started = Date()
        try Data("generated video bytes".utf8).write(to: output)
        while workspace.entries[logs.path]?.contains(where: { $0.name == output.lastPathComponent }) != true && Date().timeIntervalSince(started) < 6 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(workspace.entries[logs.path]?.contains { $0.path == output.path } == true)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertTrue(workspace.expanded.contains(logs.path)); XCTAssertEqual(workspace.query, "video")
        monitor.cancel(); await monitor.value
        XCTAssertNil(workspace.monitorID); XCTAssertNil(workspace.localWatcher)
        if let directory = ProcessInfo.processInfo.environment["HARBOR_QA_OUTPUT"] {
            try JSONSerialization.data(withJSONObject: ["generated_file_visible_seconds": Date().timeIntervalSince(started), "watcher_released_on_cancel": workspace.localWatcher == nil], options: .prettyPrinted)
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("file-sync.json"))
        }
    }
    @MainActor func testRefreshPreservesTreeAndDraftsAndReloadsStableCleanPreview() async throws {
        let (store, workspace, root) = try await fixture(); defer { store.shutdown() }
        let child = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        let file = child.appendingPathComponent("run.py")
        try "old".write(to: file, atomically: true, encoding: .utf8)
        await workspace.navigate(root.path)
        await workspace.toggle(try XCTUnwrap(workspace.entries[root.path]?.first { $0.name == "logs" }))
        await workspace.open(try XCTUnwrap(workspace.entries[child.path]?.first))
        let document = try XCTUnwrap(workspace.currentDocument), previousURL = document.localURL
        workspace.query = "run"
        try "new clean output".write(to: file, atomically: true, encoding: .utf8)
        await workspace.refreshExpanded(); await workspace.refreshExpanded()
        XCTAssertEqual(document.text, "new clean output"); XCTAssertNotEqual(document.localURL, previousURL)
        XCTAssertEqual(workspace.selection, document.id); XCTAssertEqual(workspace.query, "run")
        XCTAssertTrue(workspace.expanded.contains(child.path))
        document.text = "my unsaved draft"
        try "another program's output".write(to: file, atomically: true, encoding: .utf8)
        await workspace.refreshExpanded(force: true); await workspace.refreshExpanded()
        XCTAssertEqual(document.text, "my unsaved draft"); XCTAssertTrue(document.dirty)
        XCTAssertEqual(document.savedText, "new clean output")
        await workspace.save(document)
        XCTAssertNotNil(document.error); XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "another program's output")
        try FileManager.default.removeItem(at: child)
        await workspace.refreshExpanded(force: true)
        XCTAssertFalse(workspace.expanded.contains(child.path))
        XCTAssertFalse(workspace.entries[root.path]?.contains { $0.name == "logs" } == true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        try Data().write(to: child.appendingPathComponent("recreated.mp4"))
        await workspace.refreshExpanded(force: true)
        await workspace.toggle(try XCTUnwrap(workspace.entries[root.path]?.first { $0.name == "logs" }))
        XCTAssertEqual(workspace.entries[child.path]?.first?.name, "recreated.mp4")
    }
    @MainActor func testRestoringManyTabsLoadsOnlySelectedPreview() async throws {
        let (store, workspace, root) = try await fixture(); defer { store.shutdown() }
        let paths = (0..<12).map { root.appendingPathComponent("sample-\($0).py") }
        for path in paths { try path.lastPathComponent.write(to: path, atomically: true, encoding: .utf8) }
        await workspace.navigate(root.path)
        workspace.savedOpenPaths = paths.map(\.path)
        await workspace.activate(store: store)
        XCTAssertEqual(workspace.documents.count, 12)
        XCTAssertEqual(workspace.documents.filter { $0.localURL != nil }.count, 1)
        XCTAssertEqual(workspace.currentDocument?.entry.path, paths.last?.path)
        XCTAssertEqual(workspace.currentDocument?.text, paths.last?.lastPathComponent)
    }
    @MainActor func testReloadKeepsInputThatArrivesWhileReadingFile() async throws {
        let (store, workspace, root) = try await fixture(); defer { store.shutdown() }
        let file = root.appendingPathComponent("draft.py")
        try "original".write(to: file, atomically: true, encoding: .utf8)
        await workspace.navigate(root.path)
        await workspace.open(try XCTUnwrap(workspace.entries[root.path]?.first { $0.name == "draft.py" }))
        let document = try XCTUnwrap(workspace.currentDocument), previousURL = document.localURL
        try "changed by script".write(to: file, atomically: true, encoding: .utf8)
        let observer = document.$loading.dropFirst().filter { $0 }.prefix(1).sink { _ in document.text = "new user draft" }
        defer { observer.cancel() }
        await workspace.load(document)
        XCTAssertEqual(document.text, "new user draft")
        XCTAssertEqual(document.savedText, "original")
        XCTAssertEqual(document.localURL, previousURL)
        XCTAssertTrue(document.dirty)
    }
}
