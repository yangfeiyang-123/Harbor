import XCTest
import SwiftUI
import AppKit
import HarborCore
@testable import HarborSSH

final class ExplorerNativeInteractionTests: XCTestCase {
    @MainActor func testNativeExplorerLayoutAndOptionalInteractionSession() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-native-explorer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let prefsName = "app.harbor.native-explorer." + UUID().uuidString
        let prefs = UserDefaults(suiteName: prefsName)!
        prefs.set("dark", forKey: "appearance"); prefs.set(190.0, forKey: "sidebarWidth")
        prefs.set(34.0, forKey: "headerHeight"); prefs.set(245.0, forKey: "fileTreeWidth")
        let store = AppStore(historyRoot: root.appendingPathComponent(".state"), workspaceDefaults: prefs)
        try store.history.prepare(); store.loading = false
        store.profiles = [ServerProfile(name: "QA Alpha", host: "alpha.invalid"), ServerProfile(name: "QA Beta", host: "beta.invalid")]
        store.selectWorkspace(nil)
        let workspaceRoot = root.appendingPathComponent("WorkSpace")
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: false)
        for name in ["目标文件夹", "另一个项目"] { try FileManager.default.createDirectory(at: workspaceRoot.appendingPathComponent(name), withIntermediateDirectories: false) }
        try "print('Harbor file operations')\n".write(to: workspaceRoot.appendingPathComponent("main.py"), atomically: true, encoding: .utf8)
        try "# Harbor QA\n\n文件与终端交互验证。\n".write(to: workspaceRoot.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let files = store.currentFiles; files.enabled = true; files.terminalVisible = true
        await files.prepare(store: store); await files.navigate(workspaceRoot.path)
        let source = try XCTUnwrap(files.entries[files.root]?.first { $0.name == "main.py" }); await files.open(source)
        store.openWorkspaceTerminal()
        let host = NSHostingView(rootView: ContentView().environmentObject(store).defaultAppStorage(prefs))
        let window = NSWindow(contentRect: NSRect(x: 140, y: 150, width: 1120, height: 760), styleMask: [.titled, .resizable, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Harbor 0.14 · 交互验证"; window.isReleasedWhenClosed = false; window.contentView = host
        defer {
            store.shutdown(); window.contentView = nil; window.close()
            prefs.removePersistentDomain(forName: prefsName); try? FileManager.default.removeItem(at: root)
        }
        let hold = min(1800, Double(ProcessInfo.processInfo.environment["HARBOR_EXPLORER_QA_HOLD_SECONDS"] ?? "0") ?? 0)
        if hold > 0 { NSApp.setActivationPolicy(.regular); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        let deadline = Date().addingTimeInterval(12)
        while files.currentDocument?.editor?.ready != true && Date() < deadline { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 30_000_000) }
        XCTAssertEqual(files.currentDocument?.entry.name, "main.py")
        XCTAssertTrue(files.currentDocument?.editor?.ready == true)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertTrue(host.bounds.width >= 1100)
        if hold > 0 {
            let ready = ["pid": String(ProcessInfo.processInfo.processIdentifier), "root": workspaceRoot.path, "title": window.title]
            try JSONSerialization.data(withJSONObject: ready, options: .prettyPrinted).write(to: URL(fileURLWithPath: "/private/tmp/harbor-native-explorer-ready.json"))
            let end = Date().addingTimeInterval(hold)
            while Date() < end && !FileManager.default.fileExists(atPath: "/private/tmp/harbor-native-explorer-done") { try await Task.sleep(nanoseconds: 200_000_000) }
        }
    }
}
