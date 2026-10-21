import SwiftUI
import AppKit
import UniformTypeIdentifiers
import HarborCore

/// The first page of a window: one calm column for starting work and one for
/// returning to it. It replaces the sidebar and toolbar while it is shown, so
/// servers, forwarding, remote display and settings are all reachable here.
///
/// It opens from the top down: the name, the line under it, the agents, then the two
/// columns row by row. The columns hold what is read from disk at launch, so they wait
/// for that and then take their turn; there is no separate loading screen.
struct StartView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.openWindow) private var openWindow
    let addServer: () -> Void
    let editServer: (ServerProfile) -> Void
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    /// A folder from Finder is being held over the page.
    @State private var dropping = false
    /// The closed windows changed.
    @State private var revision = 0

    /// When the columns begin, after the agents have started to arrive, and the step between rows.
    private static let columns = 0.38, step = 0.07
    private func turn(_ row: Int) -> Double { Self.columns + Self.step * Double(min(row, 7)) }
    private var groups: [RecentWorkspaceGroup] {
        RecentWorkspaceGroup.make(store.recents, profiles: store.profiles, query: query)
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 940
            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    hero
                    if wide {
                        HStack(alignment: .top, spacing: 56) {
                            start.frame(width: 280, alignment: .leading)
                            recent.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 34) { start; recent }
                    }
                }
                .frame(maxWidth: 980, alignment: .leading)
                .padding(.horizontal, 44).padding(.top, 58).padding(.bottom, 44)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.harborEditor)
        .overlay(alignment: .top) { WindowDragArea().frame(height: WorkbenchWindowMetrics.titlebarHeight) }
        .onReceive(NotificationCenter.default.publisher(for: .harborFindRecent)) { _ in searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .harborWindowFoldersChanged)) { _ in revision += 1 }
        // A folder dropped anywhere on the page opens here; a file opens in its folder.
        .onDrop(of: [UTType.fileURL], isTargeted: $dropping) { providers in
            Task { @MainActor in
                do {
                    let items = try await WorkspaceDragDrop.items(from: providers)
                    let plan = try WorkspaceDropPlan(items: items)
                    if plan.profileID == nil { await store.openOutside(items.map { URL(fileURLWithPath: $0.entry.path) }) }
                    else { await store.openDroppedWorkspace(plan) }
                } catch { store.errorMessage = error.localizedDescription }
            }
            return true
        }
        .overlay {
            if dropping {
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.harborAccent.opacity(0.07))
                    RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.harborAccent.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                    Text("Drop to open").harborFont(12, weight: .medium).padding(.horizontal, 14).frame(height: 30)
                        .background(Color.harborEditor, in: Capsule()).overlay(Capsule().strokeBorder(Color.harborBorder))
                        .padding(.bottom, 26)
                }
                .padding(10).allowsHitTesting(false).transition(.opacity)
            }
        }
        .animation(HarborMotion.feedback(.crossfade), value: dropping)
        .accessibilityIdentifier("start-page")
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Harbor").harborFont(40, weight: .semibold, design: .serif).harborReveal()
                Text("One quiet place for your code, your servers and your command-line agents.")
                    .harborFont(14).foregroundStyle(Color.harborMuted).harborReveal(after: 0.07)
            }
            // The scene's own clock starts a little ahead, so its first card is arriving as it fades in.
            AgentHarborAnimation(lead: 0.5, covered: store.organizerVisible || store.settingsVisible)
                .frame(height: 188).frame(maxWidth: .infinity)
                .harborReveal(distance: 0, after: 0.14)
        }
    }

    private var start: some View {
        let _ = revision
        // The windows that were closed, to have again with one click. The organizer lists them all.
        // (All of them, also one that is a column of the organizer right now: the page does not move behind it.)
        let closed = store.loading ? [] : Array(store.recentWindows().prefix(3))
        return VStack(alignment: .leading, spacing: 26) {
            // Where a day in Harbor begins: which folders are in which window. It leads the page.
            StartSection(title: "Windows", after: turn(0), ready: !store.loading) {
                StartFeature(title: "Folders in Windows…", detail: "Arrange folders into windows", symbol: "rectangle.3.group", shortcut: "⌥⇧⌘W") {
                    store.organizerVisible = true
                }.padding(.bottom, closed.isEmpty ? 0 : 4)
                ForEach(closed) { window in
                    StartWindowRow(window: window, titles: window.folders.compactMap { AppStore.folder($0)?.title })
                }
            }
            StartSection(title: "Start", after: turn(1), ready: !store.loading) {
                StartAction(title: "Open Folder…", symbol: "folder", shortcut: "⌥⌘O") { store.chooseLocal(directories: true) }
                StartAction(title: "Open File…", symbol: "doc", shortcut: "⌘O") { store.chooseLocal(directories: false) }
                StartAction(title: "New Terminal", symbol: "terminal", shortcut: "⌘T") { store.openHomeTerminal(nil) }
                StartAction(title: "New Window", symbol: "macwindow.badge.plus", shortcut: "⇧⌘N") { openWindow(id: "main") }
            }
            StartSection(title: "Servers", after: turn(3), ready: !store.loading) {
                StartAction(title: LocalMachine.name, symbol: "laptopcomputer", detail: "This Mac") { store.selectWorkspace(nil) }
                ForEach(store.profiles) { profile in
                    StartAction(title: profile.name, symbol: profile.displayIcon,
                                detail: profile.user.isEmpty ? profile.host : profile.user,
                                active: store.connectionStates[profile.id] == "Connected",
                                trailing: ("folder", "Open a folder on " + profile.name, { store.chooseDirectoryWorkspace(from: store.files(for: profile)) })) {
                        store.selectWorkspace(profile.id)
                    }
                    // The servers are put in order here: a row is dragged above or below another.
                    .harborDragSource(.server(profile.id)).harborDropTarget(.server(profile.id))
                    .contextMenu {
                        Button("New Terminal") { store.openHomeTerminal(profile) }
                        Button("Open Folder…") { store.chooseDirectoryWorkspace(from: store.files(for: profile)) }
                        // The server is chosen for the page without being shown first: that recorded the
                        // editor as the page to go back to, and put one of its folders into this window.
                        Button("Remote Display") { store.selectWorkspace(profile.id, show: false); store.page = .display }
                        Divider()
                        Button("Edit Server") { editServer(profile) }
                        Button("Remove Server", role: .destructive) { store.remove(profile) }
                    }
                }
                StartAction(title: "Add Server…", symbol: "plus", action: addServer)
            }
            StartSection(title: "More", after: turn(5), ready: !store.loading) {
                StartAction(title: "Reverse Proxy", symbol: "arrow.left.arrow.right") { store.page = .proxy }
                StartAction(title: "Remote Display", symbol: "display") { store.page = .display }
                StartAction(title: "Settings…", symbol: "gearshape", shortcut: "⌘,") { store.settingsVisible = true }
            }
        }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent").harborFont(11, weight: .semibold).foregroundStyle(Color.harborMuted).textCase(.uppercase).kerning(0.6)
                Spacer()
                if !store.recents.isEmpty {
                    TextField("Search folders or servers", text: $query).textFieldStyle(HarborTextFieldStyle())
                        .harborFont(12).frame(maxWidth: 220).focused($searchFocused)
                }
            }.padding(.horizontal, 10).harborReveal(after: turn(0), ready: !store.loading)
            if groups.isEmpty {
                Text(query.isEmpty ? "Folders and servers you open will appear here." : "No matching folders.")
                    .harborFont(12).foregroundStyle(Color.harborMuted).padding(.horizontal, 10).padding(.vertical, 12).harborReveal(after: turn(1), ready: !store.loading)
            }
            ForEach(Array(groups.enumerated()), id: \.element.id) { offset, group in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(group.name).harborFont(12, weight: .semibold)
                        Text("\(group.entries.count)").harborFont(11).foregroundStyle(Color.harborMuted)
                    }.padding(.horizontal, 10).padding(.top, offset == 0 ? 4 : 14).padding(.bottom, 4)
                    ForEach(group.entries) { item in StartRecentRow(item: item) }
                }
                .accessibilityElement(children: .contain).accessibilityLabel(group.name + " recent workspaces")
                .harborReveal(after: turn(1 + offset), ready: !store.loading)
            }
        }
    }
}

