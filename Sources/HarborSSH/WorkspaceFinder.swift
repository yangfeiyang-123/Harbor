import AppKit
import SwiftUI
import HarborCore

extension FileWorkspace {
    var rootEntry: WorkspaceEntry? {
        guard !root.isEmpty else { return nil }
        let name = (root as NSString).lastPathComponent
        return WorkspaceEntry(path: root, name: name.isEmpty ? root : name, directory: true, size: 0, modified: 0)
    }
}

/// Shared by the workspace title, explorer menu, and individual file rows.
struct WorkspaceFinderAction: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var workspace: FileWorkspace
    var entry: WorkspaceEntry? = nil
    var includeSelection = false

    var body: some View {
        if workspace.profile == nil, let target = entry ?? workspace.rootEntry {
            Button("Show in Finder") {
                let entries = includeSelection ? workspace.entriesForAction(on: target) : [target]
                store.showInFinder(entries, in: workspace)
            }
        }
    }
}

extension AppStore {
    func showInFinder(_ entries: [WorkspaceEntry], in files: FileWorkspace) {
        // A remote path can match a real local path; never reveal it locally.
        guard files.profile == nil, !entries.isEmpty else { return }
        let urls = entries.map { WorkspacePath.local($0.path) }
        if let missing = urls.first(where: { !FileManager.default.fileExists(atPath: $0.path) }) {
            errorMessage = "“\(missing.lastPathComponent)” is no longer available. Refresh the folder and try again."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
