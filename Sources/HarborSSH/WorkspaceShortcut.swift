import AppKit
import SwiftUI

struct WorkspaceShortcut: Codable, Equatable {
    let key: String
    let keyCode: UInt16
    let modifiers: UInt
    static let preferenceKey = "workspaceModeShortcut"
    static let standard = WorkspaceShortcut(key: "z", keyCode: 6, modifiers: NSEvent.ModifierFlags.option.rawValue)
    static let maximizeTerminal = WorkspaceShortcut(key: "x", keyCode: 7, modifiers: NSEvent.ModifierFlags.option.rawValue)
    static let newTerminal = WorkspaceShortcut(key: "`", keyCode: 50, modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue)
    static let modifierMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers).intersection(Self.modifierMask) }
    var encoded: String { String(data: try! JSONEncoder().encode(self), encoding: .utf8)! }
    static func decode(_ raw: String) -> Self {
        guard let data = raw.data(using: .utf8), let value = try? JSONDecoder().decode(Self.self, from: data), value.validationError == nil else { return .standard }
        return value
    }
    static func migratePreference(in defaults: UserDefaults) {
        guard let raw = defaults.string(forKey: preferenceKey) else { return }
        let resolved = decode(raw)
        if let data = raw.data(using: .utf8), let stored = try? JSONDecoder().decode(Self.self, from: data), stored == resolved { return }
        defaults.set(resolved.encoded, forKey: preferenceKey)
    }
    var label: String {
        (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") +
        (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + key.uppercased()
    }
    var swiftModifiers: EventModifiers {
        var result: EventModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }
    var validationError: String? {
        guard key.count == 1, key.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.union(.whitespacesAndNewlines).contains($0) }),
              !flags.intersection([.command, .option, .control]).isEmpty else {
            return "Use ⌘, ⌥, or ⌃ with a letter, number, or symbol."
        }
        if keyCode == Self.newTerminal.keyCode && flags == Self.newTerminal.flags {
            return "⌃⇧` is assigned to “New Terminal Workspace”. Choose another shortcut."
        }
        if keyCode == Self.maximizeTerminal.keyCode && flags == Self.maximizeTerminal.flags {
            return "⌥X maximizes or restores the terminal panel. Choose another shortcut."
        }
        if flags == .command, let index = TerminalKeyboardCommand.groupIndex(for: keyCode) {
            return "⌘\(index + 1) switches terminal workspaces. Choose another shortcut."
        }
        let reserved: [String: String] = [
            "⌘D": "Split Right", "⌘H": "Split Down", "⌘T": "New Terminal", "⌘N": "New Window", "⌘W": "Close Window",
            "⌘Q": "Quit", "⌘S": "Save", "⌘F": "Find", "⌘J": "Terminal Panel", "⌘0": "Workbench", "⌘,": "Settings",
            "⌘C": "Copy", "⌘V": "Paste", "⌘X": "Cut", "⌘A": "Select All", "⌘Z": "Undo", "⇧⌘Z": "Redo",
            "⌘=": "Increase Font Size", "⌘-": "Decrease Font Size", "⇧⌘0": "Reset Font Size", "⇧⌘W": "Close Terminal", "⇧⌘O": "Go to Symbol",
            "⇧⌘L": "Local Terminal", "⇧⌘H": "Recents", "⇧⌘P": "Command Palette", "⌥⌘H": "Hide Other Apps", "⌃`": "Switch Focus", "⌃⇧`": "New Terminal Workspace",
            "⌘P": "Quick Open", "⇧⌘F": "Search in Project", "⌘B": "Toggle Explorer", "⌃G": "Go to Line", "⌥⌘O": "Open Folder"
        ]
        if let action = reserved[label] { return "\(label) is assigned to “\(action)”. Choose another shortcut." }
        return nil
    }
    static func recorded(from event: NSEvent) -> Self {
        // Translate the physical key without Option's alternate character (⌥Z
        // produces Ω). The key code also works while a Chinese input source is on.
        let key = (event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? "").lowercased()
        return Self(key: key, keyCode: event.keyCode, modifiers: event.modifierFlags.intersection(modifierMask).rawValue)
    }
    func matches(_ event: NSEvent) -> Bool {
        event.type == .keyDown && event.keyCode == keyCode && event.modifierFlags.intersection(Self.modifierMask) == flags
    }
}

