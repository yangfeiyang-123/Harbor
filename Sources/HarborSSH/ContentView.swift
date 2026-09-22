import SwiftUI
import AppKit
import HarborCore

struct ContentView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("sidebarWidth") private var sidebarWidth = 220.0
    @AppStorage("headerHeight") private var headerHeight = 48.0
    @AppStorage(WorkspaceShortcut.preferenceKey) private var modeShortcut = WorkspaceShortcut.standard.encoded
    @State private var sidebarDragStart: Double?
    @State private var headerDragStart: Double?
    @State private var editing: ServerProfile?
    var body: some View {
        GeometryReader { geometry in
            let width = min(max(sidebarWidth, 52), min(380, geometry.size.width - 500))
            VStack(spacing: 0) {
                header(reveal: min(HarborLayout.reveal(headerHeight, from: 32, to: 46), HarborLayout.reveal(geometry.size.width, from: 560, to: 850)))
                    .frame(height: max(30, min(112, headerHeight)))
                    .background(Color.harborBackground)
                ResizeHandle(vertical: false, label: "Resize Toolbar", reset: { animateLayout { headerHeight = 48 } }) { delta in
                        if headerDragStart == nil { headerDragStart = headerHeight }
                        headerHeight = min(max((headerDragStart ?? 48) + delta, 30), 112)
                } end: { headerDragStart = nil }
                HStack(spacing: 0) {
                    WorkspaceSidebar(width: width, resize: { sidebarWidth = $0 }, edit: { editing = $0 }).frame(width: width)
                    ResizeHandle(vertical: true, label: "Resize Sidebar", reset: { animateLayout { sidebarWidth = 220 } }) { delta in
                        if sidebarDragStart == nil { sidebarDragStart = width }
                        sidebarWidth = min(max((sidebarDragStart ?? width) + delta, 52), min(380, geometry.size.width - 500))
                    } end: { sidebarDragStart = nil }
                    switch store.page {
                    case .workspace: FileWorkspaceView(workspace: store.currentFiles) { terminalWorkspace }.id(store.currentFiles.key)
                    case .display: RemoteDisplayPage(controller: store.remoteDisplays)
                    case .proxy: ProxyPage()
                    case .recent: RecentWorkspacesView()
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 760, minHeight: 500)
        .background(Color.harborBackground)
        .background(WindowChrome())
        .background(WorkspaceShortcutHandler(shortcut: WorkspaceShortcut.decode(modeShortcut), newTerminal: { store.openIndependentTerminal() },
            maximizeTerminal: store.page == .workspace && store.currentFiles.enabled ? { store.toggleTerminalMaximized() } : nil,
            terminalCommand: { (store.page == .workspace && store.currentFiles.handleEditorKey($0)) || store.handleExplorerKey($0) || store.handleServerKey($0) || store.handleTerminalKey($0, in: store.currentTerminalScope) },
            action: { store.page = .workspace; store.toggleFiles() }).accessibilityHidden(true))
        .focusedSceneValue(\.harborWorkspace, true)
        .tint(.harborButton)
        .harborFont().foregroundStyle(Color.harborForeground)
        .environment(\.locale, Locale(identifier: "en"))
            .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .onChange(of: store.loading) { _, loading in
            if !loading { for id in Set(store.sessions.compactMap(\.windowID)) { openWindow(id: "terminal", value: id) } }
        }
        .disabled(store.loading)
        .overlay { if store.loading { ProgressView("Loading local data…").padding(30).harborGlass(radius: 14, elevated: true) } }
        .sheet(item: $editing) { profile in ServerEditor(profile: profile) { store.upsert($0) } }
        .sheet(item: $store.directoryBrowser) { browser in DirectoryBrowserView(browser: browser).environmentObject(store) }
        .alert("Harbor", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }
    private func animateLayout(_ changes: () -> Void) { withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.88), changes) }
    private var pageTitle: String { store.page == .workspace ? store.selectedProfile?.name ?? "Local Terminal" : store.page.rawValue }
    private var pageIcon: String {
        switch store.page {
        case .workspace: return store.selectedProfile?.displayIcon ?? "laptopcomputer"
        case .display: return "display"
        case .proxy: return "arrow.left.arrow.right"
        case .recent: return "clock.arrow.circlepath"
        }
    }
    private func header(reveal: Double) -> some View {
        HarborGlassCluster {
        HStack(spacing: 8 + 4 * reveal) {
            Color.clear.frame(width: 84).allowsHitTesting(false)
            HStack(spacing: 8) {
                HarborSymbol(systemName: pageIcon).font(.system(size: 15)).foregroundStyle(Color.harborAccent).frame(width: 24, height: 26)
                Text(pageTitle).harborFont(15, weight: .semibold).lineLimit(1).truncationMode(.tail)
                    .layoutPriority(1)
            }.fixedSize(horizontal: false, vertical: true).accessibilityElement(children: .ignore)
                .accessibilityLabel(pageTitle).compactHint(pageTitle, edge: .minY)
            if store.page == .workspace { DirectoryWorkspaceMenu() }
            WindowDragArea().frame(minWidth: 8, maxWidth: .infinity)
            if store.page == .workspace {
                headerAction(store.currentFiles.enabled ? "Terminal Mode" : "Files & Code", icon: store.currentFiles.enabled ? "terminal" : "folder", reveal: reveal) { store.toggleFiles() }.help("Switch Files / Terminal Mode \(WorkspaceShortcut.decode(modeShortcut).label) · Switch focus ⌃`")
                headerAction("Remote Display", icon: "display", reveal: 0) { store.page = .display }
                headerAction("New Terminal", icon: "plus", reveal: reveal, prominent: true) { store.openWorkspaceTerminal() }
            }
            Menu {
                if store.page == .workspace {
                    Button("Switch Editor / Terminal Focus ⌃`") { store.toggleWorkspaceFocus() }
                    Button("Show / Hide Terminal Panel ⌘J") { store.toggleTerminalPanel() }
                    if store.currentFiles.enabled {
                        Button("Maximize / Restore Terminal Panel ⌥X") { store.toggleTerminalMaximized() }
                    }
                    if store.selectedDirectoryID != nil { Button("Close Folder Workspace") { store.closeDirectoryWorkspace(store.currentFiles) } }
                    Button("Open in New Window") { if let id = store.openTerminal(store.selectedProfile, detached: true) { openWindow(id: "terminal", value: id) } }
                    Divider().overlay(Color.harborBorder)
                }
                Button("Add Server…") { editing = ServerProfile() }
                Button(headerHeight < 46 ? "Expand Toolbar" : "Toolbar Icons Only") { animateLayout { headerHeight = headerHeight < 46 ? 58 : 30 } }
                Button("Sidebar Icons Only") { animateLayout { sidebarWidth = 52 } }
                Button("Reset Layout") { animateLayout { headerHeight = 48; sidebarWidth = 220; UserDefaults.standard.set(215.0, forKey: "fileTreeWidth"); UserDefaults.standard.set(160.0, forKey: "fileTerminalListWidth") } }
            } label: { HarborSymbol(systemName: "ellipsis").frame(width: 28, height: 26).harborGlass() }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Workbench Options")
                .compactHint("Workbench Options", enabled: reveal < 0.9, edge: .minY)
        }.padding(.leading, 6).padding(.trailing, 10)
        }
    }
    private func headerAction(_ title: String, icon: String, reveal: Double, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6 * reveal) {
                HarborSymbol(systemName: icon).font(.system(size: 14))
                RevealingLabel(amount: reveal) { Text(title).harborFont(12, weight: .medium).lineLimit(1) }
            }.frame(minWidth: 28, minHeight: 26).padding(.horizontal, 8 * reveal)
                .foregroundStyle(prominent ? Color.white : .harborIcon)
                .contentShape(Rectangle())
        }.buttonStyle(HarborGlassButtonStyle(prominent: prominent)).accessibilityLabel(title).compactHint(title, enabled: reveal < 0.9, edge: .minY)
    }
    private var terminalWorkspace: some View { TerminalWorkspaceView(scope: store.currentTerminalScope) }

}

