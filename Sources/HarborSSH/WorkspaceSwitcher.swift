import SwiftUI
import AppKit
import HarborCore

/// Option+Tab steps through the folders of the window it is pressed in, most
/// recently shown first, the way Command+Tab steps through apps. A window is a
/// workspace: the folders it keeps, on whichever servers they are. Hold Option
/// while stepping and release it to go. Typing finds any folder Harbor knows
/// and keeps the panel open until Return or Escape. Switching changes the
/// window it was asked in and never which window is in front.
@MainActor final class WorkspaceSwitcher: ObservableObject {
    static let shared = WorkspaceSwitcher()

    struct Entry: Identifiable, Equatable {
        let id: String
        let profileID: UUID?
        let directoryID: UUID?
        let title: String
        let server: String
        let path: String
        let icon: String
        var current = false
        var otherWindow = false
        /// This window has an editor on the folder, on screen or in the background.
        var open = false
        /// The folder is kept in this window.
        var member = false
        /// The other window that keeps it or is showing it, by name.
        var window: String?
    }
    /// Where a server is open. A new window has opened none; each one it opens joins its own
    /// group, and what the other windows have open is listed after that.
    enum Placement: Equatable {
        case here
        /// Open in other windows only, with the name of the window (or how many).
        case elsewhere(String)
        case closed
        var order: Int { switch self { case .here: return 0; case .elsewhere: return 1; case .closed: return 2 } }
        var title: String { switch self { case .here: return "THIS WINDOW"; case .elsewhere: return "OTHER WINDOWS"; case .closed: return "NOT OPEN" } }
    }
    /// One server (or this Mac) with its folders.
    struct Group: Identifiable, Equatable {
        let id: String
        let name: String
        let detail: String
        let icon: String
        var entries: [Entry]
        var placement = Placement.closed
        /// This window has an editor on the server, on screen or in the background.
        var open = false
        var current: Bool { entries.contains(where: \.current) }
    }
    /// The heading over the folders that are not this window's.
    static let otherTitle = "NOT IN THIS WINDOW"
    /// The rows of the panel: this window's folders, and while a filter is typed, after them the
    /// folders of the library that match it.
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var query = ""
    @Published private(set) var visible = false
    /// Counts the times the panel was shown. Its list is built anew each time: rows that were
    /// laid out for an earlier showing kept that showing's look (no highlight, no dot).
    @Published private(set) var showing = 0
    /// The first row that is not one of this window's folders; a heading goes before it.
    @Published private(set) var firstOther: String?
    /// The name of the window the list is for.
    @Published private(set) var windowTitle = ""
    private var mine: [Entry] = [], others: [Entry] = []
    /// Typing or using the menu keeps the list open after Option is released.
    private var sticky = false
    private var panel: NSPanel?
    private var monitors: [Any] = []
    private weak var origin: AppStore?
    /// Workspace identities, most recently shown first. Kept between launches: the order of the
    /// list, and the folder each server comes up on, are the same after Harbor is restarted.
    private(set) static var recency: [String] = persistent ? UserDefaults.standard.stringArray(forKey: recencyKey) ?? [] : []
    private static let recencyKey = "workspaceSwitcherRecency"
    /// Tests share one process and must not inherit an order from an earlier run.
    private static let persistent = NSClassFromString("XCTestCase") == nil

    static func identity(profileID: UUID?, root: String, fallback: String) -> String {
        (profileID?.uuidString ?? "local") + "\n" + (RecentWorkspace.normalize(root) ?? fallback)
    }
    static func touch(_ identity: String) {
        guard recency.first != identity else { return }
        recency.removeAll { $0 == identity }; recency.insert(identity, at: 0)
        if recency.count > 64 { recency.removeLast(recency.count - 64) }
        if persistent { UserDefaults.standard.set(recency, forKey: recencyKey) }
    }

