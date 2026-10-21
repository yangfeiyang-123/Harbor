import XCTest
import AppKit
import HarborCore
@testable import HarborSSH

final class TerminalSplitRequestTests: XCTestCase {
    @MainActor private final class LookupGate {
        var started = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            await withCheckedContinuation { continuation = $0; started = true }
        }
        func finish() { continuation?.resume(); continuation = nil }
    }

    @MainActor private func wait(until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { await Task.yield() }
        XCTAssertTrue(condition())
    }

    @MainActor func testRepeatedSplitsWaitForOneFreshDirectoryLookup() async {
        let request = TerminalSplitRequest(), gate = LookupGate()
        var lookups = 0, directories: [String] = [], directory = "/before-cd"
        for _ in 0..<8 {
            request.run(refresh: {
                lookups += 1; await gate.wait(); directory = "/after-cd"
            }, completion: { directories.append(directory) })
        }
        await wait { gate.started }
        XCTAssertEqual(lookups, 1)
        XCTAssertTrue(request.pending)
        XCTAssertTrue(directories.isEmpty, "Never start the split from the stale cached directory")
        gate.finish()
        await wait { !request.pending }
        XCTAssertEqual(directories, ["/after-cd"])
        request.run(refresh: {}, completion: { directories.append("/next-split") })
        await wait { !request.pending }
        XCTAssertEqual(directories, ["/after-cd", "/next-split"])
    }

    @MainActor func testCancelledLookupCannotCompleteOrClearAReplacementRequest() async {
        let request = TerminalSplitRequest(), old = LookupGate(), next = LookupGate()
        var completed: [String] = []
        request.run(refresh: { await old.wait() }, completion: { completed.append("old") })
        await wait { old.started }
        request.cancel()
        request.run(refresh: { await next.wait() }, completion: { completed.append("next") })
        await wait { next.started }
        old.finish()
        // The lookup deliberately ignores cancellation, like an in-flight SSH
        // subprocess. Its late completion must not unlock the next request.
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(request.pending)
        XCTAssertTrue(completed.isEmpty)
        next.finish()
        await wait { !request.pending }
        XCTAssertEqual(completed, ["next"])
    }

    @MainActor func testIndependentPanesDoNotBlockEachOthersSplit() async {
        let first = TerminalSplitRequest(), second = TerminalSplitRequest(), gate = LookupGate()
        var completed: [Int] = []
        first.run(refresh: { await gate.wait() }, completion: { completed.append(1) })
        second.run(refresh: {}, completion: { completed.append(2) })
        await wait { gate.started && completed == [2] }
        XCTAssertTrue(first.pending)
        gate.finish()
        await wait { !first.pending }
        XCTAssertEqual(completed, [2, 1])
    }

    @MainActor func testClosingSourceCancelsPendingSplit() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-split-cancel-" + UUID().uuidString)
        let history = HistoryStore(location: root)
        try history.prepare()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try TerminalSession(profile: nil, title: "Source", history: history)
        let gate = LookupGate()
        var completed = false
        source.splitRequest.run(refresh: { await gate.wait() }, completion: { completed = true })
        await wait { gate.started }
        source.stop()
        XCTAssertFalse(source.splitRequest.pending)
        gate.finish()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(completed)
    }

    @MainActor func testLocalSplitUsesLiveShellDirectoryAfterCD() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-split-cwd-" + UUID().uuidString).resolvingSymlinksInPath()
        let child = root.appendingPathComponent("new folder")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let suite = "app.harbor.split." + UUID().uuidString, prefs = TestDefaults.suite(suite)!
        let store = AppStore(historyRoot: root.appendingPathComponent("state"), workspaceDefaults: prefs)
        try store.history.prepare(); store.loading = false; store.selectWorkspace(nil)
        defer { store.shutdown(); prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        store.currentFiles.root = root.path
        store.openTerminal(store.selectedProfile)
        let source = try XCTUnwrap(store.activeSession)
        source.terminal.send(txt: "cd " + SSHArguments.quote(child.path) + "\n")
        func canonical(_ path: String?) -> String? { path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } }
        await wait { canonical(source.effectiveDirectory) == child.path }
        store.splitTerminal(.columns, session: source)
        let split = try XCTUnwrap(store.activeSession)
        XCTAssertNotEqual(split.id, source.id)
        XCTAssertEqual(canonical(split.workingDirectory), child.path)
        XCTAssertEqual(store.arrangement(in: store.currentTerminalScope).groups.count, 1)
        await wait { canonical(split.effectiveDirectory) == child.path }
    }

    @MainActor func testPendingSplitPreservesNewServerDirectoryGroupAndEditorFocus() async throws {
        _ = NSApplication.shared
        for destination in ["server", "directory", "group", "editor"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-pending-split-" + UUID().uuidString)
            let suite = "app.harbor.pending-split." + UUID().uuidString, prefs = TestDefaults.suite(suite)!
            let store = AppStore(historyRoot: root, workspaceDefaults: prefs)
            try store.history.prepare(); store.loading = false; store.selectWorkspace(nil)
            defer { store.shutdown(); prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
            store.currentFiles.root = root.path; store.currentFiles.enabled = true
            store.openTerminal(store.selectedProfile)
            let source = try XCTUnwrap(store.activeSession), sourceScope = store.currentTerminalScope
            let gate = LookupGate()
            // Exercise the production asynchronous split coordinator with a
            // controlled directory lookup; no remote network or extra runtime.
            store.enqueueTerminalSplit(.columns, source: source, refresh: { await gate.wait() })
            await wait { gate.started }
            switch destination {
            case "server":
                let server = ServerProfile(name: "Other", host: "other.example.invalid")
                store.profiles = [server]; store.selectWorkspace(server.id)
            case "directory":
                let next = store.directoryWorkspaceForPath(root.appendingPathComponent("other-folder").path, profile: nil)
                store.selectDirectoryWorkspace(next)
            case "group": store.openTerminal(store.selectedProfile)
            default: store.currentFiles.requestFocus(.editor)
            }
            let selectedScope = store.currentTerminalScope, selectedID = store.selectedSessionID
            let selectedGroup = store.arrangement(in: selectedScope).selectedGroup?.id
            let sourceSelection = store.arrangement(in: sourceScope).selectedID
            let files = store.currentFiles, focusRequest = files.focusRequest, focusArea = files.focusArea
            let count = store.sessions.count
            gate.finish()
            await wait { !source.splitRequest.pending }
            XCTAssertEqual(store.sessions.count, count + 1, destination)
            XCTAssertEqual(store.currentTerminalScope, selectedScope, destination)
            XCTAssertEqual(store.selectedSessionID, selectedID, destination)
            XCTAssertEqual(store.arrangement(in: selectedScope).selectedGroup?.id, selectedGroup, destination)
            XCTAssertEqual(store.arrangement(in: sourceScope).selectedID, sourceSelection, destination)
            XCTAssertEqual(files.focusRequest, focusRequest, destination)
            XCTAssertEqual(files.focusArea, focusArea, destination)
            XCTAssertEqual(store.arrangement(in: sourceScope).groups.first(where: { $0.layout.contains(source.id) })?.sessionIDs.count, 2, destination)
            XCTAssertTrue(source.terminal.process.running, destination)
        }
    }

    @MainActor func testPendingSplitStillActivatesWhenPresentationHasNotChanged() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-pending-active-" + UUID().uuidString)
        let suite = "app.harbor.pending-active." + UUID().uuidString, prefs = TestDefaults.suite(suite)!
        let store = AppStore(historyRoot: root, workspaceDefaults: prefs)
        try store.history.prepare(); store.loading = false; store.selectWorkspace(nil)
        defer { store.shutdown(); prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        store.currentFiles.root = root.path; store.openTerminal(store.selectedProfile)
        let source = try XCTUnwrap(store.activeSession), gate = LookupGate()
        store.enqueueTerminalSplit(.rows, source: source, refresh: { await gate.wait() })
        await wait { gate.started }
        gate.finish()
        await wait { !source.splitRequest.pending }
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertNotEqual(store.selectedSessionID, source.id)
        XCTAssertEqual(store.currentFiles.focusArea, .terminal)
        XCTAssertEqual(store.arrangement(in: store.currentTerminalScope).groups.count, 1)
    }
}