private struct StartSection<Content: View>: View {
    let title: String
    let after: Double
    let ready: Bool
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).harborFont(11, weight: .semibold).foregroundStyle(Color.harborMuted)
                .textCase(.uppercase).kerning(0.6).padding(.horizontal, 10).padding(.bottom, 6)
            content
        }.harborReveal(after: after, ready: ready)
    }
}

/// A full-width row: symbol, title, optional detail, shortcut or trailing action.
private struct StartAction: View {
    let title: String
    let symbol: String
    var detail: String?
    var shortcut: String?
    var active = false
    var trailing: (symbol: String, label: String, action: () -> Void)?
    let action: () -> Void
    @State private var hovered = false

    init(title: String, symbol: String, detail: String? = nil, shortcut: String? = nil, active: Bool = false,
         trailing: (symbol: String, label: String, action: () -> Void)? = nil, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.detail = detail; self.shortcut = shortcut
        self.active = active; self.trailing = trailing; self.action = action
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: symbol).font(.system(size: 13)).frame(width: 20, height: 20)
                        .foregroundStyle(hovered ? Color.harborAccent : Color.harborIcon)
                        .overlay(alignment: .bottomTrailing) {
                            if active { Circle().fill(Color.harborSuccess).frame(width: 5, height: 5).offset(x: 2, y: 1) }
                        }
                    Text(title).harborFont(13).lineLimit(1).truncationMode(.middle)
                    if let detail { Text(detail).harborFont(11).foregroundStyle(Color.harborMuted).lineLimit(1).truncationMode(.middle) }
                    Spacer(minLength: 8)
                    if let shortcut, trailing == nil || !hovered {
                        Text(shortcut).harborFont(11, design: .monospaced).foregroundStyle(Color.harborMuted).opacity(hovered ? 1 : 0.7)
                    }
                }.padding(.leading, 10).padding(.trailing, trailing == nil ? 10 : 4).frame(height: 32).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(title)
            if let trailing {
                Button(action: trailing.action) {
                    Image(systemName: trailing.symbol).font(.system(size: 12)).frame(width: 28, height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(Color.harborMuted).opacity(hovered ? 1 : 0)
                    .help(trailing.label).accessibilityLabel(trailing.label).padding(.trailing, 4)
            }
        }
        .background(hovered ? Color.harborHover : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { inside in withAnimation(HarborMotion.feedback(.hover)) { hovered = inside } }
    }
}

