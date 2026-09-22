import XCTest
import AppKit
import SwiftUI
import WebKit
import HarborCore
@testable import HarborSSH

final class RemoteDisplayIntegrationTests: XCTestCase {
    @MainActor func testIsaacViewerServesOnlyTokenScopedBundledAssets() async throws {
        let viewer = IsaacViewerServer(optionalViewerDirectory: URL(fileURLWithPath: "/tmp/harbor-missing-" + UUID().uuidString)); try await viewer.start(); defer { viewer.stop() }
        var profile = RemoteDisplayProfile(); profile.address = "isaac://example.org:49100"; profile.name = "Robot & lab"
        let url = try XCTUnwrap(viewer.url(profile: profile))
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("Set up the Isaac Sim viewer"))
        XCTAssertTrue(url.fragment?.contains("example.org") == true)
        let unscoped = URL(string: "http://127.0.0.1:\(try XCTUnwrap(viewer.port))/index.html")!
        let (_, denied) = try await URLSession.shared.data(from: unscoped)
        XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode, 404)
        let traversal = url.deletingLastPathComponent().appendingPathComponent("%2e%2e/session.py")
        let (_, deniedTraversal) = try await URLSession.shared.data(from: traversal)
        XCTAssertEqual((deniedTraversal as? HTTPURLResponse)?.statusCode, 404)
        viewer.stop(); XCTAssertNil(viewer.port)
    }
    @MainActor func testWebViewerInputResizeDetachAndRelease() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        var profile = RemoteDisplayProfile(); profile.useSSHTunnel = false
        profile.address = "http://127.0.0.1:1/"
        let session = RemoteDisplaySession(profile: profile)
        session.connect(server: nil)
        try await wait { session.web != nil }
        let web = try XCTUnwrap(session.web)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 560), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RemoteDisplayCanvas(session: session))
        window.makeKeyAndOrderFront(nil)
        defer { session.disconnect(); window.contentView = nil; window.close() }
        web.loadHTMLString("<html><body><input id='name'><button id='go' onclick='document.title=document.querySelector(\"#name\").value'>Apply</button><canvas id='frame'></canvas></body></html>", baseURL: nil)
        try await wait { web.isLoading == false && web.url?.absoluteString == "about:blank" }
        _ = try await web.evaluateJavaScript("document.querySelector('#name').value='simulation-input-ok';document.querySelector('#go').click()")
        let pageTitle = try await web.evaluateJavaScript("document.title") as? String
        XCTAssertEqual(pageTitle, "simulation-input-ok")
        for width in [420.0, 1000.0] {
            window.setContentSize(NSSize(width: width, height: 500)); window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertLessThanOrEqual(web.bounds.width, width)
        }
        session.detachWindow(); XCTAssertTrue(session.detached)
        try await wait { web.window?.title.contains("Remote Display") == true }
        XCTAssertTrue(web.window?.title.contains("Remote Display") == true)
        XCTAssertGreaterThan(web.bounds.height, 200)
        XCTAssertGreaterThan(web.bounds.width, 400)
        XCTAssertTrue(session.web === web, "Detaching must move the live viewer, not create another client")
        session.disconnect(); XCTAssertNil(session.web); XCTAssertNil(session.connectedURL); XCTAssertFalse(session.detached)
    }
    @MainActor func testCorruptCatalogCannotBeOverwrittenAndReopenDoesNotConnect() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var profile = RemoteDisplayProfile(); profile.useSSHTunnel = false
        let store = RemoteDisplayController(root: root)
        XCTAssertTrue(store.save(profile))
        let reopened = RemoteDisplayController(root: root); reopened.load()
        XCTAssertEqual(reopened.profiles, [profile]); XCTAssertTrue(reopened.sessions.isEmpty)
        let file = root.appendingPathComponent("remote-displays.json")
        try Data("broken".utf8).write(to: file)
        let damaged = RemoteDisplayController(root: root); damaged.load()
        XCTAssertNotNil(damaged.error); XCTAssertFalse(damaged.save(profile))
        XCTAssertEqual(try String(contentsOf: file), "broken")
    }
    @MainActor func testRemoteSSHTunnelWebSocketAndCleanup() async throws {
        guard let host = ProcessInfo.processInfo.environment["HARBOR_DISPLAY_QA_HOST"],
              let address = ProcessInfo.processInfo.environment["HARBOR_DISPLAY_QA_URL"] else { throw XCTSkip("Set an authorized server and test viewer URL") }
        _ = NSApplication.shared
        let server = ServerProfile(name: "Display QA", host: host, imported: true)
        var profile = RemoteDisplayProfile(serverID: server.id); profile.address = address; profile.preset = .web
        let session = RemoteDisplaySession(profile: profile); defer { session.disconnect() }
        session.connect(server: server)
        try await wait { session.web != nil || session.error != nil }
        XCTAssertNil(session.error)
        let url = try XCTUnwrap(session.connectedURL), port = try XCTUnwrap(url.port)
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertGreaterThan(data.count, 100)
        let web = try XCTUnwrap(session.web)
        try await wait { session.status == "Viewer loaded" }
        let title = try await web.evaluateJavaScript("document.title") as? String
        XCTAssertFalse(title?.isEmpty ?? true)
        if ProcessInfo.processInfo.environment["HARBOR_DISPLAY_QA_SIM"] == "1" {
            let result = try await web.callAsyncJavaScript("""
                await new Promise((resolve,reject)=>{let n=0;const t=setInterval(()=>{if(window.simState && window.framesReceived>2){clearInterval(t);resolve()}else if(++n>80){clearInterval(t);reject('No live simulation frames')}},100)});
                const before=window.simState.running;
                document.querySelector('#pause').click();
                await new Promise(resolve=>setTimeout(resolve,400));
                return {frames:window.framesReceived, toggled:before!==window.simState.running, time:window.simState.time};
                """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
            XCTAssertGreaterThan(result?["frames"] as? Int ?? 0, 2)
            XCTAssertEqual(result?["toggled"] as? Bool, true)
            _ = try await web.evaluateJavaScript("document.querySelector('#reset').click();document.querySelector('#pause').click()")
        }

        session.pauseIfHidden(); XCTAssertNil(session.web); XCTAssertTrue(RemoteDisplaySession.portIsOpen(port))
        session.resumeWeb(); XCTAssertNotNil(session.web)
        session.disconnect()
        try await wait { !RemoteDisplaySession.portIsOpen(port) }
        XCTAssertFalse(session.connected)
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(18)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        guard condition() else { XCTFail("Timed out waiting for display state"); throw DisplayError.message("Timed out") }
    }
}
