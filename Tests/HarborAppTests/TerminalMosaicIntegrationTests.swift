import XCTest
import AppKit
import SwiftUI
import HarborCore
@testable import HarborSSH

final class TerminalMosaicIntegrationTests: XCTestCase {
    @MainActor private func fixture() throws -> (AppStore, URL, UserDefaults) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-mosaic-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "app.harbor.tests." + UUID().uuidString
        let prefs = TestDefaults.suite(suite)!
        addTeardownBlock { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = AppStore(historyRoot: root.appendingPathComponent("data"), workspaceDefaults: prefs)
        try store.history.prepare(); store.loading = false; store.selectWorkspace(nil)
        store.currentFiles.root = root.path
        prefs.set(52.0, forKey: "sidebarWidth"); prefs.set(30.0, forKey: "headerHeight"); prefs.set(215.0, forKey: "fileTreeWidth")
        return (store, root, prefs)
    }
    @MainActor func testServerIsolationReconnectAndDetachedWindowSplits() throws {
        let (store, _, _) = try fixture(); defer { store.shutdown() }
        let a = ServerProfile(name: "A", host: "a.example.invalid"), b = ServerProfile(name: "B", host: "b.example.invalid")
        store.profiles = [a, b]; store.files(for: a).root = "/work/a"; store.files(for: b).root = "/work/b"
        _ = store.openTerminal(a); store.splitTerminal(.columns)
        let aScope = store.currentTerminalScope, aLayout = store.arrangement(in: aScope)
        XCTAssertEqual(aLayout.sessionIDs.count, 2)
        let source = try XCTUnwrap(store.activeSession); source.rename(to: "Build"); source.stop(); store.reconnect(source)
        let replacement = try XCTUnwrap(store.activeSession)
        XCTAssertEqual(replacement.customTitle, "Build"); XCTAssertEqual(replacement.workingDirectory, "/work/a")
        XCTAssertEqual(store.arrangement(in: aScope).roots.count, 1)
        XCTAssertFalse(store.arrangement(in: aScope).sessionIDs.contains(source.id))
        let restoredA = store.arrangement(in: aScope)
        _ = store.openTerminal(b); store.splitTerminal(.rows)
        XCTAssertEqual(store.arrangement(in: .workspace(b.id)).sessionIDs.count, 2)
        XCTAssertEqual(store.arrangement(in: aScope), restoredA)
        store.selectWorkspace(a.id); XCTAssertEqual(store.arrangement(in: aScope), restoredA)
        let windowID = try XCTUnwrap(store.openTerminal(b, detached: true))
        let detached = try XCTUnwrap(store.sessions.first { $0.id == windowID })
        store.splitTerminal(.columns, session: detached)
        XCTAssertEqual(store.terminalSessions(in: .window(windowID)).count, 2)
        XCTAssertTrue(store.terminalSessions(in: .window(windowID)).allSatisfy { $0.detached && $0.workingDirectory == "/work/b" })
        XCTAssertEqual(store.arrangement(in: aScope), restoredA)
        store.close(detached, ask: false)
        XCTAssertEqual(store.terminalSessions(in: .window(windowID)).count, 1)
        XCTAssertNotNil(store.selectedTerminal(in: .window(windowID)))
        store.closeTerminalWindow(windowID); XCTAssertTrue(store.terminalSessions(in: .window(windowID)).isEmpty)
    }
    @MainActor func testNewTerminalInDetachedWindowStaysInSameWindowAndLeavesMainGroupUntouched() async throws {
        let (store, root, prefs) = try fixture(); defer { store.shutdown() }
        store.openTerminal(store.selectedProfile); store.splitTerminal(.columns)
        let main = store.arrangement(in: store.currentTerminalScope)
        let id = try XCTUnwrap(store.openTerminal(nil, detached: true))
        let scope = TerminalScope.window(id)
        store.splitTerminal(.rows, session: store.selectedTerminal(in: scope))
        let hosting = NSHostingView(rootView: TerminalWindowView(windowID: id).environmentObject(store).defaultAppStorage(prefs))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(nanoseconds: 100_000_000); hosting.layoutSubtreeIfNeeded()
        let before = store.arrangement(in: scope)
        window.makeFirstResponder(store.selectedTerminal(in: scope)!.terminal)
        NSApp.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .shift], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "~", charactersIgnoringModifiers: "~", isARepeat: false, keyCode: 50)))
        try await Task.sleep(nanoseconds: 130_000_000); hosting.layoutSubtreeIfNeeded()
        let after = store.arrangement(in: scope), created = try XCTUnwrap(store.selectedTerminal(in: scope))
        XCTAssertEqual(after.groups.count, 2); XCTAssertEqual(after.groups[0], before.groups[0])
        XCTAssertEqual(after.visible?.sessionIDs, [created.id]); XCTAssertEqual(created.windowID, id)
        XCTAssertEqual(created.workingDirectory, root.path); XCTAssertTrue(created.detached)
        XCTAssertTrue(created.terminal.window === window)
        XCTAssertTrue(window.firstResponder === created.terminal, "New detached terminal must be ready for typing")
        XCTAssertEqual(store.arrangement(in: store.currentTerminalScope), main)
    }
    @MainActor private func assertMounted(_ sessions: [TerminalSession], in host: NSView, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await Task.sleep(nanoseconds: 120_000_000); host.layoutSubtreeIfNeeded()
        var frames: [NSRect] = []
        for session in sessions {
            XCTAssertTrue(session.terminal.isDescendant(of: host), "Terminal detached during presentation switch: \(session.tabTitle)", file: file, line: line)
            let rect = session.terminal.convert(session.terminal.bounds, to: host)
            XCTAssertGreaterThan(rect.width, 80); XCTAssertGreaterThan(rect.height, 18)
            XCTAssertGreaterThanOrEqual(rect.minY, 32); XCTAssertLessThanOrEqual(rect.maxY, host.bounds.maxY - 24)
            XCTAssertGreaterThanOrEqual(rect.minX, 52); XCTAssertLessThanOrEqual(rect.maxX, host.bounds.maxX)
            for other in frames { XCTAssertFalse(rect.intersects(other), "Terminal panes overlap") }
            frames.append(rect)
        }
    }
    @MainActor private func assertSingleTerminal(_ selected: TerminalSession, among sessions: [TerminalSession], in host: NSView, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await assertMounted([selected], in: host, file: file, line: line)
        let visible = sessions.filter { $0.terminal.isDescendant(of: host) && !$0.terminal.isHiddenOrHasHiddenAncestor }
        XCTAssertEqual(visible.map(\.id), [selected.id], "Expected \(selected.tabTitle); visible: \(visible.map(\.tabTitle))", file: file, line: line)
        XCTAssertGreaterThan(selected.terminal.frame.width, 450, "The selected terminal must use the panel width, not a split column")
    }
}
