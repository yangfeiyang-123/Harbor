import XCTest
import AppKit
import HarborCore
@testable import HarborSSH

final class DirectoryBrowserTests: XCTestCase {
    @MainActor private func settled(_ browser: DirectoryBrowser) async throws {
        for _ in 0..<160 {
            if !browser.loading { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Directory browser did not finish loading")
    }
    @MainActor func testBrowseSuggestConfirmAndCancelPreserveWorkspace() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-browser-" + UUID().uuidString).resolvingSymlinksInPath()
        let prefsName = "app.harbor.browser." + UUID().uuidString, prefs = UserDefaults(suiteName: prefsName)!
        defer { try? FileManager.default.removeItem(at: root); prefs.removePersistentDomain(forName: prefsName) }
        for path in ["Current", "Next 项目/Child", ".hidden"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true) }
        try Data("unchanged".utf8).write(to: root.appendingPathComponent("Current/file.txt"))
        let store = AppStore(historyRoot: root.appendingPathComponent("data"), workspaceDefaults: prefs)
        try store.history.prepare(); store.loading = false; store.selectWorkspace(nil)
        defer { store.shutdown() }
        let result = await store.openDirectoryWorkspace(root.appendingPathComponent("Current").path, profile: nil)
        let first = try XCTUnwrap(result)
        await first.open(try XCTUnwrap(first.entries[first.root]?.first))
        first.currentDocument?.text = "draft stays here"
        store.chooseDirectoryWorkspace()
        let browser = try XCTUnwrap(store.directoryBrowser)
        browser.browse(browser.path)
        browser.editPath(browser.path)
        try await settled(browser)
        XCTAssertEqual(browser.currentPath, first.root)
        XCTAssertTrue(browser.folders.isEmpty, "The initial picker lists children, not its parent directory")
        browser.browse(root.path); try await settled(browser)
        XCTAssertTrue(browser.folders.contains { $0.name == ".hidden" })
        XCTAssertTrue(browser.folders.allSatisfy(\.directory))
        XCTAssertTrue(store.currentFiles === first); XCTAssertEqual(first.currentDocument?.text, "draft stays here")
        browser.editPath(root.path + "/Next"); try await settled(browser)
        XCTAssertEqual(browser.folders.map(\.name), ["Next 项目"]); XCTAssertFalse(browser.canOpen)
        browser.browse(try XCTUnwrap(browser.folders.first).path); try await settled(browser)
        XCTAssertEqual(browser.folders.map(\.name), ["Child"])
        XCTAssertEqual(browser.candidatePath, root.path + "/Next 项目")
        XCTAssertTrue(store.currentFiles === first, "Browsing must not commit the folder selection")
        browser.cancel(); store.directoryBrowser = nil
        XCTAssertTrue(store.currentFiles === first)

        store.chooseDirectoryWorkspace()
        let nextBrowser = try XCTUnwrap(store.directoryBrowser)
        nextBrowser.editPath(root.path + "/Next 项目/Child"); try await settled(nextBrowser)
        XCTAssertTrue(nextBrowser.canOpen)
        let opened = await store.openDirectoryWorkspace(try XCTUnwrap(nextBrowser.candidatePath), profile: nextBrowser.profile)
        XCTAssertEqual(opened?.root, root.path + "/Next 项目/Child")
        XCTAssertEqual(first.currentDocument?.text, "draft stays here")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Current/file.txt"), encoding: .utf8), "unchanged")
        let current = store.currentFiles
        nextBrowser.browse(root.path + "/missing"); try await settled(nextBrowser)
        XCTAssertNotNil(nextBrowser.error); XCTAssertFalse(nextBrowser.canOpen)
        nextBrowser.editPath(root.path + "/Current/file.txt"); try await settled(nextBrowser)
        XCTAssertFalse(nextBrowser.canOpen, "A file cannot be confirmed as a directory")
        XCTAssertTrue(store.currentFiles === current)
    }
    @MainActor func testLateResultsNeverReplaceNewerFolderAndCancellationStopsUpdates() async throws {
        let slow = WorkspaceEntry(path: "/slow/old", name: "old", directory: true, size: 0, modified: 0)
        let fast = WorkspaceEntry(path: "/fast/new", name: "new", directory: true, size: 0, modified: 0)
        let browser = DirectoryBrowser(profile: nil, path: "/") { path in
            if path == "/slow" { await withCheckedContinuation { c in DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { c.resume() } } }
            // Deliberately ignore cancellation as a late network response might.
            return WorkspaceListing(path: path, entries: [path == "/slow" ? slow : fast], truncated: false)
        }
        browser.browse("/slow"); await Task.yield()
        browser.browse("/fast"); try await settled(browser)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(browser.currentPath, "/fast"); XCTAssertEqual(browser.folders.map(\.name), ["new"])
        browser.browse("/slow"); await Task.yield(); browser.cancel()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(browser.currentPath, "/fast")
    }
}
