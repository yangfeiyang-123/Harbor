import XCTest
import AppKit
import HarborCore
@testable import HarborSSH

final class RecentWorkspaceIntegrationTests: XCTestCase {
    @MainActor func testRecentsPersistIndependentlyAndNeverWriteTerminalOutput() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-recents-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try HistoryStore(root: root)
        let legacy = SessionRecord(serverID: nil, serverName: "Local", title: "Legacy")
        try history.write([legacy], name: "history.json")
        let original = try Data(contentsOf: root.appendingPathComponent("history.json"))
        let suite = "app.harbor.tests." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let store = AppStore(historyRoot: root, workspaceDefaults: prefs)
        var profile = ServerProfile(name: "A", host: "example.invalid"); profile.recordOutput = true
        store.profiles = [profile]; store.loading = false
        let session = try TerminalSession(profile: profile, title: "Existing", history: history, workingDirectory: root.path)
        XCTAssertNil(session.writer)
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.logURL(session.id).path))
        session.ready = true; store.sessions = [session]
        store.remember(profile: profile, directory: root.path, tmuxName: session.tmuxName)
        XCTAssertEqual(try history.read("recent-workspaces.json", as: [RecentWorkspace].self)?.count, 1)
        let recent = try XCTUnwrap(store.recents.first)
        store.openRecent(recent)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.selectedSessionID, session.id)
        XCTAssertEqual(store.currentFiles.root, root.path)
        store.removeRecent(recent)
        XCTAssertTrue(store.recents.isEmpty); XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("history.json")), original)
        session.stop()
    }
}
