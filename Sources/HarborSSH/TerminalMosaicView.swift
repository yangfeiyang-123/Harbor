import SwiftUI
import HarborCore

struct TerminalWorkspaceView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(HarborMotion.preferenceKey) private var motion = HarborMotion.Level.full.rawValue
    private var motionLevel: HarborMotion.Level { HarborMotion.level(motion, reduceMotion: reduceMotion) }
    let scope: TerminalScope
    var compact = false
    var body: some View {
        let arrangement = store.arrangement(in: scope)
        VStack(spacing: 0) {
            if !arrangement.sessionIDs.isEmpty {
                HStack(spacing: 0) {
                ScrollViewReader { reader in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 3) {
                            ForEach(arrangement.groups) { group in
                                if let session = store.sessions.first(where: { $0.id == group.sessionIDs.first }) {
                                    TerminalGroupTab(group: group, session: session, scope: scope,
                                                     selected: group.id == arrangement.selectedGroup?.id).id(group.id)
                                }
                            }
                        }.padding(.horizontal, 6).padding(.vertical, 4)
                            .animation(motionLevel == .full ? Animation.easeInOut(duration: 0.2) : nil, value: arrangement.groups.map(\.id))
                    }.frame(height: compact ? 36 : 40)
                        .onChange(of: arrangement.selectedGroup?.id) { _, id in if let id { reader.scrollTo(id, anchor: .trailing) } }
                }
                if compact {
                    WorkspaceIconButton(title: "Show Sidebar · ⌘B", symbol: "sidebar.left") {
                        store.codeWorkbench.existing(for: store.currentFiles)?.command("workbench.action.toggleSidebarVisibility")
                    }
                    WorkspaceIconButton(title: "Files & Code · ⌥Z", symbol: "doc.text") { store.toggleFiles() }
                    WorkspaceIconButton(title: "New Terminal · ⌃⇧`", symbol: "plus") { store.openIndependentTerminal() }
                    Menu {
                        Button("Split Right · ⌘D") { store.splitTerminal(.columns, session: store.activeSession) }
                        Button("Split Down · ⌘H") { store.splitTerminal(.rows, session: store.activeSession) }
                        Button("Settings…") { store.settingsVisible = true }
                    } label: { Image(systemName: "ellipsis").frame(width: 24, height: 28) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().padding(.trailing, 6)
                }
                }.background(WorkspaceTheme.sidebar)
                WorkbenchDivider()
            }
            if let layout = arrangement.visible {
                TerminalMosaicNode(layout: layout, scope: scope, showsTitles: layout.sessionIDs.count > 1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            } else if case .window = scope {
                ContentUnavailableView("Terminal Closed", systemImage: "terminal").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { ContentUnavailableView("No Terminal", systemImage: "terminal").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
    }
}

struct TerminalGroupTab: View {
    let group: TerminalGroup
    @ObservedObject var session: TerminalSession
    @EnvironmentObject var store: AppStore
    @AppStorage("terminalTabWidth") private var defaultWidth = 150.0
    let scope: TerminalScope
    let selected: Bool
    var body: some View {
        let title = group.title ?? session.tabTitle
        WorkspaceTab(title: title,
                     detail: "\(group.sessionIDs.count) terminals · \(session.profile?.name ?? LocalMachine.name)" + (session.workingDirectory.map { "\n" + $0 } ?? ""),
                     symbol: group.sessionIDs.count > 1 ? "rectangle.split.2x1" : "terminal", selected: selected,
                     status: group.sessionIDs.count > 1 ? nil : session.ended ? .secondary : session.ready ? .harborSuccess : .orange,
                     width: Binding(get: { group.tabWidth ?? session.tabWidth ?? defaultWidth }, set: {
                         store.resizeTerminalTab(group.id, in: scope, width: $0); defaultWidth = $0
                     }),
                     select: { store.activateTerminalGroup(group.id, in: scope) },
                     close: { store.closeTerminalGroup(group.id, in: scope) },
                     rename: { store.renameTerminalGroup(group.id, in: scope) },
                     renameLabel: group.sessionIDs.count > 1 ? "Rename Workspace…" : "Rename Terminal…",
                     dragSource: .group(group.id, scope))
            .accessibilityIdentifier("terminal-group-" + group.id.uuidString)
            .harborDropTarget(.group(group.id, scope))
            .onAppear {
                if group.tabWidth == nil { store.resizeTerminalTab(group.id, in: scope, width: session.tabWidth ?? defaultWidth) }
            }
    }
}

struct TerminalMosaicNode: View {
    @EnvironmentObject var store: AppStore
    let layout: TerminalLayout
    let scope: TerminalScope
    let showsTitles: Bool
    /// Under a bar of the page's own, a terminal's ground stops at the bar.
    var fillsTitleRow = true
    var body: some View {
        switch layout {
        case .terminal(let id):
            if let session = store.sessions.first(where: { $0.id == id }) {
                TerminalPane(session: session, scope: scope, showsTitle: showsTitles, fillsTitleRow: fillsTitleRow).id(id)
            }
        case .split(let id, let axis, let ratio, let first, let second):
            TerminalSplitView(id: id, axis: axis, ratio: ratio, scope: scope,
                              first: AnyView(TerminalMosaicNode(layout: first, scope: scope, showsTitles: showsTitles, fillsTitleRow: fillsTitleRow)),
                              second: AnyView(TerminalMosaicNode(layout: second, scope: scope, showsTitles: showsTitles, fillsTitleRow: fillsTitleRow)))
        }
    }
}

struct TerminalSplitView: View {
    @EnvironmentObject var store: AppStore
    let id: UUID
    let axis: TerminalSplitAxis
    let ratio: Double
    let scope: TerminalScope
    let first: AnyView
    let second: AnyView
    @State private var dragStart: Double?
    @State private var liveRatio: Double?
    var body: some View {
        GeometryReader { geometry in
            let columns = axis == .columns
            let extent = columns ? geometry.size.width : geometry.size.height
            let available = max(0, extent - 1)
            let minimum = min(columns ? 110.0 : 60.0, available * 0.25)
            let firstSize = min(max(available * (liveRatio ?? ratio), minimum), available - minimum)
            let secondSize = available - firstSize
            let handle = ResizeHandle(vertical: columns,
                                      label: columns ? "Resize Terminal Columns" : "Resize Terminal Rows",
                                      reset: { store.resizeTerminalSplit(id, in: scope, ratio: 0.5) }) { delta in
                if dragStart == nil { dragStart = firstSize }
                let size = min(max((dragStart ?? firstSize) + delta, minimum), available - minimum)
                liveRatio = size / max(available, 1)
            } end: { if let ratio = liveRatio { store.resizeTerminalSplit(id, in: scope, ratio: ratio) }; liveRatio = nil; dragStart = nil }
            if columns {
                HStack(spacing: 0) {
                    first.frame(width: firstSize, height: geometry.size.height).clipped()
                    handle.zIndex(2)
                    second.frame(width: secondSize, height: geometry.size.height).clipped()
                }
            } else {
                VStack(spacing: 0) {
                    first.frame(width: geometry.size.width, height: firstSize).clipped()
                    handle.zIndex(2)
                    second.frame(width: geometry.size.width, height: secondSize).clipped()
                }
            }
        }.clipped()
    }
}

struct TerminalPane: View {
    @ObservedObject var session: TerminalSession
    @EnvironmentObject var store: AppStore
    let scope: TerminalScope
    let showsTitle: Bool
    var fillsTitleRow = true
    private var selected: Bool { store.arrangement(in: scope).selectedID == session.id }
    var body: some View {
        VStack(spacing: 0) {
            if showsTitle {
                HStack(spacing: 5) {
                    Button { store.activateTerminal(session) } label: {
                        HStack(spacing: 6) {
                            HarborSymbol(systemName: "terminal").foregroundStyle(selected ? Color.harborForeground : .harborMuted)
                            Text(session.tabTitle).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                        }.frame(maxWidth: .infinity, minHeight: 25).contentShape(Rectangle())
                    }.buttonStyle(.plain).simultaneousGesture(TapGesture(count: 2).onEnded { store.promptForTerminalName(session) })
                        .compactHint(session.displayTitle, detail: session.workingDirectory ?? "", edge: .minY)
                        .harborDragSource(.terminal(session.id, scope))
                    Button { store.close(session) } label: {
                        HarborSymbol(systemName: "xmark").font(.system(size: 9)).frame(width: 20, height: 24).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Close Pane " + session.tabTitle)
                }.harborFont(10).padding(.horizontal, 7).frame(height: 27)
                    .background(selected ? Color.harborSelection : Color.harborBackground)
                    .contextMenu {
                        Button("Rename Terminal…") { store.promptForTerminalName(session) }
                        Button("Split Right") { store.splitTerminal(.columns, session: session) }
                        Button("Split Down") { store.splitTerminal(.rows, session: session) }
                        Button("Move to New Terminal Workspace") { store.separateTerminal(session) }
                        Divider().overlay(Color.harborBorder); Button("Close Terminal") { store.close(session) }
                    }
            }
            SessionPanel(session: session, showsStatus: false, fillsTitleRow: fillsTitleRow).frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
        }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            .overlay { if showsTitle && selected { Rectangle().stroke(Color.harborFocus, lineWidth: 1).allowsHitTesting(false) } }
            .harborDropTarget(.pane(session.id, scope))
    }
}

struct TerminalWindowView: View {
    @EnvironmentObject var store: AppStore
    @AppStorage("appearance") private var appearance = HarborTheme.defaultAppearance
    let windowID: UUID
    var body: some View {
        VStack(spacing: 0) {
            TerminalWorkspaceView(scope: .window(windowID))
            if let session = store.selectedTerminal(in: .window(windowID)) {
                HStack { ConnectionStatus(session: session); Spacer() }.harborFont(10).foregroundStyle(Color.harborMuted).padding(.horizontal, 12).frame(height: 26)
            }
        }.navigationTitle(store.selectedTerminal(in: .window(windowID))?.displayTitle ?? "Harbor Terminal")
            .frame(minWidth: 640, minHeight: 400).harborFont().foregroundStyle(Color.harborForeground).harborTypography().background(Color.harborBackground).tint(.harborButton)
            .environment(\.locale, Locale(identifier: "en"))
            .preferredColorScheme(HarborTheme.scheme(appearance))
            .focusedSceneValue(\.harborSession, store.selectedTerminal(in: .window(windowID)))
            .background(WorkspaceShortcutHandler(shortcut: .standard, newTerminal: { store.openIndependentTerminal(in: .window(windowID)) },
                terminalCommand: { store.handleTerminalKey($0, in: .window(windowID)) }, action: nil).accessibilityHidden(true))
            .onDisappear { store.closeTerminalWindow(windowID) }
    }
}
