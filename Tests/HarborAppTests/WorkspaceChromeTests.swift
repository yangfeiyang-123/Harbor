import XCTest
import AppKit
import SwiftUI
import WebKit
import HarborCore
@testable import HarborSSH

final class WorkspaceChromeTests: XCTestCase {
    @MainActor private func fixture() throws -> (AppStore, URL) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-chrome-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "app.harbor.tests." + UUID().uuidString
        let prefs = TestDefaults.suite(suite)!
        addTeardownBlock { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = AppStore(historyRoot: root.appendingPathComponent("data"), workspaceDefaults: prefs)
        try store.history.prepare(); store.loading = false
        return (store, root)
    }

    @MainActor func testRenamePreservesIdentityDirectoryAndNumberAllocation() throws {
        let (store, _) = try fixture(); defer { store.shutdown() }
        let profile = ServerProfile(name: "Test", host: "test.example.invalid")
        store.profiles = [profile]; store.files(for: profile).root = "/work/project"
        let firstID = try XCTUnwrap(store.openTerminal(profile))
        let first = try XCTUnwrap(store.activeSession)
        first.rename(to: "  长名称 · 编译与分析终端 🧪 \n")
        XCTAssertEqual(first.id, firstID)
        XCTAssertEqual(first.title, "Test · 1")
        XCTAssertEqual(first.tabTitle, "长名称 · 编译与分析终端 🧪")
        XCTAssertEqual(first.workingDirectory, "/work/project")
        XCTAssertGreaterThan(first.tabWidth ?? 0, 150)
        _ = store.openTerminal(profile)
        XCTAssertEqual(store.activeSession?.title, "Test · 2")
        first.stop(); store.reconnect(first)
        XCTAssertEqual(store.activeSession?.customTitle, first.customTitle)
        XCTAssertEqual(store.activeSession?.tabWidth, first.tabWidth)
        first.rename(to: " \n "); XCTAssertEqual(first.tabTitle, "project")
        XCTAssertEqual(WorkspaceTabLayout.clamp(-100), 40)
        XCTAssertEqual(WorkspaceTabLayout.clamp(10000), 360)
    }

}
