import SwiftUI
import HarborCore

extension Notification.Name { static let harborFindRecent = Notification.Name("harbor.find.recent") }

struct RecentWorkspacesView: View {
    @EnvironmentObject var store: AppStore
    var scoped = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    private var groups: [RecentWorkspaceGroup] {
        RecentWorkspaceGroup.make(store.recents.filter { !scoped || $0.serverID == store.selectedProfileID }, profiles: store.profiles, query: query)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(scoped ? store.selectedProfile?.name ?? "Local" : "Welcome Back").harborFont(27, weight: .semibold, design: .rounded)
                    Text("Connect to a server and pick up where you left off.").harborFont(13).foregroundStyle(Color.harborMuted)
                }
                HStack(spacing: 12) {
                    Button { store.openWorkspaceTerminal() } label: { Label(scoped ? "New Terminal" : "Connect to Current Server", systemImage: "terminal") }
                        .buttonStyle(.borderedProminent)
                    Button { store.chooseDirectoryWorkspace() } label: { Label("Open Folder…", systemImage: "folder") }.buttonStyle(.bordered)
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Recents").harborFont(17, weight: .semibold)
                        Spacer()
                        if !store.recents.isEmpty { TextField("Search folders or servers", text: $query).textFieldStyle(HarborTextFieldStyle()).frame(maxWidth: 230).focused($searchFocused) }
                    }.padding(.bottom, 6)
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 9) {
                                HarborSymbol(systemName: store.profiles.first { $0.id == group.serverID }?.displayIcon ?? "laptopcomputer")
                                    .foregroundStyle(Color.harborAccent)
                                Text(group.name).harborFont(13, weight: .semibold)
                                Text("\(group.entries.count)").harborFont(11).foregroundStyle(Color.harborMuted)
                                Spacer()
                            }.padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 5)
                            ForEach(group.entries) { item in RecentWorkspaceRow(item: item) }
                        }.accessibilityElement(children: .contain).accessibilityLabel(group.name + " recent workspaces")
                    }
                    if groups.isEmpty {
                        Text(query.isEmpty ? "Your 12 most recent folders and server logins will appear here." : "No matching folders.").harborFont(12).foregroundStyle(Color.harborMuted).padding(.vertical, 12)
                    }
                }
            }.frame(maxWidth: 850, alignment: .leading).padding(.horizontal, 32).padding(.vertical, 30).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.harborEditor)
            .onReceive(NotificationCenter.default.publisher(for: .harborFindRecent)) { _ in searchFocused = true }
    }
}

private struct RecentWorkspaceRow: View {
    @EnvironmentObject var store: AppStore
    let item: RecentWorkspace
    @State private var hovered = false
    private var profile: ServerProfile? { store.profiles.first { $0.id == item.serverID } }
    private var serverName: String { profile?.name ?? "Local" }
    private var title: String { item.directory == nil ? "Default login" : item.directory == "/" ? "/" : item.directory == "~" ? "Home" : item.title }
    var body: some View {
        HStack(spacing: 0) {
            Button { store.openRecent(item) } label: {
                HStack(spacing: 12) {
                    HarborSymbol(systemName: item.directory == nil ? profile?.displayIcon ?? "laptopcomputer" : "folder.fill").frame(width: 24, height: 26)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title)
                            .harborFont(14, weight: .medium).foregroundStyle(Color.harborAccent).lineLimit(1).truncationMode(.middle)
                        Text(item.directory ?? "Default login directory").harborFont(11).foregroundStyle(Color.harborMuted).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 12)
                    Text(item.openedAt, style: .relative).harborFont(10).foregroundStyle(.tertiary).lineLimit(1)
                }.padding(.vertical, 10).padding(.leading, 10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).compactHint(title, detail: item.directory ?? serverName, enabled: false)
            Button { store.removeRecent(item) } label: { HarborSymbol(systemName: "xmark").frame(width: 28, height: 30) }
                .buttonStyle(.plain).opacity(hovered ? 1 : 0.12).accessibilityLabel("Remove \(title) from Recents").help("Remove this shortcut only")
        }.background(hovered ? Color.harborHover : .clear, in: RoundedRectangle(cornerRadius: 8))
            .onHover { hovered = $0 }.help((item.directory ?? "Default directory") + " · " + serverName)
    }
}