    /// App-local monitors; no global listener or Accessibility permission.
    func install() {
        guard monitors.isEmpty else { return }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged], handler: { [weak self] event in
            MainActor.assumeIsolated { Self.monitored(event, by: self) }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated {
                if let self, self.visible, event.window !== self.panel { self.dismiss() }
                return event
            }
        }) { monitors.append(monitor) }
        // Leaving Harbor cancels the switch; Option may be released elsewhere.
        monitors.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        })
    }

    /// What the key monitor hands back: nothing for a key the switcher took, so that it stops
    /// there. (It used to be `switcher?.handle(event) ?? event`, which gave every such key back:
    /// the list moved, and the terminal typed the "œ" of Option+Q or the tab as well.)
    static func monitored(_ event: NSEvent, by switcher: WorkspaceSwitcher?) -> NSEvent? {
        guard let switcher else { return event }
        return switcher.handle(event)
    }

    #if DEBUG
    /// The last key events seen, for reproducing reports with a real keyboard.
    private(set) var trace: [String] = []
    #endif
    func handle(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        #if DEBUG
        trace.append("\(event.type == .flagsChanged ? "flags" : "down") code=\(event.keyCode) option=\(flags.contains(.option)) raw=\(flags.rawValue) repeat=\(event.type == .keyDown && event.isARepeat) visible=\(visible) selected=\(entries.first { $0.id == selectedID }?.title ?? "-") t=\(Int(event.timestamp * 1000) % 100000)")
        if trace.count > 60 { trace.removeFirst() }
        #endif
        // One key press can reach a local monitor twice. Stepping twice skips an entry, and with
        // two folders that lands back on the current one, so nothing seemed to happen.
        if event.type == .keyDown {
            if let lastKey, lastKey.timestamp == event.timestamp, lastKey.code == event.keyCode { return lastKey.consumed ? nil : event }
            let result = route(event, flags: flags)
            lastKey = (event.timestamp, event.keyCode, result == nil)
            return result
        }
        return route(event, flags: flags)
    }
    private var lastKey: (timestamp: TimeInterval, code: UInt16, consumed: Bool)?
    private func route(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> NSEvent? {
        if event.type == .flagsChanged {
            if visible, !sticky, !flags.contains(.option) { commit() }
            return event
        }
        // Tab (48) steps through the folders of the window.
        if event.keyCode == 48, flags == .option || flags == [.option, .shift] {
            guard visible || canPresent(for: event) else { return event }
            // A held key repeats; each press is one step.
            if event.isARepeat { return nil }
            if !visible {
                present(sticky: false, window: event.window)
                // With a folder on screen the list opens on it and the press steps away from it.
                // With none (the start page) the press chooses the first, most recent one.
                guard visible, entries.first?.current == true else { return nil }
            }
            move(flags.contains(.shift) ? -1 : 1)
            return nil
        }
        guard visible else { return event }
        switch event.keyCode {
        case 53: dismiss()
        case 36, 76: commit()
        case 125: move(1)
        case 126: move(-1)
        case 48: move(flags.contains(.shift) ? -1 : 1)
        case 123, 124: break
        case 51:
            if !query.isEmpty { query.removeLast(); sticky = true; filter() }
        default:
            guard !flags.contains(.command), !flags.contains(.control),
                  let text = event.charactersIgnoringModifiers, !text.isEmpty,
                  text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) else { return nil }
            query += text; sticky = true; filter()
        }
        return nil
    }

    private func canPresent(for event: NSEvent) -> Bool {
        guard NSApp.modalWindow == nil, event.window?.attachedSheet == nil,
              !(event.window?.firstResponder is ShortcutRecorderButton) else { return false }
        return AppStore.all.contains { !$0.loading }
    }

    func present(sticky: Bool, window: NSWindow? = nil) {
        // The window the key was pressed in decides whose folders are listed and which one is current.
        guard let store = AppStore.all.first(where: { window != nil && $0.window === window }) ?? AppStore.lastActive
                ?? AppStore.all.first(where: { $0.window != nil }) ?? AppStore.all.first, !store.loading else { return }
        origin = store; self.sticky = sticky; query = ""
        (mine, others) = Self.folders(for: store)
        windowTitle = store.windowTitle
        guard !mine.isEmpty || !others.isEmpty else { return }
        // A window that keeps nothing yet lists the library. Nothing there is one step away:
        // it waits for Return or a click, so letting go of Option opens no folder by accident.
        if mine.isEmpty { self.sticky = true }
        filter()
        // Start on the folder itself; the first step moves to the previous one.
        selectedID = entries.first?.id
        showing += 1
        showPanel(over: store.window ?? NSApp.keyWindow)
        visible = true
    }

    /// The folders as the panel lists them: this window's own (what it keeps, and what it has an
    /// editor on), the one on screen first and then the most recently shown; and every other
    /// folder Harbor knows, for the filter.
    static func folders(for store: AppStore) -> (mine: [Entry], others: [Entry]) {
        let all = groups(for: store).flatMap(\.entries)
        func recent(_ entries: [Entry]) -> [Entry] {
            entries.enumerated().sorted { a, b in
                if a.element.current != b.element.current { return a.element.current }
                let left = store.recencyRank(a.element.id), right = store.recencyRank(b.element.id)
                return left != right ? left < right : a.offset < b.offset
            }.map(\.element)
        }
        return (recent(all.filter { $0.current || $0.open || $0.member }), recent(all.filter { !($0.current || $0.open || $0.member) }))
    }

    /// Servers with their folders. The server and folder on screen come first,
    /// then the most recently used; unused ones keep the order of the sidebar.
    static func groups(for store: AppStore) -> [Group] {
        let currentKey = store.page == .workspace ? identity(profileID: store.currentFiles.profile?.id, root: store.currentFiles.root, fallback: store.currentFiles.key) : nil
        let elsewhere = Set(AppStore.all.filter { $0 !== store && $0.window != nil }.compactMap { $0.workspaceClaim?.key })
        // What this window showed comes before what any window showed.
        var order: [String: Int] = [:]
        for (index, key) in recency.enumerated() { order[key] = 1_000 + index }
        for (index, key) in store.ownRecency.enumerated() { order[key] = index }
        /// A server comes up on the folder this window last showed there. A folder another window
        /// is showing now cannot be shown here as well, so it is never the one a server comes up on.
        func ranked(_ entries: [Entry], own: String?) -> [Entry] {
            entries.enumerated().sorted { a, b in
                if a.element.current != b.element.current { return a.element.current }
                if a.element.otherWindow != b.element.otherWindow { return b.element.otherWindow }
                // What is open here already comes before anything that would have to be opened:
                // stepping reaches the folders in use first, and a server comes up on one of them.
                if a.element.open != b.element.open { return a.element.open }
                // Then this window's own folders, then the free ones, then those another window keeps.
                if a.element.member != b.element.member { return a.element.member }
                if (a.element.window == nil) != (b.element.window == nil) { return a.element.window == nil }
                let mine = (a.element.directoryID?.uuidString ?? "default") == own, theirs = (b.element.directoryID?.uuidString ?? "default") == own
                if mine != theirs { return mine }
                let left = order[a.element.id] ?? Int.max, right = order[b.element.id] ?? Int.max
                return left != right ? left < right : a.offset < b.offset
            }.map(\.element)
        }
        /// The folder this window last showed on a server; before it has shown any, the one chosen
        /// there last in any window, which is remembered between launches.
        func own(_ profileID: UUID?) -> String? {
            let key = store.directoryCatalogKey(profileID)
            return store.ownDirectories[key] ?? store.workspaceDefaults.string(forKey: key + ".selected")
        }
        let others = AppStore.all.filter { $0 !== store && $0.window != nil }
        // The folders each window keeps: a server is "here" when one of its folders is this
        // window's, whether or not an editor is running on it.
        // Asked by the folder itself: two windows may spell a path through a link differently.
        let mine = Set(store.keptFolders.map(\.match))
        var keeper: [String: String] = [:], shown: [String: String] = [:]
        for other in others {
            for folder in other.keptFolders { keeper[folder.match] = other.windowTitle }
            if let key = other.workspaceClaim?.key { shown[key] = other.windowTitle }
        }
        func placement(_ profileID: UUID?, _ entries: [Entry]) -> Placement {
            if store.hasOpen(profileID) || entries.contains(where: \.member) { return .here }
            var names = Set(others.filter { $0.hasOpen(profileID) }.map(\.windowTitle))
            names.formUnion(entries.compactMap(\.window))
            guard let first = names.first else { return .closed }
            return .elsewhere(names.count == 1 ? first : "\(names.count) windows")
        }
        var result: [Group] = []
        for profile in [ServerProfile?.none] + store.profiles.map(Optional.some) {
            let name = profile?.name ?? LocalMachine.name, icon = profile?.displayIcon ?? "laptopcomputer"
            let detail = profile.map { $0.user.isEmpty ? $0.host : $0.user + "@" + $0.host } ?? "This Mac"
            var entries: [Entry] = []
            for files in store.directoryWorkspaces(for: profile) where !files.root.isEmpty {
                let key = identity(profileID: profile?.id, root: files.root, fallback: files.key)
                guard !entries.contains(where: { $0.id == key }) else { continue }
                let match = WindowFolder.match(profileID: profile?.id, path: files.root)
                entries.append(Entry(id: key, profileID: profile?.id, directoryID: files.directoryID, title: files.directoryTitle, server: name,
                                     path: files.root, icon: "folder", current: key == currentKey, otherWindow: elsewhere.contains(key),
                                     open: key == currentKey || store.codeWorkbench.runs(files),
                                     member: mine.contains(match), window: mine.contains(match) ? nil : keeper[match] ?? shown[key]))
            }
            if entries.isEmpty {
                // A server without folders is still one Tab away.
                let files = store.files(for: profile, directoryID: nil)
                let key = identity(profileID: profile?.id, root: "", fallback: files.key)
                entries.append(Entry(id: key, profileID: profile?.id, directoryID: nil, title: "Login directory", server: name,
                                     path: "Opens where the server puts you", icon: "house", current: key == currentKey, otherWindow: elsewhere.contains(key)))
            }
            result.append(Group(id: profile?.id.uuidString ?? "local", name: name, detail: detail, icon: icon,
                                entries: ranked(entries, own: own(profile?.id)),
                                placement: placement(profile?.id, entries), open: store.hasOpen(profile?.id)))
        }
        return result.enumerated().sorted { a, b in
            if a.element.current != b.element.current { return a.element.current }
            // What this window has open, then what the other windows have, then the rest.
            if a.element.placement.order != b.element.placement.order { return a.element.placement.order < b.element.placement.order }
            // Among this window's servers, those with an editor running come before those it only keeps a folder of.
            if a.element.open != b.element.open { return a.element.open }
            let left = a.element.entries.compactMap { order[$0.id] }.min() ?? Int.max, right = b.element.entries.compactMap { order[$0.id] }.min() ?? Int.max
            return left != right ? left < right : a.offset < b.offset
        }.map(\.element)
    }

    /// While the panel is up, a folder joining or leaving the window shows at once.
    func refresh() {
        guard visible, let store = origin else { return }
        let fresh = Self.folders(for: store)
        guard fresh.mine != mine || fresh.others != others else { return }
        (mine, others) = fresh; filter()
    }

    private func filter() {
        let text = query.trimmingCharacters(in: .whitespaces)
        func matches(_ entry: Entry) -> Bool { (entry.title + " " + entry.server + " " + entry.path).localizedCaseInsensitiveContains(text) }
        // Without a filter the list is the window's own folders; the library is searched, not stepped through.
        let rest = text.isEmpty ? (mine.isEmpty ? others.filter { !$0.path.isEmpty && $0.icon == "folder" } : []) : others.filter(matches)
        entries = (text.isEmpty ? mine : mine.filter(matches)) + rest
        firstOther = rest.first?.id
        if !entries.contains(where: { $0.id == selectedID }) { selectedID = entries.first?.id }
    }
    /// Steps through the rows.
    func move(_ delta: Int) {
        guard !entries.isEmpty else { return }
        let index = entries.firstIndex { $0.id == selectedID } ?? 0
        selectedID = entries[(index + delta + entries.count) % entries.count].id
    }
    func choose(_ entry: Entry) { selectedID = entry.id; commit() }

    func commit() {
        let entry = entries.first { $0.id == selectedID }
        let store = origin
        dismiss()
        guard let entry, let store, !entry.current else { return }
        // A folder that another window is showing opens here as a notice with a button to go
        // there; choosing it does not change which window is in front.
        let profile = store.profiles.first { $0.id == entry.profileID }
        guard entry.profileID == nil || profile != nil else { return }
        let files = store.files(for: profile, directoryID: entry.directoryID)
        files.enabled = true
        store.selectDirectoryWorkspace(files)
    }

    func dismiss() {
        visible = false; sticky = false; query = ""
        panel?.orderOut(nil)
    }
    /// Leaves the list for the organizer, where folders are moved between windows.
    func arrange() {
        let store = origin
        dismiss()
        store?.organizerVisible = true
    }

    private func showPanel(over window: NSWindow?) {
        let panel = self.panel ?? {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 480), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false; panel.level = .floating
            panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: WorkspaceSwitcherView(switcher: self))
            self.panel = panel; return panel
        }()
        let frame = window?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2 + min(60, frame.height * 0.06)))
        panel.orderFront(nil)
    }
}

