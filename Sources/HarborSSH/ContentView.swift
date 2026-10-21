import SwiftUI
import AppKit
import HarborCore

struct ContentView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(HarborMotion.preferenceKey) private var motion = HarborMotion.Level.full.rawValue
    private var motionLevel: HarborMotion.Level { HarborMotion.level(motion, reduceMotion: reduceMotion) }
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("appearance") private var appearance = HarborTheme.defaultAppearance
    @AppStorage(WorkspaceShortcut.preferenceKey) private var modeShortcut = WorkspaceShortcut.standard.encoded
    @State private var editing: ServerProfile?
    @StateObject private var toolbarVisibility = WorkbenchToolbarVisibility()
    var body: some View {
        GeometryReader { _ in
            let top = store.windowTop
            // Every page fills the window under one slim bar of its own in the title row: the
            // editor's, the terminal's, or a page's with the way back. (There used to be a second
            // shell, a sidebar of servers and a toolbar, around every page that was not the editor.)
            VStack(spacing: 0) {
                // The content reaches the top of the window, where the system puts the tab bar once
                // there are tabs. A page keeps its bar in the title row and leaves room under it (or
                // above it in full screen, where there is no title row); the start page starts below.
                if (startPage ? top.covered : top.aboveBar) > 0 {
                    // A background would otherwise spread over the whole covered region, the bar included.
                    WindowDragArea().frame(height: startPage ? top.covered : top.aboveBar).background(barBackground, ignoresSafeAreaEdges: [])
                }
                if startPage {
                    StartView(addServer: { editing = ServerProfile() }, editServer: { editing = $0 })
                } else {
                    if plainTerminal {
                        HomeTerminalBar(height: top.barHeight, leading: top.barLeading)
                    } else if unifiedEditor {
                        WorkbenchTopBar(visibility: toolbarVisibility, session: store.codeWorkbench.session(for: store.currentFiles),
                                        height: top.barHeight, leading: top.barLeading, addServer: { editing = ServerProfile() })
                    } else {
                        // In front of its page, whatever that page paints its ground with.
                        PageBar(title: pageTitle, symbol: pageIcon, returns: store.page != .workspace, height: top.barHeight, leading: top.barLeading).zIndex(1)
                    }
                    if top.belowBar > 0 { WindowDragArea().frame(height: top.belowBar).background(barBackground, ignoresSafeAreaEdges: []) }
                    pageContent.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // The page a workspace shows while its editor starts; its title ends in the bar above.
            .overlay {
                if unifiedEditor, !store.loading {
                    WorkspaceOpening(session: store.codeWorkbench.session(for: store.currentFiles), workspace: store.currentFiles, top: top)
                        .id(store.currentFiles.key)
                } else if let note = store.arriving {
                    // A folder dropped on Harbor: its name is here before anything about it has been read.
                    WorkspaceArrival(note: note, top: top)
                }
            }
        }.ignoresSafeArea(.container, edges: .top)
        // Under the organizer the page takes no clicks anyway. Saying so keeps it out of what is
        // gone through for the pointer on every frame while a list of the organizer scrolls.
        .allowsHitTesting(!store.organizerVisible)
        .frame(minWidth: 760, minHeight: 500)
        .background(Color.harborBackground)
        .background(WindowChrome(top: { [weak store] top in if let store, store.windowTop != top { store.windowTop = top } }))
        .background(WorkspaceShortcutHandler(shortcut: WorkspaceShortcut.decode(modeShortcut), newTerminal: { store.openIndependentTerminal() },
            maximizeTerminal: store.page == .workspace && store.currentFiles.enabled ? { store.toggleTerminalMaximized() } : nil,
            terminalCommand: { store.handleSettingsKey($0) || store.handleWindowKey($0) || store.handleCodeWorkbenchKey($0) || store.handleServerKey($0) || store.handleTerminalKey($0, in: store.currentTerminalScope) },
            // The mode switch is a workspace's. On any other page the key is not taken: in a plain
            // terminal ⌥Z reaches the shell instead of sending the window to an editor.
            action: store.page == .workspace ? { store.toggleFiles() } : nil).accessibilityHidden(true))
        .focusedSceneValue(\.harborWorkspace, store.page == .workspace)
        .tint(.harborButton)
        .harborFont().foregroundStyle(Color.harborForeground).harborTypography()
        .environment(\.locale, Locale(identifier: "en"))
            .preferredColorScheme(HarborTheme.scheme(appearance))
        .onChange(of: store.loading) { _, loading in
            // The terminals that were windows come back as windows. One of a server's plain
            // terminal page waits for that page (Start ▸ the server ▸ New Terminal).
            if !loading { for id in Set(store.sessions.compactMap(\.windowID)).subtracting(store.homeTerminalScopes.values) { openWindow(id: "terminal", value: id) } }
        }
        // The start page opens while the local data is read (a tenth of a second) and brings its
        // lists in when it is there. Only a read that takes unusually long says so.
        .overlay(alignment: .bottom) { if store.loading { LoadingNote().padding(.bottom, 28) } }
        .overlay { if store.settingsVisible { SettingsPanel().transition(.opacity) } }
        .overlay { if store.organizerVisible { WindowOrganizer().transition(.opacity) } }
        // The tab bar, while the pointer has brought it, lies over the top of the page: this is the ground under it.
        .overlay(alignment: .top) {
            if store.windowTop.peek > 0 {
                VStack(spacing: 0) {
                    (store.page == .workspace ? WorkspaceTheme.background : Color.harborBackground).frame(height: store.windowTop.peek)
                    Rectangle().fill(Color.harborBorder).frame(height: 1)
                }
                .padding(.top, store.windowTop.titleRow).ignoresSafeArea(.container, edges: .top)
                .allowsHitTesting(false).transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : HarborMotion.fade(0.16, level: motionLevel), value: store.windowTop.peek)
        .animation(HarborMotion.fade(level: motionLevel), value: store.settingsVisible)
        .animation(HarborMotion.fade(level: motionLevel), value: store.organizerVisible)
        .onChange(of: store.settingsVisible) { _, visible in store.codeWorkbench.setCovered(visible || store.organizerVisible) }
        .onChange(of: store.organizerVisible) { _, visible in store.codeWorkbench.setCovered(visible || store.settingsVisible) }
        .onChange(of: store.workbenchUIRequest) { _, request in
            guard let request else { return }
            store.workbenchUIRequest = nil
            // One Settings panel holds Harbor's preferences and every editor setting.
            if request == "settings" { store.settingsVisible = true }
            if request == "editorKeybindings" {
                store.page = .workspace; store.currentFiles.enabled = true
                store.currentFiles.focusArea = .editor
                store.codeWorkbench.session(for: store.currentFiles).openSettings(store: store, keybindings: true)
            }
            if request == "addServer" { editing = ServerProfile() }
            if request == "newWindow" { openWindow(id: "main") }
        }
        .sheet(item: $editing) { profile in ServerEditor(profile: profile) { store.upsert($0) } }
        .sheet(item: $store.directoryBrowser) { browser in DirectoryBrowserView(browser: browser).environmentObject(store) }
        .alert("Harbor", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }
    @ViewBuilder private var pageContent: some View {
        switch store.page {
        case .workspace:
            // Launch chooses a workspace before it settles on the start page. Showing the editor for
            // that moment started it: a connection to the first server at every launch, with an
            // editor left running there, for a page that was never looked at.
            if store.loading { Color.harborEditor }
            else if let owner = store.workspaceOwner { WorkspaceElsewhereView(owner: owner) }
            else {
                let session = store.codeWorkbench.session(for: store.currentFiles)
                ZStack {
                    WorkspaceTheme.background
                    WorkbenchStageLayer(stage: store.codeWorkbench.stage, session: session)
                    CodeWorkbenchView(workspace: store.currentFiles, session: session).id(store.currentFiles.key)
                }
            }
        case .display: RemoteDisplayPage(controller: store.remoteDisplays).harborReveal(distance: 8)
        case .proxy: ProxyPage().harborReveal(distance: 8)
        case .recent: EmptyView()
        case .terminal: HomeTerminalPage()
        }
    }
    /// The start page is full-bleed: it carries its own navigation.
    private var startPage: Bool { store.page == .recent }
    private var plainTerminal: Bool { store.page == .terminal }
    private var unifiedEditor: Bool {
        store.page == .workspace && store.workspaceOwner == nil
    }
    /// What the bar of a page says it is. A folder that another window has open is named by the folder.
    private var pageTitle: String { store.page == .workspace ? store.currentFiles.directoryTitle : store.page.rawValue }
    private var pageIcon: String {
        switch store.page {
        case .workspace: return "folder"
        case .display: return "display"
        case .proxy: return "arrow.left.arrow.right"
        case .recent: return "clock.arrow.circlepath"
        case .terminal: return "terminal"
        }
    }
    /// The ground of the title row, and of the room left around it for a tab bar.
    private var barBackground: Color {
        plainTerminal ? HomeTerminalPage.background(colorScheme) : unifiedEditor ? WorkspaceTheme.background : Color.harborBackground
    }
}

struct ResizeHandle: View {
    let vertical: Bool
    var thickness = 1.0
    var showsLine = true
    var accessibilityReversed = false
    let label: String
    let reset: () -> Void
    let change: (Double) -> Void
    let end: () -> Void
    @State private var hovered = false
    var body: some View {
        Rectangle().fill(showsLine ? Color.harborBorder : .clear)
            .frame(width: vertical ? thickness : nil, height: vertical ? nil : thickness)
            // Separate the grab area from the visual boundary.
            .overlay {
                Rectangle().fill(hovered ? Color.harborFocus.opacity(0.55) : .clear)
                    .frame(width: vertical ? 7 : nil, height: vertical ? nil : 7)
                    .contentShape(Rectangle())
                    .onHover { hovered = $0; ($0 ? (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown) : NSCursor.arrow).set() }
                    .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                        .onChanged { change(vertical ? $0.translation.width : $0.translation.height) }
                        .onEnded { _ in end() })
                    .onTapGesture(count: 2, perform: reset)
            }
            .help("\(label); drag to resize, double-click to reset")
            .accessibilityLabel(label)
            .accessibilityAdjustableAction { direction in change((direction == .increment ? 10.0 : -10.0) * (accessibilityReversed ? -1 : 1)); end() }
    }
}

struct WorkbenchDivider: View {
    var body: some View { Rectangle().fill(Color.harborBorder).frame(height: 1).allowsHitTesting(false) }
}

/// Start page ▸ New Terminal: a shell filling the window and nothing around it. Harbor's own
/// terminal view, so the prompt is there as soon as the page is. It is split into panes (⌘D to
/// the right, ⇧⌘D below) and given further tabs (⌘T) like any terminal; the tabs' row is there
/// only once there is more than one, and a pane has a title only beside another.
struct HomeTerminalPage: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.colorScheme) private var colorScheme
    static func background(_ scheme: ColorScheme) -> Color { Color(nsColor: TerminalTheme.background(dark: scheme == .dark)) }
    var body: some View {
        ZStack {
            Self.background(colorScheme)
            if let id = store.homeTerminalScope {
                let scope = TerminalScope.window(id), arrangement = store.arrangement(in: scope)
                VStack(spacing: 0) {
                    if arrangement.groups.count > 1 {
                        ScrollViewReader { reader in
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 3) {
                                    ForEach(arrangement.groups) { group in
                                        if let session = store.sessions.first(where: { $0.id == group.sessionIDs.first }) {
                                            TerminalGroupTab(group: group, session: session, scope: scope, selected: group.id == arrangement.selectedGroup?.id).id(group.id)
                                        }
                                    }
                                }.padding(.horizontal, 6).padding(.vertical, 3)
                            }.frame(height: 36)
                                .onChange(of: arrangement.selectedGroup?.id) { _, id in if let id { reader.scrollTo(id, anchor: .trailing) } }
                        }
                        WorkbenchDivider()
                    }
                    if let layout = arrangement.visible {
                        TerminalMosaicNode(layout: layout, scope: scope, showsTitles: layout.sessionIDs.count > 1, fillsTitleRow: false)
                            .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                    }
                }
                // The keyboard goes to the pane in use once its view is in the window: a new
                // pane or tab, and the one that is left when another closes.
                .task(id: store.homeTerminal?.id) {
                    guard let session = store.homeTerminal else { return }
                    for _ in 0..<20 where session.terminal.window == nil { try? await Task.sleep(nanoseconds: 20_000_000) }
                    if !Task.isCancelled { store.activateTerminal(session) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .harborReveal(distance: 0)
        .accessibilityIdentifier("home-terminal")
    }
}

/// The title row of the plain terminal: its name, and the way back to the start page.
struct HomeTerminalBar: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.colorScheme) private var colorScheme
    var height = WorkbenchWindowMetrics.titlebarHeight
    var leading = WorkbenchWindowMetrics.trafficLightInset
    var body: some View {
        ZStack {
            WindowDragArea()
            WorkspaceTitle(window: store.windowName, server: store.homeTerminal?.profile?.name ?? LocalMachine.name, folder: "Terminal",
                           muted: .harborMuted, strong: .harborForeground)
                .padding(.horizontal, 130).allowsHitTesting(false)
            HStack(spacing: 2) {
                StartPageButton()
                Spacer()
                // What the keys do, where it can be seen and clicked.
                control("New Terminal · ⌘T", symbol: "plus") { store.openIndependentTerminal() }
                control("Split Right · ⌘D", symbol: "rectangle.split.2x1") { store.splitTerminal(.columns, session: store.homeTerminal) }
                control("Split Down · ⇧⌘D", symbol: "rectangle.split.1x2") { store.splitTerminal(.rows, session: store.homeTerminal) }
            }.padding(.leading, leading).padding(.trailing, 8)
        }.frame(height: height).background(HomeTerminalPage.background(colorScheme), ignoresSafeAreaEdges: [])
            .contextMenu { Button("Rename Window…") { store.promptForWindowName() } }
            .accessibilityIdentifier("home-terminal-bar")
    }
    private func control(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: WorkbenchWindowMetrics.controlSize, height: WorkbenchWindowMetrics.controlSize)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(Color.harborMuted).help(title).accessibilityLabel(title)
    }
}