struct ResizeHandle: View {
    let vertical: Bool
    var thickness = 5.0
    var accessibilityReversed = false
    let label: String
    let reset: () -> Void
    let change: (Double) -> Void
    let end: () -> Void
    @State private var hovered = false
    var body: some View {
        Rectangle().fill(hovered ? Color.harborFocus : Color.harborBackground)
            .overlay { Rectangle().fill(Color.harborBorder).frame(width: vertical ? 1 : nil, height: vertical ? nil : 1) }
            .frame(width: vertical ? thickness : nil, height: vertical ? nil : thickness)
            .contentShape(Rectangle())
            .onHover { hovered = $0; ($0 ? (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown) : NSCursor.arrow).set() }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { change(vertical ? $0.translation.width : $0.translation.height) }
                .onEnded { _ in end() })
            .onTapGesture(count: 2, perform: reset)
            .help("\(label); drag to resize, double-click to reset")
            .accessibilityLabel(label)
            .accessibilityAdjustableAction { direction in change((direction == .increment ? 10.0 : -10.0) * (accessibilityReversed ? -1 : 1)); end() }
    }
}

struct SessionPanel: View {
    @ObservedObject var session: TerminalSession
    var showsStatus = true
    @EnvironmentObject var store: AppStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var search = ""
    @State private var found = true
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            if session.searching {
                HStack {
                    HarborSymbol(systemName: "magnifyingglass")
                    TextField("Find in terminal", text: $search).textFieldStyle(HarborTextFieldStyle()).focused($searchFocused)
                        .onSubmit { find(forward: true) }
                        .task { await Task.yield(); searchFocused = true }
                        .onDisappear { searchFocused = false }
                    if !found { Text("No matches").harborFont(11).foregroundStyle(Color.harborMuted) }
                    Button { find(forward: false) } label: { HarborSymbol(systemName: "chevron.up") }.help("Previous Match")
                    Button { find(forward: true) } label: { HarborSymbol(systemName: "chevron.down") }.help("Next Match")
                    Button("Done") { searchFocused = false; session.searching = false }
                }.padding(10)
            }
            if session.ended {
                HStack { Label(session.status, systemImage: "network.slash"); Spacer(); Button("Saved Output") { session.showSavedOutput() }; Button("Reconnect") { store.reconnect(session) } }.harborFont(12).padding(12).background(Color.orange.opacity(0.09))
            }
            TerminalSurface(session: session).padding(.top, 8).background(Color(nsColor: TerminalTheme.background(dark: colorScheme == .dark)))
            if showsStatus {
                HStack { ConnectionStatus(session: session); Spacer() }.harborFont(10).foregroundStyle(Color.harborMuted)
                    .padding(.horizontal, 12).frame(height: 26)
            }
        }
        .task(id: session.searching) {
            await Task.yield()
            guard !Task.isCancelled, !session.searching,
                  session.detached || (store.page == .workspace && store.currentTerminalScope == store.terminalScope(of: session) &&
                    (store.currentFiles.focusArea == .terminal)),
                  store.selectedTerminal(in: store.terminalScope(of: session))?.id == session.id else { return }
            session.terminal.window?.makeFirstResponder(session.terminal)
        }
    }
    private func find(forward: Bool) {
        guard !search.isEmpty else { return }
        found = forward ? session.terminal.findNext(search) : session.terminal.findPrevious(search)
    }
}


