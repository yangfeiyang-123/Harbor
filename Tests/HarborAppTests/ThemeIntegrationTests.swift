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
        let prefs = TestDefaults.suite(suite)!
        addTeardownBlock { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = AppStore(historyRoot: root.appendingPathComponent("data"), workspaceDefaults: prefs)
        try store.history.prepare(); store.loading = false; store.selectWorkspace(nil)
        store.currentFiles.root = root.path
        prefs.set(190.0, forKey: "sidebarWidth"); prefs.set(38.0, forKey: "headerHeight")
        return (store, root, prefs)
    }
    private func rgb(_ color: NSColor) throws -> String {
        let c = try XCTUnwrap(color.usingColorSpace(.sRGB))
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
    @MainActor func testLiveAppearanceChangesUpdateNativeSurfacesWithoutReplacingPTY() async throws {
        let (store, _, prefs) = try fixture(); defer { store.shutdown() }
        // Harbor's own terminals live in terminal windows; the workbench window is Code-OSS.
        let id = try XCTUnwrap(store.openTerminal(nil, detached: true))
        let session = try XCTUnwrap(store.sessions.first { $0.id == id }), windowID = try XCTUnwrap(session.windowID)
        let pid = session.terminal.process.shellPid
        let hosting = NSHostingView(rootView: TerminalWindowView(windowID: windowID).environmentObject(store).defaultAppStorage(prefs))
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
}
