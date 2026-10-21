import AppKit
import SwiftUI
import HarborCore

enum TerminalKeyboardCommand: Equatable {
    case close, move(Int), group(Int), rename, enterTerminal
    /// For terminals that fill their page or window: the pane before or after this one (⌥⌘ with
    /// an arrow, as in the editor's terminal), the tab before or after (⇧⌘[ and ⇧⌘]), a pane
    /// under this one (⇧⌘D, beside ⌘D for one to the right), a new tab (⌘T), and closing the
    /// pane in use with the key that closes anything (⌘W).
    case pane(Int), tab(Int), split(TerminalSplitAxis), newTab, closePane

    static func groupIndex(for keyCode: UInt16) -> Int? {
        // Use physical keys, as with the mode shortcut, including numeric keypads.
        let numbers: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        let keypad: [UInt16] = [83, 84, 85, 86, 87, 88, 89, 91, 92]
        return numbers.firstIndex(of: keyCode) ?? keypad.firstIndex(of: keyCode)
    }
    /// The letter a Command shortcut is meant by: the one on the key in the layout in use, as
    /// the menu's shortcuts are, so ⌘W is the key marked W on AZERTY and Dvorak too. A layout
    /// without Latin letters goes by the key's place on a US keyboard.
    static func letter(_ event: NSEvent) -> String? {
        if let typed = event.charactersIgnoringModifiers?.lowercased(), typed.count == 1, let scalar = typed.unicodeScalars.first,
           scalar.isASCII, CharacterSet.lowercaseLetters.contains(scalar) { return typed }
        return [13: "w", 2: "d", 17: "t"][event.keyCode]
    }
    /// Whether the event is the key a shortcut names by `character`: the key marked so in the
    /// layout in use, as for the menu's shortcuts. A layout that has no such character on the key
    /// (Cyrillic, Greek) goes by the key's place on a US keyboard.
    static func isKey(_ event: NSEvent, _ character: String, code: UInt16) -> Bool {
        if let typed = event.charactersIgnoringModifiers?.lowercased(), typed.count == 1, let scalar = typed.unicodeScalars.first,
           scalar.isASCII, scalar.value > 32, scalar.value < 127 { return typed == character }
        return event.keyCode == code
    }
    static func matching(_ event: NSEvent) -> Self? {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection(WorkspaceShortcut.modifierMask)
        if flags == .command {
            if event.keyCode == 51 || event.keyCode == 117 { return .close }
            if let index = groupIndex(for: event.keyCode) { return .group(index) }
            switch letter(event) {
            case "w": return .closePane
            case "d": return .split(.columns)
            case "t": return .newTab
            default: break
            }
        } else if flags == [.command, .option] {
            switch event.keyCode {
            case 123, 126: return .pane(-1)
            case 124, 125: return .pane(1)
            default: break
            }
        } else if flags == [.command, .shift] {
            switch event.keyCode {
            case 33: return .tab(-1)            // [
            case 30: return .tab(1)             // ]
            default: if letter(event) == "d" { return .split(.rows) }
            }
        } else if flags.isEmpty {
            switch event.keyCode {
            case 123, 126: return .move(-1)
            case 124, 125: return .move(1)
            case 36, 76: return .rename
            case 53: return .enterTerminal
            default: break
            }
        }
        return nil
    }
}