/// "‹ Start": the way back to the start page, at the leading end of every bar. On a page that was
/// opened from the editor or a terminal (Reverse Proxy, Remote Display) it leads back there instead,
/// and says where.
struct StartPageButton: View {
    @EnvironmentObject var store: AppStore
    var tint = Color.harborMuted
    /// Back to where this page was opened from, rather than always to the start page.
    var returns = false
    @State private var hovered = false
    private var target: AppPage { returns ? store.pageReturn : .recent }
    private var title: String {
        switch target {
        case .workspace: return store.currentFiles.directoryTitle
        case .terminal: return "Terminal"
        default: return "Start"
        }
    }
    var body: some View {
        Button { store.page = target } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 180, alignment: .leading).fixedSize()
            }
                .padding(.horizontal, 7).frame(height: 22).contentShape(Rectangle())
                .background(hovered ? Color.harborHover : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }.buttonStyle(.plain).foregroundStyle(tint).onHover { hovered = $0 }
            .help(target == .recent ? "Start Page · ⇧⌘H" : "Back to " + title).accessibilityLabel(target == .recent ? "Back to Start Page" : "Back to " + title)
            .accessibilityIdentifier("back-to-start")
    }
}

/// The title row of a page that is neither the editor nor a terminal (Reverse Proxy, Remote
/// Display, a folder another window has open): the way back at its leading end and what the page
/// is in the middle, like the bars of the editor and the terminal.
struct PageBar: View {
    @EnvironmentObject var store: AppStore
    let title: String
    let symbol: String
    var returns = true
    var height = WorkbenchWindowMetrics.titlebarHeight
    var leading = WorkbenchWindowMetrics.trafficLightInset
    var body: some View {
        ZStack {
            WindowDragArea()
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.harborMuted)
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.harborForeground.opacity(0.88)).lineLimit(1).truncationMode(.middle)
            }.padding(.horizontal, 130).allowsHitTesting(false)
                .accessibilityElement(children: .ignore).accessibilityLabel(title)
            HStack {
                StartPageButton(returns: returns)
                Spacer()
            }.padding(.leading, leading)
        }.frame(height: height).background(Color.harborBackground, ignoresSafeAreaEdges: [])
            .contextMenu { Button("Rename Window…") { store.promptForWindowName() } }
            .accessibilityIdentifier("page-bar")
    }
}

