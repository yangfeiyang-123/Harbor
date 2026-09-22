import AppKit
import SwiftUI
import HarborCore

/// Lives behind the rows, so only empty explorer space selects the workspace.
struct ExplorerBackground: NSViewRepresentable {
    let store: AppStore
    @ObservedObject var workspace: FileWorkspace
    let focus: BrowserListFocus

    func makeNSView(context: Context) -> ExplorerBackgroundView { ExplorerBackgroundView() }
    func updateNSView(_ view: ExplorerBackgroundView, context: Context) {
        view.store = store; view.workspace = workspace; view.focus = focus
        view.registerForDraggedTypes(WorkspaceDragDrop.folderTypes.map { NSPasteboard.PasteboardType($0) })
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel("Select workspace folder: " + workspace.directoryTitle)
        view.setAccessibilityIdentifier("explorer-root-background")
    }
}

final class ExplorerBackgroundView: NSView {
    weak var store: AppStore?
    weak var workspace: FileWorkspace?
    weak var focus: BrowserListFocus?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let workspace, !workspace.fileOperation, let root = workspace.rootEntry,
              sender.draggingPasteboard.availableType(from: WorkspaceDragDrop.folderTypes.map { NSPasteboard.PasteboardType($0) }) != nil else { return [] }
        workspace.dropDestination = root
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { clearDrop() }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { clearDrop() }
    private func clearDrop() {
        if workspace?.dropDestination?.path == workspace?.root { workspace?.dropDestination = nil }
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { clearDrop() }
        guard let workspace, let store, !workspace.fileOperation, !workspace.root.isEmpty else { return false }
        let payload = WorkspaceDropPayload.capture([], pasteboard: sender.draggingPasteboard)
        let copy = NSEvent.modifierFlags.contains(.option) || sender.draggingPasteboard.availableType(from: [.init(WorkspaceDropItem.typeIdentifier)]) == nil
        store.acceptFileDrop(payload, into: workspace.root, in: workspace, copy: copy)
        return true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { selectRoot() }
    override func accessibilityPerformPress() -> Bool { selectRoot(); return true }
    override func rightMouseDown(with event: NSEvent) {
        guard let menu = rootMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    override func accessibilityPerformShowMenu() -> Bool {
        guard let menu = rootMenu() else { return false }
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.midX, y: bounds.midY), in: self)
        return true
    }

    private func selectRoot() {
        workspace?.selectExplorerRoot()
        focus?.view?.focusList()
    }

    override func menu(for event: NSEvent) -> NSMenu? { rootMenu() }
    private func rootMenu() -> NSMenu? {
        guard let workspace, !workspace.root.isEmpty else { return nil }
        // Select before menu tracking begins, including a right-click without
        // a preceding left-click. Child selections must not affect this menu.
        selectRoot()
        let menu = NSMenu(); menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, enabled: Bool = true, key: String = "") {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self; item.isEnabled = enabled; menu.addItem(item)
        }
        let ready = workspace.service != nil && !workspace.busy && !workspace.fileOperation
        add("New File…", #selector(newFile(_:)), enabled: ready)
        add("New Folder…", #selector(newFolder(_:)), enabled: ready)
        menu.addItem(.separator())
        add("Paste", #selector(pasteItems(_:)), enabled: ready, key: "v")
        add("Copy Path", #selector(copyPath(_:)))
        if workspace.profile == nil { add("Show in Finder", #selector(showInFinder(_:))) }
        menu.addItem(.separator())
        add("Refresh Explorer", #selector(refresh(_:)), enabled: ready)
        return menu
    }

    @objc private func newFile(_ sender: Any?) { workspace?.create(directory: false, parent: workspace?.root) }
    @objc private func newFolder(_ sender: Any?) { workspace?.create(directory: true, parent: workspace?.root) }
    @objc private func pasteItems(_ sender: Any?) {
        if let workspace { store?.pasteEntries(in: workspace, parent: workspace.root) }
    }
    @objc private func copyPath(_ sender: Any?) {
        if let entry = workspace?.rootEntry { store?.copyEntryPath(entry) }
    }
    @objc private func showInFinder(_ sender: Any?) {
        if let workspace, let entry = workspace.rootEntry { store?.showInFinder([entry], in: workspace) }
    }
    @objc private func refresh(_ sender: Any?) {
        if let workspace { Task { await workspace.refreshExpanded(force: true) } }
    }
}
