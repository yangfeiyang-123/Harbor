import XCTest
import AppKit
import SwiftUI
@testable import HarborSSH

final class WorkbenchChromeTests: XCTestCase {
    @MainActor func testHoverReentryCancelsCollapseAndPopoverKeepsControlsReachable() async throws {
        let visibility = WorkbenchToolbarVisibility()
        defer { visibility.reset() }
        XCTAssertFalse(visibility.revealed)
        visibility.setHovered(true)
        XCTAssertTrue(visibility.revealed, "Entering the title bar must reveal controls immediately")
        visibility.setHovered(false)
        try await Task.sleep(nanoseconds: 50_000_000)
        visibility.setHovered(true)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(visibility.revealed, "A stale leave task must not hide controls under the pointer")
        visibility.setPopoverPresented(true)
        visibility.setHovered(false)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(visibility.revealed, "Moving into the folder picker must preserve its visible anchor")
        visibility.setPopoverPresented(false)
        try await Task.sleep(nanoseconds: 220_000_000)
        XCTAssertFalse(visibility.revealed)
    }

    @MainActor func testNestedMenusKeepToolbarVisibleUntilTheLastMenuCloses() async throws {
        let visibility = WorkbenchToolbarVisibility()
        defer { visibility.reset() }
        visibility.menuTracking(true)
        XCTAssertFalse(visibility.revealed, "A menu opened elsewhere must not reveal the title bar")
        visibility.menuTracking(false)
        visibility.setHovered(true)
        visibility.menuTracking(true)
        visibility.menuTracking(true)
        visibility.setHovered(false)
        visibility.menuTracking(false)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(visibility.revealed)
        visibility.menuTracking(false)
        try await Task.sleep(nanoseconds: 220_000_000)
        XCTAssertFalse(visibility.revealed)
    }

    @MainActor func testRevealingTitleControlsDoesNotResizeOrRefocusWorkbench() async throws {
        _ = NSApplication.shared
        let suite = "app.harbor.chrome-test." + UUID().uuidString
        let preferences = TestDefaults.suite(suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let store = AppStore(historyRoot: root, workspaceDefaults: preferences)
        store.loading = false; store.selectWorkspace(nil)
        store.currentFiles.root = "/tmp/Project"
        let visibility = WorkbenchToolbarVisibility()
        let editor = NSTextView(frame: .zero)
        editor.string = "Keep this editor mounted and focused."
        let hosting = NSHostingView(rootView: VStack(spacing: 0) {
            WorkbenchTopBar(visibility: visibility, session: store.codeWorkbench.session(for: store.currentFiles), addServer: {})
            ChromeEditorProbe(editor: editor).frame(maxWidth: .infinity, maxHeight: .infinity)
        }.environmentObject(store).defaultAppStorage(preferences))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        defer {
            visibility.reset(); window.contentView = nil; window.close(); store.shutdown()
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertTrue(window.makeFirstResponder(editor))
        let frame = editor.convert(editor.bounds, to: hosting)
        XCTAssertGreaterThan(frame.width, 900)
        XCTAssertEqual(frame.height, hosting.bounds.height - WorkbenchWindowMetrics.titlebarHeight, accuracy: 1)
        for hovered in [true, false, true, false] {
            visibility.setHovered(hovered)
            try await Task.sleep(nanoseconds: 240_000_000)
            hosting.layoutSubtreeIfNeeded()
            XCTAssertEqual(editor.convert(editor.bounds, to: hosting), frame, "Hover must not move any workbench boundary")
            XCTAssertTrue(editor.window === window)
            XCTAssertTrue(window.firstResponder === editor, "Revealing layout buttons must not steal keyboard focus")
        }
        XCTAssertEqual(editor.string, "Keep this editor mounted and focused.")
    }
}

private struct ChromeEditorProbe: NSViewRepresentable {
    let editor: NSTextView
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        // Fill the pane like an editor; a text view otherwise shrinks to its text.
        editor.isVerticallyResizable = false; editor.isHorizontallyResizable = false
        editor.frame = container.bounds; editor.autoresizingMask = [.width, .height]
        container.addSubview(editor); return container
    }
    func updateNSView(_ view: NSView, context: Context) { }
}
