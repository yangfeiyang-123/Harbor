import XCTest
import AppKit
import SwiftUI
import HarborCore
@testable import HarborSSH

final class TerminalMaximizeIntegrationTests: XCTestCase {
    @MainActor private func fixture() throws -> (AppStore, UserDefaults, WorkspaceDocument) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-maximize-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "app.harbor.maximize." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        addTeardownBlock { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = AppStore(historyRoot: root.appendingPathComponent("data"), workspaceDefaults: prefs)
        try store.history.prepare(); store.loading = false; store.selectWorkspace(nil)
        let workspace = store.currentFiles
        workspace.root = root.path; workspace.entries[root.path] = []
        let doc = WorkspaceDocument(WorkspaceEntry(path: root.appendingPathComponent("draft.py").path, name: "draft.py", directory: false, size: 1000, modified: 0))
        doc.savedText = "# Saved file\n"
        doc.text = "# Unsaved draft — keep this text\n" + String(repeating: "print('workspace')\n", count: 100)
        workspace.documents = [doc]; workspace.selection = doc.id
        prefs.set(52.0, forKey: "sidebarWidth"); prefs.set(30.0, forKey: "headerHeight")
        prefs.set(215.0, forKey: "fileTreeWidth"); prefs.set(0.64, forKey: "editorHeightRatio")
        prefs.set("dark", forKey: "appearance")
        return (store, prefs, doc)
    }
    @MainActor private func window(_ store: AppStore, _ prefs: UserDefaults) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView().environmentObject(store).defaultAppStorage(prefs))
        return window
    }
    @MainActor private func settle(_ window: NSWindow) async throws {
        try await Task.sleep(nanoseconds: 310_000_000); window.contentView?.layoutSubtreeIfNeeded()
    }
    @MainActor private func press(_ code: UInt16, in window: NSWindow, repeatKey: Bool = false) throws {
        let input = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: code == 6 ? "Ω" : "≈",
            charactersIgnoringModifiers: code == 6 ? "z" : "x", isARepeat: repeatKey, keyCode: code))
        NSApp.sendEvent(input)
    }
    @MainActor private func snapshot(_ window: NSWindow, name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["HARBOR_QA_OUTPUT"], let view = window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
    }
    @MainActor func testOptionKeysMaximizeAndRestoreLiveTerminalWithoutLosingDraftOrSplitLayout() async throws {
        let (store, prefs, doc) = try fixture(); defer { store.shutdown() }
        store.openWorkspaceTerminal(); store.splitTerminal(.columns); store.splitTerminal(.rows)
        let sessions = store.sessions, pids = sessions.map { $0.terminal.process.shellPid }
        let scope = store.currentTerminalScope, original = store.arrangement(in: scope)
        let draft = doc.text, selected = try XCTUnwrap(store.activeSession)
        let window = window(store, prefs); defer { window.contentView = nil; window.close() }
        try await settle(window)
        window.makeFirstResponder(selected.terminal)
        try press(6, in: window); try await settle(window)
        let workspace = store.currentFiles
        XCTAssertTrue(workspace.enabled); XCTAssertFalse(workspace.terminalMaximized)
        let deadline = Date().addingTimeInterval(10)
        while doc.editor?.ready != true && Date() < deadline { try await Task.sleep(nanoseconds: 30_000_000) }
        let web = try XCTUnwrap(doc.editor?.web), hosting = try XCTUnwrap(window.contentView)
        let normal = selected.terminal.convert(selected.terminal.bounds, to: hosting)
        XCTAssertGreaterThan(web.bounds.height, 100)
        try snapshot(window, name: "file-mode-normal")
        try press(7, in: window); try await settle(window)
        XCTAssertTrue(workspace.enabled); XCTAssertTrue(workspace.terminalMaximized)
        XCTAssertTrue(window.firstResponder === selected.terminal, "Responder: \(String(describing: window.firstResponder)), focus: \(workspace.focusArea), selected: \(String(describing: store.activeSession?.id)), attached: \(selected.terminal.window === window)")
        let maximum = selected.terminal.convert(selected.terminal.bounds, to: hosting)
        XCTAssertLessThan(maximum.minY, 65, "The toolbar and editor must both disappear: \(maximum)")
        XCTAssertGreaterThan(maximum.height, hosting.bounds.height - 110)
        XCTAssertGreaterThan(maximum.height, normal.height + 300)
        XCTAssertLessThanOrEqual(web.bounds.height, 1, "Hidden editor must not paint over the terminal")
        XCTAssertTrue(doc.editor?.web === web, "Keep the editor mounted and preserve its state")
        XCTAssertEqual(prefs.double(forKey: "editorHeightRatio"), 0.64)
        XCTAssertEqual(doc.text, draft); XCTAssertTrue(doc.dirty)
        try snapshot(window, name: "file-mode-maximized")
        try press(7, in: window, repeatKey: true); try await settle(window)
        XCTAssertTrue(workspace.terminalMaximized, "Holding the key must not toggle repeatedly")
        try press(7, in: window); try await settle(window)
        XCTAssertFalse(workspace.terminalMaximized)
        XCTAssertEqual(selected.terminal.bounds.height, normal.height, accuracy: 1)
        XCTAssertGreaterThan(web.bounds.height, 100)
        XCTAssertEqual(doc.text, draft); XCTAssertTrue(doc.dirty)
        // Leaving a maximized panel for terminal mode retains the split tree;
        // returning to files reveals the code and one selected terminal again.
        try press(7, in: window); try await settle(window)
        try press(6, in: window); try await settle(window)
        XCTAssertFalse(workspace.enabled)
        XCTAssertEqual(store.arrangement(in: scope).roots, original.roots)
        XCTAssertEqual(store.arrangement(in: scope).visible, original.visible)
        XCTAssertEqual(sessions.filter { $0.terminal.isDescendant(of: hosting) && !$0.terminal.isHiddenOrHasHiddenAncestor }.count, 3)
        try press(6, in: window); try await settle(window)
        XCTAssertTrue(workspace.enabled); XCTAssertFalse(workspace.terminalMaximized)
        XCTAssertEqual(sessions.filter { $0.terminal.isDescendant(of: hosting) && !$0.terminal.isHiddenOrHasHiddenAncestor }.map(\.id), [selected.id])
        XCTAssertEqual(sessions.map { $0.terminal.process.shellPid }, pids)
        XCTAssertTrue(sessions.allSatisfy { $0.terminal.process.running })
        XCTAssertEqual(doc.text, draft)
    }
    @MainActor func testTopEdgeDragRestoresPriorHeightAndDraggingBackDownRevealsEditor() async throws {
        let (store, prefs, doc) = try fixture(); defer { store.shutdown() }
        store.openWorkspaceTerminal(); store.toggleFiles()
        let workspace = store.currentFiles, session = try XCTUnwrap(store.activeSession)
        let window = window(store, prefs); defer { window.contentView = nil; window.close() }
        try await settle(window)
        let normalHeight = session.terminal.bounds.height
        // Exercise the exact resize action shared by pointer and accessibility
        // drags. At the top it retains the ratio from the start of the gesture.
        let originalRatio = prefs.double(forKey: "editorHeightRatio")
        prefs.set(workspace.resizeTerminalPanel(editorHeight: 5, totalHeight: 700, startingRatio: originalRatio), forKey: "editorHeightRatio")
        try await settle(window)
        XCTAssertTrue(workspace.terminalMaximized)
        XCTAssertGreaterThan(session.terminal.bounds.height, normalHeight + 300)
        XCTAssertEqual(prefs.double(forKey: "editorHeightRatio"), originalRatio)
        try press(7, in: window); try await settle(window)
        XCTAssertFalse(workspace.terminalMaximized)
        XCTAssertEqual(session.terminal.bounds.height, normalHeight, accuracy: 1)
        prefs.set(workspace.resizeTerminalPanel(editorHeight: -500, totalHeight: 700, startingRatio: originalRatio), forKey: "editorHeightRatio")
        try await settle(window)
        XCTAssertTrue(workspace.terminalMaximized)
        prefs.set(workspace.resizeTerminalPanel(editorHeight: 10, totalHeight: 700, startingRatio: originalRatio), forKey: "editorHeightRatio")
        try await settle(window)
        XCTAssertFalse(workspace.terminalMaximized, "One accessible increment must leave the top snap zone")
        prefs.set(workspace.resizeTerminalPanel(editorHeight: 260, totalHeight: 700, startingRatio: originalRatio), forKey: "editorHeightRatio")
        try await settle(window)
        XCTAssertFalse(workspace.terminalMaximized)
        XCTAssertGreaterThan(try XCTUnwrap(doc.editor?.web).bounds.height, 150)
        let restoredRatio = prefs.double(forKey: "editorHeightRatio")
        try press(7, in: window); try await settle(window)
        await workspace.open(doc.entry)
        try await settle(window)
        XCTAssertFalse(workspace.terminalMaximized, "Selecting a file must reveal it")
        XCTAssertEqual(prefs.double(forKey: "editorHeightRatio"), restoredRatio)
        XCTAssertTrue(doc.dirty); XCTAssertTrue(session.terminal.process.running)
    }
    @MainActor func testEmptyAndHiddenTerminalPanelsCanMaximizeWithoutStartingConnections() async throws {
        let (store, prefs, _) = try fixture(); defer { store.shutdown() }
        store.toggleFiles(); let workspace = store.currentFiles
        workspace.documents = []; workspace.selection = nil
        let window = window(store, prefs); defer { window.contentView = nil; window.close() }
        try await settle(window)
        workspace.terminalVisible = false
        try await settle(window)
        try press(7, in: window); try await settle(window)
        XCTAssertTrue(workspace.terminalVisible); XCTAssertTrue(workspace.terminalMaximized)
        XCTAssertEqual(workspace.focusArea, .terminal); XCTAssertTrue(store.sessions.isEmpty)
        try snapshot(window, name: "empty-terminal-maximized")
        store.toggleTerminalPanel(); try await settle(window)
        XCTAssertFalse(workspace.terminalVisible); XCTAssertFalse(workspace.terminalMaximized)
        XCTAssertEqual(workspace.focusArea, .editor)
        try press(7, in: window); try await settle(window)
        XCTAssertTrue(workspace.terminalVisible); XCTAssertTrue(workspace.terminalMaximized)
        XCTAssertTrue(store.sessions.isEmpty)
        let other = ServerProfile(name: "Other", host: "other.example.invalid")
        store.profiles = [other]; store.selectWorkspace(other.id)
        XCTAssertFalse(store.currentFiles.terminalMaximized, "Maximizing one server must not change another")
        store.selectWorkspace(nil)
        XCTAssertTrue(store.currentFiles.terminalMaximized)
    }
}
