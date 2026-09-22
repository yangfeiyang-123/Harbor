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
        let prefs = UserDefaults(suiteName: suite)!
        addTeardownBlock { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = AppStore(historyRoot: root.appendingPathComponent("data"), workspaceDefaults: prefs)
        try store.history.prepare(); store.loading = false; store.selectWorkspace(nil)
        store.currentFiles.root = root.path; store.currentFiles.entries[root.path] = []
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
    @MainActor func testNewTerminalShortcutCreatesIndependentGroupFromTerminalAndFileModes() async throws {
        let (store, root, prefs) = try fixture(); defer { store.shutdown() }
        store.openWorkspaceTerminal(); store.splitTerminal(.columns); store.splitTerminal(.rows)
        let scope = store.currentTerminalScope, original = store.arrangement(in: scope)
        let pids = store.sessions.map { $0.terminal.process.shellPid }
        let hosting = NSHostingView(rootView: ContentView().environmentObject(store).defaultAppStorage(prefs))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        for fileMode in [false, true] {
            store.currentFiles.enabled = fileMode
            try await Task.sleep(nanoseconds: 100_000_000); hosting.layoutSubtreeIfNeeded()
            window.makeFirstResponder(store.activeSession!.terminal)
            let before = store.arrangement(in: scope)
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .shift], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "~", charactersIgnoringModifiers: "~", isARepeat: false, keyCode: 50))
            NSApp.sendEvent(event)
            try await Task.sleep(nanoseconds: 130_000_000); hosting.layoutSubtreeIfNeeded()
            let after = store.arrangement(in: scope), created = try XCTUnwrap(store.activeSession)
            XCTAssertEqual(after.groups.count, before.groups.count + 1)
            XCTAssertEqual(after.sessionIDs.count, before.sessionIDs.count + 1)
            XCTAssertEqual(Array(after.groups.prefix(before.groups.count)), before.groups, "Existing split groups changed")
            XCTAssertEqual(after.visible?.sessionIDs, [created.id])
            XCTAssertEqual(created.workingDirectory, root.path)
            XCTAssertEqual(store.currentFiles.enabled, fileMode)
            XCTAssertTrue(created.terminal.window === window)
            XCTAssertTrue(window.firstResponder === created.terminal, "New terminal must be ready for typing")
            XCTAssertEqual(Array(store.sessions.prefix(3).map { $0.terminal.process.shellPid }), pids)
            XCTAssertTrue(store.sessions.allSatisfy { $0.terminal.process.running })
        }
        store.currentFiles.enabled = false
        store.activateTerminalGroup(original.groups[0].id, in: scope)
        XCTAssertEqual(store.arrangement(in: scope).visible, original.visible)
    }
    @MainActor func testNewTerminalInDetachedWindowStaysInSameWindowAndLeavesMainGroupUntouched() async throws {
        let (store, root, prefs) = try fixture(); defer { store.shutdown() }
        store.openWorkspaceTerminal(); store.splitTerminal(.columns)
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
    @MainActor func testRepeatedPresentationSwitchKeepsFourLivePTYsAndTheirGeometry() async throws {
        let (store, _, prefs) = try fixture(); defer { store.shutdown() }
        store.openWorkspaceTerminal(); let first = try XCTUnwrap(store.activeSession)
        store.splitTerminal(.columns); let second = try XCTUnwrap(store.activeSession)
        store.splitTerminal(.columns); let third = try XCTUnwrap(store.activeSession)
        store.splitTerminal(.rows, session: second); let fourth = try XCTUnwrap(store.activeSession)
        let scope = store.currentTerminalScope
        let layout = store.arrangement(in: scope)
        XCTAssertEqual(layout.groups.count, 1, "Splitting must not add top-level tabs")
        XCTAssertEqual(layout.visible?.sessionIDs, [first.id, second.id, fourth.id, third.id])
        let sessions = [first, second, fourth, third]
        let pids = sessions.map { $0.terminal.process.shellPid }
        XCTAssertTrue(pids.allSatisfy { $0 > 0 })
        let hosting = NSHostingView(rootView: ContentView().environmentObject(store).defaultAppStorage(prefs))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        for _ in 0..<3 {
            store.currentFiles.terminalVisible = false
            store.toggleFiles()
            XCTAssertTrue(store.currentFiles.enabled); XCTAssertTrue(store.currentFiles.terminalVisible)
            try await assertSingleTerminal(fourth, among: sessions, in: hosting)
            XCTAssertEqual(store.arrangement(in: scope).visible, layout.visible)
            store.toggleFiles(); XCTAssertFalse(store.currentFiles.enabled)
            try await assertMounted(sessions, in: hosting)
            XCTAssertEqual(store.arrangement(in: scope).visible, layout.visible)
            XCTAssertEqual(sessions.map { $0.terminal.process.shellPid }, pids)
            XCTAssertTrue(sessions.allSatisfy { $0.terminal.process.running })
        }
        if case .split(let splitID, _, _, _, _) = layout.visible {
            let beforeWidth = first.terminal.frame.width
            store.resizeTerminalSplit(splitID, in: scope, ratio: 0.33)
            try await assertMounted(sessions, in: hosting)
            XCTAssertLessThan(first.terminal.frame.width, beforeWidth - 100)
            store.resizeTerminalSplit(splitID, in: scope, ratio: 0.5)
            try await assertMounted(sessions, in: hosting)
        }
        store.toggleFiles()
        try await assertSingleTerminal(fourth, among: sessions, in: hosting)
        let expandedX = fourth.terminal.convert(fourth.terminal.bounds, to: hosting).minX
        prefs.set(52.0, forKey: "fileTreeWidth")
        var positions: [Double] = []
        for _ in 0..<26 {
            try await Task.sleep(nanoseconds: 20_000_000); hosting.layoutSubtreeIfNeeded()
            positions.append(fourth.terminal.convert(fourth.terminal.bounds, to: hosting).minX)
        }
        let collapsedX = try XCTUnwrap(positions.last)
        XCTAssertLessThan(collapsedX, expandedX - 150)
        XCTAssertGreaterThan(Set(positions.filter { $0 > collapsedX + 2 && $0 < expandedX - 2 }.map { Int($0) }).count, 2,
                             "The native content must pass through intermediate widths: \(positions)")
        XCTAssertTrue(positions.allSatisfy { $0 >= collapsedX - 1 && $0 <= expandedX + 1 })
        if let output = ProcessInfo.processInfo.environment["HARBOR_QA_OUTPUT"] {
            let evidence: [String: Any] = ["expandedX": expandedX, "collapsedX": collapsedX, "sampleIntervalMs": 20, "nativeTerminalX": positions]
            try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output).appendingPathComponent("explorer-motion.json"))
        }
        prefs.set(215.0, forKey: "fileTreeWidth")
        try await Task.sleep(nanoseconds: 500_000_000)
        try await assertSingleTerminal(fourth, among: sessions, in: hosting)
        XCTAssertEqual(fourth.terminal.convert(fourth.terminal.bounds, to: hosting).minX, expandedX, accuracy: 1)
        store.toggleFiles()
        try await assertMounted(sessions, in: hosting)
        window.makeFirstResponder(first.terminal)
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(store.selectedSessionID, first.id)
        window.makeFirstResponder(fourth.terminal)
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(store.selectedSessionID, fourth.id)
        store.close(fourth, ask: false)
        try await assertMounted([first, second, third], in: hosting)
        XCTAssertEqual(store.arrangement(in: scope).visible?.sessionIDs, [first.id, second.id, third.id])
    }
    @MainActor func testFileModeShowsOneTerminalWithOrderedListAndRestoresSplitGroups() async throws {
        let (store, root, prefs) = try fixture(); defer { store.shutdown() }
        store.openWorkspaceTerminal(); let first = try XCTUnwrap(store.activeSession)
        store.splitTerminal(.columns); let second = try XCTUnwrap(store.activeSession)
        store.splitTerminal(.rows, session: second); let third = try XCTUnwrap(store.activeSession)
        store.openWorkspaceTerminal(); let independent = try XCTUnwrap(store.activeSession)
        let sessions = [first, second, third, independent]
        let pids = sessions.map { $0.terminal.process.shellPid }
        let scope = store.currentTerminalScope
        let arrangement = store.arrangement(in: scope)
        XCTAssertEqual(arrangement.sessionIDs, sessions.map(\.id))
        let groupIDs = arrangement.groups.map(\.id)
        let document = WorkspaceDocument(WorkspaceEntry(path: root.appendingPathComponent("example.swift").path, name: "example.swift", directory: false, size: 100, modified: 0))
        document.text = "// Harbor workspace\n" + (1...80).map { "let value\($0) = \($0)" }.joined(separator: "\n")
        document.savedText = document.text
        store.currentFiles.documents = [document]; store.currentFiles.selection = document.id
        store.toggleFiles()
        let hosting = NSHostingView(rootView: ContentView().environmentObject(store).defaultAppStorage(prefs))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        for session in [independent, first, third, second] {
            let previous = store.activeSession
            store.activateTerminal(session)
            // Reproduce a queued AppKit focus callback from the outgoing pane.
            previous?.terminal.onFocus?()
            XCTAssertEqual(store.selectedSessionID, session.id)
            try await assertSingleTerminal(session, among: sessions, in: hosting)
            XCTAssertEqual(store.selectedSessionID, session.id)
            XCTAssertEqual(store.arrangement(in: scope).roots, arrangement.roots)
            XCTAssertEqual(store.arrangement(in: scope).groups.map(\.id), groupIDs)
            XCTAssertEqual(sessions.map { $0.terminal.process.shellPid }, pids)
        }
        store.toggleFiles()
        try await assertMounted([first, second, third], in: hosting)
        XCTAssertEqual(store.arrangement(in: scope).roots, arrangement.roots)
        XCTAssertEqual(store.selectedSessionID, second.id)
        store.toggleFiles()
        try await assertSingleTerminal(second, among: sessions, in: hosting)
        let normalWidth = second.terminal.frame.width
        prefs.set(52.0, forKey: "fileTerminalListWidth")
        try await assertSingleTerminal(second, among: sessions, in: hosting)
        XCTAssertGreaterThan(second.terminal.frame.width, normalWidth + 100)
        prefs.set(160.0, forKey: "fileTerminalListWidth")
        prefs.set(0.82, forKey: "editorHeightRatio")
        try await assertSingleTerminal(second, among: sessions, in: hosting)
        XCTAssertLessThan(second.terminal.frame.height, 150, "Hidden split rows must not enforce a multi-pane minimum height")
        if let output = ProcessInfo.processInfo.environment["HARBOR_QA_OUTPUT"], let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output).appendingPathComponent("file-terminal-list-native.png"))
        }
        store.close(third, ask: false)
        try await assertSingleTerminal(second, among: sessions, in: hosting)
        XCTAssertEqual(store.arrangement(in: scope).sessionIDs, [first.id, second.id, independent.id])
        window.makeFirstResponder(second.terminal)
        try await Task.sleep(nanoseconds: 40_000_000)
        store.close(second, ask: false)
        try await assertSingleTerminal(first, among: sessions, in: hosting)
        XCTAssertTrue(window.firstResponder === first.terminal)
        XCTAssertTrue(first.terminal.process.running); XCTAssertTrue(independent.terminal.process.running)
        store.toggleFiles()
        try await assertMounted([first], in: hosting)
        XCTAssertEqual(store.arrangement(in: scope).groups.map(\.id), groupIDs)
        store.activateTerminal(independent); store.toggleFiles()
        try await assertSingleTerminal(independent, among: sessions, in: hosting)
        XCTAssertTrue(store.currentFiles.enabled)
        XCTAssertEqual(store.activeSession?.id, independent.id)
    }
    @MainActor func testSwitchingAndClosingGroupedTabsPreservesOtherLiveWorkspace() async throws {
        let (store, _, prefs) = try fixture(); defer { store.shutdown() }
        store.openWorkspaceTerminal(); let first = try XCTUnwrap(store.activeSession)
        store.splitTerminal(.columns); let second = try XCTUnwrap(store.activeSession)
        store.splitTerminal(.rows, session: second); let third = try XCTUnwrap(store.activeSession)
        let scope = store.currentTerminalScope
        let groupID = try XCTUnwrap(store.arrangement(in: scope).selectedGroup?.id)
        store.activateTerminal(second)
        store.openWorkspaceTerminal(); let independent = try XCTUnwrap(store.activeSession)
        let independentGroup = try XCTUnwrap(store.arrangement(in: scope).selectedGroup?.id)
        let pids = store.sessions.map { $0.terminal.process.shellPid }
        let hosting = NSHostingView(rootView: ContentView().environmentObject(store).defaultAppStorage(prefs))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        try await assertMounted([independent], in: hosting)
        store.activateTerminalGroup(groupID, in: scope)
        try await assertMounted([first, second, third], in: hosting)
        XCTAssertEqual(store.selectedSessionID, second.id)
        XCTAssertEqual(store.arrangement(in: scope).groups.count, 2)
        store.activateTerminalGroup(independentGroup, in: scope)
        try await assertMounted([independent], in: hosting)
        store.activateTerminalGroup(groupID, in: scope)
        try await assertMounted([first, second, third], in: hosting)
        XCTAssertEqual(store.selectedSessionID, second.id)
        XCTAssertEqual(store.sessions.map { $0.terminal.process.shellPid }, pids)
        if let output = ProcessInfo.processInfo.environment["HARBOR_QA_OUTPUT"],
           let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output).appendingPathComponent("grouped-tabs-native.png"))
        }
        store.closeTerminalGroup(groupID, in: scope, ask: false)
        try await assertMounted([independent], in: hosting)
        XCTAssertEqual(store.sessions.map(\.id), [independent.id])
        XCTAssertTrue(independent.terminal.process.running)
        XCTAssertEqual(store.arrangement(in: scope).selectedGroup?.id, independentGroup)
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
    @MainActor func testExplorerCollapsePreservesDocumentsAndDarkColorMatchesReference() throws {
        let (store, root, _) = try fixture()
        let workspace = store.currentFiles
        let document = WorkspaceDocument(WorkspaceEntry(path: root.appendingPathComponent("a.py").path, name: "a.py", directory: false, size: 3, modified: 0))
        document.text = "draft"; document.savedText = "old"
        workspace.documents = [document]; workspace.selection = document.id
        workspace.expanded = [root.path + "/a", root.path + "/a/b", root.path + "/c"]
        workspace.collapseFolders()
        XCTAssertTrue(workspace.expanded.isEmpty); XCTAssertTrue(document.dirty); XCTAssertEqual(workspace.selection, document.id)
        let color = try XCTUnwrap(TerminalTheme.background(dark: true).usingColorSpace(.sRGB))
        XCTAssertEqual(color.redComponent, 25.0 / 255, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent, 26.0 / 255, accuracy: 0.001)
        XCTAssertEqual(color.blueComponent, 27.0 / 255, accuracy: 0.001)
        for symbol in ["doc.badge.plus", "folder.badge.plus", "square.on.square", "sidebar.left", "sidebar.leading"] {
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), symbol)
        }
    }
}
