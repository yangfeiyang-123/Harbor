import SwiftUI
import HarborCore

struct FileWorkspaceView<Terminals: View>: View {
    @ObservedObject var workspace: FileWorkspace
    @EnvironmentObject var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("fileTreeWidth") private var treeWidth = 215.0
    @AppStorage("fileTreeExpandedWidth") private var expandedTreeWidth = 215.0
    @AppStorage("editorHeightRatio") private var editorRatio = 0.64
    @State private var treeStart: Double?
    @State private var editorStart: Double?
    @State private var editorRatioStart: Double?
    @StateObject private var explorerFocus = BrowserListFocus()
    @State private var showingFileSearch = false
    @State private var workspacePicker = false
    @FocusState private var folderFocused: Bool
    @FocusState private var emptyTerminalFocused: Bool
    let terminals: Terminals
    init(workspace: FileWorkspace, @ViewBuilder terminals: () -> Terminals) { self.workspace = workspace; self.terminals = terminals() }
    var body: some View {
        VStack(spacing: 0) {
            if workspace.enabled {
                GeometryReader { geometry in
                    let targetWidth = workspace.explorerVisible ? min(max(treeWidth, 52), min(400, geometry.size.width * 0.40)) : 0
                    InterpolatedWidth(width: targetWidth) { width in
                        HStack(spacing: 0) {
                            explorer(width: width).frame(width: width).clipped().allowsHitTesting(workspace.explorerVisible).accessibilityHidden(!workspace.explorerVisible)
                            ResizeHandle(vertical: true, label: "Resize Explorer", reset: { treeWidth = 215 }) { delta in
                                if treeStart == nil { treeStart = width }; treeWidth = min(max((treeStart ?? width) + delta, 52), min(400, geometry.size.width * 0.40))
                            } end: { treeStart = nil }
                            .frame(width: workspace.explorerVisible ? 4 : 0).clipped()
                            GeometryReader { detail in detailArea(size: detail.size) }
                        }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading).clipped()
                    }.animation(reduceMotion || treeStart != nil ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.42), value: targetWidth)
                }.task { await workspace.activate(store: store) }
                    .task(id: scenePhase) {
                        if scenePhase == .active { await workspace.monitorDirectoryChanges() }
                    }
            } else { terminals.frame(maxWidth: .infinity, maxHeight: .infinity).clipped() }
            Divider().overlay(workspace.enabled ? WorkspaceTheme.border : Color.harborBorder)
            WorkspaceStatusBar(workspace: workspace, session: store.activeSession)
        }
        .background(workspace.enabled ? WorkspaceTheme.background : Color.harborBackground)
        .tint(workspace.enabled ? WorkspaceTheme.foreground : Color.harborButton)
        .sheet(item: $workspace.navigator, onDismiss: {
            if let next = workspace.nextNavigator { workspace.nextNavigator = nil; workspace.navigator = next }
        }) { mode in WorkspaceNavigator(workspace: workspace, mode: mode).environmentObject(store) }
        .overlay(alignment: .top) {
            if let target = workspace.dropDestination {
                VStack(spacing: 5) {
                    Label("Drop into: " + target.name, systemImage: "folder.badge.plus").harborFont(13, weight: .semibold)
                    Text(target.path).harborFont(11).lineLimit(2).truncationMode(.middle)
                    Text("Upload local items · Move on this server · ⌥ Copy").harborFont(10).foregroundStyle(Color.harborMuted)
                }.padding(14).frame(maxWidth: 420).harborGlass(radius: 16, elevated: true)
                    .padding(.top, 44).allowsHitTesting(false)
            }
        }
        .task(id: workspace.focusRequest) {
            await Task.yield()
            guard !Task.isCancelled, workspace.focusArea != .terminalList, workspace.focusArea != .explorer, workspace.focusArea != .servers, workspace.focusArea != .search else { return }
            if workspace.focusArea == .terminal {
                if let terminal = store.activeSession?.terminal { terminal.window?.makeFirstResponder(terminal) }
                else if workspace.enabled && workspace.terminalVisible { emptyTerminalFocused = true }
            } else if let editor = workspace.currentDocument?.editor { editor.focus() }
            else { folderFocused = true }
        }
    }
    private func detailArea(size: CGSize) -> some View {
        let split = WorkspaceSplitLayout(height: size.height, ratio: workspace.terminalMaximized ? 0 : editorRatio)
        let targetHeight = workspace.terminalVisible ? split.editor : size.height
        let editorHidden = workspace.terminalVisible && workspace.terminalMaximized
        return InterpolatedHeight(height: targetHeight) { presentedHeight in
            let height = min(presentedHeight, size.height)
            let toolbarHeight = min(workspace.currentDocument == nil ? 35 : 56, height)
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        toolbar.frame(height: 35)
                        if let document = workspace.currentDocument { WorkspaceBreadcrumbs(workspace: workspace, document: document).frame(height: 21) }
                    }.frame(height: toolbarHeight, alignment: .top).clipped()
                    editor.frame(width: size.width, height: max(0, height - toolbarHeight)).clipped().workspaceOpenDrop(workspace: workspace)
                }
                .frame(width: size.width, height: height, alignment: .topLeading).clipped()
                .opacity(min(1, height / 39)).allowsHitTesting(!editorHidden).accessibilityHidden(editorHidden)
                if workspace.terminalVisible {
                    ResizeHandle(vertical: false, thickness: WorkspaceSplitLayout.divider, label: "Resize Editor and Terminal", reset: {
                        workspace.setTerminalMaximized(false); editorRatio = 0.64
                    }) { delta in
                        if editorStart == nil { editorStart = height; editorRatioStart = editorRatio }
                        editorRatio = workspace.resizeTerminalPanel(
                            editorHeight: (editorStart ?? height) + delta, totalHeight: size.height,
                            startingRatio: editorRatioStart ?? editorRatio)
                    } end: { editorStart = nil; editorRatioStart = nil }
                    .zIndex(2)
                    terminalPane.frame(width: size.width, height: max(0, size.height - WorkspaceSplitLayout.divider - height)).clipped()
                }
            }.frame(width: size.width, height: size.height, alignment: .topLeading).clipped()
        }.animation(reduceMotion || editorStart != nil ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.24), value: targetHeight)
    }
    private var terminalPane: some View {
        VStack(spacing: 0) {
            if !workspace.terminalMaximized {
            HStack(spacing: 4) {
                Text("TERMINAL").font(.system(size: 10, weight: .medium)).foregroundStyle(WorkspaceTheme.foreground)
                    .padding(.horizontal, 12).frame(height: 30)
                Spacer()
                WorkspaceIconButton(title: workspace.terminalMaximized ? "Restore Panel · ⌥X" : "Maximize Panel · ⌥X", symbol: workspace.terminalMaximized ? "chevron.down" : "chevron.up") { store.toggleTerminalMaximized() }
                WorkspaceIconButton(title: "Hide Terminal · ⌘J", symbol: "xmark") { store.toggleTerminalPanel() }
            }.padding(.trailing, 6).background(WorkspaceTheme.sidebar)
            }
            if store.workspaceSessions.isEmpty {
                VStack(spacing: 10) {
                    Button("Open Terminal in Folder") { store.openWorkspaceTerminal() }.buttonStyle(.bordered).focused($emptyTerminalFocused)
                    Text("⌃` Switch focus · ⌘J Hide panel").harborFont(10).foregroundStyle(WorkspaceTheme.muted)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { FileTerminalPanel(scope: store.currentTerminalScope) }
        }.background(WorkspaceTheme.sidebar)
    }
    private var toolbar: some View {
        HStack(spacing: 0) {
            if !workspace.explorerVisible {
                WorkspaceIconButton(title: "Show Explorer · ⌘B", symbol: "sidebar.left") { workspace.explorerVisible = true }
            }
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(workspace.documents) { doc in WorkspaceFileTab(workspace: workspace, document: doc).id(doc.id) }
                    }
                }.frame(maxWidth: .infinity).frame(height: 34)
                    .onChange(of: workspace.selection) { _, id in if let id { reader.scrollTo(id, anchor: .trailing) } }
            }
            HStack(spacing: 2) {
                if let doc = workspace.currentDocument { DocumentActions(workspace: workspace, document: doc) }
                Menu {
                    Button("Quick Open…    ⌘P") { workspace.navigator = .files }
                    Button("Command Palette…    ⇧⌘P") { workspace.navigator = .commands }
                    Button("Go to Symbol…    ⇧⌘O") { workspace.navigator = .symbols }.disabled(workspace.currentDocument?.text == nil)
                    Button("Go to Line…    ⌃G") { workspace.navigator = .line }.disabled(workspace.currentDocument?.text == nil)
                    Divider()
                    Button("Find / Replace…    ⌘F") { workspace.currentDocument?.editor?.find() }.disabled(workspace.currentDocument?.text == nil)
                    Button("Toggle Word Wrap") { UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "editorWrap"), forKey: "editorWrap") }
                    Button("Refresh Current File") { if let doc = workspace.currentDocument { Task { await workspace.load(doc) } } }
                        .disabled(workspace.currentDocument == nil || workspace.currentDocument?.loading == true)
                    Divider()
                    Button(workspace.outlineVisible ? "Hide Outline" : "Show Outline") { workspace.outlineVisible.toggle() }
                    Button(workspace.terminalVisible ? "Hide Terminal    ⌘J" : "Show Terminal    ⌘J") { store.toggleTerminalPanel() }
                } label: { Image(systemName: "ellipsis").frame(width: 26, height: 26) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Editor Actions")
            }.padding(.horizontal, 5)
        }.buttonStyle(.plain).harborFont(11).background(WorkspaceTheme.sidebar)
    }
    private var directoryTitle: String {
        let name = (workspace.root as NSString).lastPathComponent
        return name.isEmpty ? "Open Folder…" : name
    }
    private var directoryButton: some View {
        GeometryReader { geometry in
            let reveal = HarborLayout.reveal(geometry.size.width, from: 34, to: 68)
            Button { workspacePicker.toggle() } label: {
                ZStack(alignment: .leading) {
                    HarborSymbol(systemName: "folder").foregroundStyle(WorkspaceTheme.muted)
                        .frame(width: 24, height: 26).opacity(1 - reveal)
                    Text(directoryTitle).harborFont(11, weight: .semibold).foregroundStyle(WorkspaceTheme.foreground)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                        .opacity(reveal)
                }.frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26).contentShape(Rectangle()).clipped()
            }.buttonStyle(.plain).focused($folderFocused)
                .background(workspace.explorerRootSelected ? WorkspaceTheme.selection : .clear, in: RoundedRectangle(cornerRadius: 2))
                .accessibilityLabel("Folder: " + directoryTitle).accessibilityIdentifier("workspace-directory")
                .accessibilityAddTraits(workspace.explorerRootSelected ? .isSelected : [])
                .compactHint(directoryTitle, detail: workspace.root, edge: .minY)
                .help("Switch Folder")
                .popover(isPresented: $workspacePicker) { workspacePickerContent }
                .contextMenu {
                    WorkspaceFinderAction(workspace: workspace)
                }
                .workspaceFolderDrop(entry: WorkspaceEntry(path: workspace.root, name: directoryTitle, directory: true, size: 0, modified: 0), workspace: workspace)
        }.frame(height: 26)
    }
    private var workspacePickerContent: some View {
        VStack(spacing: 0) {
            DirectoryWorkspaceList(profile: workspace.profile) { workspacePicker = false }
            Divider().overlay(Color.harborBorder)
            Button {
                workspacePicker = false
                store.chooseDirectoryWorkspace(from: workspace)
            } label: {
                Label("Open Folder…", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12).contentShape(Rectangle())
            }.buttonStyle(.plain).harborFont(12)
        }
    }
    private func toggleFileTree() {
        if treeWidth > 82 { expandedTreeWidth = treeWidth; treeWidth = 52 }
        else { treeWidth = max(160, expandedTreeWidth) }
    }
    private func explorer(width: Double) -> some View {
        let reveal = HarborLayout.reveal(width, from: 82, to: 195)
        let compact = reveal < 0.5
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                if width > 82 { directoryButton }
                else { WorkspaceIconButton(title: "Expand Explorer", symbol: "sidebar.left") { toggleFileTree() } }
                if width > 82 {
                    WorkspaceIconButton(title: workspace.sidebarMode == .search ? "Back to Explorer" : "Search in Project · ⇧⌘F", symbol: workspace.sidebarMode == .search ? "arrow.left" : "magnifyingglass") {
                        if workspace.sidebarMode == .search { workspace.sidebarMode = .explorer }
                        else { workspace.focusSearch() }
                    }
                    Menu {
                        Button("New File…") { workspace.create(directory: false) }.disabled(workspace.busy || workspace.service == nil)
                        Button("New Folder…") { workspace.create(directory: true) }.disabled(workspace.busy || workspace.service == nil)
                        WorkspaceFinderAction(workspace: workspace)
                        Button("Quick Open…    ⌘P") { workspace.navigator = .files }
                        Divider()
                        Button("Collapse All Folders") { workspace.collapseFolders() }.disabled(workspace.expanded.isEmpty)
                        Button("Filter Expanded Files…") { showingFileSearch = true }
                        Toggle("Show Hidden Files", isOn: $workspace.showHidden)
                            .onChange(of: workspace.showHidden) { _, _ in Task { await workspace.navigate(workspace.root) } }
                        Button("Refresh Explorer") { Task { await workspace.refreshExpanded(force: true) } }
                        Divider()
                        Button(workspace.outlineVisible ? "Hide Outline" : "Show Outline") { workspace.outlineVisible.toggle() }
                        Button("Compact Explorer") { toggleFileTree() }
                        Button("Hide Explorer    ⌘B") { workspace.explorerVisible = false }
                    } label: { Image(systemName: "ellipsis").frame(width: 26, height: 26) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Explorer Actions")
                }
            }.padding(.horizontal, 7).frame(height: 35).foregroundStyle(WorkspaceTheme.muted)
            if workspace.sidebarMode == .search && width > 82 {
                WorkspaceProjectSearch(workspace: workspace)
            } else {
            VStack(spacing: 5) {
                if showingFileSearch || !workspace.query.isEmpty {
                    TextField("Filter expanded files", text: $workspace.query).textFieldStyle(HarborTextFieldStyle()).harborFont(11)
                        .onExitCommand { showingFileSearch = false; workspace.query = "" }
                }
            }.padding(.horizontal, 1 + 9 * reveal).frame(width: width).clipped()
                .contextMenu {
                    Toggle("Show Hidden Files", isOn: $workspace.showHidden)
                        .onChange(of: workspace.showHidden) { _, _ in Task { await workspace.navigate(workspace.root) } }
                }
            if workspace.busy { ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 8) }
            if let error = workspace.error {
                if compact {
                    Menu {
                        Text(error)
                        if workspace.profile != nil { Button("Open Connection Terminal") { store.openTerminal(workspace.profile); workspace.terminalVisible = true } }
                        Button("Retry") { Task { await workspace.activate(store: store); await workspace.navigate(workspace.root) } }
                    } label: { HarborSymbol(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(maxWidth: .infinity).padding(.vertical, 6)
                        .accessibilityLabel("Unable to Load Folder").compactHint("Unable to Load Folder", detail: error)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(error).harborFont(11).textSelection(.enabled).foregroundStyle(Color.harborMuted)
                        if workspace.profile != nil { Button("Open Connection Terminal") { store.openTerminal(workspace.profile); workspace.terminalVisible = true } }
                        Button("Retry") { Task { await workspace.activate(store: store); await workspace.navigate(workspace.root) } }
                    }.padding(12)
                }
            }
            ScrollViewReader { reader in
              GeometryReader { viewport in
              ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows, id: \.entry.path) { row in fileRow(row.entry, depth: row.depth, width: width).id(row.entry.path) }
                    if rows.isEmpty && !workspace.busy && workspace.error == nil {
                        ZStack {
                            HarborSymbol(systemName: "folder").foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.vertical, 12)
                                .opacity(1 - reveal)
                                .compactHint(workspace.query.isEmpty ? "Empty folder" : "No matching files")
                            Text(workspace.query.isEmpty ? "Empty folder" : "No matching files").harborFont(11).foregroundStyle(Color.harborMuted).lineLimit(1).padding(12).opacity(reveal)
                        }
                    }
                }.padding(.horizontal, 4).padding(.vertical, 3)
                    .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .topLeading)
                    .background(ExplorerBackground(store: store, workspace: workspace, focus: explorerFocus))
              }.onChange(of: workspace.selectedEntryPath) { _, path in if let path { reader.scrollTo(path) } }
              }
            }
            if let notice = workspace.notice {
                if compact { HarborSymbol(systemName: "info.circle").frame(maxWidth: .infinity).padding(.vertical, 8).compactHint("Folder Notice", detail: notice) }
                else { Text(notice).harborFont(10).foregroundStyle(Color.harborMuted).padding(10) }
            }
            }
            if width > 82 && workspace.outlineVisible { WorkspaceOutline(workspace: workspace) }
        }.frame(width: width, alignment: .leading).background(WorkspaceTheme.sidebar).foregroundStyle(WorkspaceTheme.foreground).clipped()
            .background(BrowserListKeyboardBridge(store: store, workspace: workspace, focus: explorerFocus))
    }
    private func fileRow(_ entry: WorkspaceEntry, depth: Int, width: Double) -> some View {
        let reveal = HarborLayout.reveal(width, from: 82, to: 195)
        let indent = Double(min(depth, 2)) * 3 * (1 - reveal) + Double(depth) * 13 * reveal
        return Button {
            let openItem = workspace.selectExplorerEntry(entry, modifiers: NSApp.currentEvent?.modifierFlags ?? [])
            explorerFocus.view?.focusList()
            guard openItem else { return }
            Task {
                if entry.directory { await workspace.toggle(entry) }
                else { await workspace.open(entry); explorerFocus.view?.focusList() }
            }
        } label: {
            HStack(spacing: 3 + 3 * reveal) {
                HarborSymbol(systemName: workspace.expanded.contains(entry.path) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 6 + 2 * reveal)).opacity(entry.directory ? 1 : 0).frame(width: 6)
                WorkspaceFileIcon(path: entry.path, directory: entry.directory)
                Text(entry.name).lineLimit(1).truncationMode(.middle)
                    .frame(width: max(0, width - 61 - indent - 6 * reveal), alignment: .leading).opacity(reveal).clipped()
            }.harborFont(12).padding(.leading, 6 + indent).padding(.trailing, 4).padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(workspace.explorerSelection.paths.contains(entry.path) ? WorkspaceTheme.selection : .clear, in: RoundedRectangle(cornerRadius: 2))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(entry.name)
            .accessibilityIdentifier("file-entry-" + entry.path)
            .accessibilityAddTraits(workspace.explorerSelection.paths.contains(entry.path) ? .isSelected : [])
            .compactHint(entry.name, detail: entry.path, enabled: reveal < 0.9)
            .onDrag { WorkspaceDragDrop.provider(for: workspace.entriesForDrag(from: entry), profileID: workspace.profile?.id) }
            .workspaceFolderDrop(entry: entry, workspace: workspace)
            .contextMenu {
                let count = workspace.explorerSelection.paths.contains(entry.path) ? workspace.explorerSelection.paths.count : 1
                Button(count > 1 ? "Copy \(count) Items" : "Copy") { store.copyEntries(workspace.entriesForAction(on: entry), in: workspace) }.keyboardShortcut("c", modifiers: .command)
                Button(count > 1 ? "Copy Paths" : "Copy Path") { store.copyEntryPaths(workspace.entriesForAction(on: entry)) }.keyboardShortcut("c", modifiers: [.command, .option])
                if entry.directory { Button("Paste") { store.pasteEntries(in: workspace, parent: entry.path) }.keyboardShortcut("v", modifiers: .command) }
                Button("Rename…") { store.promptRenameEntry(entry, in: workspace) }.keyboardShortcut(.return, modifiers: []).disabled(count != 1)
                Button(count > 1 ? "Delete \(count) Items…" : "Delete…", role: .destructive) { store.deleteEntries(workspace.entriesForAction(on: entry), in: workspace) }.keyboardShortcut(.delete, modifiers: .command)
                Button(count > 1 ? "Download \(count) Items…" : "Download…") { store.downloadEntries(workspace.entriesForAction(on: entry), in: workspace) }
                WorkspaceFinderAction(workspace: workspace, entry: entry, includeSelection: true)
                Divider()
                if entry.directory { Button("Open as Folder Workspace") { Task { await store.openDirectoryWorkspace(entry.path, profile: workspace.profile) } } }
                Button("Open Terminal Here") { store.openTerminal(workspace.profile, workingDirectory: entry.directory ? entry.path : (entry.path as NSString).deletingLastPathComponent); workspace.terminalVisible = true }
            }
    }
    @ViewBuilder private var editor: some View {
        if let doc = workspace.currentDocument { FilePreview(workspace: workspace, document: doc).id(doc.id).background(WorkspaceTheme.background) }
        else {
            ContentUnavailableView {
                Label("Files & Code", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text("Drop a folder or file here, or choose code, Markdown, PDFs, images, and videos from the explorer.")
            } actions: { Button("Open Folder…") { store.chooseDirectoryWorkspace() } }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private var rows: [(entry: WorkspaceEntry, depth: Int)] { workspace.visibleRows }
}