extension AppStore {
    /// Interpret navigation in the event's own window. Ordinary shell/editor
    /// keys must never be swallowed just because a terminal remains selected.
    func handleTerminalKey(_ event: NSEvent, in scope: TerminalScope) -> Bool {
        guard !loading, let window = event.window, let command = TerminalKeyboardCommand.matching(event) else { return false }
        let fileMode: Bool
        switch scope {
        case .workspace, .directory:
            guard page == .workspace, scope == currentTerminalScope else { return false }
            fileMode = currentFiles.enabled
        case .window: fileMode = false
        }
        let list = window.firstResponder as? TerminalListKeyView
        let listFocused = fileMode && currentFiles.terminalVisible && list?.scope == scope && list?.store === self
        /// The terminal the keys are going to: the pane that has the keyboard, else the one selected.
        var inUse: TerminalSession? {
            let responder = window.firstResponder as? NSView
            return terminalSessions(in: scope).first { session in
                isTerminalPresented(session, in: scope) && responder.map { $0 === session.terminal || $0.isDescendant(of: session.terminal) } == true
            } ?? selectedTerminal(in: scope)
        }
        switch command {
        case .pane, .tab, .split, .newTab, .closePane:
            // Only where terminals are the whole page: the plain terminal page, and a terminal
            // window for all but the keys it already has a meaning for (⌘W closes the window,
            // ⌘T and ⌘D are its menu's). In the editor these keys are the editor's.
            guard case .window(let id) = scope else { return false }
            let plain = homeTerminalScopes.values.contains(id) && page == .terminal
            switch command {
            case .pane(let step): if !event.isARepeat { focusTerminalPane(step, in: scope) }
            case .tab(let step): if !event.isARepeat { cycleTerminalGroup(step, in: scope) }
            case .split(.rows): if !event.isARepeat { splitTerminal(.rows, session: inUse) }
            case .split(.columns):
                guard plain else { return false }
                if !event.isARepeat { splitTerminal(.columns, session: inUse) }
            case .newTab:
                guard plain else { return false }
                if !event.isARepeat { openIndependentTerminal(in: scope) }
            case .closePane:
                guard plain, let target = inUse else { return false }
                if !event.isARepeat { close(target) }
            default: return false
            }
            return true
        case .group(let index):
            guard !fileMode else { return false }
            let groups = arrangement(in: scope).groups
            if !event.isARepeat, groups.indices.contains(index) { activateTerminalGroup(groups[index].id, in: scope) }
            return true
        case .move(let step):
            guard listFocused else { return false }
            let ids = arrangement(in: scope).sessionIDs
            if let selected = selectedTerminal(in: scope), let index = ids.firstIndex(of: selected.id),
               ids.indices.contains(index + step), let session = sessions.first(where: { $0.id == ids[index + step] }) {
                list?.select(session)
            }
            return true
        case .rename:
            guard listFocused else { return false }
            if !event.isARepeat, let session = selectedTerminal(in: scope) {
                promptForTerminalName(session)
                list?.focusList()
            }
            return true
        case .enterTerminal:
            guard listFocused else { return false }
            if !event.isARepeat, let session = selectedTerminal(in: scope) { activateTerminal(session) }
            return true
        case .close:
            let target: TerminalSession?
            if listFocused { target = selectedTerminal(in: scope) }
            else if let responder = window.firstResponder as? NSView {
                // Native focus can change before its queued selection callback.
                // Close the pane the user actually clicked, never its sibling.
                target = terminalSessions(in: scope).first { session in
                    isTerminalPresented(session, in: scope) && (responder === session.terminal || responder.isDescendant(of: session.terminal))
                }
            } else { target = nil }
            guard let target else { return false }
            if !event.isARepeat {
                close(target)
                if listFocused {
                    if selectedTerminal(in: scope) != nil { list?.focusList() }
                    else { currentFiles.requestFocus(.editor) }
                }
            }
            return true
        }
    }
}

/// A persistent first responder for the whole list. It survives row changes,
/// allowing held arrow keys to keep navigating without entering the next PTY.
@MainActor final class TerminalListFocus: ObservableObject {
    weak var view: TerminalListKeyView?
}

struct TerminalListKeyboardBridge: NSViewRepresentable {
    let store: AppStore
    let scope: TerminalScope
    let focus: TerminalListFocus
    func makeNSView(context: Context) -> TerminalListKeyView {
        let view = TerminalListKeyView(); focus.view = view; return view
    }
    func updateNSView(_ view: TerminalListKeyView, context: Context) {
        view.store = store; view.scope = scope
    }
}

final class TerminalListKeyView: NSView {
    weak var store: AppStore?
    var scope: TerminalScope = .workspace(nil)
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func focusList() {
        guard let store, let window, store.currentTerminalScope == scope,
              store.page == .workspace, store.currentFiles.enabled, store.currentFiles.terminalVisible else { return }
        store.currentFiles.requestFocus(.terminalList)
        window.makeFirstResponder(self)
    }
    func select(_ session: TerminalSession) {
        guard let store, store.terminalScope(of: session) == scope else { return }
        // Suppress any pending terminal-mount focus task before selecting a row.
        focusList()
        store.activateTerminal(session, requestFocus: false)
    }
}
