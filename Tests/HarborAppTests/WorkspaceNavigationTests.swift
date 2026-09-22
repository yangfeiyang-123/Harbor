import XCTest
import SwiftUI
import HarborCore
@testable import HarborSSH

final class WorkspaceNavigationTests: XCTestCase {
    func testOutlineRecognizesDeclarationsWithoutTreatingCallsAsSymbols() {
        let text = "# Controller\nclass Robot:\n    async def step(self):\n        run()\nexport const reset = () => {};\npublic struct State {}\n    func update() {}"
        let symbols = CodeSymbol.parse(text)
        XCTAssertEqual(symbols.map(\.name), ["Robot", "step", "reset", "State", "update"])
        XCTAssertEqual(symbols.map(\.line), [2, 3, 5, 6, 7])
        XCTAssertEqual(CodeSymbol.parse(text, markdown: true).map(\.name), ["Controller"])
    }

    @MainActor func testSearchNavigationPreservesDraftAndTerminalWhileChangingPanels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-navigation-" + UUID().uuidString)
        let folder = root.appendingPathComponent("src/control")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "app.harbor.navigation." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let source = "class RobotPolicy:\n    def predict(self, step):\n        target_velocity = 0.5\n        return target_velocity\n"
        try Data(source.utf8).write(to: folder.appendingPathComponent("policy.py"))
        try Data("# Workspace\n\nRun the robot controller.\n".utf8).write(to: root.appendingPathComponent("README.md"))
        let store = AppStore(historyRoot: root.appendingPathComponent(".state"), workspaceDefaults: defaults)
        try store.history.prepare(); store.loading = false; store.selectWorkspace(nil)
        let files = store.currentFiles; files.root = root.path; files.enabled = true
        await files.prepare(store: store); await files.navigate(root.path)
        let service = try XCTUnwrap(files.service)
        let result = try await service.search("target_velocity", root: files.root, content: true)
        await files.openSearchHit(try XCTUnwrap(result.hits.first))
        let document = try XCTUnwrap(files.currentDocument)
        XCTAssertEqual(document.entry.name, "policy.py"); XCTAssertEqual(document.pendingPosition?.line, 3)
        await files.revealInExplorer(document.entry.path)
        XCTAssertTrue(files.expanded.contains(folder.path)); XCTAssertEqual(files.selectedEntryPath, document.entry.path)
        store.openWorkspaceTerminal(); let session = try XCTUnwrap(store.activeSession), pid = session.terminal.process.shellPid
        defer { store.shutdown() }
        defaults.set(52.0, forKey: "sidebarWidth"); defaults.set(235.0, forKey: "fileTreeWidth")
        defaults.set(38.0, forKey: "headerHeight"); defaults.set(0.70, forKey: "editorHeightRatio")
        files.outlineVisible = true
        let view = NSHostingView(rootView: ContentView().environmentObject(store).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1223, height: 768), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.contentView = nil; window.close() }
        let deadline = Date().addingTimeInterval(12)
        while document.editor?.ready != true && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        let editor = try XCTUnwrap(document.editor); XCTAssertTrue(editor.ready)
        files.goToLine(3)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(document.position.line, 3)
        document.text = source + "# unsaved draft\n"; document.revision += 1
        for dark in [true, false] {
            defaults.set(dark ? "dark" : "light", forKey: "appearance")
            files.explorerVisible = false; files.terminalVisible = false
            try await Task.sleep(nanoseconds: 280_000_000)
            files.explorerVisible = true; files.terminalVisible = true
            try await Task.sleep(nanoseconds: 450_000_000); view.layoutSubtreeIfNeeded()
            XCTAssertEqual(store.activeSession?.id, session.id)
            XCTAssertEqual(session.terminal.process.shellPid, pid); XCTAssertTrue(session.terminal.process.running)
            XCTAssertTrue(document.dirty); XCTAssertTrue(document.text?.contains("unsaved draft") == true)
            if let output = ProcessInfo.processInfo.environment["HARBOR_QA_OUTPUT"], let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output).appendingPathComponent("workbench-\(dark ? "dark" : "light").png"))
            }
        }
        await files.save(document)
        XCTAssertFalse(document.dirty)
        XCTAssertTrue(try String(contentsOf: folder.appendingPathComponent("policy.py"), encoding: .utf8).contains("unsaved draft"))
        let closeKey = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "w",
            charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        window.makeFirstResponder(session.terminal)
        XCTAssertFalse(files.handleEditorKey(closeKey), "Terminal focus must retain its own window behavior")
        window.makeFirstResponder(editor.web)
        files.focusArea = .search // A WebKit click can precede SwiftUI's focus update.
        NSApp.sendEvent(closeKey)
        XCTAssertTrue(files.documents.isEmpty, "Command-W should close the file before the window menu handles it")
        XCTAssertTrue(window.contentView === view)
        XCTAssertTrue(session.terminal.process.running)
    }
}
