import XCTest
import AppKit
import WebKit
@testable import HarborSSH

/// Switching between two open folders: the editor that leaves stays on screen until the one that
/// arrives has drawn itself, so the window is never empty in between.
final class WorkbenchStageTests: XCTestCase {
    @MainActor private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(nanoseconds: 20_000_000) }
    }

    @MainActor func testOneEditorGivesWayToTheNext() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let stage = WorkbenchStage(frame: .init(x: 0, y: 0, width: 400, height: 300))
        stage.entrance = .off
        window.contentView?.addSubview(stage)
        let first = WKWebView(frame: .zero), second = WKWebView(frame: .zero)

        stage.show(first, motion: .full)
        XCTAssertTrue(first.superview === stage); XCTAssertEqual(first.frame.size, stage.bounds.size)
        stage.show(first, motion: .full)
        XCTAssertEqual(stage.subviews.count, 1, "showing what is already there changes nothing")

        // The next editor goes underneath; the one leaving stays on top, and is not what a click reaches.
        stage.show(second, motion: .full)
        XCTAssertEqual(stage.subviews.count, 2)
        XCTAssertTrue(stage.subviews.first === second); XCTAssertTrue(stage.subviews.last === first)
        XCTAssertTrue(stage.current === second)
        let hit = stage.hitTest(NSPoint(x: 200, y: 150))
        XCTAssertTrue(hit === second || hit?.isDescendant(of: second) == true)
        try await settle { first.superview == nil }
        XCTAssertNil(first.superview, "it has faded and left")
        XCTAssertEqual(first.alphaValue, 1, "and can be shown again as it is")
        XCTAssertEqual(stage.subviews.count, 1)

        // Asked for again while it is leaving: it stays, and the other one goes at once.
        stage.show(first, motion: .full)
        stage.show(second, motion: .full)
        XCTAssertTrue(second.superview === stage); XCTAssertEqual(second.alphaValue, 1)
        XCTAssertTrue(stage.current === second)
        try await settle { stage.subviews.count == 1 }
        XCTAssertTrue(stage.subviews.first === second)

        // A folder whose editor has not started: the editor on screen fades to the page behind it.
        stage.show(nil, motion: .full)
        XCTAssertNil(stage.current); XCTAssertNil(stage.hitTest(NSPoint(x: 200, y: 150)))
        try await settle { stage.subviews.isEmpty }
        XCTAssertTrue(stage.subviews.isEmpty)

        // With motion off nothing fades, and the old editor still waits for the new one to draw.
        stage.show(first, motion: .off)
        stage.show(second, motion: .off)
        XCTAssertEqual(stage.subviews.count, 2)
        try await settle { stage.subviews.count == 1 }
        XCTAssertTrue(stage.subviews.first === second)

        // Out of a window there is nobody to see a change: it is immediate.
        stage.removeFromSuperview()
        stage.show(first, motion: .full)
        XCTAssertEqual(stage.subviews.count, 1); XCTAssertTrue(stage.subviews.first === first)
        XCTAssertEqual([WorkbenchStage.fade(.full), WorkbenchStage.fade(.subtle), WorkbenchStage.fade(.off)], [0.24, 0.12, 0])
    }

    /// Under a panel over the whole window the editor is a picture of itself, its web view hidden;
    /// when the panel goes, the page comes back and the picture leaves once it has drawn.
    @MainActor func testAnEditorUnderAPanelIsAPicture() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let stage = WorkbenchStage(frame: .init(x: 0, y: 0, width: 400, height: 300))
        stage.entrance = .off
        window.contentView?.addSubview(stage)
        let web = WKWebView(frame: .zero), other = WKWebView(frame: .zero)
        web.loadHTMLString("<body style='background:#c33'>Editor</body>", baseURL: nil)
        stage.show(web, motion: .off)
        try await settle { !web.isLoading }

        stage.setCovered(true)
        try await settle { web.isHidden }
        guard web.isHidden else { throw XCTSkip("WebKit takes no snapshot of a window that is not on screen here") }
        let picture = try XCTUnwrap(stage.subviews.last as? NSImageView)
        XCTAssertNotNil(picture.image); XCTAssertEqual(picture.frame, stage.bounds)
        XCTAssertNil(stage.hitTest(NSPoint(x: 200, y: 150)), "nothing under the panel takes a click")

        stage.setCovered(false)
        XCTAssertFalse(web.isHidden, "the page is live again at once")
        try await settle { stage.subviews.count == 1 }
        XCTAssertTrue(stage.subviews.first === web, "and the picture has gone once it drew")

        // Another folder shown while the panel is there: the picture goes at once, the editor arriving is live.
        stage.setCovered(true)
        try await settle { web.isHidden }
        stage.show(other, motion: .off)
        XCTAssertFalse(web.isHidden); XCTAssertFalse(stage.subviews.contains { $0 is NSImageView })
        stage.setCovered(false)
        XCTAssertFalse(other.isHidden)
    }

    /// A new theme for the editor on stage: a picture of it lies over it while the theme changes and
    /// then dissolves into it. Under a panel the page is shown for the change, and is a picture
    /// again afterwards, in its new colors.
    @MainActor func testAnEditorDissolvesIntoANewTheme() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let stage = WorkbenchStage(frame: .init(x: 0, y: 0, width: 400, height: 300))
        stage.entrance = .off
        window.contentView?.addSubview(stage)
        let web = WKWebView(frame: .zero)
        web.loadHTMLString("<body style='background:#c33'>Editor</body>", baseURL: nil)
        stage.show(web, motion: .off)
        try await settle { !web.isLoading }

        var during: [NSView] = []
        await stage.dissolve(.full) { during = stage.subviews }
        guard during.contains(where: { $0 is NSImageView }) else { throw XCTSkip("WebKit takes no snapshot of a window that is not on screen here") }
        XCTAssertTrue(during.last is NSImageView, "the picture lies over the editor while it changes")
        try await settle { stage.subviews.count == 1 }
        XCTAssertTrue(stage.subviews.first === web, "and has dissolved into it")

        // A slow change (a distant server): the picture does not wait for it. The editor under it
        // goes on, and a still picture of it longer than the hold's limit looked stuck.
        var stillHeld = true
        await stage.dissolve(.full) {
            try? await Task.sleep(for: .seconds(WorkbenchStage.holdLimit + 0.8))
            stillHeld = stage.subviews.contains { $0 is NSImageView }
        }
        XCTAssertFalse(stillHeld, "the picture has gone before the change was done")
        XCTAssertTrue(stage.subviews.first === web); XCTAssertEqual(stage.subviews.count, 1)

        // Motion off: no picture; the change is made as it comes.
        await stage.dissolve(.off) { during = stage.subviews }
        XCTAssertEqual(during.count, 1)

        // Under a panel.
        stage.setCovered(true)
        try await settle { web.isHidden }
        var hiddenDuring = true
        await stage.dissolve(.full) { hiddenDuring = web.isHidden }
        XCTAssertFalse(hiddenDuring, "the page is drawn for the change, under the picture")
        try await settle { web.isHidden }
        XCTAssertTrue(web.isHidden, "and is a picture again afterwards")
        XCTAssertTrue(stage.subviews.last is NSImageView)
        stage.setCovered(false)
        try await settle { stage.subviews.count == 1 && !web.isHidden }
        XCTAssertTrue(stage.subviews.first === web)
    }

    /// A panel's shadow is cast from its outline, inside the view's own bounds.
    @MainActor func testAPanelShadowIsCastFromItsOutline() {
        let view = HarborPanelShadow.ShadowView(frame: .init(x: 0, y: 0, width: 300 + 96, height: 200 + 96))
        view.radius = 24; view.cornerRadius = 12; view.opacity = 0.3
        view.layout()
        let path = try? XCTUnwrap(view.caster.shadowPath)
        XCTAssertEqual(path?.boundingBoxOfPath, CGRect(x: 48, y: 48, width: 300, height: 200))
        XCTAssertEqual(view.caster.shadowOpacity, 0.3, accuracy: 0.001)
        XCTAssertEqual(view.caster.shadowRadius, 24); XCTAssertEqual(view.caster.shadowOffset, .zero)
        XCTAssertNil(view.hitTest(NSPoint(x: 100, y: 100)))
        // Too small for its margin: no shadow, and no outline to draw it from.
        view.frame = .init(x: 0, y: 0, width: 60, height: 60); view.layout()
        XCTAssertNil(view.caster.shadowPath); XCTAssertEqual(view.caster.shadowOpacity, 0)
        XCTAssertEqual(HarborPanelShadow.margin(24), 48)
    }
}