private struct WorkspaceSwitcherView: View {
    @ObservedObject var switcher: WorkspaceSwitcher
    @AppStorage("appearance") private var appearance = HarborTheme.defaultAppearance
    var body: some View {
        // The list starts with this window's folders unless it keeps none.
        let own = switcher.entries.first.map { $0.id != switcher.firstOther } ?? true
        let headed = switcher.firstOther != nil && own
        let listHeight = 30 + 46 * CGFloat(max(switcher.entries.count, 1)) + (headed ? 26 : 0) + 31
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Color.harborMuted)
                Text(switcher.query.isEmpty ? "Type to find any folder" : switcher.query)
                    .harborFont(13).foregroundStyle(switcher.query.isEmpty ? Color.harborMuted : Color.harborForeground).lineLimit(1)
                Spacer()
                Text("⌥⇥ next · ⏎ open").harborFont(10, design: .monospaced).foregroundStyle(Color.harborMuted)
            }.padding(.horizontal, 14).frame(height: 40)
            Rectangle().fill(Color.harborBorder).frame(height: 1)
            if switcher.entries.isEmpty {
                Text("No matching folder.").harborFont(12).foregroundStyle(Color.harborMuted).frame(maxWidth: .infinity).padding(.vertical, 26)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text(own ? switcher.windowTitle.uppercased() : WorkspaceSwitcher.otherTitle).harborFont(10, weight: .semibold).kerning(0.6)
                        .foregroundStyle(Color.harborMuted).lineLimit(1).truncationMode(.middle).padding(.horizontal, 16).frame(height: 30)
                    ScrollViewReader { reader in
                        // Not lazy: a dozen rows, and every one of them must follow the selection.
                        ScrollView {
                            VStack(spacing: 2) {
                                ForEach(switcher.entries) { entry in
                                    if headed, entry.id == switcher.firstOther {
                                        Text(WorkspaceSwitcher.otherTitle).harborFont(10, weight: .semibold).kerning(0.6).foregroundStyle(Color.harborMuted)
                                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).frame(height: 24, alignment: .bottom)
                                    }
                                    WorkspaceSwitcherRow(entry: entry, selected: entry.id == switcher.selectedID)
                                        .id(entry.id).onTapGesture { switcher.choose(entry) }
                                }
                            }.padding(.horizontal, 6).padding(.bottom, 6)
                        }
                        .onChange(of: switcher.selectedID) { _, id in
                            if let id { withAnimation(HarborMotion.animation(HarborMotion.quick)) { reader.scrollTo(id) } }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .id(switcher.showing)
                Rectangle().fill(Color.harborBorder).frame(height: 1)
                HStack {
                    Text(own ? "A window switches between its own folders." : "This window keeps no folder yet.").harborFont(10).foregroundStyle(Color.harborMuted)
                    Spacer()
                    Button("Folders in Windows…") { switcher.arrange() }.buttonStyle(.link).harborFont(11)
                        .help("Choose which folders are kept in which window")
                }.padding(.horizontal, 14).frame(height: 30)
            }
        }
        // As tall as the list, up to the panel's height.
        .frame(width: 500, height: min(430, 41 + listHeight + 8))
        .background(Color.harborWidget, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.harborBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // Cast from the panel's outline, not by everything in the list (worked out again as it scrolls).
        .harborPanelGround(Color.harborWidget, cornerRadius: 14, shadow: 0.22, radius: 18, y: 8)
        .padding(.horizontal, 30).padding(.top, 6)
        .frame(width: 660, height: 480, alignment: .top)
        .foregroundStyle(Color.harborForeground)
        .environment(\.locale, Locale(identifier: "en"))
        .preferredColorScheme(HarborTheme.scheme(appearance))
        .accessibilityIdentifier("workspace-switcher")
    }
}