/// Shown only when reading the local data takes long enough to wonder about.
private struct LoadingNote: View {
    @State private var late = false
    var body: some View {
        VStack(spacing: 8) { Text("Reading local data…").harborFont(12).foregroundStyle(Color.harborMuted); HarborProgressBar(width: 120) }
            .opacity(late ? 1 : 0)
            .task { try? await Task.sleep(nanoseconds: 1_500_000_000); withAnimation(HarborMotion.fade(0.3)) { late = true } }
            .accessibilityHidden(!late)
    }
}

struct SessionPanel: View {
    @ObservedObject var session: TerminalSession
    var showsStatus = true
    /// A terminal that is the whole window colors the title row too; under a bar of its own it stops at the bar.
    var fillsTitleRow = true
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
            TerminalSurface(session: session).padding(.top, 8)
                .background(Color(nsColor: TerminalTheme.background(dark: colorScheme == .dark)), ignoresSafeAreaEdges: fillsTitleRow ? .all : [])
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
    @State var passwordKept = false
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
                Section("Password") {
                    Text("A server\u{2019}s password is asked for once, in the terminal or in a dialog when a folder is opened. Harbor keeps it in your login keychain and gives it to ssh from then on.").harborFont(11).foregroundStyle(Color.harborMuted)
                    if passwordKept {
                        HStack {
                            Text("A password is kept for this server.")
                            Spacer()
                            Button("Forget Password") {
                                let id = profile.id
                                Task {
                                    _ = await Task.detached { ServerPasswords.forget(server: id) }.value
                                    passwordKept = false
                                }
                            }
                        }
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
        }.frame(width: 570, height: profile.imported ? 625 : 705)
        .task {
            let id = profile.id
            passwordKept = await Task.detached { ServerPasswords.kept(server: id) }.value
        }
    }
}
