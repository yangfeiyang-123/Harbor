import SwiftUI
import AppKit
import HarborCore

struct RemoteDisplayPage: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var controller: RemoteDisplayController
    @State private var editing: RemoteDisplayProfile?
    @State private var preparing = false
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Displays").font(.headline)
                    Spacer()
                    Button { editing = RemoteDisplayProfile(serverID: store.selectedProfileID) } label: { Image(systemName: "plus") }.help("Add Remote Display").accessibilityLabel("Add Remote Display")
                }.padding(.horizontal, 14).padding(.top, 16)
                if store.selectedProfile != nil {
                    Button(preparing ? "Preparing…" : "View Current Project") { prepareProject() }
                        .buttonStyle(.borderedProminent).disabled(preparing).padding(.horizontal, 12)
                        .help("Start or reconnect to the simulation in your current project")
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(serverGroups, id: \.key) { group in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(group.name).font(.caption).foregroundStyle(Color.harborMuted).padding(.horizontal, 10)
                                ForEach(group.items) { profile in
                                    Button { controller.selectedID = profile.id } label: {
                                        HStack {
                                            Image(systemName: "display")
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(profile.name).lineLimit(1)
                                                Text(profile.preset.title).font(.caption2).foregroundStyle(Color.harborMuted).lineLimit(1)
                                            }
                                            Spacer(minLength: 0)
                                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).harborSelectionGlass(controller.selectedID == profile.id)
                                    }.buttonStyle(.plain).contextMenu {
                                        Button("Edit Display…") { editing = profile }
                                        Button("Remove Display", role: .destructive) { controller.remove(profile) }
                                    }
                                }
                            }
                        }
                    }.padding(8)
                }
                Text("Simulation runs on your server. Disconnecting a display keeps it running.").font(.caption).foregroundStyle(Color.harborMuted).padding(14)
            }.frame(width: 220).background(Color.harborSidebar)
            Divider()
            if let profile = controller.profiles.first(where: { $0.id == controller.selectedID }) {
                RemoteDisplayDetail(session: controller.session(for: profile), server: store.profiles.first(where: { $0.id == profile.serverID }), edit: { editing = profile }).id(profile.id)
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "display.2").font(.system(size: 42)).foregroundStyle(Color.harborAccent)
                    Text("Remote Simulation").font(.title.bold())
                    Text("View and control your simulator without leaving your workbench.").foregroundStyle(Color.harborMuted)
                    Text("Isaac Sim · MuJoCo · Gazebo · Webots · VNC · Web viewers").font(.callout).foregroundStyle(Color.harborMuted)
                    Button("Add Remote Display") { editing = RemoteDisplayProfile(serverID: store.selectedProfileID) }.buttonStyle(.borderedProminent)
                }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(Color.harborBackground)
        .onAppear { controller.load() }
        .sheet(item: $editing) { profile in
            RemoteDisplayEditor(profile: profile, servers: store.profiles, controller: controller)
        }
        .alert("Remote Display", isPresented: Binding(get: { controller.error != nil }, set: { if !$0 { controller.error = nil } })) {
            Button("OK") { controller.error = nil }
        } message: { Text(controller.error ?? "") }
    }
    private var serverGroups: [(key: String, name: String, items: [RemoteDisplayProfile])] {
        let groups = Dictionary(grouping: controller.profiles, by: { $0.serverID?.uuidString ?? "local" })
        return groups.map { key, items in
            (key: key, name: store.profiles.first(where: { $0.id.uuidString == key })?.name ?? (key == "local" ? "Local / Direct" : "Unavailable Server"), items: items)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private func prepareProject() {
        guard let server = store.selectedProfile else { return }
        let directory = store.currentFiles.root
        if let saved = controller.profiles.first(where: { $0.serverID == server.id && $0.launch?.directory == directory && $0.client == .isaac }) {
            controller.selectedID = saved.id; controller.session(for: saved).connect(server: server); return
        }
        preparing = true
        Task {
            defer { preparing = false }
            let result = await ProcessRunner.run("/usr/bin/ssh", SSHArguments.connection(server) + ["-G", "--", server.host], timeout: 8)
            let host = result.output.components(separatedBy: "\n").first(where: { $0.hasPrefix("hostname ") }).map { String($0.dropFirst(9)) } ?? server.host
            var profile = RemoteDisplayProfile(serverID: server.id)
            profile.name = URL(fileURLWithPath: directory).lastPathComponent + " · Isaac"
            profile.preset = .isaac; profile.client = .isaac; profile.useSSHTunnel = false
            profile.address = "isaac://\(host):49100"
            profile.launch = SimulationLaunch(directory: directory)
            let quoted = "'" + directory.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
            let probe = await ProcessRunner.run("/usr/bin/ssh", SSHArguments.connection(server) + ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "RemoteCommand=none", "--", server.host, "cd -- \(quoted) && test -x scripts/replay_remote.sh"], timeout: 12)
            if probe.succeeded && profile.validationError == nil && controller.save(profile) {
                controller.session(for: profile).connect(server: server)
            } else { editing = profile }
        }
    }
}