/// App-local interception precedes the terminal's Option/meta input handling.
/// No global key listener or Accessibility permission is needed.
struct WorkspaceShortcutHandler: NSViewRepresentable {
    let shortcut: WorkspaceShortcut
    var newTerminal: (() -> Void)? = nil
    var maximizeTerminal: (() -> Void)? = nil
    var terminalCommand: ((NSEvent) -> Bool)? = nil
    let action: (() -> Void)?
    func makeNSView(context: Context) -> ModeShortcutView { ModeShortcutView() }
    func updateNSView(_ view: ModeShortcutView, context: Context) {
        view.shortcut = shortcut; view.action = action; view.newTerminal = newTerminal; view.maximizeTerminal = maximizeTerminal; view.terminalCommand = terminalCommand
    }
}
final class ModeShortcutView: NSView {
    var shortcut = WorkspaceShortcut.standard
    var action: (() -> Void)?
    var newTerminal: (() -> Void)?
    var maximizeTerminal: (() -> Void)?
    var terminalCommand: ((NSEvent) -> Bool)?
    private var monitor: Any?
    private var menuObservers: [NSObjectProtocol] = []
    private var trackingMenus = Set<ObjectIdentifier>()
    private var consumedTerminalKey: UInt16?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        menuObservers.forEach(NotificationCenter.default.removeObserver); menuObservers.removeAll(); trackingMenus.removeAll()
        if window != nil {
            for (name, opening) in [(NSMenu.didBeginTrackingNotification, true), (NSMenu.didEndTrackingNotification, false)] {
                menuObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated {
                        guard let menu = note.object as? NSMenu else { return }
                        if opening { self?.trackingMenus.insert(ObjectIdentifier(menu)) }
                        else { self?.trackingMenus.remove(ObjectIdentifier(menu)) }
                    }
                })
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }
    }
    func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window else { return event }
        if event.type == .keyUp {
            if consumedTerminalKey == event.keyCode { consumedTerminalKey = nil }
            return event
        }
        guard event.type == .keyDown, trackingMenus.isEmpty, window.attachedSheet == nil, NSApp.modalWindow == nil,
              !(window.firstResponder is ShortcutRecorderButton) else { return event }
        // Handle Copy before menus or SwiftTerm keyDown can clear the selection.
        // Text fields, the editor, and terminal search retain their own Copy.
        if let terminal = window.firstResponder as? CapturingTerminal, terminal.handleCopyKey(event) { return nil }
        // Closing the last terminal can focus the editor. A held Delete must
        // not continue there and remove code after closing that terminal.
        if event.isARepeat, consumedTerminalKey == event.keyCode { return nil }
        if !event.isARepeat { consumedTerminalKey = nil }
        // Match the physical grave key: Shift may produce '~' or a layout-specific character.
        if WorkspaceShortcut.newTerminal.matches(event), let newTerminal {
            if !event.isARepeat { newTerminal() }
            return nil
        }
        if WorkspaceShortcut.maximizeTerminal.matches(event), let maximizeTerminal {
            if !event.isARepeat { maximizeTerminal() }
            return nil
        }
        if terminalCommand?(event) == true {
            // Arrow repeats are intentional list navigation; destructive and
            // group actions are one-shot until their physical key is released.
            if event.modifierFlags.intersection(WorkspaceShortcut.modifierMask) == .command || TerminalKeyboardCommand.matching(event) == .rename { consumedTerminalKey = event.keyCode }
            return nil
        }
        if shortcut.matches(event), let action {
            if !event.isARepeat { action() }
            return nil
        }
        return event
    }
    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        menuObservers.forEach(NotificationCenter.default.removeObserver)
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var value: String
    var reportError: (String?) -> Void
    func makeNSView(context: Context) -> ShortcutRecorderButton { ShortcutRecorderButton() }
    func updateNSView(_ view: ShortcutRecorderButton, context: Context) {
        view.shortcut = WorkspaceShortcut.decode(value)
        view.onRecord = { shortcut in value = shortcut.encoded; reportError(nil) }
        view.onError = reportError
        view.refreshTitle()
    }
    static func dismantleNSView(_ view: ShortcutRecorderButton, coordinator: ()) { view.stopRecording() }
}

final class ShortcutRecorderButton: NSButton {
    var shortcut = WorkspaceShortcut.standard
    var onRecord: ((WorkspaceShortcut) -> Void)?
    var onError: ((String?) -> Void)?
    private(set) var recording = false
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    override var acceptsFirstResponder: Bool { true }
    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded; target = self; action = #selector(beginRecording)
        toolTip = "Click, then press a new shortcut; Esc cancels"
        setAccessibilityLabel("Mode Switch Shortcut")
        refreshTitle()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func refreshTitle() { title = recording ? "Press shortcut…" : shortcut.label }
    @objc func beginRecording() {
        guard let window else { return }
        if recording { stopRecording(); return }
        recording = true; onError?(nil); refreshTitle(); window.makeFirstResponder(self)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.recording, event.window === self.window else { return event }
            self.record(event); return nil
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in self?.stopRecording() }
    }
    func record(_ event: NSEvent) {
        if event.keyCode == 53 { stopRecording(); return }
        guard !event.isARepeat else { return }
        let value = WorkspaceShortcut.recorded(from: event)
        if let error = value.validationError { onError?(error); return }
        shortcut = value; stopRecording(); onRecord?(value)
    }
    func stopRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver); self.resignObserver = nil }
        refreshTitle()
    }
    override func resignFirstResponder() -> Bool { stopRecording(); return super.resignFirstResponder() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { stopRecording() } }
    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }
}
