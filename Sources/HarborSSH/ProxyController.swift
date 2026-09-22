import Foundation
import AppKit
import HarborCore

@MainActor
final class ProxyController: ObservableObject {
    @Published var states: [UUID: String] = [:]
    @Published var logs: [UUID: String] = [:]
    private var processes: [UUID: Process] = [:]
    private var pipes: [UUID: Pipe] = [:]
    private var starting = Set<UUID>()
    private var cancelledStarts = Set<UUID>()
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
            logs[rule.id] = "This SSH alias already configures port forwarding. Use a login alias without RemoteForward or LocalForward."; return
        }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh"); process.arguments = SSHArguments.forward(rule, profile: profile)
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
                    self.logs[rule.id, default: ""] += "\nThe server expanded the listener from 127.0.0.1 to all interfaces. This rule was stopped to keep the local service private. An administrator can set GatewayPorts to no or clientspecified.\n"
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
                result = await ProcessRunner.run("/usr/bin/ssh", SSHArguments.probe(profile, socket: socket, command: command), timeout: 30)
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
        logs[r.id, default: ""] += "\n[Request verification] \(result.output)\nOpen a terminal on this server before checking its remote HTTP proxy. Local forwarding checks require an HTTP service.\n"
    }
}
