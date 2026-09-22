import XCTest
import AppKit
import HarborCore
@testable import HarborSSH

final class RemoteTerminalHostTests: XCTestCase {
    @MainActor func testOldProfileFlagDoesNotCreateTmuxAndRecoveryKeepsPTYIdentity() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-pty-identity-" + UUID().uuidString)
        let suite = "harbor.pty." + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        let store = AppStore(historyRoot: root, workspaceDefaults: prefs)
        let profile = ServerProfile(name: "Legacy flag", host: "example.invalid", useTmux: true)
        store.profiles = [profile]
        try store.history.prepare()
        let session = try TerminalSession(profile: profile, title: "Test", history: store.history, workingDirectory: "/tmp")
        let identity = try XCTUnwrap(session.remotePTYID)
        XCTAssertNil(session.tmuxName)
        XCTAssertEqual(session.directoryToken, identity.uuidString)
        session.remotePTYReconnect = true
        session.ended = true
        store.sessions.append(session); store.registerTerminal(session)
        XCTAssertTrue(store.checkpointTerminals(synchronously: true))
        let restored = AppStore(historyRoot: root, workspaceDefaults: prefs)
        defer {
            restored.shutdown(); store.shutdown()
            prefs.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        restored.profiles = [profile]
        await restored.restoreTerminals()
        let loaded = try XCTUnwrap(restored.sessions.first)
        XCTAssertEqual(loaded.remotePTYID, identity)
        XCTAssertEqual(loaded.directoryToken, session.directoryToken)
        XCTAssertTrue(loaded.remotePTYReconnect)
        XCTAssertNil(loaded.tmuxName)
        let args = try RemoteTerminalHost.arguments(loaded, profile: profile, socket: "/tmp/test")
        let command = try XCTUnwrap(args.last)
        XCTAssertTrue(command.contains("'attach' '" + identity.uuidString + "'"))
        XCTAssertFalse(command.contains("exec tmux"))
    }

    @MainActor func testExplicitLegacySessionKeepsCompatibilityButNewTerminalUsesHost() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-pty-legacy-" + UUID().uuidString)
        let history = try HistoryStore(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = ServerProfile(name: "Legacy", host: "example.invalid", useTmux: true)
        let old = try TerminalSession(profile: profile, title: "Old", history: history, tmuxName: "harbor-existing")
        XCTAssertNil(old.remotePTYID)
        XCTAssertEqual(old.tmuxName, "harbor-existing")
        let new = try TerminalSession(profile: profile, title: "New", history: history)
        XCTAssertNotNil(new.remotePTYID)
        XCTAssertNil(new.tmuxName)
    }

    func testHostCommandQuotesDirectoryAndRejectsUnknownMode() throws {
        let id = UUID(), directory = "/tmp/a' b;$(touch should-not-run)"
        let command = try RemoteTerminalHost.command(id: id, mode: "create", directory: directory)
        XCTAssertTrue(command.contains("'--directory' " + SSHArguments.quote(directory)))
        XCTAssertThrowsError(try RemoteTerminalHost.command(id: id, mode: "serve; other", directory: nil))
    }
}
