import SwiftUI
import AppKit
import HarborCore

struct FileDropGlass: View {
    let title: String
    let detail: String
    var body: some View {
        RoundedRectangle(cornerRadius: 10).fill(Color.harborAccent.opacity(0.10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.harborFocus.opacity(0.8), lineWidth: 1.5) }
            .overlay {
                VStack(spacing: 4) {
                    Label(title, systemImage: "folder.badge.plus").harborFont(12, weight: .medium)
                    Text(detail).harborFont(10).lineLimit(2).truncationMode(.middle).foregroundStyle(Color.harborMuted)
                }.padding(12).harborGlass(radius: 14, elevated: true).padding(5)
            }.allowsHitTesting(false)
    }
}
private struct WorkspaceOpenDrop: ViewModifier {
    @EnvironmentObject var store: AppStore
    let workspace: FileWorkspace
    @State private var targeted = false
    func body(content: Content) -> some View {
        content.contentShape(Rectangle()).onDrop(of: WorkspaceDragDrop.types, isTargeted: $targeted) { providers in
            targeted = false
            Task {
                do { await store.openDroppedWorkspace(try await WorkspaceDragDrop.plan(from: providers), target: workspace) }
                catch { store.errorMessage = error.localizedDescription }
            }
            return true
        }.overlay {
            if targeted { FileDropGlass(title: "Drop to Open", detail: "Preview files here · Open folders as separate workspaces") }
        }.onDisappear { targeted = false }
    }
}
private struct WorkspaceFolderDrop: ViewModifier {
    @EnvironmentObject var store: AppStore
    let entry: WorkspaceEntry
    let workspace: FileWorkspace
    @State private var targeted = false
    @ViewBuilder func body(content: Content) -> some View {
        if entry.directory {
            content.onDrop(of: WorkspaceDragDrop.folderTypes, isTargeted: $targeted) { providers in
                targeted = false
                let payload = WorkspaceDropPayload.capture(providers)
                let copy = NSEvent.modifierFlags.contains(.option) || payload.external
                store.acceptFileDrop(payload, into: entry.path, in: workspace, copy: copy)
                return true
            }.overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 7).fill(Color.harborFocus.opacity(0.18))
                        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Color.harborFocus, lineWidth: 1.5) }.allowsHitTesting(false)
                }
            }.onChange(of: targeted) { _, active in
                if active { workspace.dropDestination = entry }
                else if workspace.dropDestination?.path == entry.path { workspace.dropDestination = nil }
            }.onDisappear { targeted = false; if workspace.dropDestination?.path == entry.path { workspace.dropDestination = nil } }
        } else { content }
    }
}
extension View {
    func workspaceOpenDrop(workspace: FileWorkspace) -> some View { modifier(WorkspaceOpenDrop(workspace: workspace)) }
    func workspaceFolderDrop(entry: WorkspaceEntry, workspace: FileWorkspace) -> some View { modifier(WorkspaceFolderDrop(entry: entry, workspace: workspace)) }
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
