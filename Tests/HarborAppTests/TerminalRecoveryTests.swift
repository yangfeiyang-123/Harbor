import XCTest
import AppKit
import HarborCore
@testable import HarborSSH

final class TerminalRecoveryTests: XCTestCase {
    @MainActor func fixture() throws -> (AppStore, URL, UserDefaults) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "harbor.recovery." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        let store = AppStore(historyRoot: root.appendingPathComponent("state"), workspaceDefaults: prefs)
        try store.history.prepare(); store.loading = false; store.selectWorkspace(nil); store.currentFiles.root = root.path
        addTeardownBlock { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        return (store, root, prefs)
    }
    @MainActor func add(_ store: AppStore, text: String, window: UUID? = nil) throws -> TerminalSession {
        let s = try TerminalSession(profile: nil, title: "Local · \(store.sessions.count + 1)", detached: window != nil, history: store.history, workingDirectory: store.currentFiles.root)
        s.windowID = window; s.terminal.feed(text: text); s.ended = true
        store.sessions.append(s); store.registerTerminal(s); store.selectSession(s)
        return s
    }
    @MainActor func testReconnectKeepsUnicodeScrollbackAndNamesWithNewPTY() async throws {
        let (store, _, _) = try fixture(); defer { store.shutdown() }
        let s = try add(store, text: "Question: 中文 alpha\r\nAnswer: keep  two spaces\r\n")
        s.rename(to: "Chat"); store.reconnect(s)
        let new = try XCTUnwrap(store.activeSession)
        XCTAssertNotEqual(s.id, new.id); XCTAssertEqual(new.tabTitle, "Chat")
        XCTAssertTrue(new.recoveryOutput().contains("Question: 中文 alpha"))
        XCTAssertTrue(new.recoveryOutput().contains("Answer: keep  two spaces"))
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(new.terminal.process.running)
        new.stop(); store.reconnect(new)
        let again = try XCTUnwrap(store.activeSession)
        XCTAssertEqual(again.recoveryOutput().components(separatedBy: "Question: 中文 alpha").count, 2)
    }
    @MainActor func testRestartRestoresIndependentTerminalsSplitOrderAndSelectedPaneWithoutLaunching() async throws {
        let (store, root, prefs) = try fixture()
        let a = try add(store, text: "conversation A\r\n"), b = try add(store, text: "conversation B\r\n")
        a.rename(to: "Alpha"); b.rename(to: "Beta"); a.currentDirectory = root.path
        let scope = store.currentTerminalScope
        var layout = store.arrangement(in: scope); layout.split(a.id, adding: b.id, axis: .rows)
        store.terminalLayouts[scope] = layout; store.selectSession(b)
        let expected = store.arrangement(in: scope)
        store.shutdown()
        let restored = AppStore(historyRoot: store.history.root, workspaceDefaults: prefs)
        restored.loading = false; defer { restored.shutdown() }
        await restored.restoreTerminals()
        XCTAssertEqual(restored.sessions.map(\.id), [a.id,b.id])
        XCTAssertEqual(restored.arrangement(in: scope), expected)
        XCTAssertEqual(restored.activeSession?.id, b.id)
        XCTAssertEqual(restored.sessions.map(\.tabTitle), ["Alpha","Beta"])
        XCTAssertTrue(restored.sessions.allSatisfy { $0.ended && !$0.started && !$0.terminal.process.running })
        XCTAssertTrue(restored.sessions[0].recoveryOutput().contains("conversation A"))
        XCTAssertFalse(restored.sessions[0].recoveryOutput().contains("conversation B"))
        XCTAssertTrue(restored.sessions[1].recoveryOutput().contains("conversation B"))
    }
    @MainActor func testAlternateScreenAndSoftWrapSurviveRestartAndApplicationClear() throws {
        let (store, _, _) = try fixture(); defer { store.shutdown() }
        let s = try add(store, text: "")
        s.terminal.getTerminal().resize(cols: 20, rows: 8)
        let line = "Long chat answer 中文 with spaces and details"
        s.terminal.feed(text: line + "\r\n\u{1b}[?1049hAlternate chat 中文\r\n")
        let captured = s.recoveryOutput()
        XCTAssertTrue(captured.contains(line), captured.debugDescription); XCTAssertTrue(captured.contains("Alternate chat 中文"))
        let replacement = try TerminalSession(profile: nil, title: "Local · 2", history: store.history)
        replacement.terminal.getTerminal().resize(cols: 40, rows: 12)
        replacement.restoreOutput(captured)
        XCTAssertEqual(replacement.recoveryOutput().components(separatedBy: line).count, 2)
        replacement.terminal.feed(text: "\u{1b}[3J\u{1b}[2J\u{1b}[HNew screen")
        XCTAssertTrue(replacement.recoveryOutput().contains(line), replacement.recoveryOutput().debugDescription)
        XCTAssertTrue(replacement.savedOutput.contains("Alternate chat 中文"))
    }
    @MainActor func testExplicitCloseRemovesOnlyThatTerminalsSavedOutput() async throws {
        let (store, _, prefs) = try fixture(); defer { store.shutdown() }
        let a = try add(store, text: "remove me"), b = try add(store, text: "keep me")
        XCTAssertTrue(store.checkpointTerminals(synchronously: true))
        store.close(a, ask: false); XCTAssertTrue(store.checkpointTerminals(synchronously: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.recoveryStore.root.appendingPathComponent(a.id.uuidString + ".txt").path))
        let restored = AppStore(historyRoot: store.history.root, workspaceDefaults: prefs)
        defer { restored.shutdown() }; await restored.restoreTerminals()
        XCTAssertEqual(restored.sessions.map(\.id), [b.id])
    }
    @MainActor func testMalformedRecoveryCannotOverwriteOriginalFile() async throws {
        let (store, _, _) = try fixture()
        try FileManager.default.createDirectory(at: store.recoveryStore.root, withIntermediateDirectories: true)
        let path = store.recoveryStore.root.appendingPathComponent("manifest.json")
        try Data("broken recovery data".utf8).write(to: path)
        await store.restoreTerminals()
        XCTAssertFalse(store.recoveryWritable); XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.checkpointTerminals(synchronously: true))
        store.shutdown()
        XCTAssertEqual(try String(contentsOf: path), "broken recovery data")
    }
    @MainActor func testDisconnectedRemoteKeepsTmuxAndDirectoryIdentity() async throws {
        let (store, _, prefs) = try fixture(); defer { store.shutdown() }
        let profile = ServerProfile(name: "Server", host: "example.invalid", useTmux: true)
        store.profiles = [profile]
        let s = try TerminalSession(profile: profile, title: "Server · 1", history: store.history, tmuxName: "harbor-legacy-qa", workingDirectory: "/work/chat")
        s.directoryWorkspaceID = UUID(); s.ended = true
        s.terminal.feed(text: "remote conversation\r\n")
        store.sessions.append(s); store.registerTerminal(s); store.selectSession(s)
        XCTAssertTrue(store.checkpointTerminals(synchronously: true))
        let restored = AppStore(historyRoot: store.history.root, workspaceDefaults: prefs)
        restored.profiles = [profile]; defer { restored.shutdown() }
        await restored.restoreTerminals()
        let loaded = try XCTUnwrap(restored.sessions.first)
        XCTAssertEqual(loaded.tmuxName,s.tmuxName)
        XCTAssertEqual(loaded.directoryWorkspaceID,s.directoryWorkspaceID)
        XCTAssertEqual(loaded.effectiveDirectory,"/work/chat")
        XCTAssertFalse(loaded.started)
    }
    @MainActor func testRecoveryDoesNotReplayClipboardEscapeSequence() throws {
        let (store, _, _) = try fixture(); defer { store.shutdown() }
        let s = try add(store, text: "")
        var oscCalls = 0
        s.terminal.getTerminal().registerOscHandler(code: 52) { _ in oscCalls += 1 }
        s.restoreOutput("safe\u{1b}]52;c;dW5zYWZl\u{7}\n中文")
        XCTAssertEqual(oscCalls,0)
        XCTAssertTrue(s.terminal.getTerminal().getRecoveryText().contains("中文"))
    }
    @MainActor func testCheckpointFilesArePrivateAndDetachedWindowIdentitySurvives() async throws {
        let (store, _, prefs) = try fixture(); defer { store.shutdown() }
        let windowID = UUID(), s = try add(store,text:"detached output",window: windowID)
        XCTAssertTrue(store.checkpointTerminals(synchronously:true))
        let path = store.recoveryStore.root.appendingPathComponent(s.id.uuidString + ".txt")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:path.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
        let restored = AppStore(historyRoot:store.history.root,workspaceDefaults:prefs)
        defer {restored.shutdown()}; await restored.restoreTerminals()
        XCTAssertEqual(restored.sessions.first?.windowID,windowID)
        XCTAssertEqual(restored.arrangement(in:.window(windowID)).sessionIDs,[s.id])
    }
    @MainActor func testNormalLaunchRestoresBeforeShowingWorkspaceAndSavedOutputMenuWorks() async throws {
        let (store, _, prefs) = try fixture()
        store.profiles = [ServerProfile(name: "QA",host: "harbor-recovery.example.invalid")]
        store.save()
        let s = try add(store,text:"saved on quit 中文")
        store.shutdown()
        let restored = AppStore(historyRoot:store.history.root,workspaceDefaults:prefs)
        await restored.load(); defer { restored.shutdown() }
        XCTAssertFalse(restored.loading); XCTAssertEqual(restored.page,.workspace)
        let loaded = try XCTUnwrap(restored.activeSession)
        XCTAssertEqual(loaded.id,s.id); XCTAssertFalse(loaded.started)
        XCTAssertFalse(restored.profiles[0].useTmux)
        let item = NSMenuItem(title:"Saved Output",action:#selector(CapturingTerminal.showSavedOutput(_:)),keyEquivalent:"")
        XCTAssertTrue(loaded.terminal.validateUserInterfaceItem(item))
        loaded.showSavedOutput()
        let window = try XCTUnwrap(loaded.savedOutputWindow)
        defer { window.close() }
        let view = try XCTUnwrap((window.contentView as? NSScrollView)?.documentView as? NSTextView)
        XCTAssertTrue(view.string.contains("saved on quit 中文")); XCTAssertFalse(view.isEditable); XCTAssertTrue(view.isSelectable)
    }

}
