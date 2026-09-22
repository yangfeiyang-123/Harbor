import XCTest
import AppKit
import SwiftUI
@testable import HarborSSH

final class WorkspaceShortcutTests: XCTestCase {
    @MainActor func testNativeMenusKeepArrowAndEscapeKeysOutOfTheExplorer() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let handler = ModeShortcutView(); window.contentView = handler
        defer { window.contentView = nil; window.close() }
        var commands = 0
        handler.terminalCommand = { _ in commands += 1; return true }
        let menu = NSMenu(), submenu = NSMenu()
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        XCTAssertNotNil(handler.handle(try event(code: 53, flags: [], chars: "\u{1b}", plain: "\u{1b}", window: window)))
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: submenu)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: submenu)
        XCTAssertNotNil(handler.handle(try event(code: 125, flags: [], chars: "", plain: "", window: window)))
        XCTAssertEqual(commands, 0)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        XCTAssertNil(handler.handle(try event(code: 125, flags: [], chars: "", plain: "", window: window)))
        XCTAssertEqual(commands, 1)
    }
    @MainActor func testSettingsRecorderFitsAndUpdatesTheStoredShortcut() async throws {
        _ = NSApplication.shared
        let suite = "app.harbor.settings." + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        prefs.set("dark", forKey: "appearance")
        defer { prefs.removePersistentDomain(forName: suite) }
        let store = AppStore(workspaceDefaults: prefs)
        let hosting = NSHostingView(rootView: SettingsView().environmentObject(store).defaultAppStorage(prefs))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 610, height: 740), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(nanoseconds: 150_000_000); hosting.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> ShortcutRecorderButton? {
            if let button = view as? ShortcutRecorderButton { return button }
            return view.subviews.lazy.compactMap(find).first
        }
        let recorder = try XCTUnwrap(find(hosting))
        XCTAssertTrue(hosting.bounds.contains(recorder.convert(recorder.bounds, to: hosting)))
        XCTAssertGreaterThanOrEqual(recorder.frame.width, 160)
        XCTAssertEqual(recorder.title, "⌥Z")
        recorder.beginRecording()
        NSApp.sendEvent(try event(code: 14, flags: [.control, .option], chars: "e", plain: "e", window: window))
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(WorkspaceShortcut.decode(try XCTUnwrap(prefs.string(forKey: WorkspaceShortcut.preferenceKey))).label, "⌃⌥E")
        if let output = ProcessInfo.processInfo.environment["HARBOR_QA_OUTPUT"], let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output).appendingPathComponent("settings-native.png"))
        }
    }
    @MainActor private func event(code: UInt16 = 6, flags: NSEvent.ModifierFlags = .option, chars: String = "Ω", plain: String = "z", window: NSWindow? = nil, repeatKey: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                      windowNumber: window?.windowNumber ?? 0, context: nil, characters: chars,
                                      charactersIgnoringModifiers: plain, isARepeat: repeatKey, keyCode: code))
    }
    @MainActor func testOptionShortcutRecordsWithoutAlternateTextAndPersists() throws {
        _ = NSApplication.shared
        let input = try event()
        let recorded = WorkspaceShortcut.recorded(from: input)
        XCTAssertEqual(recorded, .standard); XCTAssertEqual(recorded.label, "⌥Z")
        XCTAssertTrue(recorded.matches(input))
        XCTAssertTrue(recorded.matches(try event(flags: [.option, .capsLock])))
        XCTAssertFalse(recorded.matches(try event(flags: [.command, .option])))
        XCTAssertFalse(recorded.matches(try event(code: 8)))
        let suite = "app.harbor.shortcut." + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!; defer { prefs.removePersistentDomain(forName: suite) }
        let custom = WorkspaceShortcut(key: "e", keyCode: 14, modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue)
        prefs.set(custom.encoded, forKey: WorkspaceShortcut.preferenceKey)
        let reopened = UserDefaults(suiteName: suite)!
        XCTAssertEqual(WorkspaceShortcut.decode(reopened.string(forKey: WorkspaceShortcut.preferenceKey)!), custom)
        XCTAssertEqual(WorkspaceShortcut.decode("broken preference"), .standard)
    }
    @MainActor func testRecorderRejectsConflictsAndTypingAndCancelsWithoutChangingBinding() throws {
        _ = NSApplication.shared
        let button = ShortcutRecorderButton()
        var saved: WorkspaceShortcut?, error: String?
        button.onRecord = { saved = $0 }; button.onError = { error = $0 }
        button.record(try event(flags: [], chars: "x"))
        XCTAssertNotNil(error); XCTAssertNil(saved)
        button.record(try event(code: 2, flags: .command, chars: "d", plain: "d"))
        XCTAssertTrue(error?.contains("Split Right") == true); XCTAssertNil(saved)
        button.record(try event(code: 50, flags: [.control, .shift], chars: "~", plain: "~"))
        XCTAssertTrue(error?.contains("New Terminal Workspace") == true); XCTAssertNil(saved)
        button.record(try event(code: 18, flags: .command, chars: "1", plain: "1"))
        XCTAssertTrue(error?.contains("switches terminal workspaces") == true); XCTAssertNil(saved)
        button.record(try event(code: 7, flags: .option, chars: "≈", plain: "x"))
        XCTAssertTrue(error?.contains("maximizes or restores") == true); XCTAssertNil(saved)
        XCTAssertEqual(WorkspaceShortcut.decode(WorkspaceShortcut(key: "1", keyCode: 18, modifiers: NSEvent.ModifierFlags.command.rawValue).encoded), .standard)
        button.record(try event(code: 53, flags: [], chars: "\u{1b}", plain: "\u{1b}"))
        XCTAssertNil(saved); XCTAssertEqual(button.shortcut, .standard)
        button.record(try event(code: 14, flags: [.control, .option], chars: "e", plain: "e"))
        XCTAssertEqual(saved?.label, "⌃⌥E"); XCTAssertEqual(button.title, "⌃⌥E")
    }
    @MainActor func testOldOptionXPreferenceMigratesButCustomModeShortcutIsPreserved() throws {
        let suite = "app.harbor.shortcut-migration." + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        prefs.set(WorkspaceShortcut.maximizeTerminal.encoded, forKey: WorkspaceShortcut.preferenceKey)
        _ = AppStore(workspaceDefaults: prefs)
        XCTAssertEqual(WorkspaceShortcut.decode(prefs.string(forKey: WorkspaceShortcut.preferenceKey)!), .standard)
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceShortcut.self, from: Data(prefs.string(forKey: WorkspaceShortcut.preferenceKey)!.utf8)), .standard)
        let custom = WorkspaceShortcut(key: "e", keyCode: 14, modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue)
        prefs.set(custom.encoded, forKey: WorkspaceShortcut.preferenceKey)
        _ = AppStore(workspaceDefaults: prefs)
        XCTAssertEqual(WorkspaceShortcut.decode(prefs.string(forKey: WorkspaceShortcut.preferenceKey)!), custom)
    }
    @MainActor func testMaximizeKeyIsScopedToFileWorkspaceAndDoesNotInsertAlternateCharacter() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: window.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; other.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close(); other.close() }
        let handler = ModeShortcutView(); window.contentView = handler
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        handler.addSubview(text); window.makeFirstResponder(text)
        var maximized = 0, modes = 0
        handler.maximizeTerminal = { maximized += 1 }; handler.action = { modes += 1 }
        NSApp.sendEvent(try event(code: 7, chars: "≈", plain: "x", window: window))
        NSApp.sendEvent(try event(code: 7, chars: "≈", plain: "x", window: window, repeatKey: true))
        XCTAssertEqual(maximized, 1); XCTAssertEqual(modes, 0); XCTAssertEqual(text.string, "")
        XCTAssertNotNil(handler.handle(try event(code: 7, chars: "≈", plain: "x", window: other)))
        let recorder = ShortcutRecorderButton(); handler.addSubview(recorder); window.makeFirstResponder(recorder)
        XCTAssertNotNil(handler.handle(try event(code: 7, chars: "≈", plain: "x", window: window)))
        window.makeFirstResponder(text)
        handler.maximizeTerminal = nil
        XCTAssertNotNil(handler.handle(try event(code: 7, chars: "≈", plain: "x", window: window)), "Terminal-only mode must retain its Option/meta key")
        NSApp.sendEvent(try event(window: window))
        XCTAssertEqual(modes, 1); XCTAssertEqual(maximized, 1); XCTAssertEqual(text.string, "")
    }
    @MainActor func testNewTerminalKeyHandlesShiftTranslationWithoutConsumingOtherShortcuts() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let handler = ModeShortcutView(); window.contentView = handler
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100)); handler.addSubview(text); window.makeFirstResponder(text)
        var created = 0, toggled = 0
        handler.newTerminal = { created += 1 }; handler.action = { toggled += 1 }
        let shortcut = try event(code: 50, flags: [.control, .shift], chars: "~", plain: "~", window: window)
        NSApp.sendEvent(shortcut)
        XCTAssertEqual(created, 1); XCTAssertEqual(toggled, 0); XCTAssertEqual(text.string, "")
        NSApp.sendEvent(try event(code: 50, flags: [.control, .shift], chars: "~", plain: "~", window: window, repeatKey: true))
        XCTAssertEqual(created, 1)
        XCTAssertNotNil(handler.handle(try event(code: 50, flags: [.control], chars: "`", plain: "`", window: window)))
        XCTAssertNotNil(handler.handle(try event(code: 50, flags: [.shift], chars: "~", plain: "~", window: window)))
        XCTAssertNotNil(handler.handle(try event(code: 2, flags: [.command], chars: "d", plain: "d", window: window)))
        XCTAssertNotNil(handler.handle(try event(code: 4, flags: [.command], chars: "h", plain: "h", window: window)))
        XCTAssertNotNil(handler.handle(try event(code: 50, flags: [.control, .shift, .command], chars: "~", plain: "~", window: window)))
        XCTAssertNil(handler.handle(try event(code: 50, flags: [.control, .shift, .capsLock], chars: "~", plain: "~", window: window)))
        XCTAssertEqual(created, 2)
    }
    @MainActor func testShortcutIsConsumedOnceOnlyInItsWorkspaceAndOutsideRecorder() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: window.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; other.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close(); other.close() }
        let handler = ModeShortcutView(); window.contentView = handler
        var toggles = 0; handler.action = { toggles += 1 }
        XCTAssertNil(handler.handle(try event(window: window))); XCTAssertEqual(toggles, 1)
        XCTAssertNil(handler.handle(try event(window: window, repeatKey: true))); XCTAssertEqual(toggles, 1)
        XCTAssertNotNil(handler.handle(try event(window: other))); XCTAssertEqual(toggles, 1)
        XCTAssertNotNil(handler.handle(try event(flags: [], chars: "x", window: window))); XCTAssertEqual(toggles, 1)
        let recorder = ShortcutRecorderButton(); handler.addSubview(recorder); window.makeFirstResponder(recorder)
        XCTAssertNotNil(handler.handle(try event(window: window))); XCTAssertEqual(toggles, 1)
        window.makeFirstResponder(nil)
        handler.shortcut = WorkspaceShortcut(key: "e", keyCode: 14, modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue)
        XCTAssertNotNil(handler.handle(try event(window: window)))
        XCTAssertNil(handler.handle(try event(code: 14, flags: [.control, .option], chars: "e", plain: "e", window: window)))
        XCTAssertEqual(toggles, 2)
    }
    @MainActor func testAppEventDispatchConsumesShortcutBeforeTextInputAndWhileRecording() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let handler = ModeShortcutView(); window.contentView = handler
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        handler.addSubview(text); window.makeFirstResponder(text)
        var toggles = 0; handler.action = { toggles += 1 }
        NSApp.sendEvent(try event(window: window))
        XCTAssertEqual(toggles, 1); XCTAssertEqual(text.string, "", "Option's alternate character leaked into the editor")
        let recorder = ShortcutRecorderButton(); handler.addSubview(recorder)
        var saved: WorkspaceShortcut?, error: String?
        recorder.onRecord = { saved = $0 }; recorder.onError = { error = $0 }
        recorder.beginRecording()
        NSApp.sendEvent(try event(code: 2, flags: .command, chars: "d", plain: "d", window: window))
        XCTAssertTrue(error?.contains("Split Right") == true); XCTAssertTrue(recorder.recording); XCTAssertNil(saved)
        NSApp.sendEvent(try event(window: window))
        XCTAssertEqual(saved, .standard); XCTAssertFalse(recorder.recording)
        XCTAssertEqual(toggles, 1, "Recording must not trigger mode changes")
    }
}
