import XCTest
import AppKit
import HarborCore
@testable import SwiftTerm
@testable import HarborSSH

final class TerminalDisplayRepairTests: XCTestCase {
    @MainActor func testDisplayRepairDoesNotExposePartiallyWrittenTUIFrames() {
        _ = NSApplication.shared
        let terminal = DisplayRecordingTerminal(frame: NSRect(x: 0, y: 0, width: 700, height: 380))
        terminal.feed(text: "\u{1b}[?2026h\u{1b}[2J\u{1b}[HPartial frame")
        terminal.repaintRequests = 0
        terminal.refreshDisplay()
        XCTAssertEqual(terminal.repaintRequests, 0)
        XCTAssertTrue(terminal.getTerminal().synchronizedOutputActive)
        terminal.feed(text: " complete\u{1b}[?2026l")
        terminal.refreshDisplay()
        XCTAssertGreaterThan(terminal.repaintRequests, 0)
        XCTAssertTrue(terminal.getTerminal().getRecoveryText().contains("Partial frame complete"))
    }

    @MainActor func testReattachedTUIRepaintsAtTheCurrentSizeWithoutFontChanges() async throws {
        _ = NSApplication.shared
        let terminal = CapturingTerminal(frame: NSRect(x: 0, y: 0, width: 820, height: 440))
        let window = NSWindow(contentRect: terminal.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = terminal
        defer { window.close() }
        TerminalTheme.apply(to: terminal, dark: true)
        let font = terminal.font.pointSize, cols = terminal.getTerminal().cols
        terminal.feed(text: "Previous response\r\n")
        terminal.isHidden = true
        terminal.setFrameSize(NSSize(width: 820, height: 0))
        terminal.dataReceived(slice: Array("\u{1b}c\u{1b}[3J\u{1b}[?1049h\u{1b}[?2026h\u{1b}[HRestored terminal session\r\n\r\nPrevious response is visible immediately.\r\n中文与 emoji 👩🏽‍💻 are preserved.\r\n\r\nThinking…\r\n> \u{1b}[?2026l".utf8)[...])
        terminal.setFrameSize(NSSize(width: 820, height: 440)); terminal.isHidden = false
        terminal.scheduleDisplayRepair()
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(terminal.font.pointSize, font)
        XCTAssertEqual(terminal.getTerminal().cols, cols)
        XCTAssertTrue(terminal.getTerminal().getRecoveryText(kind: .alt).contains("Previous response is visible immediately."))
        XCTAssertFalse(terminal.getTerminal().synchronizedOutputActive)
        let bitmap = try XCTUnwrap(terminal.bitmapImageRepForCachingDisplay(in: terminal.bounds))
        terminal.cacheDisplay(in: terminal.bounds, to: bitmap)
        if let path = ProcessInfo.processInfo.environment["HARBOR_QA_RENDER_PATH"] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
    }

    @MainActor func testReplayCannotSendDeviceRepliesIntoLiveInputButFreshQueriesStillWork() throws {
        _ = NSApplication.shared
        let terminal = CapturingTerminal(frame: NSRect(x: 0, y: 0, width: 700, height: 380))
        let recorder = ReplyRecorder()
        terminal.terminalDelegate = recorder
        terminal.beginHistoryReplay()
        // Chunked cursor/device/color queries occur in real Claude/Codex history.
        terminal.feed(text: "\u{1b}[6")
        terminal.feed(text: "n\u{1b}[c\u{1b}[>c\u{1b}]10;?\u{7}\u{1b}]11;?\u{7}")
        XCTAssertTrue(recorder.replies.isEmpty)
        terminal.endHistoryReplay()
        terminal.feed(text: "\u{1b}[6n")
        XCTAssertFalse(recorder.replies.isEmpty, "A current query must still receive a reply")
    }
    @MainActor func testRestoredHistoryIsInScrollbackAndDoesNotOverwriteTheLiveTUI() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try TerminalSession(profile: nil, title: "QA", history: HistoryStore(root: root))
        let model = session.terminal.getTerminal()
        session.savedOutput = "Earlier answer 中文 👩🏽‍💻\nOverlapping line"
        session.terminal.feed(text: "Overlapping line\r\nNew answer\r\n\u{1b}[?1049h\u{1b}[?2004h\u{1b}[HThinking…\u{1b}[5;8H")
        let cursor = model.getCursorLocation(), screen = model.getRecoveryText(kind: .alt)
        session.finishHistoryReplay()
        XCTAssertTrue(model.getRecoveryText(kind: .normal).contains("Earlier answer 中文 👩🏽‍💻"))
        XCTAssertEqual(model.getRecoveryText(kind: .normal).components(separatedBy: "Overlapping line").count, 2)
        XCTAssertEqual(model.getRecoveryText(kind: .alt), screen)
        XCTAssertEqual(model.getCursorLocation().x, cursor.x); XCTAssertEqual(model.getCursorLocation().y, cursor.y)
        XCTAssertTrue(model.bracketedPasteMode); XCTAssertTrue(model.isDisplayBufferAlternate)
        XCTAssertEqual(session.terminal.bellStyle, .none)
    }
    @MainActor func testDisplayRestoreWaitsForConnectionReadyAndKeepsFontSize() async throws {
        _ = NSApplication.shared
        let terminal = CapturingTerminal(frame: NSRect(x: 0, y: 0, width: 700, height: 380))
        let window = NSWindow(contentRect: terminal.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = terminal
        defer { window.close() }
        var ready = false, redraws = 0
        terminal.onDisplayRestore = { if ready { redraws += 1 }; return ready }
        terminal.scheduleDisplayRepair(restoreRemote: true)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(redraws, 0)
        let font = terminal.font.pointSize
        ready = true; terminal.scheduleDisplayRepair()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(redraws, 1); XCTAssertEqual(terminal.font.pointSize, font)
    }
    @MainActor func testCollapsedSurfaceKeepsPTYDimensionsAndRestoringRepaintsWithoutChangingModes() throws {
        _ = NSApplication.shared
        let terminal = CapturingTerminal(frame: NSRect(x: 0, y: 0, width: 700, height: 380))
        terminal.feed(text: "saved scrollback\r\n\u{1b}[?1049h\u{1b}[?2004h\u{1b}[Hfull screen UI")
        let model = terminal.getTerminal(), cols = model.cols, rows = model.rows, font = terminal.font.pointSize
        terminal.setFrameSize(NSSize(width: 700, height: 0))
        XCTAssertEqual(model.cols, cols); XCTAssertEqual(model.rows, rows)
        terminal.setFrameSize(NSSize(width: 0, height: 380))
        XCTAssertEqual(model.cols, cols); XCTAssertEqual(model.rows, rows)
        terminal.setFrameSize(NSSize(width: 700, height: 380))
        terminal.refreshDisplay()
        XCTAssertEqual(terminal.font.pointSize, font)
        XCTAssertTrue(model.bracketedPasteMode)
        XCTAssertTrue(model.isDisplayBufferAlternate)
        XCTAssertNotNil(model.getUpdateRange())
        terminal.feed(text: "\u{1b}[?1049l")
        XCTAssertTrue(model.getBufferAsData().contains(Data("saved scrollback".utf8)))
    }

    @MainActor func testRemoteConnectionUsesPipesAndInputFramesAreByteExact() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = ServerProfile(name: "QA", host: "example.invalid")
        let session = try TerminalSession(profile: profile, title: "QA", history: HistoryStore(root: root))
        let args = try RemoteTerminalHost.arguments(session, profile: profile, socket: "/tmp/test")
        XCTAssertTrue(args.contains("-T")); XCTAssertFalse(args.contains("-tt"))
        XCTAssertTrue(try XCTUnwrap(args.last).contains("'--framed'"))
        XCTAssertEqual(TerminalTransport.packet(73, Data([0, 13, 27, 255])), Data([73, 0, 0, 0, 4, 0, 13, 27, 255]))
    }
}

private final class DisplayRecordingTerminal: TerminalView {
    var repaintRequests = 0
    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set { if newValue { repaintRequests += 1 }; super.needsDisplay = newValue }
    }
}

private final class ReplyRecorder: TerminalViewDelegate {
    var replies: [[UInt8]] = []
    func send(source: TerminalView, data: ArraySlice<UInt8>) { replies.append(Array(data)) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
