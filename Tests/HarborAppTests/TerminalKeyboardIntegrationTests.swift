import XCTest
import AppKit
import SwiftUI
import HarborCore
@testable import HarborSSH

final class TerminalKeyboardIntegrationTests: XCTestCase {
    @MainActor private func fixture() throws -> (AppStore, UserDefaults) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-keys-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "app.harbor.keys." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        addTeardownBlock { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = AppStore(historyRoot: root.appendingPathComponent("data"), workspaceDefaults: prefs)
        try store.history.prepare(); store.loading = false; store.selectWorkspace(nil)
        store.currentFiles.root = root.path; store.currentFiles.entries[root.path] = []
        prefs.set(52.0, forKey: "sidebarWidth"); prefs.set(30.0, forKey: "headerHeight")
        return (store, prefs)
    }
    @MainActor private func window<V: View>(_ view: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: 760), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = NSHostingView(rootView: view)
        return window
    }
    @MainActor private func settle(_ window: NSWindow) async throws {
        try await Task.sleep(nanoseconds: 140_000_000); window.contentView?.layoutSubtreeIfNeeded()
    }
    @MainActor private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }
    @MainActor private func event(_ code: UInt16, _ window: NSWindow, flags: NSEvent.ModifierFlags = [], repeatKey: Bool = false, type: NSEvent.EventType = .keyDown) throws -> NSEvent {
        let characters: [UInt16: String] = [123: "\u{f702}", 124: "\u{f703}", 125: "\u{f701}", 126: "\u{f700}", 51: "\u{7f}", 36: "\r", 53: "\u{1b}", 18: "1", 19: "2", 20: "3", 25: "9", 50: "~", 7: "≈"]
        return try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters[code] ?? "", charactersIgnoringModifiers: characters[code] ?? "", isARepeat: repeatKey, keyCode: code))
    }
    @MainActor private func press(_ code: UInt16, _ window: NSWindow, flags: NSEvent.ModifierFlags = [], repeatKey: Bool = false) throws {
        NSApp.sendEvent(try event(code, window, flags: flags, repeatKey: repeatKey))
    }
    @MainActor func testListSelectionAndArrowNavigationKeepFocusAndPreserveLiveSplitGroups() async throws {
        let (store, prefs) = try fixture(); defer { store.shutdown() }
        store.openWorkspaceTerminal(); let first = try XCTUnwrap(store.activeSession)
        store.splitTerminal(.columns); let second = try XCTUnwrap(store.activeSession)
        store.splitTerminal(.rows); let third = try XCTUnwrap(store.activeSession)
        store.openWorkspaceTerminal(); let fourth = try XCTUnwrap(store.activeSession)
        let sessions = [first, second, third, fourth], pids = sessions.map { $0.terminal.process.shellPid }
        let scope = store.currentTerminalScope, layout = store.arrangement(in: scope)
        store.toggleFiles()
        let window = window(ContentView().environmentObject(store).defaultAppStorage(prefs))
        defer { window.contentView = nil; window.close() }
        try await settle(window)
        let list = try XCTUnwrap(find(TerminalListKeyView.self, in: window.contentView!))
        // Use the row's selection handler; offscreen SwiftUI windows do not
        // publish an accessibility tree. Subsequent keys use real app dispatch.
        list.select(first)
        try await settle(window)
        XCTAssertEqual(store.activeSession?.id, first.id); XCTAssertTrue(window.firstResponder === list)
        // Includes both horizontal and vertical keys, a held-key repeat, and
        // boundaries. List order crosses groups without flattening split trees.
        for (code, expected, repeating): (UInt16, TerminalSession, Bool) in [
            (123, first, false), (125, second, false), (125, third, true),
            (124, fourth, false), (125, fourth, false), (126, third, false), (123, second, false)
        ] {
            try press(code, window, repeatKey: repeating); try await settle(window)
            XCTAssertEqual(store.activeSession?.id, expected.id)
            XCTAssertTrue(window.firstResponder === list, "Native terminal stole list focus")
            XCTAssertEqual(store.currentFiles.focusArea, .terminalList)
            let visible = sessions.filter { $0.terminal.isDescendant(of: window.contentView!) && !$0.terminal.isHiddenOrHasHiddenAncestor }
            XCTAssertEqual(visible.map(\.id), [expected.id])
            XCTAssertEqual(store.arrangement(in: scope).roots, layout.roots)
        }
        try press(53, window); try await settle(window)
        XCTAssertTrue(window.firstResponder === second.terminal)
        let handler = try XCTUnwrap(find(ModeShortcutView.self, in: window.contentView!))
        for code: UInt16 in [123, 124, 125, 126] {
            XCTAssertNotNil(handler.handle(try event(code, window)), "Shell cursor/history keys must pass through")
        }
        list.select(third); try await settle(window)
        window.makeFirstResponder(third.terminal); try await settle(window)
        XCTAssertEqual(store.currentFiles.focusArea, .terminal)
        XCTAssertNotNil(handler.handle(try event(125, window)))
        store.toggleFiles(); try await settle(window)
        XCTAssertEqual(store.arrangement(in: scope).visible, layout.groups[0].layout)
        XCTAssertEqual(sessions.map { $0.terminal.process.shellPid }, pids)
        XCTAssertTrue(sessions.allSatisfy { $0.terminal.process.running })
    }

    @MainActor func testEnterRenamesSelectedRowAndEscapeStillReturnsToShell() async throws {
        let (store, prefs) = try fixture(); defer { store.shutdown() }
        store.openWorkspaceTerminal(); let first = try XCTUnwrap(store.activeSession)
        store.openWorkspaceTerminal(); let second = try XCTUnwrap(store.activeSession)
        let pids = store.sessions.map { $0.terminal.process.shellPid }
        store.toggleFiles()
        let window = window(ContentView().environmentObject(store).defaultAppStorage(prefs))
        defer { window.contentView = nil; window.close() }
        try await settle(window)
        let list = try XCTUnwrap(find(TerminalListKeyView.self, in: window.contentView!))
        let handler = try XCTUnwrap(find(ModeShortcutView.self, in: window.contentView!))
        list.select(first); try await settle(window)
        var dialogs = 0
        let timer = Timer(timeInterval: 0.03, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let modal = NSApp.modalWindow, let content = modal.contentView else { return }
                func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                let views = descendants(content)
                guard let field = views.compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable }) else { return }
                dialogs += 1
                XCTAssertEqual(field.stringValue, dialogs == 1 ? first.tabTitle : second.tabTitle)
                field.stringValue = "训练 / Train 训练长名称"
                guard let button = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == (dialogs == 1 ? "Save" : "Cancel") }) else {
                    XCTFail("Expected an English Save / Cancel button"); NSApp.abortModal(); return
                }
                button.performClick(nil)
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel); defer { timer.invalidate() }
        try press(36, window); try await settle(window)
        XCTAssertEqual(first.customTitle, "训练 / Train 训练长名称"); XCTAssertNil(second.customTitle)
        XCTAssertTrue(window.firstResponder === list)
        XCTAssertEqual(dialogs, 1)
        XCTAssertNil(handler.handle(try event(36, window, repeatKey: true)))
        XCTAssertEqual(dialogs, 1, "Held Return cannot reopen the dialog")
        _ = handler.handle(try event(36, window, type: .keyUp))
        try press(125, window); try await settle(window)
        try press(76, window); try await settle(window)
        XCTAssertEqual(dialogs, 2); XCTAssertNil(second.customTitle, "Cancel must keep the old name")
        XCTAssertTrue(window.firstResponder === list)
        try press(53, window); try await settle(window)
        XCTAssertTrue(window.firstResponder === second.terminal)
        XCTAssertNotNil(handler.handle(try event(36, window)), "Shell Return must remain a shell key")
        XCTAssertEqual(store.sessions.map { $0.terminal.process.shellPid }, pids)
        XCTAssertTrue(store.sessions.allSatisfy { $0.terminal.process.running })
    }

    @MainActor func testCommandNumbersSwitchGroupsAndRestoreTheSelectedSplitPane() async throws {
        let (store, prefs) = try fixture(); defer { store.shutdown() }
        store.openWorkspaceTerminal(); let first = try XCTUnwrap(store.activeSession)
        store.splitTerminal(.columns); let second = try XCTUnwrap(store.activeSession)
        store.splitTerminal(.rows); let third = try XCTUnwrap(store.activeSession)
        store.activateTerminal(second)
        store.openWorkspaceTerminal(); let independent = try XCTUnwrap(store.activeSession)
        let scope = store.currentTerminalScope, original = store.arrangement(in: scope)
        let pids = store.sessions.map { $0.terminal.process.shellPid }
        let window = window(ContentView().environmentObject(store).defaultAppStorage(prefs))
        defer { window.contentView = nil; window.close() }
        try await settle(window)
        for (code, selected): (UInt16, TerminalSession) in [(18, second), (19, independent), (18, second), (25, second)] {
            try press(code, window, flags: .command); try await settle(window)
            XCTAssertEqual(store.activeSession?.id, selected.id)
            XCTAssertTrue(window.firstResponder === selected.terminal)
            XCTAssertEqual(store.arrangement(in: scope).roots, original.roots)
            XCTAssertEqual(store.arrangement(in: scope).groups.map(\.id), original.groups.map(\.id))
        }
        XCTAssertEqual(store.arrangement(in: scope).visible?.sessionIDs, [first.id, second.id, third.id])
        XCTAssertEqual(store.sessions.map { $0.terminal.process.shellPid }, pids)
        let handler = try XCTUnwrap(find(ModeShortcutView.self, in: window.contentView!))
        XCTAssertNotNil(handler.handle(try event(18, window, flags: [.command, .shift])))
        store.toggleFiles(); try await settle(window)
        XCTAssertNotNil(handler.handle(try event(19, window, flags: .command)), "File mode must not use group-number navigation")
        XCTAssertEqual(store.activeSession?.id, second.id)
        store.page = .recent
        XCTAssertNotNil(handler.handle(try event(18, window, flags: .command)))
    }

    @MainActor func testCommandDeleteClosesOnlySelectedPaneAndNeverConsumesEditorKeys() async throws {
        let (store, prefs) = try fixture(); defer { store.shutdown() }
        store.openWorkspaceTerminal(); let first = try XCTUnwrap(store.activeSession)
        store.splitTerminal(.columns); let second = try XCTUnwrap(store.activeSession)
        store.openWorkspaceTerminal(); let independent = try XCTUnwrap(store.activeSession)
        let scope = store.currentTerminalScope
        let groups = store.arrangement(in: scope).groups.map(\.id)
        store.toggleFiles()
        let window = window(ContentView().environmentObject(store).defaultAppStorage(prefs))
        defer { window.contentView = nil; window.close() }
        try await settle(window)
        let list = try XCTUnwrap(find(TerminalListKeyView.self, in: window.contentView!))
        let handler = try XCTUnwrap(find(ModeShortcutView.self, in: window.contentView!))
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 120, height: 30))
        window.contentView!.addSubview(text); text.string = "keep this draft"; window.makeFirstResponder(text)
        XCTAssertNotNil(handler.handle(try event(51, window, flags: .command)))
        XCTAssertNotNil(handler.handle(try event(125, window)))
        XCTAssertEqual(store.sessions.count, 3)
        list.select(second); try await settle(window)
        // End only the fixture target first, so the normal production close
        // confirmation is skipped without any test-only behavior in the app.
        second.stop(); try press(51, window, flags: .command); try await settle(window)
        XCTAssertEqual(store.sessions.map(\.id), [first.id, independent.id])
        XCTAssertTrue(window.firstResponder === list)
        XCTAssertEqual(store.activeSession?.id, first.id)
        XCTAssertEqual(store.arrangement(in: scope).groups.map(\.id), groups)
        XCTAssertTrue(first.terminal.process.running); XCTAssertTrue(independent.terminal.process.running)
        try press(51, window, flags: .command, repeatKey: true)
        XCTAssertEqual(store.sessions.count, 2, "Holding Delete must not close a second terminal")
        try press(125, window); try await settle(window)
        XCTAssertEqual(store.activeSession?.id, independent.id)
        store.toggleFiles(); try await settle(window)
        first.stop(); store.activateTerminalGroup(groups[0], in: scope); try await settle(window)
        XCTAssertTrue(window.firstResponder === first.terminal)
        try press(51, window, flags: .command); try await settle(window)
        XCTAssertEqual(store.sessions.map(\.id), [independent.id])
        XCTAssertTrue(independent.terminal.process.running)
        independent.stop(); try press(51, window, flags: .command); try await settle(window)
        XCTAssertTrue(store.sessions.isEmpty)
        window.makeFirstResponder(text)
        XCTAssertNil(handler.handle(try event(51, window, flags: .command, repeatKey: true)), "Held Delete leaked into the editor after closing the last terminal")
        _ = handler.handle(try event(51, window, flags: .command, type: .keyUp))
        XCTAssertNotNil(handler.handle(try event(51, window, flags: .command)))
        XCTAssertEqual(text.string, "keep this draft")
    }

    @MainActor func testNumberAndCloseShortcutsStayInTheirDetachedWindow() async throws {
        let (store, prefs) = try fixture(); defer { store.shutdown() }
        store.openWorkspaceTerminal(); store.splitTerminal(.columns)
        let main = store.arrangement(in: store.currentTerminalScope)
        let id = try XCTUnwrap(store.openTerminal(nil, detached: true)), scope = TerminalScope.window(id)
        let first = try XCTUnwrap(store.selectedTerminal(in: scope))
        store.splitTerminal(.rows, session: first)
        let second = try XCTUnwrap(store.selectedTerminal(in: scope))
        store.openIndependentTerminal(in: scope)
        let independent = try XCTUnwrap(store.selectedTerminal(in: scope))
        let window = window(TerminalWindowView(windowID: id).environmentObject(store).defaultAppStorage(prefs))
        defer { window.contentView = nil; window.close() }
        try await settle(window)
        try press(18, window, flags: .command); try await settle(window)
        XCTAssertEqual(store.selectedTerminal(in: scope)?.id, second.id)
        XCTAssertTrue(window.firstResponder === second.terminal)
        XCTAssertEqual(store.arrangement(in: scope).visible?.sessionIDs, [first.id, second.id])
        second.stop(); try press(51, window, flags: .command); try await settle(window)
        XCTAssertEqual(store.terminalSessions(in: scope).map(\.id), [first.id, independent.id])
        XCTAssertTrue(window.firstResponder === first.terminal)
        try press(19, window, flags: .command); try await settle(window)
        XCTAssertTrue(window.firstResponder === independent.terminal)
        XCTAssertEqual(store.arrangement(in: store.currentTerminalScope), main)
        XCTAssertTrue(store.sessions.allSatisfy { $0.terminal.process.running })
        let handler = try XCTUnwrap(find(ModeShortcutView.self, in: window.contentView!))
        let other = self.window(Text("Unrelated window"))
        defer { other.contentView = nil; other.close() }
        XCTAssertNotNil(handler.handle(try event(51, other, flags: .command)))
    }
}
