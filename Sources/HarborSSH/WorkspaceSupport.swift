import AppKit
import SwiftUI
import UniformTypeIdentifiers
import HarborCore

extension Notification.Name {
    static let harborFindRecent = Notification.Name("harbor.find.recent")
    /// A window started or stopped an editor on a server, or changed which workspace it shows.
    static let harborServersChanged = Notification.Name("harbor.servers.changed")
}

/// Reads files and folders dropped onto a terminal or the workbench.
enum WorkspaceDragDrop {
    static let types = [WorkspaceDropItem.typeIdentifier, UTType.fileURL.identifier]
    static func plan(from providers: [NSItemProvider]) async throws -> WorkspaceDropPlan {
        try await WorkspaceDropPlan(items: items(from: providers))
    }
    static func items(from providers: [NSItemProvider]) async throws -> [WorkspaceDropItem] {
        var items: [WorkspaceDropItem] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(WorkspaceDropItem.typeIdentifier) {
                let data = try await data(from: provider, type: WorkspaceDropItem.typeIdentifier)
                if let group = try? JSONDecoder().decode([WorkspaceDropItem].self, from: data) { items += group }
                else { items.append(try JSONDecoder().decode(WorkspaceDropItem.self, from: data)) }
            } else {
                let data = try await data(from: provider, type: UTType.fileURL.identifier)
                guard let url = URL(dataRepresentation: data, relativeTo: nil) else { throw WorkspaceError.message("Unable to read the dropped file path.") }
                items += try WorkspaceDropPlan.localItems(urls: [url])
            }
        }
        return items
    }
    private static func data(from provider: NSItemProvider, type: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if let data, data.count <= 1_048_576 { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? WorkspaceError.message("Unable to read the dropped item.")) }
            }
        }
    }
}

/// Reveals a local workspace's folder in Finder. A remote path can match a real
/// local path, so remote workspaces never offer this.
struct WorkspaceFinderAction: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var workspace: FileWorkspace
    var body: some View {
        if workspace.profile == nil, !workspace.root.isEmpty {
            Button("Show in Finder") {
                let url = WorkspacePath.local(workspace.root)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    store.errorMessage = "“\(url.lastPathComponent)” is no longer available."; return
                }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }
}

/// Up/Down in the server list moves between servers once the list has focus.
@MainActor final class BrowserListFocus: ObservableObject { weak var view: BrowserListKeyView? }
struct BrowserListKeyboardBridge: NSViewRepresentable {
    let store: AppStore
    var serverIDs: [UUID] = []
    let focus: BrowserListFocus
    func makeNSView(context: Context) -> BrowserListKeyView {
        let view = BrowserListKeyView(); focus.view = view; return view
    }
    func updateNSView(_ view: BrowserListKeyView, context: Context) { view.store = store; view.serverIDs = serverIDs }
}
final class BrowserListKeyView: NSView {
    weak var store: AppStore?
    var serverIDs: [UUID] = []
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func focusList() {
        guard let store, let window else { return }
        store.currentFiles.requestFocus(.servers)
        window.makeFirstResponder(self)
    }
}

extension AppStore {
    func handleServerKey(_ event: NSEvent) -> Bool {
        guard !loading, let list = event.window?.firstResponder as? BrowserListKeyView, list.store === self,
              event.modifierFlags.intersection(WorkspaceShortcut.modifierMask).isEmpty,
              event.keyCode == 125 || event.keyCode == 126 else { return false }
        let ids = list.serverIDs
        if let id = selectedProfileID, let index = ids.firstIndex(of: id) {
            let next = index + (event.keyCode == 125 ? 1 : -1)
            if ids.indices.contains(next) { selectWorkspace(ids[next]); list.focusList() }
        } else if let id = ids.first { selectWorkspace(id); list.focusList() }
        return true
    }
}

extension WorkspaceDragDrop {
    static func items(from pasteboard: NSPasteboard) throws -> [WorkspaceDropItem] {
        var result: [WorkspaceDropItem] = []
        for item in pasteboard.pasteboardItems ?? [] {
            if let data = item.data(forType: .init(WorkspaceDropItem.typeIdentifier)), data.count <= 1_048_576 {
                if let single = try? JSONDecoder().decode(WorkspaceDropItem.self, from: data) { result.append(single) }
                else { result += try JSONDecoder().decode([WorkspaceDropItem].self, from: data) }
            } else if let text = item.string(forType: .fileURL), let url = URL(string: text) { result += try WorkspaceDropPlan.localItems(urls: [url]) }
        }
        return result
    }
    static func terminalText(_ items: [WorkspaceDropItem], profileID: UUID?) throws -> String {
        guard !items.isEmpty, items.allSatisfy({ $0.profileID == nil || $0.profileID == profileID }) else { throw WorkspaceError.message("This path belongs to a different server.") }
        return try items.map { item in
            guard item.entry.path.hasPrefix("/"), !item.entry.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw WorkspaceError.message("The path contains control characters that cannot be inserted into the terminal.") }
            return SSHArguments.quote(item.entry.path)
        }.joined(separator: " ") + " "
    }
}