struct RemoteDisplayDetail: View {
    @ObservedObject var session: RemoteDisplaySession
    let server: ServerProfile?
    let edit: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(session.profile.name).font(.headline).lineLimit(1)
                Spacer()
                Button("Edit", action: edit)
                if session.simulationOwned {
                    Button(session.simulationStopPending ? "Force Stop" : "Stop Simulation", role: .destructive) {
                        session.stopSimulation(server: server, force: session.simulationStopPending)
                    }.disabled(session.connecting)
                    .help(session.simulationStopPending ? "Force-quit only this Harbor-started simulation after it failed to stop normally." : "Stop only the simulation started by Harbor.")
                }
                if session.connected || session.connecting { Button("Disconnect") { session.disconnect() } }
                else { Button(session.profile.launch == nil ? "Connect" : "Start & View") { session.connect(server: server) }.buttonStyle(.borderedProminent) }
            }.padding(12)
            Divider()
            RemoteDisplayCanvas(session: session)
        }.onAppear { session.mainVisible = true; if !session.detached { session.resumeWeb() } }
            .onDisappear { session.mainVisible = false; session.pauseIfHidden() }
    }
}

struct RemoteDisplayCanvas: View {
    @ObservedObject var session: RemoteDisplaySession
    var inWindow = false
    var body: some View {
        VStack(spacing: 0) {
            if let error = session.error {
                HStack { Image(systemName: "exclamationmark.triangle"); Text(error).textSelection(.enabled); Spacer() }.font(.callout).padding(12).background(Color.orange.opacity(0.12))
            }
            if session.detached && !inWindow {
                VStack(spacing: 12) { Image(systemName: "macwindow.on.rectangle").font(.largeTitle); Text("Display is open in its own window"); Button("Show Window") { session.detachWindow() } }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let web = session.web {
                RemoteWebSurface(web: web).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if session.connecting { ProgressView("Connecting…") }
                        Text(session.profile.preset.title).font(.title2.bold())
                        Text(session.profile.client == .isaac ? "Start & View opens your project's simulation automatically. Keep this Mac connected to your server network or VPN. The interactive viewer opens in its own Harbor window powered by Chrome or Edge. Close any other Isaac viewer before connecting." : session.profile.preset.guidance).foregroundStyle(Color.harborMuted).fixedSize(horizontal: false, vertical: true)
                        Label(session.profile.client.title, systemImage: "display")
                        Text(session.profile.address).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        if session.connected && session.profile.client != .embedded { Button("Open Viewer Again") { session.openExternal() } }
                        if let launch = session.profile.launch {
                            Label(launch.directory, systemImage: "folder").font(.callout).textSelection(.enabled)
                            Text(session.simulationOwned ? "Harbor started this simulation. Stop Simulation ends only this job." : "Existing streams are reused. Simulations started outside Harbor are never stopped here.").font(.caption).foregroundStyle(Color.harborMuted)
                        }
                        if !session.simulationLog.isEmpty {
                            DisclosureGroup("Startup Log") { ScrollView { Text(session.simulationLog).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 200) }
                        }
                        Link("Setup Guide ↗", destination: session.profile.preset.docs)
                    }.padding(30).frame(maxWidth: 780, alignment: .leading)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 14) {
                Circle().fill(session.connected ? Color.harborSuccess : Color.harborMuted).frame(width: 6, height: 6)
                Text(session.status).font(.caption).lineLimit(1)
                Spacer()
                if session.connected {
                    if session.profile.client == .embedded {
                        Button { session.reload() } label: { Image(systemName: "arrow.clockwise") }.help("Reload Viewer").accessibilityLabel("Reload Viewer")
                        if !inWindow { Button { session.detachWindow() } label: { Image(systemName: "macwindow") }.help("Open in Window").accessibilityLabel("Open Display in Window") }
                        Button { session.fullScreen() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("Full Screen").accessibilityLabel("Full Screen Display")
                    }
                    Button { session.openExternal() } label: { Image(systemName: "arrow.up.right.square") }.help("Open External Viewer").accessibilityLabel("Open External Viewer")
                }
            }.buttonStyle(.plain).padding(.horizontal, 12).frame(height: 34)
        }.background(Color.harborBackground).foregroundStyle(Color.harborForeground)
    }
}

struct RemoteDisplayEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var profile: RemoteDisplayProfile
    let servers: [ServerProfile]
    @ObservedObject var controller: RemoteDisplayController
    @State private var checking = false
    @State private var diagnostics: String?
    @State private var saveError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Remote Display").font(.title2.bold()).padding(22)
            Form {
                Section("Connection") {
                    TextField("Name", text: $profile.name)
                    Picker("Server", selection: $profile.serverID) {
                        Text("Local / Direct").tag(nil as UUID?)
                        ForEach(servers) { Text($0.name).tag(Optional($0.id)) }
                    }.onChange(of: profile.serverID) { _, id in if id == nil { profile.useSSHTunnel = false } }
                    Picker("Simulator", selection: $profile.preset) { ForEach(SimulationPreset.allCases) { Text($0.title).tag($0) } }
                        .onChange(of: profile.preset) { _, preset in applyPreset(preset) }
                    Picker("Viewer", selection: $profile.client) { ForEach(DisplayClient.allCases) { Text($0.title).tag($0) } }
                        .onChange(of: profile.client) { _, client in
                            if client == .vnc { profile.address = "vnc://127.0.0.1:5901" }
                            else if client == .isaac { profile.address = "isaac://\(servers.first(where: { $0.id == profile.serverID })?.host ?? "127.0.0.1"):49100"; profile.useSSHTunnel = false }
                            else if profile.address.hasPrefix("vnc:") { profile.address = "http://127.0.0.1:6080/vnc.html?resize=remote" }
                        }
                    TextField(profile.client == .vnc ? "VNC Address" : "Viewer URL", text: $profile.address)
                    Toggle("Connect through SSH", isOn: $profile.useSSHTunnel).disabled(profile.serverID == nil || profile.client == .isaac)
                    Text(profile.useSSHTunnel ? "The URL host is reached from the SSH server. Harbor opens a private local TCP tunnel." : "The URL must be reachable from this Mac over your network or VPN.").font(.caption).foregroundStyle(Color.harborMuted)
                }
                if profile.client == .isaac {
                    Section("Launch Settings") {
                        Toggle("Start simulation when connecting", isOn: Binding(get: { profile.launch != nil }, set: { profile.launch = $0 ? SimulationLaunch(directory: "") : nil }))
                        if profile.launch != nil {
                            TextField("Project Directory", text: Binding(get: { profile.launch?.directory ?? "" }, set: { profile.launch?.directory = $0 }))
                            TextField("Launch Command", text: Binding(get: { profile.launch?.command ?? "" }, set: { profile.launch?.command = $0 }))
                            Text("Saved once for this project. Harbor reuses running streams and stops only jobs it started.").font(.caption)
                        }
                    }
                }
                Section("Server Setup") {
                    Text(profile.preset.guidance).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Link("Open Official Setup Guide ↗", destination: profile.preset.docs)
                    HStack {
                        Button(checking ? "Checking…" : "Check Server") { checkServer() }.disabled(checking || profile.serverID == nil)
                        Text("Checks installed tools and listening ports; does not start a simulator.").font(.caption).foregroundStyle(Color.harborMuted)
                    }
                    if let diagnostics { ScrollView { Text(diagnostics).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 130) }
                }
                if let issue = saveError ?? profile.validationError { Text(issue).foregroundStyle(.orange).font(.callout) }
            }.formStyle(.grouped)
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Save Display") { if controller.save(profile) { dismiss() } else { saveError = controller.error; controller.error = nil } }.keyboardShortcut(.defaultAction).disabled(profile.validationError != nil) }.padding(18)
        }.frame(width: 640, height: 680)
    }
    private func applyPreset(_ preset: SimulationPreset) {
        profile.name = preset.title
        if preset != .isaac { profile.launch = nil }
        switch preset {
        case .isaac: profile.client = .isaac; profile.address = "isaac://\(servers.first(where: { $0.id == profile.serverID })?.host ?? "127.0.0.1"):49100"; profile.useSSHTunnel = false
        case .gazebo, .webots, .web: profile.client = .embedded; profile.address = ""
        case .mujoco, .desktop: profile.client = .embedded; profile.address = "http://127.0.0.1:6080/vnc.html?resize=remote"
        }
    }
    private func checkServer() {
        guard let server = servers.first(where: { $0.id == profile.serverID }) else { return }
        checking = true; diagnostics = nil
        Task {
            let command = "printf 'Display tools on PATH\\n'; for x in isaacsim webots gz gazebo Xvnc Xtigervnc vncserver x11vnc websockify; do command -v \"$x\" || :; done; printf '\\nGPU\\n'; if command -v nvidia-smi >/dev/null; then nvidia-smi --query-gpu=name --format=csv,noheader; fi; printf '\\nListening TCP ports\\n'; if command -v ss >/dev/null; then ss -ltn | head -30; fi"
            let result = await ProcessRunner.run("/usr/bin/ssh", SSHArguments.connection(server) + ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "RemoteCommand=none", "--", server.host, command], timeout: 15)
            diagnostics = result.succeeded ? result.output + "\nConda, containers and other environments may contain additional tools." : "Server check failed.\n" + result.output
            checking = false
        }
    }
}
