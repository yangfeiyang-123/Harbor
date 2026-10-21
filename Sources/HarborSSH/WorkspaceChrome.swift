import SwiftUI
import HarborCore
import AppKit

/// Native connection controls share one compact title-bar row. Code-OSS owns
/// the editor, terminal, activity bar and status bar underneath this fixed row.
struct WorkbenchTopBar: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(HarborMotion.preferenceKey) private var motion = HarborMotion.Level.full.rawValue
    private var motionLevel: HarborMotion.Level { HarborMotion.level(motion, reduceMotion: reduceMotion) }
    @ObservedObject var visibility: WorkbenchToolbarVisibility
    /// The editor of the workspace on screen: while it opens, the opening page shows the title.
    @ObservedObject var session: CodeWorkbenchSession
    var height = WorkbenchWindowMetrics.titlebarHeight
    var leading = WorkbenchWindowMetrics.trafficLightInset
    let addServer: () -> Void
    @State private var foldersPresented = false

    var body: some View {
        ZStack {
            WindowDragArea()
            Group {
                // The window's name if it has one, where the workspace is, then its folder; the
                // opening page hands this same title over.
                WorkspaceTitle(window: store.windowName, server: store.selectedProfile?.name ?? LocalMachine.name, folder: store.currentFiles.directoryTitle)
                    .opacity((session.ready || session.revealed || session.error != nil) && !session.titleInFlight ? 1 : 0)
                    // Switching folders: the old title gives way to the new one, as the editors do.
                    .id(store.currentFiles.key).transition(.opacity)
            }
                .animation(HarborMotion.animation(HarborMotion.standard), value: store.currentFiles.key)
                .padding(.horizontal, 110).allowsHitTesting(false)
                .opacity(visibility.revealed ? 0 : 1).accessibilityHidden(visibility.revealed)
            HStack(spacing: 7) {
                // Always there, as on the terminal page; the menus beside it come with the pointer.
                StartPageButton(tint: WorkspaceTheme.muted)
                Group {
                    serverMenu
                    folderMenu
                    moreMenu
                }.opacity(visibility.revealed ? 1 : 0).allowsHitTesting(visibility.revealed).accessibilityHidden(!visibility.revealed)
                Spacer(minLength: 12)
                HStack(spacing: 2) {
                    layoutButton("Toggle Sidebar · ⌘B", symbol: "sidebar.left", command: "workbench.action.toggleSidebarVisibility")
                    layoutButton("Toggle Panel · ⌘J", symbol: "rectangle.bottomthird.inset.filled", command: "workbench.action.togglePanel")
                    layoutButton("Toggle Secondary Sidebar", symbol: "sidebar.right", command: "workbench.action.toggleAuxiliaryBar")
                    layoutButton("Split Editor", symbol: "rectangle.split.2x1", command: "workbench.action.splitEditor")
                    Button { store.settingsVisible.toggle() } label: {
                        Image(systemName: "gearshape").frame(width: WorkbenchWindowMetrics.controlSize, height: WorkbenchWindowMetrics.controlSize)
                    }.buttonStyle(.plain).help("Settings · ⌘,").accessibilityLabel("Settings")
                        .accessibilityIdentifier("workbench-settings")
                }.font(.system(size: 13)).foregroundStyle(WorkspaceTheme.muted)
                    .opacity(visibility.revealed ? 1 : 0).allowsHitTesting(visibility.revealed).accessibilityHidden(!visibility.revealed)
            }.padding(.leading, max(leading - 4, 8)).padding(.trailing, 8)
        }.frame(height: height)
            .background(WorkspaceTheme.background).contentShape(Rectangle())
            .contextMenu { Button("Rename Window…") { store.promptForWindowName() } }
            .onHover { visibility.setHovered($0) }
            .animation(HarborMotion.feedback(.crossfade, level: motionLevel), value: visibility.revealed)
            .onChange(of: foldersPresented) { _, presented in visibility.setPopoverPresented(presented) }
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in visibility.menuTracking(true) }
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in visibility.menuTracking(false) }
            .onDisappear { visibility.reset() }
            #if DEBUG
            // The probe shows the bar's controls as the pointer would, to look at them.
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("harbor.qa.bar"))) { note in visibility.setHovered(note.object as? Bool ?? true) }
            #endif
            .accessibilityIdentifier("workbench-titlebar")
    }

    private var serverMenu: some View {
        Menu {
            Button { store.selectWorkspace(nil) } label: {
                Label(LocalMachine.name, systemImage: store.selectedProfileID == nil ? "checkmark" : "laptopcomputer")
            }
            if !store.profiles.isEmpty { Divider() }
            ForEach(store.profiles) { profile in
                Button { store.selectWorkspace(profile.id) } label: {
                    Label(profile.name, systemImage: store.selectedProfileID == profile.id ? "checkmark" : profile.displayIcon)
                }
            }
            Divider()
            Button("Add Server…", action: addServer)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: store.selectedProfile?.displayIcon ?? "laptopcomputer")
                Text(store.selectedProfile?.name ?? LocalMachine.name).lineLimit(1).truncationMode(.tail)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }.font(.system(size: 11)).frame(height: WorkbenchWindowMetrics.controlSize)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden)
            .frame(maxWidth: 180, alignment: .leading).fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("Switch Server").accessibilityIdentifier("workbench-servers")
    }

    private var folderMenu: some View {
        HStack(spacing: 1) {
            Button { foldersPresented.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                    Text(store.currentFiles.directoryTitle).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }.padding(.horizontal, 4).frame(height: WorkbenchWindowMetrics.controlSize)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).frame(maxWidth: 220)
                .accessibilityLabel("Switch Folder Workspace").accessibilityIdentifier("directory-workspaces")
                .popover(isPresented: $foldersPresented) {
                    DirectoryWorkspaceList(profile: store.selectedProfile) { foldersPresented = false }.environmentObject(store)
                }
                .contextMenu { WorkspaceFinderAction(workspace: store.currentFiles) }
            Button { store.chooseDirectoryWorkspace() } label: {
                Image(systemName: "plus").frame(width: WorkbenchWindowMetrics.controlSize, height: WorkbenchWindowMetrics.controlSize)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).help("Open Folder…").accessibilityLabel("Add Folder Workspace")
                .accessibilityIdentifier("add-directory-workspace")
        }.font(.system(size: 11)).foregroundStyle(WorkspaceTheme.muted).fixedSize(horizontal: true, vertical: false)
    }

    /// Harbor's other places, and what is done with the folder on screen. (The editor's sidebar
    /// used to carry a "Harbor" view with these; they are here, in the menu bar and in the Command Palette.)
    private var moreMenu: some View {
        Menu {
            Button { store.page = .proxy } label: { Label("Reverse Proxy", systemImage: "arrow.left.arrow.right") }
            Button { store.page = .display } label: { Label("Remote Display", systemImage: "display") }
            Divider()
            Button { store.organizerVisible = true } label: { Label("Folders in Windows…", systemImage: "rectangle.3.group") }
            Button { WorkspaceSwitcher.shared.present(sticky: true) } label: { Label("Switch Folder…", systemImage: "arrow.left.arrow.right.square") }
            Divider()
            // Terminals of a server that ran before the editor had its own: attached again on request.
            if store.hasPreviousSessions {
                Button { session.command("resumePreviousSession") } label: { Label("Resume Previous Session…", systemImage: "clock.arrow.circlepath") }
            }
            Button { store.closeDirectoryWorkspace(store.currentFiles) } label: { Label("Close Folder", systemImage: "xmark") }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 11)).frame(width: WorkbenchWindowMetrics.controlSize, height: WorkbenchWindowMetrics.controlSize)
                .contentShape(Rectangle())
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().tint(WorkspaceTheme.muted)
            .help("Reverse Proxy, Remote Display, Folders in Windows").accessibilityLabel("More").accessibilityIdentifier("workbench-more")
    }

    private func layoutButton(_ title: String, symbol: String, command: String) -> some View {
        Button { store.codeWorkbench.existing(for: store.currentFiles)?.command(command) } label: {
            Image(systemName: symbol).frame(width: WorkbenchWindowMetrics.controlSize, height: WorkbenchWindowMetrics.controlSize)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(title).accessibilityLabel(title)
    }
}

