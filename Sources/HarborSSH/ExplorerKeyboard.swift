import AppKit
import SwiftUI
import HarborCore

@MainActor final class BrowserListFocus: ObservableObject { weak var view: BrowserListKeyView? }
struct BrowserListKeyboardBridge: NSViewRepresentable {
    let store: AppStore
    var workspace: FileWorkspace?
    var serverIDs: [UUID] = []
    let focus: BrowserListFocus
    func makeNSView(context: Context) -> BrowserListKeyView {
        let view = BrowserListKeyView(); focus.view = view; return view
    }
    func updateNSView(_ view: BrowserListKeyView, context: Context) {
        view.store = store; view.workspace = workspace; view.serverIDs = serverIDs
    }
}
final class BrowserListKeyView: NSView {
    weak var store: AppStore?
    weak var workspace: FileWorkspace?
    var serverIDs: [UUID] = []
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func focusList() {
        guard let store, let window else { return }
        (workspace ?? store.currentFiles).requestFocus(workspace == nil ? .servers : .explorer)
        window.makeFirstResponder(self)
    }
}

extension AppStore {
    func handleServerKey(_ event: NSEvent) -> Bool {
        guard !loading, let list = event.window?.firstResponder as? BrowserListKeyView,
              list.store === self, list.workspace == nil,
              event.modifierFlags.intersection(WorkspaceShortcut.modifierMask).isEmpty,
              event.keyCode == 125 || event.keyCode == 126 else { return false }
        let ids = list.serverIDs
        if let id = selectedProfileID, let index = ids.firstIndex(of: id) {
            let next = index + (event.keyCode == 125 ? 1 : -1)
            if ids.indices.contains(next) { selectWorkspace(ids[next]); list.focusList() }
        } else if let id = ids.first { selectWorkspace(id); list.focusList() }
        return true
    }
    func handleExplorerKey(_ event: NSEvent) -> Bool {
        guard !loading, page == .workspace, let list = event.window?.firstResponder as? BrowserListKeyView,
              list.store === self, let files = list.workspace, files === currentFiles, files.enabled else { return false }
        let flags = event.modifierFlags.intersection(WorkspaceShortcut.modifierMask)
        if (flags.isEmpty || flags == .shift), event.keyCode == 125 || event.keyCode == 126 {
            let rows = files.visibleRows.map(\.entry)
            guard !rows.isEmpty else { return true }
            let index = rows.firstIndex { $0.path == files.selectedEntryPath } ?? (event.keyCode == 125 ? -1 : rows.count)
            let next = min(max(index + (event.keyCode == 125 ? 1 : -1), 0), rows.count - 1)
            files.selectExplorerEntry(rows[next], modifiers: flags)
            return true
        }
        if flags.isEmpty {
            switch event.keyCode {
            case 123, 124:
                if let entry = files.selectedEntry, entry.directory {
                    let expanded = files.expanded.contains(entry.path)
                    if expanded == (event.keyCode == 123) { Task { await files.toggle(entry) } }
                }
                return true
            case 36, 76:
                if !event.isARepeat, files.selectedEntries.count == 1, let entry = files.selectedEntries.first { promptRenameEntry(entry, in: files); list.focusList() }
                return true
            case 53:
                files.explorerSelection.select(nil); return true
            default: return false
            }
        }
        if flags == .command {
            switch event.keyCode {
            case 0: files.explorerSelection.selectAll(files.visibleRows.map { $0.entry.path }); return true
            case 8: copyEntries(files.selectedEntries, in: files); return true
            case 9: if !event.isARepeat { pasteEntries(in: files) }; return true
            case 51, 117:
                if !event.isARepeat { deleteEntries(files.selectedEntries, in: files) }
                return true
            default: break
            }
        }
        if flags == [.command, .option], event.keyCode == 8 {
            copyEntryPaths(files.selectedEntries); return true
        }
        return false
    }
}

extension FileWorkspace {
    var explorerRootSelected: Bool {
        focusArea == .explorer && explorerSelection.paths.isEmpty && explorerSelection.focusedPath == nil
    }
    func selectExplorerRoot() {
        explorerSelection.select(nil)
        requestFocus(.explorer)
    }
    var selectedEntry: WorkspaceEntry? { entries.values.lazy.flatMap { $0 }.first { $0.path == selectedEntryPath } }
    var selectedEntries: [WorkspaceEntry] { visibleRows.map(\.entry).filter { explorerSelection.paths.contains($0.path) } }

    /// Returns whether this was a normal click that should also open the item.
    @discardableResult func selectExplorerEntry(_ entry: WorkspaceEntry, modifiers: NSEvent.ModifierFlags) -> Bool {
        if modifiers.contains(.shift) {
            explorerSelection.extend(to: entry.path, in: visibleRows.map { $0.entry.path }, additive: modifiers.contains(.command))
        } else if modifiers.contains(.command) { explorerSelection.toggle(entry.path) }
        else { explorerSelection.select(entry.path); return true }
        return false
    }
    func reconcileExplorerSelection() { explorerSelection.reconcile(with: visibleRows.map { $0.entry.path }) }
    func entriesForAction(on entry: WorkspaceEntry) -> [WorkspaceEntry] {
        explorerSelection.paths.contains(entry.path) ? selectedEntries : [entry]
    }
    func entriesForDrag(from entry: WorkspaceEntry) -> [WorkspaceEntry] {
        if !explorerSelection.paths.contains(entry.path) { explorerSelection.select(entry.path) }
        return selectedEntries
    }
    var visibleRows: [(entry: WorkspaceEntry, depth: Int)] {
        var result: [(WorkspaceEntry, Int)] = []
        func walk(_ path: String, depth: Int) {
            guard depth < 30 else { return }
            for entry in entries[path] ?? [] {
                if query.isEmpty || entry.name.localizedCaseInsensitiveContains(query) { result.append((entry, depth)) }
                if entry.directory && expanded.contains(entry.path) { walk(entry.path, depth: depth + 1) }
            }
        }
        walk(root, depth: 0); return result
    }
}