private struct WorkspaceSwitcherRow: View {
    let entry: WorkspaceSwitcher.Entry
    let selected: Bool
    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: entry.icon).font(.system(size: 14)).frame(width: 22, height: 22)
                .foregroundStyle(selected ? Color.harborAccent : Color.harborIcon)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).harborFont(13, weight: .medium).lineLimit(1).truncationMode(.middle)
                // The folders of a window are on several servers: each row says which.
                (Text(entry.server).foregroundStyle(Color.harborForeground.opacity(0.78)) + Text("  " + entry.path))
                    .harborFont(11).foregroundStyle(Color.harborMuted).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if entry.open, !entry.current { Circle().fill(Color.harborSuccess).frame(width: 6, height: 6).help("An editor on this folder is running in this window") }
            else if entry.member, !entry.current { Circle().stroke(Color.harborSuccess, lineWidth: 1.3).frame(width: 5.5, height: 5.5).help("Kept in this window") }
            if entry.current { badge("Current") } else if let window = entry.window { badge("in " + window).frame(maxWidth: 150, alignment: .trailing) } else if entry.otherWindow { badge("Other window") }
        }
        .padding(.horizontal, 10).frame(height: 44).contentShape(Rectangle())
        .background(selected ? Color.harborSelection : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine).accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
    private func badge(_ text: String) -> some View {
        Text(text).harborFont(10).foregroundStyle(Color.harborMuted).lineLimit(1).truncationMode(.middle).padding(.horizontal, 7).padding(.vertical, 2)
            .overlay(Capsule().stroke(Color.harborBorder, lineWidth: 1))
    }
}
