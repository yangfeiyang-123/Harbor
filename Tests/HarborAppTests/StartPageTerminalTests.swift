import XCTest
import AppKit
import HarborCore
@testable import HarborSSH

/// Start page ▸ New Terminal is a shell filling the window: Harbor's own terminal, with no
/// editor, folder or server behind it. It is split and given tabs with the keys of any terminal.
final class StartPageTerminalTests: XCTestCase {
    @MainActor private func fixture() throws -> (AppStore, UserDefaults) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-start-" + UUID().uuidString)
        let suite = "app.harbor.start." + UUID().uuidString, prefs = TestDefaults.suite(suite)!
        addTeardownBlock { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = AppStore(historyRoot: root.appendingPathComponent("data"), workspaceDefaults: prefs)
        try store.history.prepare(); store.loading = false
        return (store, prefs)
    }

    @MainActor func testNewTerminalOnTheStartPageIsOnePlainShell() async throws {
        let (store, _) = try fixture(); defer { store.shutdown() }
        XCTAssertEqual(store.page, .recent); XCTAssertNil(store.homeTerminal)
        store.openHomeTerminal(nil)
        XCTAssertEqual(store.page, .terminal, "the start page gives way to the terminal")
        let shell = try XCTUnwrap(store.homeTerminal)
        XCTAssertNil(shell.profile); XCTAssertEqual(shell.workingDirectory, NSHomeDirectory())
        XCTAssertTrue(store.isHomeTerminal(shell)); XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.windowTitle, LocalMachine.name + " · Terminal")
        XCTAssertNil(store.codeWorkbench.existing(for: store.currentFiles), "no editor is started for it")
        XCTAssertTrue(store.recents.isEmpty, "a plain terminal is not a folder that was opened")
        XCTAssertEqual(store.currentTerminalScope, store.terminalScope(of: shell), "its keys go to it")
        // Asking again returns to the same shell, from the start page or while it is on screen.
        store.page = .recent
        store.openHomeTerminal(nil)
        XCTAssertTrue(store.homeTerminal === shell); XCTAssertEqual(store.sessions.count, 1); XCTAssertEqual(store.page, .terminal)
        // It is not written to the saved terminals: at the next launch it would open as a window of its own.
        XCTAssertTrue(store.checkpointTerminals(synchronously: true))
        let saved = try store.recoveryStore.load().0
        XCTAssertEqual(saved?.terminals.count ?? 0, 0); XCTAssertEqual(saved?.layouts.count ?? 0, 0)
        // Closing it gives the window back to the start page, and the next request starts a new shell.
        store.close(shell, ask: false)
        XCTAssertEqual(store.page, .recent); XCTAssertNil(store.homeTerminal); XCTAssertTrue(store.sessions.isEmpty)
        store.openHomeTerminal(nil)
        let second = try XCTUnwrap(store.homeTerminal)
        XCTAssertFalse(second === shell); XCTAssertEqual(store.page, .terminal)
        store.close(second, ask: false)
    }

    @MainActor func testThePlainTerminalIsSplitAndGivenTabsWithItsKeys() async throws {
        let (store, _) = try fixture(); defer { store.shutdown() }
        store.openHomeTerminal(nil)
        let first = try XCTUnwrap(store.homeTerminal), scope = store.currentTerminalScope
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags, in target: TerminalScope? = nil) throws -> Bool {
            store.handleTerminalKey(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)), in: target ?? scope)
        }
        func shape(_ layout: TerminalLayout?) -> String {
            switch layout {
            case nil: return "-"
            case .terminal: return "•"
            case .split(_, let axis, _, let a, let b): return "(" + shape(a) + (axis == .columns ? " | " : " / ") + shape(b) + ")"
            }
        }
        var layout: TerminalArrangement { store.arrangement(in: scope) }
        func pane() -> Int? { layout.visible?.sessionIDs.firstIndex { $0 == layout.selectedID } }

        // ⌘D puts a pane to the right, ⇧⌘D one under the pane in use. Each starts where that pane is.
        XCTAssertTrue(try key(2, .command))
        XCTAssertEqual(shape(layout.visible), "(• | •)"); XCTAssertEqual(store.sessions.count, 2); XCTAssertEqual(pane(), 1, "the new pane is the one in use")
        XCTAssertTrue(try key(2, [.command, .shift]))
        XCTAssertEqual(shape(layout.visible), "(• | (• / •))"); XCTAssertEqual(pane(), 2)
        XCTAssertTrue(store.sessions.allSatisfy { store.isHomeTerminal($0) && $0.profile == nil }); XCTAssertEqual(store.page, .terminal)
        XCTAssertEqual(store.windowTitle, LocalMachine.name + " · Terminal")
        // ⌥⌘ with an arrow goes to the pane before or after, around at the ends.
        XCTAssertTrue(try key(123, [.command, .option])); XCTAssertEqual(pane(), 1)
        XCTAssertTrue(try key(126, [.command, .option])); XCTAssertEqual(pane(), 0)
        XCTAssertTrue(try key(123, [.command, .option])); XCTAssertEqual(pane(), 2, "before the first is the last")
        XCTAssertTrue(try key(124, [.command, .option])); XCTAssertEqual(pane(), 0)
        XCTAssertTrue(store.homeTerminal === first)
        // ⌘T is a further tab; ⇧⌘[ and ⇧⌘] go between the tabs.
        XCTAssertTrue(try key(17, .command))
        XCTAssertEqual(layout.groups.map(\.sessionIDs.count), [3, 1]); XCTAssertEqual(shape(layout.visible), "•"); XCTAssertEqual(store.sessions.count, 4)
        XCTAssertTrue(try key(33, [.command, .shift])); XCTAssertEqual(shape(layout.visible), "(• | (• / •))"); XCTAssertTrue(store.homeTerminal === first, "a tab comes back on the pane that was in use")
        XCTAssertTrue(try key(30, [.command, .shift])); XCTAssertEqual(shape(layout.visible), "•")
        XCTAssertTrue(try key(30, [.command, .shift])); XCTAssertEqual(shape(layout.visible), "(• | (• / •))", "after the last tab is the first")
        // The bar's buttons and the menu do the same.
        store.openIndependentTerminal(); XCTAssertEqual(layout.groups.count, 3)
        store.splitTerminal(.rows, session: store.homeTerminal); XCTAssertEqual(shape(layout.visible), "(• / •)")
        // Asking for the terminal again from the start page returns to all of it.
        store.page = .recent; store.openHomeTerminal(nil)
        XCTAssertEqual(store.page, .terminal); XCTAssertEqual(store.sessions.count, 6); XCTAssertEqual(layout.groups.count, 3)
        // None of it is saved: at the next launch these would open as windows of their own.
        XCTAssertTrue(store.checkpointTerminals(synchronously: true))
        XCTAssertEqual(try store.recoveryStore.load().0?.terminals.count ?? 0, 0)
        // ⌘W closes the pane in use, after asking as for any running terminal. Declined, the pane stays.
        var asked = 0, answer = false
        store.confirmClose = { _ in asked += 1; return answer }
        XCTAssertTrue(try key(13, .command)); XCTAssertEqual(asked, 1); XCTAssertEqual(store.sessions.count, 6)
        answer = true
        // The page stays while a terminal is left.
        for left in stride(from: 5, through: 1, by: -1) {
            let closing = try XCTUnwrap(store.homeTerminal)
            XCTAssertTrue(try key(13, .command))
            XCTAssertEqual(store.sessions.count, left); XCTAssertFalse(store.sessions.contains { $0 === closing }); XCTAssertEqual(store.page, .terminal)
        }
        XCTAssertTrue(try key(13, .command)); XCTAssertEqual(asked, 7)
        XCTAssertEqual(store.page, .recent, "the last one gives the window back to the start page"); XCTAssertTrue(store.sessions.isEmpty)
        // In the editor these keys are the editor's: a workspace's terminals do not take them.
        for (code, flags) in [(UInt16(2), NSEvent.ModifierFlags.command), (17, .command), (13, .command), (2, [.command, .shift]), (123, [.command, .option]), (33, [.command, .shift])] {
            XCTAssertFalse(try key(code, flags, in: .workspace(nil)))
        }
    }
    func testTheKeysOfATerminalThatFillsItsPage() throws {
        func command(_ code: UInt16, _ flags: NSEvent.ModifierFlags) -> TerminalKeyboardCommand? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)
                .flatMap(TerminalKeyboardCommand.matching)
        }
        XCTAssertEqual(command(2, .command), .split(.columns)); XCTAssertEqual(command(2, [.command, .shift]), .split(.rows))
        XCTAssertEqual(command(17, .command), .newTab); XCTAssertEqual(command(13, .command), .closePane)
        XCTAssertEqual(command(123, [.command, .option]), .pane(-1)); XCTAssertEqual(command(125, [.command, .option]), .pane(1))
        XCTAssertEqual(command(33, [.command, .shift]), .tab(-1)); XCTAssertEqual(command(30, [.command, .shift]), .tab(1))
        // What is typed into the shell stays the shell's.
        XCTAssertNil(command(2, [])); XCTAssertNil(command(2, .control)); XCTAssertNil(command(13, .control)); XCTAssertNil(command(123, .option))
        XCTAssertEqual(command(51, .command), .close); XCTAssertEqual(command(18, .command), .group(0))
    }

    @MainActor func testExitInThePlainShellReturnsToTheStartPage() async throws {
        let (store, _) = try fixture(); defer { store.shutdown() }
        store.openHomeTerminal(nil)
        let shell = try XCTUnwrap(store.homeTerminal)
        // The shell ends on its own, as after `exit`.
        store.finish(shell, code: 0)
        for _ in 0..<50 where store.page == .terminal { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(store.page, .recent); XCTAssertTrue(store.sessions.isEmpty)
        // One that failed stays on screen to say why.
        store.openHomeTerminal(nil)
        let failed = try XCTUnwrap(store.homeTerminal)
        store.finish(failed, code: 127)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(store.page, .terminal); XCTAssertTrue(store.homeTerminal === failed)
        store.close(failed, ask: false)
    }
}
