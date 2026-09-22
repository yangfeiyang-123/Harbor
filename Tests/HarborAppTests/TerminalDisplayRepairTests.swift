import XCTest
import AppKit
import HarborCore
@testable import SwiftTerm
@testable import HarborSSH

final class TerminalDisplayRepairTests: XCTestCase {
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
