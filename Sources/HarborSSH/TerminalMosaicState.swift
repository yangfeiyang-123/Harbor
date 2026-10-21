import AppKit
import HarborCore

enum TerminalScope: Hashable, Codable { case workspace(UUID?), directory(UUID?, UUID), window(UUID) }

/// One split may await a remote working-directory lookup for each source pane.
/// Repeated shortcuts share that request; cancellation also invalidates a lookup
/// that does not itself cooperate with Task cancellation.
@MainActor final class TerminalSplitRequest {
    private var task: Task<Void, Never>?
    private var ticket: UUID?
    var pending: Bool { ticket != nil }

    func run(refresh: @escaping @MainActor () async -> Void, completion: @escaping @MainActor () -> Void) {
        guard !pending else { return }
        let current = UUID(); ticket = current
        task = Task { [weak self] in
            await refresh()
            guard let self, ticket == current else { return }
            task = nil; ticket = nil
            guard !Task.isCancelled else { return }
            completion()
        }
    }

    func cancel() {
        ticket = nil
        task?.cancel(); task = nil
    }
}

extension AppStore {
    /// New terminal groups are independent of the currently selected split tree.
    func openIndependentTerminal(in scope: TerminalScope? = nil) {
        // On the terminal page a new terminal is a tab of that page.
        if scope == nil, page == .terminal, let home = homeTerminalScope { openIndependentTerminal(in: .window(home)); return }
        if case .window(let windowID) = scope {
            guard let selected = selectedTerminal(in: .window(windowID)) else { return }
            // A plain terminal belongs to no folder: the new one starts where this one is now.
            let plain = homeTerminalScopes.values.contains(windowID)
            let directory = plain ? selected.effectiveDirectory ?? (selected.profile == nil ? NSHomeDirectory() : nil) : selected.workingDirectory
            guard let id = openTerminal(selected.profile, detached: true, workingDirectory: directory, useWorkspaceDirectory: !plain, windowID: windowID, directoryWorkspace: files(for: selected.profile, directoryID: selected.directoryWorkspaceID)),
                  let created = sessions.first(where: { $0.id == id }) else { return }
            activateTerminal(created)
        } else if page == .workspace { openWorkspaceTerminal() }
        // With no workspace on screen there is no panel to add a terminal to: asking for one in
        // the background started the selected server's editor, and a connection to it, unseen.
        else if page == .recent { openHomeTerminal(nil) }
    }
    /// The pane before or after the one in use, in the order they are laid out, and around at the ends.
    func focusTerminalPane(_ step: Int, in scope: TerminalScope) {
        let layout = arrangement(in: scope)
        guard let ids = layout.visible?.sessionIDs, ids.count > 1, let selected = layout.selectedGroup?.selectedID,
              let index = ids.firstIndex(of: selected) else { return }
        let next = ids[((index + step) % ids.count + ids.count) % ids.count]
        if let session = sessions.first(where: { $0.id == next }) { activateTerminal(session) }
    }
    /// The tab before or after the one on screen, and around at the ends.
    func cycleTerminalGroup(_ step: Int, in scope: TerminalScope) {
        let groups = arrangement(in: scope).groups
        guard groups.count > 1, let current = arrangement(in: scope).selectedGroup, let index = groups.firstIndex(where: { $0.id == current.id }) else { return }
        activateTerminalGroup(groups[((index + step) % groups.count + groups.count) % groups.count].id, in: scope)
    }
    var currentTerminalScope: TerminalScope {
        if page == .terminal, let scope = homeTerminalScope { return .window(scope) }
        return selectedDirectoryID.map { .directory(selectedProfileID, $0) } ?? .workspace(selectedProfileID)
    }
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
    /// A terminal is presented when it is in the visible split group of its scope.
    func isTerminalPresented(_ session: TerminalSession, in scope: TerminalScope) -> Bool {
        guard terminalScope(of: session) == scope,
              arrangement(in: scope).visible?.contains(session.id) == true else { return false }
        if case .window = scope { return true }
        guard page == .workspace, currentTerminalScope == scope else { return false }
        guard currentFiles.enabled else { return true }
        guard currentFiles.terminalVisible else { return false }
        return true
    }
    func registerTerminal(_ session: TerminalSession) {
        let scope = terminalScope(of: session)
        var layout = arrangement(in: scope); layout.insert(session.id); terminalLayouts[scope] = layout
        session.terminal.onFocus = { [weak self, weak session] in
            guard let self, let session, self.sessions.contains(where: { $0 === session }) else { return }
            // AppKit can deliver the old pane's focus callback while SwiftUI is
            // replacing it. Only panes in the current presentation may select.
            let scope = self.terminalScope(of: session)
            guard self.isTerminalPresented(session, in: scope) else { return }
            if !session.detached {
                if self.currentFiles.enabled {
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
        var source = session ?? (page == .terminal ? homeTerminal : activeSession)
        if source == nil {
            // Only where a workspace is on screen. (From the start page this started the selected
            // server's editor in the background, with a connection nobody had asked for.)
            guard page == .workspace else { return }
            openWorkspaceTerminal(); source = activeSession
        }
        guard let source else { return }
        if source.profile != nil, source.ready {
            enqueueTerminalSplit(axis, source: source, refresh: { [weak self, weak source] in
                guard let self, let source, !source.ended else { return }
                // Keep the fresh remote lookup: cached OSC/cwd values can lag a
                // just-entered `cd`, so skipping it may start in the wrong folder.
                await self.refreshTerminalDirectories([source])
            })
        } else { completeTerminalSplit(axis, source: source) }
    }
    /// A remote directory lookup can outlive a workspace/group/focus change.
    /// Finish creating the requested pane without navigating the user back.
    func enqueueTerminalSplit(_ axis: TerminalSplitAxis, source: TerminalSession, refresh: @escaping @MainActor () async -> Void) {
        let sourceScope = terminalScope(of: source)
        let sourceGroup = arrangement(in: sourceScope).selectedGroup?.id
        let requestedPage = page, requestedScope = currentTerminalScope
        let requestedFocus = currentFiles.focusRequest
        source.splitRequest.run(refresh: refresh, completion: { [weak self, weak source] in
            guard let self, let source else { return }
            let sameGroup = self.arrangement(in: sourceScope).selectedGroup?.id == sourceGroup
            let activate = sameGroup && (source.detached ||
                self.page == requestedPage && self.currentTerminalScope == requestedScope && self.currentFiles.focusRequest == requestedFocus)
            self.completeTerminalSplit(axis, source: source, activate: activate)
        })
    }
    func completeTerminalSplit(_ axis: TerminalSplitAxis, source: TerminalSession, activate: Bool = true) {
        guard !source.ended, sessions.contains(where: { $0 === source }) else { return }
        let scope = terminalScope(of: source)
        let before = arrangement(in: scope)
        let files = files(for: source.profile, directoryID: source.directoryWorkspaceID)
        let directory = source.effectiveDirectory
        guard let newID = openTerminal(source.profile, detached: source.detached, workingDirectory: directory, useWorkspaceDirectory: false, windowID: source.windowID, directoryWorkspace: files, activate: activate) else { return }
        var layout = before
        if let group = layout.groups.first(where: { $0.layout.contains(source.id) }), group.title == nil {
            let name = sessions.first(where: { $0.id == group.sessionIDs.first })?.tabTitle ?? source.tabTitle
            layout.setTitle(name, for: group.id)
        }
        layout.split(source.id, adding: newID, axis: axis)
        if !activate, let selected = before.selectedID { layout.select(selected) }
        terminalLayouts[scope] = layout
        if activate && !source.detached { files.terminalVisible = true; files.requestFocus(.terminal) }
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
