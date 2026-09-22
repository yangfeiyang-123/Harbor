import AppKit
import HarborCore

enum TerminalScope: Hashable, Codable { case workspace(UUID?), directory(UUID?, UUID), window(UUID) }

extension AppStore {
    /// New terminal groups are independent of the currently selected split tree.
    func openIndependentTerminal(in scope: TerminalScope? = nil) {
        if case .window(let windowID) = scope {
            guard let selected = selectedTerminal(in: .window(windowID)),
                  let id = openTerminal(selected.profile, detached: true, workingDirectory: selected.workingDirectory, windowID: windowID, directoryWorkspace: files(for: selected.profile, directoryID: selected.directoryWorkspaceID)),
                  let created = sessions.first(where: { $0.id == id }) else { return }
            activateTerminal(created)
        } else { openWorkspaceTerminal() }
    }
    var currentTerminalScope: TerminalScope { selectedDirectoryID.map { .directory(selectedProfileID, $0) } ?? .workspace(selectedProfileID) }
    func terminalScope(of session: TerminalSession) -> TerminalScope {
        session.windowID.map(TerminalScope.window) ?? session.directoryWorkspaceID.map { .directory(session.profile?.id, $0) } ?? .workspace(session.profile?.id)
    }
    func terminalSessions(in scope: TerminalScope) -> [TerminalSession] {
        sessions.filter { terminalScope(of: $0) == scope }
    }
    func arrangement(in scope: TerminalScope) -> TerminalArrangement {
        if let layout = terminalLayouts[scope] { return layout }
        var layout = TerminalArrangement()
        terminalSessions(in: scope).forEach { layout.insert($0.id) }
        if scope == currentTerminalScope, let selectedSessionID { layout.select(selectedSessionID) }
        return layout
    }
    func selectedTerminal(in scope: TerminalScope) -> TerminalSession? {
        let layout = arrangement(in: scope)
        return sessions.first { $0.id == layout.selectedID }
    }
    func registerTerminal(_ session: TerminalSession) {
        let scope = terminalScope(of: session)
        var layout = arrangement(in: scope); layout.insert(session.id); terminalLayouts[scope] = layout
        session.terminal.onFocus = { [weak self, weak session] in
            guard let self, let session, self.sessions.contains(where: { $0 === session }) else { return }
            // AppKit can deliver the old pane's focus callback while SwiftUI is
            // replacing it. Only panes in the current presentation may select.
            let scope = self.terminalScope(of: session)
            guard self.arrangement(in: scope).visible?.contains(session.id) == true else { return }
            if !session.detached {
                guard self.page == .workspace, self.currentTerminalScope == scope else { return }
                if self.currentFiles.enabled {
                    guard self.currentFiles.terminalVisible, self.selectedSessionID == session.id else { return }
                    self.currentFiles.focusArea = .terminal
                }
            }
            self.activateTerminal(session, requestFocus: false)
        }
    }
    func selectInArrangement(_ session: TerminalSession) {
        let scope = terminalScope(of: session)
        var layout = arrangement(in: scope)
        if layout.selectedID != session.id { layout.select(session.id); terminalLayouts[scope] = layout }
    }
    func activateTerminal(_ session: TerminalSession, requestFocus: Bool = true) {
        if session.detached {
            selectInArrangement(session)
            if requestFocus { session.terminal.window?.makeFirstResponder(session.terminal) }
        } else if selectedSessionID != session.id || selectedProfileID != session.profile?.id {
            selectSession(session, requestFocus: requestFocus)
        } else if requestFocus { currentFiles.requestFocus(.terminal) }
    }
    func splitTerminal(_ axis: TerminalSplitAxis, session: TerminalSession? = nil) {
        var source = session ?? activeSession
        if source == nil { openWorkspaceTerminal(); source = activeSession }
        guard let source else { return }
        if source.profile != nil, source.ready {
            Task { await refreshTerminalDirectories([source]); completeTerminalSplit(axis, source: source) }
        } else { completeTerminalSplit(axis, source: source) }
    }
    func completeTerminalSplit(_ axis: TerminalSplitAxis, source: TerminalSession) {
        guard sessions.contains(where: { $0 === source }) else { return }
        let scope = terminalScope(of: source)
        let before = arrangement(in: scope)
        let files = files(for: source.profile, directoryID: source.directoryWorkspaceID)
        let directory = source.effectiveDirectory
        guard let newID = openTerminal(source.profile, detached: source.detached, workingDirectory: directory, useWorkspaceDirectory: false, windowID: source.windowID, directoryWorkspace: files) else { return }
        var layout = before
        if let group = layout.groups.first(where: { $0.layout.contains(source.id) }), group.title == nil {
            let name = sessions.first(where: { $0.id == group.sessionIDs.first })?.tabTitle ?? source.tabTitle
            layout.setTitle(name, for: group.id)
        }
        layout.split(source.id, adding: newID, axis: axis)
        terminalLayouts[scope] = layout
        if !source.detached { files.terminalVisible = true; files.requestFocus(.terminal) }
    }
    func resizeTerminalSplit(_ splitID: UUID, in scope: TerminalScope, ratio: Double) {
        var layout = arrangement(in: scope); layout.resize(splitID, ratio: ratio); terminalLayouts[scope] = layout
    }
    func separateTerminal(_ session: TerminalSession) {
        let scope = terminalScope(of: session)
        var layout = arrangement(in: scope); layout.separate(session.id); terminalLayouts[scope] = layout
        activateTerminal(session)
    }
    func activateTerminalGroup(_ groupID: UUID, in scope: TerminalScope) {
        guard let group = arrangement(in: scope).groups.first(where: { $0.id == groupID }),
              let session = sessions.first(where: { $0.id == group.selectedID }) else { return }
        activateTerminal(session)
    }
    func resizeTerminalTab(_ groupID: UUID, in scope: TerminalScope, width: Double) {
        var layout = arrangement(in: scope)
        layout.setTabWidth(width, for: groupID); terminalLayouts[scope] = layout
    }
    func promptForTerminalName(_ session: TerminalSession) {
        session.promptForName()
        let scope = terminalScope(of: session)
        var layout = arrangement(in: scope)
        if let group = layout.groups.first(where: { $0.layout.contains(session.id) }), group.sessionIDs.count == 1, group.title == nil {
            layout.setTabWidth(max(group.tabWidth ?? 150, session.tabWidth ?? 150), for: group.id)
            terminalLayouts[scope] = layout
        }
    }
    func renameTerminalGroup(_ groupID: UUID, in scope: TerminalScope) {
        var layout = arrangement(in: scope)
        guard let group = layout.groups.first(where: { $0.id == groupID }),
              let first = sessions.first(where: { $0.id == group.sessionIDs.first }) else { return }
        if group.sessionIDs.count == 1 && group.title == nil {
            first.promptForName()
            layout.setTabWidth(max(group.tabWidth ?? 150, first.tabWidth ?? 150), for: groupID)
        } else {
            let alert = NSAlert(); alert.messageText = "Rename Terminal Workspace"
            let field = NSTextField(string: group.title ?? first.tabTitle)
            field.frame = NSRect(x: 0, y: 0, width: 300, height: 24); alert.accessoryView = field
            alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let name = String(field.stringValue.components(separatedBy: .controlCharacters).joined().trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
            let title = name.isEmpty ? first.tabTitle : name
            layout.setTitle(title, for: groupID)
            layout.setTabWidth(max(group.tabWidth ?? 150, WorkspaceTabLayout.fittedWidth(title)), for: groupID)
        }
        terminalLayouts[scope] = layout
    }
    func closeTerminalGroup(_ groupID: UUID, in scope: TerminalScope, ask: Bool = true) {
        guard let group = arrangement(in: scope).groups.first(where: { $0.id == groupID }) else { return }
        let members = group.sessionIDs.compactMap { id in sessions.first { $0.id == id } }
        if members.count == 1 { if let session = members.first { close(session, ask: ask) }; return }
        if ask && members.contains(where: { !$0.ended }) {
            let alert = NSAlert(); alert.messageText = "Close this terminal workspace?"
            alert.informativeText = "This closes \(members.count) terminal panes. Their foreground commands may end. Other workspaces and shared SSH connections will remain open."
            alert.addButton(withTitle: "Close Workspace"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        members.forEach { close($0, ask: false) }
    }
    func closeTerminalWindow(_ windowID: UUID) {
        terminalSessions(in: .window(windowID)).forEach { close($0, ask: false) }
        terminalLayouts.removeValue(forKey: .window(windowID))
    }
}
