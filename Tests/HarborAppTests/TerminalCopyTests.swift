import XCTest
import AppKit
import SwiftTerm
@testable import HarborSSH

final class TerminalCopyTests: XCTestCase {
    @MainActor private func terminalWindow() -> (NSWindow, CapturingTerminal, ModeShortcutView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let terminal = CapturingTerminal(frame: NSRect(x: 0, y: 0, width: 780, height: 380))
        let handler = ModeShortcutView(frame: .zero)
        window.contentView!.addSubview(terminal); window.contentView!.addSubview(handler)
        window.makeFirstResponder(terminal)
        return (window, terminal, handler)
    }
    @MainActor private func withClipboard(_ body: () throws -> Void) rethrows {
        let clipboard = NSPasteboard.general
        let saved = (clipboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
        defer {
            clipboard.clearContents()
            clipboard.writeObjects(saved.map { data in
                let item = NSPasteboardItem(); data.forEach { item.setData($0.value, forType: $0.key) }; return item
            })
        }
        clipboard.clearContents(); clipboard.setString("clipboard sentinel", forType: .string)
        try body()
    }
    @MainActor private func copyEvent(_ window: NSWindow, flags: NSEvent.ModifierFlags = .command) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8)!
    }

    @MainActor func testStreamingOutputPreservesSelectedTextForCopy() throws {
        let (window, terminal, _) = terminalWindow(); defer { window.close() }
        terminal.feed(text: "selected output 中文\r\n")
        terminal.selection.select(row: 0)
        let chosen = terminal.selection.getSelectedText()
        XCTAssertEqual(chosen.trimmingCharacters(in: .whitespacesAndNewlines), "selected output 中文")
        terminal.feed(text: "new progress update\r\nmore output\r\n")
        XCTAssertTrue(terminal.selection.active, "Streaming logs must not discard the user's selection")
        withClipboard {
            terminal.copy(self)
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), chosen)
        }
    }

    @MainActor func testCopyShortcutKeepsSelectionAndDoesNotConsumeControlCOrEditorCopy() throws {
        let (window, terminal, handler) = terminalWindow(); defer { window.close() }
        terminal.feed(text: "  exact spaces and text  \r\n")
        terminal.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 25, row: 0))
        let chosen = terminal.selection.getSelectedText()
        withClipboard {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString("clipboard sentinel", forType: .string)
            XCTAssertNil(handler.handle(copyEvent(window)), "Copy must be handled before terminal keyDown clears the selection")
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), chosen)
            XCTAssertTrue(terminal.selection.active)
            XCTAssertNotNil(handler.handle(copyEvent(window, flags: .control)), "Control-C belongs to the shell")
            terminal.selection.selectNone()
            _ = handler.handle(copyEvent(window))
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), chosen, "No selection must not empty the clipboard")
            let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
            window.contentView!.addSubview(editor); window.makeFirstResponder(editor)
            XCTAssertNotNil(handler.handle(copyEvent(window)), "Editor copy must use the normal responder chain")
        }
    }

    @MainActor func testClickingTerminalTakesFocusFromFileList() {
        let (window, terminal, _) = terminalWindow(); defer { window.close() }
        let list = BrowserListKeyView(); window.contentView!.addSubview(list); window.makeFirstResponder(list)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 20, y: 200), modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        terminal.mouseDown(with: event)
        XCTAssertTrue(window.firstResponder === terminal, "The visible selection and Copy must belong to the clicked terminal")
    }

    @MainActor func testContextMenuCopiesTheClickedPaneAndDisablesEmptyCopy() throws {
        let (window, terminal, _) = terminalWindow(); defer { window.close() }
        terminal.feed(text: "right-click copy\r\n"); terminal.selection.select(row: 0)
        let chosen = terminal.selection.getSelectedText()
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 30, y: 200), modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let menu = try XCTUnwrap(terminal.menu(for: event))
        XCTAssertEqual(menu.items.map(\.title), ["Copy", "Paste", "Select All"])
        XCTAssertTrue(window.firstResponder === terminal)
        menu.update(); XCTAssertTrue(menu.items[0].isEnabled)
        withClipboard {
            menu.performActionForItem(at: 0)
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), chosen)
            terminal.selection.selectNone(); menu.update()
            XCTAssertFalse(menu.items[0].isEnabled)
            terminal.copy(self)
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), chosen)
        }
    }
}
