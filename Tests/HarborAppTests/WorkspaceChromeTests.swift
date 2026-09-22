import XCTest
import AppKit
import SwiftUI
import WebKit
import HarborCore
@testable import HarborSSH

final class WorkspaceChromeTests: XCTestCase {
    @MainActor private func fixture() throws -> (AppStore, URL) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-chrome-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "app.harbor.tests." + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        addTeardownBlock { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = AppStore(historyRoot: root.appendingPathComponent("data"), workspaceDefaults: prefs)
        try store.history.prepare(); store.loading = false
        return (store, root)
    }

    func testSplitRemainsBoundedAcrossSmallWindowsAndExtremeDragPositions() {
        for height in [0.0, 70, 130, 270, 400, 1200] {
            for ratio in [-100.0, 0, 0.2, 0.64, 1, 100, .infinity, .nan] {
                let split = WorkspaceSplitLayout(height: height, ratio: ratio)
                XCTAssertGreaterThanOrEqual(split.editor, 0)
                XCTAssertGreaterThanOrEqual(split.terminal, 0)
                XCTAssertEqual(split.editor + split.terminal, max(0, height - WorkspaceSplitLayout.divider), accuracy: 0.001)
                if ratio <= 0 { XCTAssertEqual(split.editor, 0, "The divider must reach the very top") }
                if height >= 270 { XCTAssertGreaterThanOrEqual(split.terminal, 90) }
            }
        }
    }

    func testDuplicateBasenamesHaveDistinctColorsAndShortestUniqueLabels() {
        let paths = ["/home/a/project/main.py", "/home/b/project/main.py", "/home/a/other/main.py", "/home/a/only.txt"]
        let colors = paths.prefix(3).compactMap { WorkspaceTabLayout.colorIndex(path: $0, peers: paths) }
        XCTAssertEqual(Set(colors).count, 3)
        XCTAssertNil(WorkspaceTabLayout.colorIndex(path: paths[3], peers: paths))
        XCTAssertEqual(WorkspaceTabLayout.disambiguatedTitle(path: paths[0], peers: paths), "a/project/main.py")
        XCTAssertEqual(WorkspaceTabLayout.disambiguatedTitle(path: paths[2], peers: paths), "other/main.py")
        XCTAssertEqual(WorkspaceTabLayout.disambiguatedTitle(path: paths[3], peers: paths), "only.txt")
        for path in paths { XCTAssertEqual(WorkspaceTabLayout.colorIndex(path: path, peers: paths), WorkspaceTabLayout.colorIndex(path: path, peers: paths.reversed())) }
        let twelve = (0..<12).map { "/folder\($0)/main.py" }
        XCTAssertEqual(Set(twelve.compactMap { WorkspaceTabLayout.colorIndex(path: $0, peers: twelve) }).count, 12)
    }

    @MainActor func testRenamePreservesIdentityDirectoryAndNumberAllocation() throws {
        let (store, _) = try fixture(); defer { store.shutdown() }
        let profile = ServerProfile(name: "Test", host: "test.example.invalid")
        store.profiles = [profile]; store.files(for: profile).root = "/work/project"
        let firstID = try XCTUnwrap(store.openTerminal(profile))
        let first = try XCTUnwrap(store.activeSession)
        first.rename(to: "  长名称 · 编译与分析终端 🧪 \n")
        XCTAssertEqual(first.id, firstID)
        XCTAssertEqual(first.title, "Test · 1")
        XCTAssertEqual(first.tabTitle, "长名称 · 编译与分析终端 🧪")
        XCTAssertEqual(first.workingDirectory, "/work/project")
        XCTAssertGreaterThan(first.tabWidth ?? 0, 150)
        _ = store.openTerminal(profile)
        XCTAssertEqual(store.activeSession?.title, "Test · 2")
        first.stop(); store.reconnect(first)
        XCTAssertEqual(store.activeSession?.customTitle, first.customTitle)
        XCTAssertEqual(store.activeSession?.tabWidth, first.tabWidth)
        first.rename(to: " \n "); XCTAssertEqual(first.tabTitle, "project")
        XCTAssertEqual(WorkspaceTabLayout.clamp(-100), 40)
        XCTAssertEqual(WorkspaceTabLayout.clamp(10000), 360)
    }

