import XCTest
import AppKit
import SwiftUI
import WebKit
import HarborCore
@testable import HarborSSH

final class ThemeIntegrationTests: XCTestCase {
    @MainActor private func fixture() throws -> (AppStore, URL, UserDefaults) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-theme-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "app.harbor.theme." + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        addTeardownBlock { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = AppStore(historyRoot: root.appendingPathComponent("data"), workspaceDefaults: prefs)
        try store.history.prepare(); store.loading = false; store.selectWorkspace(nil)
        store.currentFiles.root = root.path; store.currentFiles.entries[root.path] = []
        prefs.set(190.0, forKey: "sidebarWidth"); prefs.set(38.0, forKey: "headerHeight")
        return (store, root, prefs)
    }
    private func rgb(_ color: NSColor) throws -> String {
        let c = try XCTUnwrap(color.usingColorSpace(.sRGB))
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
    @MainActor func testLiveAppearanceChangesUpdateNativeSurfacesWithoutReplacingPTY() async throws {
        let (store, _, prefs) = try fixture(); defer { store.shutdown() }
        store.openWorkspaceTerminal(); let session = try XCTUnwrap(store.activeSession)
        let pid = session.terminal.process.shellPid
        let hosting = NSHostingView(rootView: ContentView().environmentObject(store).defaultAppStorage(prefs))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 660), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        for dark in [true, false, true] {
            for glass in [false, true] {
                prefs.set(glass, forKey: "liquidGlassEnabled")
                prefs.set(dark ? "dark" : "light", forKey: "appearance")
                try await Task.sleep(nanoseconds: 150_000_000); hosting.layoutSubtreeIfNeeded()
                XCTAssertEqual(try rgb(session.terminal.nativeBackgroundColor), dark ? "#191A1B" : "#FAFAFD")
                XCTAssertEqual(try rgb(session.terminal.nativeForegroundColor), dark ? "#CCCCCC" : "#3B3B3B")
                XCTAssertEqual(try rgb(session.terminal.caretColor), dark ? "#BFBFBF" : "#202020")
                XCTAssertEqual(try rgb(try XCTUnwrap(session.terminal.caretTextColor)), dark ? "#191A1B" : "#FFFFFF")
                XCTAssertEqual(try rgb(session.terminal.selectedTextForegroundColor), try rgb(session.terminal.nativeForegroundColor))
                XCTAssertEqual(session.terminal.selectedTextBackgroundColor.alphaComponent, dark ? 0x33 / 255.0 : 0x26 / 255.0, accuracy: 0.001)
                XCTAssertEqual(try rgb(window.backgroundColor), dark ? "#191A1B" : "#FAFAFD")
                XCTAssertEqual(session.terminal.process.shellPid, pid); XCTAssertTrue(session.terminal.process.running)
                XCTAssertTrue(session.terminal.window === window)
                if let output = ProcessInfo.processInfo.environment["HARBOR_QA_OUTPUT"], let image = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                    hosting.cacheDisplay(in: hosting.bounds, to: image)
                    let data = try XCTUnwrap(image.representation(using: .png, properties: [:]))
                    try data.write(to: URL(fileURLWithPath: output).appendingPathComponent("theme-\(dark ? "dark" : "light")-\(glass ? "glass" : "flat")-native.png"))
                }
            }
        }
    }
    @MainActor func testCodeAndMarkdownUseSameOfficialPaletteAndPreserveEditsOnThemeSwitch() async throws {
        let (store, root, _) = try fixture(); defer { store.shutdown() }
        let workspace = store.currentFiles
        let doc = WorkspaceDocument(WorkspaceEntry(path: root.appendingPathComponent("theme.js").path, name: "theme.js", directory: false, size: 90, modified: 0))
        doc.text = "const amount = 42; // comment\nfunction greet() { return \"hello\"; }"; doc.savedText = ""
        let bridge = EditorBridge(document: doc, workspace: workspace); doc.editor = bridge
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = bridge.web
        defer { window.contentView = nil; window.close() }
        bridge.update(dark: true, font: 13, wrap: false)
        let deadline = Date().addingTimeInterval(15)
        while !bridge.ready && Date() < deadline { try await Task.sleep(nanoseconds: 30_000_000) }
        XCTAssertTrue(bridge.ready)
        for dark in [true, false, true] {
            bridge.update(dark: dark, font: 13, wrap: false)
            let metrics = try await bridge.web.callAsyncJavaScript("""
                await new Promise(resolve => setTimeout(resolve, 100));
                const color = selector => getComputedStyle(document.querySelector(selector)).color;
                const token = text => [...document.querySelectorAll('.cm-content span')].find(span => span.textContent === text);
                return { background: getComputedStyle(document.querySelector('.cm-editor')).backgroundColor,
                         foreground: color('.cm-editor'), gutter: color('.cm-gutters'),
                         keyword: getComputedStyle(token('const')).color, number: getComputedStyle(token('42')).color,
                         comment: getComputedStyle(token('// comment')).color };
                """, arguments: [:], in: nil, contentWorld: .page) as? [String: String]
            XCTAssertEqual(metrics?["background"], dark ? "rgb(24, 24, 24)" : "rgb(252, 252, 252)")
            XCTAssertEqual(metrics?["foreground"], dark ? "rgb(240, 240, 240)" : "rgb(20, 20, 20)")
            XCTAssertEqual(metrics?["gutter"], dark ? "rgba(240, 240, 240, 0.36)" : "rgba(20, 20, 20, 0.36)")
            XCTAssertEqual(metrics?["keyword"], dark ? "rgb(130, 210, 206)" : "rgb(163, 0, 52)")
            XCTAssertEqual(metrics?["number"], dark ? "rgb(235, 200, 141)" : "rgb(146, 21, 106)")
            XCTAssertEqual(metrics?["comment"], dark ? "rgba(240, 240, 240, 0.6)" : "rgba(20, 20, 20, 0.6)")
            XCTAssertTrue(doc.dirty); XCTAssertTrue(doc.text?.contains("const amount = 42") == true)
        }
        for dark in [true, false] {
            let values = try await bridge.web.callAsyncJavaScript("""
                window.harborSet({ text: '# Theme\\n[Link](https://example.com)\\n\\n> Quote', path: 'preview.md', revision: 10, preview: true, font: 13, dark, wrap: false });
                const style = selector => getComputedStyle(document.querySelector(selector));
                return { background: style('body').backgroundColor, foreground: style('body').color,
                         link: style('#preview a').color, quote: style('#preview blockquote').backgroundColor };
                """, arguments: ["dark": dark], in: nil, contentWorld: .page) as? [String: String]
            XCTAssertEqual(values?["background"], dark ? "rgb(24, 24, 24)" : "rgb(252, 252, 252)")
            XCTAssertEqual(values?["foreground"], dark ? "rgb(240, 240, 240)" : "rgb(20, 20, 20)")
            XCTAssertEqual(values?["link"], dark ? "rgb(129, 161, 193)" : "rgb(0, 100, 176)")
            XCTAssertEqual(values?["quote"], dark ? "rgb(36, 37, 38)" : "rgb(234, 234, 234)")
        }
    }
}
