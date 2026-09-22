import XCTest
import AppKit
import SwiftUI
import HarborCore
@testable import HarborSSH

final class TerminalDragIntegrationTests: XCTestCase {
    @MainActor private func fixture() throws -> (AppStore, UserDefaults) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-drag-" + UUID().uuidString)
        let suite = "app.harbor.drag." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        let store = AppStore(historyRoot: root, workspaceDefaults: prefs)
        try store.history.prepare(); store.loading = false; store.selectWorkspace(nil)
        store.currentFiles.root = root.path; store.currentFiles.entries[root.path] = []
        addTeardownBlock { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        return (store, prefs)
    }
    @MainActor private func drag(_ source: HarborDragSource, store: AppStore, onto target: HarborDropTarget, intent: HarborDropIntent) async throws {
        let provider = store.dragProvider(source)
        XCTAssertFalse(provider.hasItemConformingToTypeIdentifier("public.file-url"))
        XCTAssertFalse(provider.hasItemConformingToTypeIdentifier("public.utf8-plain-text"))
        let decoded = try await HarborDragItem.read(provider, type: source.type)
        XCTAssertTrue(store.canDrop(decoded, on: target, intent: intent))
        XCTAssertTrue(store.applyDrop(decoded, on: target, intent: intent))
        XCTAssertFalse(store.applyDrop(decoded, on: target, intent: intent), "A consumed drag cannot execute again")
    }
    @MainActor private func settle(_ window: NSWindow) async throws {
        try await Task.sleep(nanoseconds: 250_000_000); window.contentView?.layoutSubtreeIfNeeded()
    }
    @MainActor func testDraggedGroupsAndRowsKeepLiveProcessesAndRestoreAcrossModes() async throws {
        let (store, prefs) = try fixture(); defer { store.shutdown() }
        store.openWorkspaceTerminal(); let first = try XCTUnwrap(store.activeSession)
        store.splitTerminal(.columns); let second = try XCTUnwrap(store.activeSession)
        let scope = store.currentTerminalScope, original = store.arrangement(in: scope)
        let groupID = try XCTUnwrap(original.selectedGroup?.id)
        store.openWorkspaceTerminal(); let third = try XCTUnwrap(store.activeSession)
        let newGroup = try XCTUnwrap(store.arrangement(in: scope).selectedGroup?.id)
        let pids = store.sessions.map { $0.terminal.process.shellPid }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView().environmentObject(store).defaultAppStorage(prefs))
        defer { window.contentView = nil; window.close() }
        try await settle(window)
        try await drag(.group(newGroup, scope), store: store, onto: .group(groupID, scope), intent: .before)
        XCTAssertEqual(store.arrangement(in: scope).groups.map(\.id), [newGroup, groupID])
        XCTAssertEqual(store.arrangement(in: scope).groups.last?.layout, original.visible)
        store.toggleFiles(); try await settle(window)
        try await drag(.terminal(second.id, scope), store: store, onto: .list(third.id, scope), intent: .before)
        try await settle(window)
        XCTAssertEqual(store.arrangement(in: scope).sessionIDs, [second.id, third.id, first.id])
        XCTAssertEqual(store.arrangement(in: scope).groups.first?.layout, original.visible)
        let visible = store.sessions.filter { $0.terminal.isDescendant(of: window.contentView!) && !$0.terminal.isHiddenOrHasHiddenAncestor }
        XCTAssertEqual(visible.map(\.id), [second.id], "The editor still shows just the selected terminal")
        store.toggleFiles(); try await settle(window)
        try await drag(.group(newGroup, scope), store: store, onto: .pane(second.id, scope), intent: .split(.rows, before: false))
        try await settle(window)
        let merged = store.arrangement(in: scope)
        XCTAssertEqual(merged.groups.count, 1); XCTAssertEqual(merged.selectedGroup?.id, groupID)
        XCTAssertEqual(merged.visible?.sessionIDs, [first.id, second.id, third.id])
        for _ in 0..<3 {
            store.toggleFiles(); try await settle(window)
            XCTAssertEqual(store.sessions.filter { $0.terminal.isDescendant(of: window.contentView!) && !$0.terminal.isHiddenOrHasHiddenAncestor }.map(\.id), [third.id])
            store.toggleFiles(); try await settle(window)
            XCTAssertEqual(store.arrangement(in: scope), merged)
        }
        XCTAssertEqual(store.sessions.map { $0.terminal.process.shellPid }, pids)
        XCTAssertTrue(store.sessions.allSatisfy { $0.terminal.process.running })
        XCTAssertEqual(store.sessions.filter { $0.terminal.isDescendant(of: window.contentView!) && !$0.terminal.isHiddenOrHasHiddenAncestor }.count, 3)
    }

    @MainActor func testServerOrderIsSavedWithoutChangingProfilesOrSelection() async throws {
        let (store, _) = try fixture(); defer { store.shutdown() }
        let a = ServerProfile(name: "A", host: "a.invalid"), b = ServerProfile(name: "B", host: "b.invalid"), c = ServerProfile(name: "C", host: "c.invalid")
        store.profiles = [a, b, c]; store.selectWorkspace(b.id)
        let files = store.currentFiles
        try await drag(.server(c.id), store: store, onto: .server(a.id), intent: .before)
        XCTAssertEqual(store.profiles, [c, a, b]); XCTAssertEqual(store.selectedProfileID, b.id)
        XCTAssertTrue(store.currentFiles === files)
        let restored = try store.history.read("servers.json", as: [ServerProfile].self)
        XCTAssertEqual(restored, [c, a, b])
        try await drag(.server(c.id), store: store, onto: .server(b.id), intent: .after)
        XCTAssertEqual(store.profiles, [a, b, c]); XCTAssertEqual(store.selectedProfileID, b.id)
        XCTAssertTrue(store.sessions.isEmpty)
    }

    @MainActor func testStaleForeignRemovedAndCrossScopeDragsDoNotMutateAnything() async throws {
        let (store, _) = try fixture(); defer { store.shutdown() }
        store.openWorkspaceTerminal(); let first = try XCTUnwrap(store.activeSession)
        store.openWorkspaceTerminal(); let second = try XCTUnwrap(store.activeSession)
        let scope = store.currentTerminalScope, before = store.arrangement(in: scope)
        let source = HarborDragSource.terminal(first.id, scope)
        let provider = store.dragProvider(source), item = try await HarborDragItem.read(provider, type: source.type)
        let target = HarborDropTarget.list(second.id, scope)
        let detached = try XCTUnwrap(store.openTerminal(nil, detached: true))
        XCTAssertFalse(store.applyDrop(item, on: .pane(detached, .window(detached)), intent: .split(.columns, before: false)))
        XCTAssertFalse(store.applyDrop(item, on: .list(UUID(), scope), intent: .after))
        let foreign = HarborDragItem(owner: UUID(), nonce: item.nonce, source: item.source)
        XCTAssertFalse(store.applyDrop(foreign, on: target, intent: .after))
        _ = store.dragProvider(source)
        XCTAssertFalse(store.applyDrop(item, on: target, intent: .after), "A canceled drag is invalid after a new drag begins")
        XCTAssertEqual(store.arrangement(in: scope), before)
        let current = try XCTUnwrap(store.activeDrag)
        store.close(first, ask: false)
        let afterClosing = store.arrangement(in: scope)
        XCTAssertFalse(store.applyDrop(current, on: target, intent: .after))
        XCTAssertEqual(store.arrangement(in: scope), afterClosing)
        let invalid = NSItemProvider(item: Data("not a drag".utf8) as NSData, typeIdentifier: source.type)
        do { _ = try await HarborDragItem.read(invalid, type: source.type); XCTFail("Malformed payload accepted") } catch {}
    }

    func testDropZonesSeparateReorderingFromMergingEvenForIconTabs() {
        let target = HarborDropTarget.group(UUID(), .workspace(nil))
        for width: CGFloat in [40, 150, 360] {
            let size = CGSize(width: width, height: 32)
            XCTAssertEqual(target.intent(at: CGPoint(x: 1, y: 16), size: size), .before)
            XCTAssertEqual(target.intent(at: CGPoint(x: width - 1, y: 16), size: size), .after)
            XCTAssertEqual(target.intent(at: CGPoint(x: width / 2, y: 16), size: size), .split(.columns, before: false))
        }
        let pane = HarborDropTarget.pane(UUID(), .workspace(nil)), size = CGSize(width: 300, height: 600)
        XCTAssertEqual(pane.intent(at: CGPoint(x: 150, y: 1), size: size), .split(.rows, before: true))
        XCTAssertEqual(pane.intent(at: CGPoint(x: 150, y: 599), size: size), .split(.rows, before: false))
        XCTAssertEqual(pane.intent(at: CGPoint(x: 1, y: 300), size: size), .split(.columns, before: true))
        XCTAssertEqual(pane.intent(at: CGPoint(x: 299, y: 300), size: size), .split(.columns, before: false))
    }
}
