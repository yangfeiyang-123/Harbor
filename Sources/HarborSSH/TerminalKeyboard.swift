import AppKit
import SwiftUI

enum TerminalKeyboardCommand: Equatable {
    case close, move(Int), group(Int), rename, enterTerminal

    static func groupIndex(for keyCode: UInt16) -> Int? {
        // Use physical keys, as with the mode shortcut, including numeric keypads.
        let numbers: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        let keypad: [UInt16] = [83, 84, 85, 86, 87, 88, 89, 91, 92]
        return numbers.firstIndex(of: keyCode) ?? keypad.firstIndex(of: keyCode)
    }
    static func matching(_ event: NSEvent) -> Self? {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection(WorkspaceShortcut.modifierMask)
        if flags == .command {
            if event.keyCode == 51 || event.keyCode == 117 { return .close }
            if let index = groupIndex(for: event.keyCode) { return .group(index) }
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
        switch command {
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
                    let visible = fileMode ? currentFiles.terminalVisible && selectedSessionID == session.id : arrangement(in: scope).visible?.contains(session.id) == true
                    return visible && (responder === session.terminal || responder.isDescendant(of: session.terminal))
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