/// The page's leading action, set apart from the rows under it: a card with what it is for.
private struct StartFeature: View {
    let title: String
    let detail: String
    let symbol: String
    let shortcut: String
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(Color.harborAccent).frame(width: 30, height: 30)
                    .background(Color.harborAccent.opacity(hovered ? 0.16 : 0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).harborFont(13, weight: .medium).lineLimit(1)
                    Text(detail).harborFont(11).foregroundStyle(Color.harborMuted).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(shortcut).harborFont(11, design: .monospaced).foregroundStyle(Color.harborMuted).opacity(hovered ? 1 : 0.7)
            }
            .padding(.leading, 9).padding(.trailing, 10).frame(height: 48).contentShape(Rectangle())
            .background(hovered ? Color.harborHover : Color.harborBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(hovered ? Color.harborAccent.opacity(0.55) : Color.harborBorder))
        }
        .buttonStyle(.plain).accessibilityLabel(title).accessibilityIdentifier("start-folders-in-windows")
        .onHover { inside in withAnimation(HarborMotion.feedback(.hover)) { hovered = inside } }
        .help("Put folders into windows, bring closed windows back, and add folders to the library")
    }
}

/// A window that was closed: its name and what it kept. A click opens it again with its folders.
private struct StartWindowRow: View {
    @EnvironmentObject var store: AppStore
    let window: RecentWindow
    let titles: [String]
    @State private var hovered = false
    var body: some View {
        Button { store.reopenNow(window) } label: {
            HStack(spacing: 10) {
                Image(systemName: "macwindow").font(.system(size: 13)).frame(width: 20, height: 20)
                    .foregroundStyle(hovered ? Color.harborAccent : Color.harborIcon)
                Text(window.name).harborFont(13).lineLimit(1).truncationMode(.middle).layoutPriority(1)
                Text(window.named ? titles.joined(separator: ", ") : titles.count == 1 ? "1 folder" : "\(titles.count) folders")
                    .harborFont(11).foregroundStyle(Color.harborMuted).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                if hovered { Text("Reopen").harborFont(11).foregroundStyle(Color.harborAccent).fixedSize() }
            }.padding(.horizontal, 10).frame(height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel("Reopen window " + window.name)
        .background(hovered ? Color.harborHover : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { inside in withAnimation(HarborMotion.feedback(.hover)) { hovered = inside } }
        .contextMenu {
            Button("Reopen") { store.reopenNow(window) }
            Button("Forget This Window", role: .destructive) { store.forget(window) }
        }
        .help("Open this window again with its folders: " + titles.joined(separator: ", "))
    }
}

private struct StartRecentRow: View {
    @EnvironmentObject var store: AppStore
    let item: RecentWorkspace
    @State private var hovered = false
    private static let ageFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en"); formatter.unitsStyle = .short
        return formatter
    }()
    /// "just now", "5 min. ago", "3 days ago".
    static func age(_ date: Date, now: Date) -> String {
        now.timeIntervalSince(date) < 60 ? "just now" : ageFormatter.localizedString(for: date, relativeTo: now)
    }
    private var profile: ServerProfile? { store.profiles.first { $0.id == item.serverID } }
    private var title: String {
        item.directory == nil ? "Default login" : item.directory == "/" ? "/" : item.directory == "~" ? "Home" : item.title
    }
    var body: some View {
        HStack(spacing: 0) {
            Button { store.openRecent(item) } label: {
                HStack(spacing: 11) {
                    Image(systemName: item.directory == nil ? profile?.displayIcon ?? "laptopcomputer" : "folder")
                        .font(.system(size: 13)).frame(width: 20, height: 20)
                        .foregroundStyle(hovered ? Color.harborAccent : Color.harborIcon)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).harborFont(13, weight: .medium).lineLimit(1).truncationMode(.middle)
                        Text(item.directory ?? "Default login directory").harborFont(11).foregroundStyle(Color.harborMuted)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 12)
                    // To the minute. A live `.relative` date ("5 min, 12 sec") had every row of the list
                    // drawn again once a second, and each drawing waited for the window server.
                    TimelineView(.everyMinute) { context in
                        Text(Self.age(item.openedAt, now: context.date)).harborFont(10).foregroundStyle(Color.harborMuted).lineLimit(1)
                    }
                }.padding(.vertical, 8).padding(.leading, 10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Open " + title)
            Button { store.removeRecent(item) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .medium)).frame(width: 28, height: 30).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(Color.harborMuted).opacity(hovered ? 1 : 0)
                .accessibilityLabel("Remove \(title) from Recent").help("Remove this shortcut only")
        }
        .background(hovered ? Color.harborHover : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { inside in withAnimation(HarborMotion.feedback(.hover)) { hovered = inside } }
        .help((item.directory ?? "Default directory") + " · " + (profile?.name ?? LocalMachine.name))
    }
}

@MainActor extension AppStore {
    /// Local folders and files open through the system panel. Server folders
    /// keep using Harbor's own browser, which lists them over SSH.
    func chooseLocal(directories: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directories; panel.canChooseFiles = !directories
        panel.allowsMultipleSelection = !directories; panel.canCreateDirectories = directories
        panel.prompt = "Open"
        panel.message = directories ? "Choose a folder to open as a workspace." : "Choose files to open. Their folder becomes the workspace."
        guard panel.runModal() == .OK else { return }
        openLocal(urls: panel.urls)
    }
    /// A folder dragged out of the Explorer becomes its own workspace.
    func openFolderWorkspace(_ path: String, profile: ServerProfile?, newWindow: Bool) async {
        if newWindow {
            // The next window's store opens the folder once it has loaded.
            Self.pendingWindowFolder = (path, profile?.id); workbenchUIRequest = "newWindow"
        } else { _ = await openDirectoryWorkspace(path, profile: profile) }
    }
    func openLocal(urls: [URL]) { Task { await openOutside(urls) } }
}
