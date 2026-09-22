import SwiftUI
import HarborCore

struct ProxyPage: View {
    @EnvironmentObject var store: AppStore
    var body: some View { ProxyContent(store: store, controller: store.proxy) }
}

struct ProxyContent: View {
    @ObservedObject var store: AppStore
    @ObservedObject var controller: ProxyController
    @State private var editing: ForwardRule?
    @State private var expanded: UUID?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) { Text("Port Forwarding").harborFont(16, weight: .semibold); Text("Remote forwarding, local forwarding, and SOCKS5 using your server’s SSH key authentication.").harborFont(11).foregroundStyle(Color.harborMuted) }
                    Spacer()
                    Button { if let p = store.selectedProfile ?? store.profiles.first { editing = ForwardRule(serverID: p.id) } } label: { Label("Add Forwarding", systemImage: "plus") }
                        .buttonStyle(.borderedProminent).disabled(store.profiles.isEmpty)
                }
                if store.rules.isEmpty {
                    ContentUnavailableView("No Port Forwarding Yet", systemImage: "arrow.left.arrow.right", description: Text(store.profiles.isEmpty ? "Add a server in the workbench first." : "Use a local proxy from your server, or access a remote web service on your Mac."))
                        .frame(maxWidth: .infinity).padding(.vertical, 30)
                }
                ForEach(store.rules) { rule in
                    ruleCard(rule)
                }
            }.padding(30)
        }
        .sheet(item: $editing) { rule in
            ForwardEditor(rule: rule, profiles: store.profiles) { updated in
                if let i = store.rules.firstIndex(where: { $0.id == updated.id }) { store.rules[i] = updated }
                else { store.rules.append(updated) }
                store.save()
            }
        }
    }
    private func ruleCard(_ rule: ForwardRule) -> some View {
        let running = controller.isRunning(rule.id)
        let profile = store.profiles.first { $0.id == rule.serverID }
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                HarborSymbol(systemName: rule.kind == .remote ? "arrow.uturn.backward" : "arrow.left.arrow.right").foregroundStyle(Color.harborAccent)
                VStack(alignment: .leading, spacing: 5) { Text(rule.name).harborFont(13, weight: .semibold); Text("\(profile?.name ?? "Server removed") · \(rule.summary)").harborFont(11).foregroundStyle(Color.harborMuted) }
                Spacer()
                Text(controller.states[rule.id] ?? "Stopped").harborFont(11).foregroundStyle(Color.harborMuted)
            }
            HStack {
                if running { Button("Stop") { controller.stop(rule.id) }; Button("Verify Request") { if let profile { Task { await controller.verify(rule, profile: profile, store: store) } } } }
                else { Button("Start") { if let profile { Task { await controller.start(rule, profile: profile) } } }.buttonStyle(.borderedProminent).disabled(profile == nil) }
                Button(expanded == rule.id ? "Hide Logs" : "View Logs") { expanded = expanded == rule.id ? nil : rule.id }
                Spacer()
                Button("Edit") { editing = rule }.disabled(running)
                Button(role: .destructive) { store.rules.removeAll { $0.id == rule.id }; store.save() } label: { HarborSymbol(systemName: "trash") }.disabled(running).help("Delete Forwarding Rule")
            }
            if expanded == rule.id {
                Text(controller.logs[rule.id].flatMap { $0.isEmpty ? nil : $0 } ?? "No logs yet.")
                    .harborFont(11, design: .monospaced).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14).background(Color.harborHover, in: RoundedRectangle(cornerRadius: 8))
            }
        }.padding(20).background(Color.harborWidget, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.harborBorder))
    }
}

struct ForwardEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var rule: ForwardRule
    let profiles: [ServerProfile]
    let onSave: (ForwardRule) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Forwarding Rule").harborFont(20, weight: .semibold).padding(24)
            Form {
                TextField("Name", text: $rule.name)
                Picker("Server", selection: $rule.serverID) { ForEach(profiles) { Text($0.name).tag($0.id) } }
                Picker("Type", selection: $rule.kind) { ForEach(ForwardKind.allCases) { Text($0.label).tag($0) } }
                TextField(rule.kind == .remote ? "Remote Listening Port" : "Local Listening Port", value: $rule.listenPort, format: .number.grouping(.never))
                if rule.kind != .dynamic {
                    TextField(rule.kind == .remote ? "Local Target Host" : "Remote Target Host", text: $rule.targetHost)
                    TextField("Target Port", value: $rule.targetPort, format: .number.grouping(.never))
                }
                if rule.kind != .local { TextField("HTTP check URL", text: $rule.checkURL) }
                Text(rule.summary).harborFont(12).foregroundStyle(Color.harborAccent)
                Text(rule.kind == .remote ? "For HTTP proxies: connect to the server, then request the check URL through its remote port. The server’s GatewayPorts setting also affects the listener." : rule.kind == .local ? "Listens on 127.0.0.1 locally. Verification requests the HTTP root path on this port. Non-HTTP services can be forwarded but need their own client to verify." : "Listens on 127.0.0.1 locally. Verification visits the check URL through SOCKS5.").harborFont(11).foregroundStyle(Color.harborMuted)
            }.formStyle(.grouped)
            HStack {
                if let error = rule.validationError { Text(error).harborFont(11).foregroundStyle(Color.harborMuted) }
                Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { onSave(rule); dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(rule.validationError != nil)
            }.padding(20)
        }.frame(width: 620, height: 570)
    }
}