struct ServerEditor: View {
    @Environment(\.dismiss) var dismiss
    @State var profile: ServerProfile
    var onSave: (ServerProfile) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(profile.name.isEmpty ? "Add Server" : "Edit Server").harborFont(20, weight: .semibold).padding(24)
            Form {
                Section("Connection") {
                    TextField("Name", text: $profile.name)
                    TextField(profile.imported ? "SSH Alias" : "Host / IP Address", text: $profile.host)
                    if profile.imported { Text("Connection options, keys, and jump hosts come from ~/.ssh/config. Changes here are saved only in Harbor.").harborFont(11).foregroundStyle(Color.harborMuted) }
                    else {
                        TextField("Username", text: $profile.user)
                        TextField("Port", value: $profile.port, format: .number.grouping(.never))
                        HStack { TextField("Identity File (optional)", text: $profile.identityFile); Button("Choose…") { let p = NSOpenPanel(); p.canChooseDirectories = false; p.showsHiddenFiles = true; if p.runModal() == .OK { profile.identityFile = p.url?.path ?? "" } } }
                    }
                }
                Section("Session") {
                    Text("Remote terminals reconnect to the same process using Harbor’s private PTY host.").font(.caption).foregroundStyle(.secondary)
                    Text("Requires Python 3. The private terminal host keeps disconnected processes for up to 24 hours. No tmux or public listening ports.").harborFont(11).foregroundStyle(Color.harborMuted)
                }
                Section("Server Icon") {
                    HStack(spacing: 6) {
                        ForEach(Array(ServerIcons.symbols.enumerated()), id: \.element) { index, symbol in
                            Button { profile.iconSymbol = symbol } label: {
                                HarborSymbol(systemName: symbol).font(.system(size: 16)).frame(width: 32, height: 32)
                                    .foregroundStyle(profile.iconSymbol == symbol ? Color.harborAccent : .secondary)
                                    .background(profile.iconSymbol == symbol ? Color.harborAccent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain).accessibilityLabel(ServerIcons.names[index]).help(ServerIcons.names[index])
                        }
                    }
                    if profile.iconSymbol == nil { Text("An icon is assigned automatically when you save.").harborFont(11).foregroundStyle(Color.harborMuted) }
                }
            }.formStyle(.grouped)
            HStack { if let error = profile.validationError { Text(error).harborFont(11).foregroundStyle(Color.harborMuted) }; Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Save") { onSave(profile); dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(profile.validationError != nil) }.padding(20)
        }.frame(width: 570, height: profile.imported ? 545 : 625)
    }
}
