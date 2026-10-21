import XCTest
import AppKit
import HarborCore
@testable import HarborSSH

final class RemoteTerminalHostTests: XCTestCase {
    @MainActor func testOldProfileFlagDoesNotCreateTmuxAndRecoveryKeepsPTYIdentity() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-pty-identity-" + UUID().uuidString)
        let suite = "harbor.pty." + UUID().uuidString
        let prefs = TestDefaults.suite(suite)!
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
        // The whole command is one quoted argument of `sh -c`; inside it the mode and the identity are quoted again.
        XCTAssertTrue(command.contains(String(SSHArguments.quote("'attach' '" + identity.uuidString + "'").dropFirst().dropLast())))
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
        XCTAssertTrue(command.hasPrefix("sh -c '"))
        XCTAssertTrue(command.contains(String(SSHArguments.quote("'--directory' " + SSHArguments.quote(directory)).dropFirst().dropLast())))
        XCTAssertFalse(command.contains("\n"), "one line: a login shell that is not sh reads it the same way")
        XCTAssertThrowsError(try RemoteTerminalHost.command(id: id, mode: "serve; other", directory: nil))
    }

    /// The command is what sshd hands to the account's login shell. Each of these must be able to
    /// read it and reach the terminal host: asked to close a terminal that does not exist, the host
    /// answers that there is nothing to close.
    func testTheHostCommandRunsUnderAnyLoginShell() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-host-shells-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        for shell in ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/csh", "/bin/tcsh"] where FileManager.default.isExecutableFile(atPath: shell) {
            let id = UUID()
            let command = try RemoteTerminalHost.command(id: id, mode: "close", directory: "/tmp/a' b;$(touch should-not-run) `touch nor-this`")
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: shell); process.arguments = ["-c", command]
            process.currentDirectoryURL = work
            process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = output
            try process.run(); process.waitUntilExit()
            let said = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertEqual(process.terminationStatus, 0, shell + ": " + said)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [], shell + " ran what was only a folder's name")
            try? FileManager.default.removeItem(atPath: "/tmp/harbor-pty-\(getuid())/" + id.uuidString + ".lock")
        }
    }
}
