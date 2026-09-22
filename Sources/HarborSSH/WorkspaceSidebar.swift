import SwiftUI
import HarborCore

struct WorkspaceSidebar: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("interfaceFontSize") private var fontSize = 13.0
    let width: Double
    let resize: (Double) -> Void
    let edit: (ServerProfile) -> Void
    @State private var search = ""
    @StateObject private var serverFocus = BrowserListFocus()
    private var visibleProfiles: [ServerProfile] { store.profiles.filter { profile in search.isEmpty || ([profile.name, profile.host] + (profile.aliases ?? [])).contains { $0.localizedCaseInsensitiveContains(search) } } }
    @State private var searchPresented = false
    private var reveal: Double { HarborLayout.reveal(width, from: 82, to: 202) }
    private var inset: Double { 6 + 4 * reveal }
    private var rowHeight: Double { 36 + 18 * reveal * min(max(fontSize / 13, 0.85), 1.55) }
    private var activeTerminalLabel: String { "\(store.activeCount) active " + (store.activeCount == 1 ? "terminal" : "terminals") }
    private func expand() { withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.88)) { resize(220) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9 * reveal) {
                HarborSymbol(systemName: "terminal.fill").font(.system(size: 17)).foregroundStyle(.white)
                    .frame(width: 30, height: 30).background(Color.harborButton, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Harbor").harborFont(21, weight: .semibold, design: .rounded).lineLimit(1)
                    Text("Your SSH workbench").harborFont(10).foregroundStyle(Color.harborMuted).lineLimit(1)
                }.frame(width: max(0, width - 65), alignment: .leading).opacity(reveal).clipped()
            }.padding(.leading, 11 + 4 * reveal).frame(height: 48 + 18 * reveal, alignment: .leading)
                .compactHint("Harbor", detail: "Your SSH workbench", enabled: reveal < 0.9)
            VStack(spacing: 4) {
                navigation(.workspace, symbol: "square.grid.2x2")
                navigation(.display, symbol: "display")
                navigation(.proxy, symbol: "arrow.left.arrow.right")
                navigation(.recent, symbol: "clock.arrow.circlepath")
            }.padding(.horizontal, inset)
            ZStack(alignment: .topLeading) {
                VStack(spacing: 10) {
                    HStack {
                        Text("Servers").harborFont(11, weight: .semibold).foregroundStyle(Color.harborMuted)
                        Spacer(minLength: 0)
                        Button { Task { await store.importSSHConfig() } } label: { HarborSymbol(systemName: "arrow.clockwise") }
                            .buttonStyle(.plain).disabled(store.importing).compactHint("Import and Merge Servers", enabled: false)
                        Button { edit(ServerProfile()) } label: { HarborSymbol(systemName: "plus") }.buttonStyle(.plain).help("Add Server")
                    }
                    TextField("Search servers", text: $search).textFieldStyle(HarborTextFieldStyle()).harborFont(11)
                }.padding(.horizontal, 14).padding(.top, 18).opacity(reveal).allowsHitTesting(reveal > 0.5).accessibilityHidden(reveal <= 0.5)
                VStack(spacing: 3) {
                    Divider().overlay(Color.harborBorder).padding(.bottom, 4)
                    Menu {
                        Button("Add Server…") { edit(ServerProfile()) }
                        Button("Import and Merge Servers") { Task { await store.importSSHConfig() } }.disabled(store.importing)
                        Button("Expand Sidebar") { expand() }
                    } label: { HarborSymbol(systemName: "plus").frame(height: 23) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Server Actions").compactHint("Server Actions")
                    Button { searchPresented.toggle() } label: { HarborSymbol(systemName: "magnifyingglass").frame(width: 32, height: 27).contentShape(Rectangle()) }
                        .buttonStyle(.plain).accessibilityLabel("Search servers").compactHint("Search servers")
                        .popover(isPresented: $searchPresented, arrowEdge: .trailing) {
                            HStack { TextField("Search servers", text: $search).textFieldStyle(HarborTextFieldStyle()); Button("Clear") { search = "" } }.padding(12).frame(width: 260)
                        }
                }.frame(width: 40).padding(.horizontal, 6).padding(.top, 10).opacity(1 - reveal).allowsHitTesting(reveal <= 0.5).accessibilityHidden(reveal > 0.5)
            }.frame(width: width, height: 92, alignment: .leading).clipped()
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(visibleProfiles) { profile in
                            server(profile).id(profile.id)
                        }
                    }
                    .padding(.horizontal, inset).padding(.vertical, 3)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.profiles.map(\.id))
                }.onChange(of: store.selectedProfileID) { _, id in if let id { reader.scrollTo(id) } }
            }
            Button { store.selectWorkspace(nil) } label: {
                row(symbol: "laptopcomputer", title: "Local Terminal", selected: store.page == .workspace && store.selectedProfileID == nil)
            }.buttonStyle(.plain).accessibilityLabel("Local Terminal").compactHint("Local Terminal", enabled: reveal < 0.9)
                .contextMenu { Button("New Local Terminal") { store.openTerminal(nil) } }.padding(.horizontal, inset)
            Divider().overlay(Color.harborBorder).padding(.horizontal, inset).padding(.vertical, 9)
            HStack(spacing: 6 * reveal) {
                SettingsLink { HarborSymbol(systemName: "gearshape").frame(width: 32, height: 30) }.buttonStyle(HarborGlassButtonStyle())
                    .accessibilityLabel("Settings").compactHint("Settings", detail: activeTerminalLabel, enabled: reveal < 0.9)
                Text(activeTerminalLabel).harborFont(10).foregroundStyle(Color.harborMuted).lineLimit(1)
                    .frame(width: max(0, width - 63), alignment: .leading).opacity(reveal).clipped()
            }.padding(.leading, 10).padding(.bottom, 8)
        }.frame(width: width, alignment: .leading).background(Color.harborSidebar).clipped()
            .background(BrowserListKeyboardBridge(store: store, serverIDs: visibleProfiles.map(\.id), focus: serverFocus))
    }
    private func navigation(_ page: AppPage, symbol: String) -> some View {
        Button { store.page = page } label: { row(symbol: symbol, title: page.rawValue, selected: store.page == page) }
            .buttonStyle(.plain).accessibilityLabel(page.rawValue).compactHint(page.rawValue, enabled: reveal < 0.9)
    }
    private func row(symbol: String, title: String, selected: Bool) -> some View {
        HStack(spacing: 10 * reveal) {
            HarborSymbol(systemName: symbol).frame(width: 22, height: 22)
            Text(title).harborFont(13, weight: selected ? .semibold : .regular).lineLimit(1)
                .frame(width: max(0, width - 2 * inset - 42 - 10 * reveal), alignment: .leading).opacity(reveal).clipped()
        }.padding(.leading, 9 + reveal).frame(maxWidth: .infinity, alignment: .leading).frame(height: 36 + 5 * reveal)
            .foregroundStyle(selected ? Color.harborSelectionText : Color.harborForeground)
            .harborSelectionGlass(selected).contentShape(Rectangle())
    }
    private func server(_ profile: ServerProfile) -> some View {
        let selected = store.page == .workspace && store.selectedProfileID == profile.id
        let connected = store.connectionStates[profile.id] == "Connected"
        let count = store.attachedSessions.filter { $0.profile?.id == profile.id }.count
        return Button { store.selectWorkspace(profile.id); serverFocus.view?.focusList() } label: {
            HStack(spacing: 10 * reveal) {
                HarborSymbol(systemName: profile.displayIcon).frame(width: 22, height: 22).overlay(alignment: .bottomTrailing) {
                    Circle().fill(connected ? Color.harborSuccess : Color.harborMuted.opacity(0.30)).frame(width: 5, height: 5).offset(x: 3, y: 2)
                }
                HStack(spacing: 3) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile.name).harborFont(13, weight: .medium).lineLimit(1)
                        Text(profile.user.isEmpty ? profile.host : profile.user).harborFont(10).foregroundStyle(Color.harborMuted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if count > 0 { Text("\(count)").harborFont(10, design: .monospaced).foregroundStyle(Color.harborMuted) }
                }.frame(width: max(0, width - 2 * inset - 42 - 10 * reveal), alignment: .leading).opacity(reveal).clipped()
            }.padding(.leading, 9 + reveal).frame(maxWidth: .infinity, alignment: .leading).frame(height: rowHeight)
                .foregroundStyle(selected ? Color.harborSelectionText : Color.harborForeground)
                .harborSelectionGlass(selected).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(profile.name)
            .accessibilityIdentifier("server-" + profile.id.uuidString)
            .harborDragSource(.server(profile.id))
            .harborDropTarget(.server(profile.id))
            .compactHint(profile.name, detail: "\(profile.user.isEmpty ? profile.host : profile.user) · \(count) terminals\nDouble-click to open a terminal", enabled: reveal < 0.9)
            .simultaneousGesture(TapGesture(count: 2).onEnded { store.openTerminal(profile) })
            .contextMenu {
                Button("New Terminal") { store.openTerminal(profile) }
                Button("Remote Display") { store.selectWorkspace(profile.id); store.page = .display }
                Button("Open in New Window") { if let id = store.openTerminal(profile, detached: true) { openWindow(id: "terminal", value: id) } }
                Divider().overlay(Color.harborBorder); Button("Edit Server") { edit(profile) }
                Button("Remove Server", role: .destructive) { store.remove(profile) }
            }
    }
}
