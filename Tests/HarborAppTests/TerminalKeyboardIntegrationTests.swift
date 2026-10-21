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
        let suite = "app.harbor.keys." + UUID().uuidString, prefs = TestDefaults.suite(suite)!
        addTeardownBlock { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = AppStore(historyRoot: root.appendingPathComponent("data"), workspaceDefaults: prefs)
        try store.history.prepare(); store.loading = false; store.selectWorkspace(nil)
        store.currentFiles.root = root.path
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

    @MainActor func testNumberAndCloseShortcutsStayInTheirDetachedWindow() async throws {
        let (store, prefs) = try fixture(); defer { store.shutdown() }
        store.openTerminal(store.selectedProfile); store.splitTerminal(.columns)
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
