import Foundation
import HarborCore

extension AppStore {
    /// No host addresses, credentials, shell commands or filesystem authority
    /// cross this bridge. Native actions resolve identifiers against our catalog.
    func workbenchNavigationState() -> [String: Any] {
        let servers: [[String: Any]] = ([nil] + profiles.map(Optional.some)).map { profile in
            let members = attachedSessions.filter { $0.profile?.id == profile?.id && !$0.ended }
            let integratedCount = codeWorkbench.terminalCount(for: profile?.id)
            let directories: [[String: Any]] = directoryWorkspaces(for: profile).filter { !$0.root.isEmpty }.map {
                ["id": $0.directoryID?.uuidString ?? "default", "name": $0.directoryTitle,
                 "active": selectedProfileID == profile?.id && selectedDirectoryID == $0.directoryID]
            }
            return ["id": profile?.id.uuidString ?? "local", "name": profile?.name ?? LocalMachine.name,
                    "connected": profile == nil || connectionStates[profile!.id] == "Connected" || integratedCount > 0 || !members.isEmpty,
                    "active": selectedProfileID == profile?.id, "count": integratedCount + members.count, "directories": directories]
        }
        return ["servers": servers, "legacyTerminals": previousSessions, "preferences": WorkbenchPreferences.payload()]
    }
    /// Terminals of this workspace's server that Harbor's own terminal host still keeps: the editor attaches one again on request.
    private var previousSessions: [[String: String]] {
        workspaceSessions.compactMap { session in
            guard session.profile != nil, session.remotePTYReconnect, let id = session.remotePTYID else { return nil }
            return ["id": id.uuidString, "name": session.displayTitle, "directory": session.effectiveDirectory ?? "~"]
        }
    }
    var hasPreviousSessions: Bool { !previousSessions.isEmpty }
    func handleWorkbenchAction(_ value: [String: String]) {
        switch value["action"] {
        case "server", "directory":
            guard let id = value["id"], id == "local" || profiles.contains(where: { $0.id.uuidString == id }) else { return }
            let profile = profiles.first { $0.id.uuidString == id }
            if value["action"] == "directory" {
                guard let directory = value["directory"], directoryIDs(for: profile?.id).contains(directory) else { return }
                let files = files(for: profile, directoryID: UUID(uuidString: directory))
                files.enabled = true; selectDirectoryWorkspace(files)
            } else {
                selectWorkspace(profile?.id)
                currentFiles.enabled = true
            }
        case "preference": WorkbenchPreferences.apply(event: value)
        case "openFolder": chooseDirectoryWorkspace()
        case "closeFolder":
            if value["id"] == nil { closeDirectoryWorkspace(currentFiles); return }
            guard let id = value["id"], id == "local" || profiles.contains(where: { $0.id.uuidString == id }),
                  let directory = value["directory"] else { return }
            let profile = profiles.first { $0.id.uuidString == id }
            guard directoryIDs(for: profile?.id).contains(directory) else { return }
            closeDirectoryWorkspace(files(for: profile, directoryID: UUID(uuidString: directory)))
        case "newTerminal": openIndependentTerminal()
        case "splitTerminal":
            if let editor = codeWorkbench.existing(for: currentFiles), editor.web != nil { editor.command("workbench.action.terminal.split") }
            else { splitTerminal(value["axis"] == "rows" ? .rows : .columns, session: activeSession) }
        case "toggleTerminal": toggleTerminalPanel()
        case "proxy": page = .proxy
        case "display": page = .display
        case "recent": page = .recent
        case "organizer": organizerVisible = true
        case "switchFolder": WorkspaceSwitcher.shared.present(sticky: true)
        case "terminalMode": currentFiles.enabled = false; currentFiles.persist(); objectWillChange.send()
        case "settings":
            // The page already asked for the panel when it held the editor's Settings editor back;
            // the extension's own report of that must not reopen a panel the user has closed since.
            if value["from"] == "editor", Date().timeIntervalSince(settingsEditorSeen) < 15 { break }
            workbenchUIRequest = "settings"
        case "addServer": workbenchUIRequest = value["action"]
        default: break
        }
    }
}
