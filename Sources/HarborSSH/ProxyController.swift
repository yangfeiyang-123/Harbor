import Foundation
import AppKit
import HarborCore

@MainActor
final class ProxyController: ObservableObject {
    @Published var states: [UUID: String] = [:]
    @Published var logs: [UUID: String] = [:]
    @Published var managedStatus = "Status not loaded"
    @Published var managedBusy = false
    @Published var managedVerifiedAt: Date?
    @Published var managedSnapshot = ManagedProxyStatus()
    @Published var managedError: String?
    @Published var verifiedHosts = Set<String>()
    private var processes: [UUID: Process] = [:]
    private var pipes: [UUID: Pipe] = [:]
    private var starting = Set<UUID>()
    private var cancelledStarts = Set<UUID>()
    nonisolated static var runtimeURL: URL {
        // Packaged apps keep SwiftPM resources in Contents/Resources, while
        // `swift run` uses Bundle.module. Never depend on a developer build path.
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/HarborSSH_HarborSSH.bundle/ProxyRuntime/server-proxy-macos.sh")
        }
        return Bundle.module.resourceURL!.appendingPathComponent("ProxyRuntime/server-proxy-macos.sh")
    }
    func isRunning(_ id: UUID) -> Bool { starting.contains(id) || processes[id]?.isRunning == true }
    func start(_ rule: ForwardRule, profile: ServerProfile) async {
        guard !isRunning(rule.id), rule.validationError == nil else { return }
        starting.insert(rule.id); cancelledStarts.remove(rule.id); states[rule.id] = "Connecting"
        defer { starting.remove(rule.id) }
        // Inherited forwarding directives cannot be removed selectively by ssh flags. Refuse rather than duplicate them.
        let effective = await ProcessRunner.run("/usr/bin/ssh", SSHArguments.connection(profile) + ["-G", "--", profile.host], timeout: 10)
        guard !cancelledStarts.contains(rule.id) else { states[rule.id] = "Stopped"; return }
        guard effective.succeeded else { states[rule.id] = "Unable to read configuration"; logs[rule.id] = effective.output; return }
        let c = SSHConfig.effective(effective.output)
        guard c["remoteforward"] == nil && c["localforward"] == nil && c["dynamicforward"] == nil else {
            states[rule.id] = "Login alias required"
            logs[rule.id] = "This SSH alias already configures port forwarding. Use a login alias without RemoteForward or LocalForward. Manage the existing A100 / RTX 4090 tunnels above."; return
        }
        let process = Process(), pipe = Pipe()
        // A server that takes a password: the one Harbor keeps for it. Nothing is asked here; without
        // a password that worked before, ssh is stopped before it sends one (ServerPasswords).
        let quiet = await ServerPasswords.quietly(SSHArguments.forward(rule, profile: profile), server: profile.id)
        if let environment = quiet.environment { process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 } }
        guard !cancelledStarts.contains(rule.id) else { states[rule.id] = "Stopped"; return }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh"); process.arguments = quiet.arguments
        process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = pipe
        processes[rule.id] = process; pipes[rule.id] = pipe; logs[rule.id] = ""
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData; guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                guard let self, self.processes[rule.id] === process else { return }
                self.logs[rule.id] = String(((self.logs[rule.id] ?? "") + text).suffix(24_000))
                if rule.kind == .remote && (self.logs[rule.id] ?? "").contains("overridden by server GatewayPorts") {
                    self.stop(rule.id)
                    self.states[rule.id] = "Listener expanded by server · Stopped"
                    self.logs[rule.id, default: ""] += "\nThe server expanded the listener from 127.0.0.1 to all interfaces. This rule was stopped to keep the local service private. For A100 / RTX 4090, use the managed proxy above. On other servers, an administrator can set GatewayPorts to no or clientspecified.\n"
                    return
                }
                if text.contains("Entering interactive session") || text.contains("pledge: network") {
                    self.states[rule.id] = "Tunnel started · Unverified"
                }
            }
        }
        process.terminationHandler = { [weak self] ended in
            Task { @MainActor in
                guard let self, self.processes[rule.id] === ended else { return }
                self.states[rule.id] = ended.terminationStatus == 0 ? "Stopped" : "Disconnected · See logs"
                self.pipes[rule.id]?.fileHandleForReading.readabilityHandler = nil
                self.pipes[rule.id] = nil; self.processes[rule.id] = nil
            }
        }
        do { try process.run() } catch { states[rule.id] = "Unable to start"; logs[rule.id] = error.localizedDescription; processes[rule.id] = nil; pipes[rule.id] = nil }
    }
    func stop(_ id: UUID) {
        cancelledStarts.insert(id)
        if let p = processes.removeValue(forKey: id), p.isRunning { p.terminate() }
        pipes.removeValue(forKey: id)?.fileHandleForReading.readabilityHandler = nil
        states[id] = "Stopped"
    }
    func stopAll() { for id in Array(processes.keys) { stop(id) }; for id in starting { cancelledStarts.insert(id) } }
    func verify(_ r: ForwardRule, profile: ServerProfile, store: AppStore) async {
        guard isRunning(r.id) else { return }
        let process = processes[r.id]
        states[r.id] = "Verifying request"
        let result: CommandResult
        if r.kind == .remote {
            do {
                let socket = try await store.resolveSocket(profile)
                let command = "curl --silent --show-error --location --fail --output /dev/null --write-out '%{http_code}' --max-time 20 --noproxy '' --proxy http://127.0.0.1:\(r.listenPort) -- \(SSHArguments.quote(r.checkURL))"
                // Through the server's shared connection when a terminal or the editor has one open.
                var shared: CommandResult?
                if FileManager.default.fileExists(atPath: socket) {
                    let attempt = await ProcessRunner.run("/usr/bin/ssh", SSHArguments.probe(profile, socket: socket, command: command), timeout: 30)
                    // A socket left by a connection that has ended: the probe then fails on purpose before reaching the server.
                    if !attempt.output.contains("Connection closed by UNKNOWN") { shared = attempt }
                }
                if let shared { result = shared }
                else {
                    // Otherwise over a connection of its own, with the server's key or the password Harbor keeps for it.
                    result = await ServerPasswords.runQuietly(SSHArguments.connection(profile) + ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=20",
                        "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "RemoteCommand=none", "--", profile.host, command], server: profile.id, timeout: 45)
                }
            } catch { states[r.id] = "Verification failed"; logs[r.id] = error.localizedDescription; return }
        } else if r.kind == .dynamic {
            result = await ProcessRunner.run("/usr/bin/curl", ["--silent", "--show-error", "--location", "--fail", "--output", "/dev/null", "--write-out", "%{http_code}", "--max-time", "20", "--noproxy", "", "--socks5-hostname", "127.0.0.1:\(r.listenPort)", "--", r.checkURL], timeout: 25)
        } else {
            result = await ProcessRunner.run("/usr/bin/curl", ["--silent", "--show-error", "--fail", "--output", "/dev/null", "--write-out", "%{http_code}", "--max-time", "20", "--noproxy", "*", "--", "http://127.0.0.1:\(r.listenPort)/"], timeout: 25)
        }
        guard processes[r.id] === process, isRunning(r.id) else { return }
        let code = String(result.output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(3))
        if result.succeeded, let http = Int(code), (200..<400).contains(http) { states[r.id] = "Verified · HTTP \(code)" }
        else { states[r.id] = "Verification failed · See logs" }
        logs[r.id, default: ""] += "\n[Request verification] \(result.output)\n" + (r.kind == .local ? "Local forwarding checks require an HTTP service.\n" : "")
    }
    func managed(_ action: String) async {
        guard !managedBusy, ["status", "check", "usa", "china", "stop", "logs"].contains(action) else { return }
        managedBusy = true; defer { managedBusy = false }
        managedError = nil
        if action != "status" && action != "logs" { verifiedHosts = []; managedVerifiedAt = nil }
        let result: CommandResult
        if action == "check" { result = await Self.checkManagedPaths() }
        else {
            result = await Task.detached(priority: .utility) {
                ProcessRunner.sync("/bin/bash", [Self.runtimeURL.path, action], timeout: ["usa", "china"].contains(action) ? 300 : 90)
            }.value
        }
        managedStatus = result.output.isEmpty ? "No status returned" : result.output
        if result.timedOut { managedError = "The operation timed out. See details and try again." }
        else if !result.succeeded { managedError = "The operation did not complete. See details." }
        if action != "logs" {
            let snapshot = ManagedProxyStatus(output: result.output)
            if action == "status", snapshot.values["MODE"] != managedSnapshot.values["MODE"] { verifiedHosts = []; managedVerifiedAt = nil }
            managedSnapshot = snapshot
            for host in ["A100", "RTX"] where !snapshot.isUp("\(host)_JOB") { verifiedHosts.remove(host) }
            if ["check", "usa", "china"].contains(action) {
                verifiedHosts = Set(["A100", "RTX"].filter { snapshot.verified($0) })
                if !verifiedHosts.isEmpty { managedVerifiedAt = Date() }
                if verifiedHosts.count != 2 && managedError == nil { managedError = "Some servers have not passed request verification." }
            }
        }
    }
    nonisolated private static func checkManagedPaths() async -> CommandResult {
        let status = await Task.detached(priority: .utility) { ProcessRunner.sync("/bin/bash", [Self.runtimeURL.path, "status"], timeout: 30) }.value
        // Probe without an old interactive master, without starting any forwards.
        let hosts = [("A100", "omnisky", 11088), ("RTX", "omnisky9", 11083)]
        let checks = await withTaskGroup(of: (String, CommandResult).self, returning: [(String, CommandResult)].self) { group in
            for (key, alias, port) in hosts {
                group.addTask { (key, await ProcessRunner.run("/usr/bin/ssh", ManagedProxyProbe.arguments(alias: alias, key: key, fallbackPort: port), timeout: 65)) }
            }
            var results: [(String, CommandResult)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }
        }
        let output = status.output + "\n" + checks.map { key, result in
            "\(key)_TUNNEL=\(result.succeeded ? "up" : "down")\n" + result.output
        }.joined(separator: "\n")
        return CommandResult(status: status.succeeded && checks.allSatisfy { $0.1.succeeded } ? 0 : 1, output: output, timedOut: status.timedOut || checks.contains { $0.1.timedOut })
    }
}