enum WorkspaceTabLayout {
    static let minimum = 40.0
    static let maximum = 360.0
    static func clamp(_ width: Double) -> Double { min(max(width.isFinite ? width : 150, minimum), maximum) }
    static func fittedWidth(_ title: String) -> Double {
        clamp(Double((title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width) + 66)
    }
}

/// A tab's own trailing edge adjusts its width, independently of every pane.
struct WorkspaceTab: View {
    let title: String
    let detail: String
    let symbol: String
    let selected: Bool
    var tint: Color = .harborIcon
    var status: Color?
    var dirty = false
    @Binding var width: Double
    let select: () -> Void
    let close: () -> Void
    var rename: (() -> Void)?
    var renameLabel = "Rename Terminal…"
    var dragSource: HarborDragSource?
    var flat = false
    var revealFile: (() -> Void)?
    var closeOthers: (() -> Void)?
    var copyPath: (() -> Void)?
    var fileLabelTint: Color?
    @State private var dragStart: Double?
    @State private var hovered = false
    private var actualWidth: Double { WorkspaceTabLayout.clamp(width) }
    private var reveal: Double { HarborLayout.reveal(actualWidth, from: 48, to: 115) }
    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: 7 * reveal) {
                    HarborSymbol(systemName: symbol).font(.system(size: 13)).foregroundStyle(tint)
                        .frame(width: 22, height: 26).overlay(alignment: .bottomTrailing) {
                            if (dirty && !flat) || status != nil { Circle().fill(dirty ? .orange : status!).frame(width: 5, height: 5).offset(x: 1, y: -1) }
                        }
                    Text(title).harborFont(12).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(fileLabelTint ?? (flat ? (selected ? WorkspaceTheme.foreground : WorkspaceTheme.muted) : (selected ? Color.harborForeground : .harborMuted)))
                        .frame(maxWidth: .infinity, alignment: .leading).opacity(reveal).clipped()
                }.padding(.leading, 8).frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(title)
                .simultaneousGesture(TapGesture(count: 2).onEnded { rename?() })
                .compactHint(title, detail: detail, edge: .minY)
                .harborDragSource(dragSource)
            Button(action: close) {
                HarborSymbol(systemName: dirty ? "circle.fill" : "xmark").font(.system(size: dirty ? 6 : 9))
                    .frame(width: 22, height: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Close " + title)
                .frame(width: 22 * reveal).opacity(reveal).clipped().allowsHitTesting(reveal > 0.45).accessibilityHidden(reveal <= 0.45)
            Color.clear.frame(width: 7)
        }.frame(width: actualWidth, height: flat ? 35 : 32).clipped()
            .foregroundStyle(flat ? (selected ? WorkspaceTheme.foreground : WorkspaceTheme.muted) : (selected ? Color.harborForeground : .harborMuted))
            .background {
                if flat { (selected ? WorkspaceTheme.background : hovered ? WorkspaceTheme.hover : WorkspaceTheme.sidebar) }
                else { Color.clear.harborSelectionGlass(selected, radius: 6, inactive: .harborTabInactive, active: .harborTabActive) }
            }
            .overlay(alignment: .bottom) { if selected && !flat { Color.harborTabBorder.frame(height: 2).padding(.horizontal, 5) } }
            .overlay(alignment: .trailing) {
                Rectangle().fill(hovered || dragStart != nil ? tint.opacity(0.45) : Color.harborBorder)
                    .frame(width: 1, height: 15).frame(width: 7, height: 32).contentShape(Rectangle())
                    .onHover { ($0 ? NSCursor.resizeLeftRight : NSCursor.arrow).set() }
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global).onChanged {
                        if dragStart == nil { dragStart = actualWidth }
                        width = WorkspaceTabLayout.clamp((dragStart ?? actualWidth) + $0.translation.width)
                    }.onEnded { _ in dragStart = nil })
                    .onTapGesture(count: 2) { width = WorkspaceTabLayout.fittedWidth(title) }
                    .help("Drag to resize the tab; double-click to fit its name")
                    .accessibilityLabel("Resize \(title) tab")
                    .accessibilityAdjustableAction { width = WorkspaceTabLayout.clamp(actualWidth + ($0 == .increment ? 20 : -20)) }
            }
            .onHover { hovered = $0 }
            .contextMenu {
                if let rename { Button(renameLabel, action: rename) }
                Button("Icons Only") { width = WorkspaceTabLayout.minimum }
                Button("Fit Tab to Name") { width = WorkspaceTabLayout.fittedWidth(title) }
                if let revealFile { Button("Reveal in Explorer", action: revealFile) }
                if let copyPath { Button("Copy Path", action: copyPath) }
                Divider().overlay(Color.harborBorder)
                Button("Close", action: close)
                if let closeOthers { Button("Close Others", action: closeOthers) }
            }
    }
}

struct ConnectionStatus: View {
    @ObservedObject var session: TerminalSession
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(session.ready ? Color.harborSuccess : .secondary).frame(width: 5, height: 5)
            Text(session.status).lineLimit(1)
            if session.tmuxName != nil { Image(systemName: "arrow.clockwise").help("Restorable tmux session") }
        }
    }
}