    @MainActor func testLongCodeUsesInternalScrollingAndStaysInsideResizedNativePane() async throws {
        let (store, root) = try fixture(); defer { store.shutdown() }
        let workspace = store.currentFiles
        workspace.root = root.path; workspace.enabled = true; workspace.entries[root.path] = []
        let doc = WorkspaceDocument(WorkspaceEntry(path: root.appendingPathComponent("long.py").path, name: "long.py", directory: false, size: 100000, modified: 0))
        doc.text = (1...500).map { "# Line \($0) " + String(repeating: "long code ", count: 80) }.joined(separator: "\n")
        doc.savedText = doc.text; workspace.documents = [doc]; workspace.selection = doc.id
        let bridge = EditorBridge(document: doc, workspace: workspace); doc.editor = bridge
        let bounded = BoundedNativeView(content: bridge.web)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.addSubview(bounded)
        bounded.frame = NSRect(x: 90, y: 100, width: 700, height: 500)
        bridge.update(dark: false, font: 13, wrap: false)
        let deadline = Date().addingTimeInterval(15)
        while (!bridge.ready || doc.position.lines != 500) && Date() < deadline { try await Task.sleep(nanoseconds: 30_000_000) }
        XCTAssertTrue(bridge.ready); XCTAssertEqual(doc.position.lines, 500)
        for size in [NSSize(width: 700, height: 500), NSSize(width: 280, height: 120), NSSize(width: 820, height: 260)] {
            bounded.setFrameSize(size); bounded.layoutSubtreeIfNeeded()
            XCTAssertEqual(bridge.web.frame, bounded.bounds)
            XCTAssertTrue(bounded.layer?.masksToBounds == true)
            let metrics = try await bridge.web.callAsyncJavaScript("""
                await new Promise(resolve => setTimeout(resolve, 40));
                const scroller = document.querySelector('.cm-scroller');
                return {width: innerWidth, height: innerHeight, rootWidth: document.documentElement.scrollWidth,
                        editorHeight: document.querySelector('#editor').getBoundingClientRect().height,
                        scrollWidth: scroller.scrollWidth, clientWidth: scroller.clientWidth,
                        statusCount: document.querySelectorAll('#status').length};
                """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
            let values = try XCTUnwrap(metrics)
            XCTAssertEqual((values["width"] as? NSNumber)?.doubleValue ?? -1, size.width, accuracy: 1)
            XCTAssertEqual((values["editorHeight"] as? NSNumber)?.doubleValue ?? -1, size.height, accuracy: 1)
            XCTAssertEqual((values["rootWidth"] as? NSNumber)?.doubleValue ?? -1, size.width, accuracy: 1)
            XCTAssertGreaterThan((values["scrollWidth"] as? NSNumber)?.doubleValue ?? 0, (values["clientWidth"] as? NSNumber)?.doubleValue ?? 0)
            XCTAssertEqual(values["statusCount"] as? Int, 0)
        }
    }
    @MainActor func testFullWorkspaceKeepsCodeBelowHeaderAndAboveTerminalAtBothSplitExtremes() async throws {
        let (store, root) = try fixture(); defer { store.shutdown() }
        let suite = "app.harbor.layout." + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        prefs.set(52.0, forKey: "sidebarWidth"); prefs.set(30.0, forKey: "headerHeight")
        prefs.set(52.0, forKey: "fileTreeWidth"); prefs.set(0.64, forKey: "editorHeightRatio")
        store.selectWorkspace(nil)
        let workspace = store.currentFiles
        workspace.enabled = true; workspace.root = root.path; workspace.entries[root.path] = []
        let doc = WorkspaceDocument(WorkspaceEntry(path: root.appendingPathComponent("layout.py").path, name: "layout.py", directory: false, size: 1000, modified: 0))
        doc.text = String(repeating: "print('a long line for testing')\n", count: 200)
        doc.savedText = doc.text; workspace.documents = [doc]; workspace.selection = doc.id
        let hosting = NSHostingView(rootView: ContentView().environmentObject(store).defaultAppStorage(prefs))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 620), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        let deadline = Date().addingTimeInterval(15)
        while doc.editor?.ready != true && Date() < deadline { hosting.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 30_000_000) }
        let web = try XCTUnwrap(doc.editor?.web)
        var heights: [Double] = []
        var flatFrames: [Double: CGRect] = [:]
        for glass in [false, true] {
            prefs.set(glass, forKey: "liquidGlassEnabled")
            heights = []
            for ratio in [0.25, 0.85] {
                prefs.set(ratio, forKey: "editorHeightRatio")
                // The pane transition lasts 240 ms. Comparing after 100 ms sampled
                // different animation frames, rather than the final native bounds.
                try await Task.sleep(nanoseconds: 400_000_000); hosting.layoutSubtreeIfNeeded()
                let rect = web.convert(web.bounds, to: hosting)
                XCTAssertGreaterThanOrEqual(rect.minY, 69, "Code covered the header: \(rect)")
                XCTAssertGreaterThanOrEqual(rect.minX, 104)
                XCTAssertLessThanOrEqual(rect.maxX, hosting.bounds.maxX + 1)
                XCTAssertLessThanOrEqual(rect.maxY, hosting.bounds.maxY - 110, "No room left for terminal and status: \(rect)")
                print("GLASS_LAYOUT enabled=\(glass) ratio=\(ratio) hosting=\(hosting.bounds) code=\(rect)")
                XCTAssertGreaterThan(rect.height, 80)
                if let baseline = flatFrames[ratio], glass {
                    XCTAssertEqual(rect.minY, baseline.minY, accuracy: 1)
                    XCTAssertEqual(rect.height, baseline.height, accuracy: 1, "Glass must not take space from the editor")
                } else { flatFrames[ratio] = rect }
                heights.append(rect.height)
            }
            XCTAssertGreaterThan(heights[1] - heights[0], 150)
        }
    }

}
