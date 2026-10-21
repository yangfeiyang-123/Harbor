import XCTest
import AppKit
@testable import SwiftTerm

/// These drive the NSTextInputClient callback contract deterministically and
/// verify the actual PTY stream. The operating system's candidate window and
/// input-source switching still require a separate interactive smoke check.
final class TerminalIMEIntegrationTests: XCTestCase {
    private let unspecified = NSRange(location: NSNotFound, length: 0)

    @MainActor private func fixture() -> (NSWindow, IMETestTerminal) {
        _ = NSApplication.shared
        let view = IMETestTerminal(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeFirstResponder(view)
        return (window, view)
    }

    @MainActor private func event(_ code: UInt16, _ text: String, type: NSEvent.EventType = .keyDown,
                                  flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                        windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
                        isARepeat: false, keyCode: code)!
    }

    @MainActor private func waitUntil(_ condition: () -> Bool, message: String) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), message)
    }

    @MainActor private func startByteCapture(_ view: IMETestTerminal, destination: URL) async throws {
        let script = """
        import os, sys, tty
        tty.setraw(0)
        os.write(1, b'HARBOR_IME_READY')
        data = bytearray()
        while True:
            block = os.read(0, 4096)
            if b'\\x04' in block:
                data.extend(block.split(b'\\x04', 1)[0])
                break
            data.extend(block)
        with open(sys.argv[1], 'wb') as output:
            output.write(data)
        os.write(1, b'HARBOR_IME_DONE')
        """
        view.startProcess(executable: "/usr/bin/python3", args: ["-u", "-c", script, destination.path])
        try await waitUntil({ view.received.contains(Data("HARBOR_IME_READY".utf8)) }, message: "Raw PTY capture did not start")
    }

    @MainActor private func finishByteCapture(_ view: IMETestTerminal, destination: URL) async throws -> Data {
        view.process.send(data: [UInt8(4)][...])
        try await waitUntil({ view.received.contains(Data("HARBOR_IME_DONE".utf8)) }, message: "Raw PTY did not finish its byte capture")
        return try Data(contentsOf: destination)
    }

    @MainActor func testInputMethodRangesDescribeOnlyPreeditInUTF16() throws {
        let (window, view) = fixture(); defer { window.close() }
        view.feed(text: "shell prompt and previously committed 中文\r\n")
        view.selection.select(row: 0)
        XCTAssertEqual(view.selectedRange(), unspecified, "Scrollback selection is not editable input-method text")
        XCTAssertEqual(view.markedRange(), unspecified)
        let preedit = NSAttributedString(string: "中😀wen")
        view.setMarkedText(preedit, selectedRange: NSRange(location: 3, length: 2), replacementRange: unspecified)
        XCTAssertEqual(view.markedRange(), NSRange(location: 0, length: 6))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 3, length: 2))
        var actual = NSRange(location: 999, length: 999)
        XCTAssertEqual(view.attributedSubstring(forProposedRange: NSRange(location: 1, length: 99), actualRange: &actual)?.string, "😀wen")
        XCTAssertEqual(actual, NSRange(location: 1, length: 5))
        view.setMarkedText(preedit, selectedRange: NSRange(location: NSNotFound, length: 4), replacementRange: unspecified)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 6, length: 0))
        view.unmarkText()
        XCTAssertEqual(view.selectedRange(), unspecified)
        XCTAssertEqual(view.markedRange(), unspecified)
        XCTAssertNil(view.attributedSubstring(forProposedRange: NSRange(location: 0, length: 4), actualRange: &actual))
        XCTAssertEqual(actual, unspecified, "The input method must not retain stale replacement ranges")
        XCTAssertTrue(view.sent.isEmpty, "Preedit updates and unmarking cannot send shell input")
    }

    @MainActor func testInputSourceCommitReachesRealPTYOnceInEveryKeyboardMode() async throws {
        let (window, view) = fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-ime-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { view.terminate(); window.close(); try? FileManager.default.removeItem(at: root) }
        let capture = root.appendingPathComponent("received.bin")
        try await startByteCapture(view, destination: capture)
        var expected = Data()
        for flags in [0, 1, 11, 31] {
            view.feed(text: "\u{1b}[=\(flags);1u")
            let count = view.sent.count
            view.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: unspecified)
            view.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: unspecified)
            XCTAssertEqual(view.sent.count, count)
            view.insertText(NSAttributedString(string: "中文"), replacementRange: unspecified)
            view.unmarkText()
            XCTAssertFalse(view.hasMarkedText())
            // Some input sources clear their preedit before committing when
            // switched to English. This must remain a pure text event.
            view.setMarkedText("emoji", selectedRange: NSRange(location: 5, length: 0), replacementRange: unspecified)
            view.unmarkText()
            view.insertText("😀", replacementRange: unspecified)
            view.insertText("", replacementRange: unspecified)
            // Legitimate repeated commits must never be deduplicated by value.
            view.insertText("哈", replacementRange: unspecified)
            view.insertText("哈", replacementRange: unspecified)
            expected.append(Data("中文😀哈哈".utf8))
        }
        let received = try await finishByteCapture(view, destination: capture)
        XCTAssertEqual(received, expected)
        XCTAssertEqual(view.sent, expected)
    }

    @MainActor func testKittyPasteReachesRealPTYWithAndWithoutBrackets() async throws {
        let (window, view) = fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-ime-paste-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { view.terminate(); window.close(); try? FileManager.default.removeItem(at: root) }
        let clipboard = NSPasteboard.general
        let saved = (clipboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
        defer {
            clipboard.clearContents()
            clipboard.writeObjects(saved.map { data in
                let item = NSPasteboardItem()
                data.forEach { item.setData($0.value, forType: $0.key) }
                return item
            })
        }
        let capture = root.appendingPathComponent("received.bin")
        try await startByteCapture(view, destination: capture)
        let payload = "目录/重复 重复\nsecond line 😀"
        clipboard.clearContents()
        clipboard.setString(payload, forType: .string)
        var expected = Data()
        for flags in [8, 11] {
            for bracketed in [false, true] {
                view.feed(text: "\u{1b}[=\(flags);1u\u{1b}[?2004\(bracketed ? "h" : "l")")
                // Exercise the same native paste action used by Cmd+V and the
                // context menu, then inspect bytes read by the child process.
                view.paste(self)
                let text = bracketed ? "\u{1b}[200~" + payload + "\u{1b}[201~" : payload
                expected.append(Data(text.utf8))
            }
        }
        let received = try await finishByteCapture(view, destination: capture)
        XCTAssertEqual(received, expected)
        XCTAssertEqual(view.sent, expected)
    }

    @MainActor func testIMECommitKeyDoesNotLeakPressOrReleaseToTUI() {
        let (window, view) = fixture(); defer { window.close() }
        view.feed(text: "\u{1b}[=31;1u")
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: unspecified)
        view.interpret = { [unowned view] _ in
            view.insertText("你", replacementRange: self.unspecified)
        }
        view.keyDown(with: event(49, " "))
        view.keyUp(with: event(49, " ", type: .keyUp))
        XCTAssertEqual(view.sent, Data("你".utf8))
        XCTAssertEqual(view.interpretCount, 1)
        // The same physical key is usable immediately after composition.
        view.interpret = { [unowned view] _ in view.insertText(" ", replacementRange: self.unspecified) }
        view.keyDown(with: event(49, " "))
        view.keyUp(with: event(49, " ", type: .keyUp))
        XCTAssertEqual(view.sent, Data("你\u{1b}[32;;32u\u{1b}[32;1:3u".utf8))
    }

    @MainActor func testCandidateKeysStayWithIMEAndDelayedCommitDoesNotReusePhysicalKey() {
        let (window, view) = fixture(); defer { window.close() }
        view.feed(text: "\u{1b}[=31;1u")
        view.setMarkedText("候选", selectedRange: NSRange(location: 2, length: 0), replacementRange: unspecified)
        for (code, character): (UInt16, String) in [(125, "\u{f701}"), (36, "\r"), (51, "\u{7f}")] {
            view.keyDown(with: event(code, character))
            view.keyUp(with: event(code, character, type: .keyUp))
        }
        XCTAssertEqual(view.interpretCount, 3)
        view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        XCTAssertTrue(view.sent.isEmpty)
        view.unmarkText()
        view.keyDown(with: event(45, "n")) // An IME consumes this without synchronously inserting text.
        view.insertText("你", replacementRange: unspecified)
        XCTAssertEqual(view.sent, Data("你".utf8), "An asynchronous commit cannot inherit the old physical n key")
        view.sent.removeAll()
        view.interpret = { [unowned view] _ in view.insertText("x", replacementRange: self.unspecified) }
        view.keyDown(with: event(7, "x"))
        XCTAssertEqual(view.sent, Data("\u{1b}[120;;120u".utf8), "Normal Kitty keyboard reporting must remain enabled")
    }

    @MainActor func testEmptyPreeditAndBracketedPasteKeepTheirNormalSemantics() {
        let (window, view) = fixture(); defer { window.close() }
        view.feed(text: "\u{1b}[=31;1u\u{1b}[?2004h")
        view.setMarkedText("draft", selectedRange: NSRange(location: 5, length: 0), replacementRange: unspecified)
        view.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: unspecified)
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(view.markedRange(), unspecified)
        XCTAssertEqual(view.selectedRange(), unspecified)
        view.insertText(NSAttributedString(string: "一行\n一行"), replacementRange: unspecified, isPaste: true)
        XCTAssertEqual(view.sent, Data("\u{1b}[200~一行\n一行\u{1b}[201~".utf8))
    }
}

private final class IMETestTerminal: LocalProcessTerminalView {
    var sent = Data()
    var received = Data()
    var interpret: (([NSEvent]) -> Void)?
    var interpretCount = 0
    override func interpretKeyEvents(_ eventArray: [NSEvent]) {
        interpretCount += 1
        interpret?(eventArray)
    }
    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        sent.append(contentsOf: data)
        if process.running { super.send(source: source, data: data) }
    }
    override func dataReceived(slice: ArraySlice<UInt8>) {
        received.append(contentsOf: slice)
        super.dataReceived(slice: slice)
    }
}
