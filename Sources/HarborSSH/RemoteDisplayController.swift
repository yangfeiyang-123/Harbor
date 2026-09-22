import AppKit
import SwiftUI
import WebKit
import Darwin
import HarborCore

@MainActor
final class RemoteDisplayController: ObservableObject {
    @Published var profiles: [RemoteDisplayProfile] = []
    @Published var selectedID: UUID?
    @Published var error: String?
    private(set) var sessions: [UUID: RemoteDisplaySession] = [:]
    private let file: URL
    private var loaded = false
    private var writable = true
    init(root: URL) { file = root.appendingPathComponent("remote-displays.json") }
    func load() {
        guard !loaded else { return }; loaded = true
        do { profiles = try RemoteDisplayPersistence.load(file); selectedID = profiles.first?.id }
        catch { writable = false; self.error = "Could not read saved displays. Original settings were kept: \(error.localizedDescription)" }
    }
    @discardableResult func save(_ profile: RemoteDisplayProfile) -> Bool {
        load()
        guard writable else { error = "Repair remote-displays.json and restart Harbor before saving."; return false }
        if let issue = profile.validationError { error = issue; return false }
        var next = profiles
        if let index = next.firstIndex(where: { $0.id == profile.id }) { next[index] = profile } else { next.append(profile) }
        do {
            try RemoteDisplayPersistence.save(next, to: file)
            sessions.removeValue(forKey: profile.id)?.disconnect()
            profiles = next; selectedID = profile.id; return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func remove(_ profile: RemoteDisplayProfile) {
        guard writable else { return }
        let next = profiles.filter { $0.id != profile.id }
        do {
            try RemoteDisplayPersistence.save(next, to: file)
            sessions.removeValue(forKey: profile.id)?.disconnect()
            profiles = next; if selectedID == profile.id { selectedID = next.first?.id }
        } catch { self.error = error.localizedDescription }
    }
    func session(for profile: RemoteDisplayProfile) -> RemoteDisplaySession {
        if let session = sessions[profile.id] { return session }
        let session = RemoteDisplaySession(profile: profile); sessions[profile.id] = session; return session
    }
    func stopAll() { for session in sessions.values { session.disconnect() }; sessions.removeAll() }
}

@MainActor
final class RemoteDisplaySession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    let profile: RemoteDisplayProfile
    @Published var status = "Disconnected"
    @Published var error: String?
    @Published var connecting = false
    @Published var connected = false
    @Published var detached = false
    @Published var simulationOwned = false
    @Published var simulationStopPending = false
    @Published var simulationLog = ""
    private let isaacViewer = IsaacViewerServer()
    @Published var web: WKWebView?
    private(set) var connectedURL: URL?
    private var tunnel: Process?
    private var tunnelPipe: Pipe?
    private var connectTask: Task<Void, Never>?
    private var generation = UUID()
    private var displayWindow: NSWindow?
    var mainVisible = false
    init(profile: RemoteDisplayProfile) { self.profile = profile }

    func connect(server: ServerProfile?) {
        disconnect(); error = nil; simulationStopPending = false
        if let issue = profile.validationError { error = issue; return }
        if let id = profile.serverID, server?.id != id { error = "The saved SSH server is unavailable. Edit this display to choose another server."; return }
        if profile.client == .isaac { connectIsaac(server: server); return }
        let token = UUID(); generation = token; connecting = true; status = "Connecting…"
        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                var url = self.profile.url!
                if self.profile.useSSHTunnel {
                    guard let server else { throw DisplayError.message("Choose an SSH server first.") }
                    let port = try Self.unusedPort()
                    try self.startTunnel(server: server, port: port, token: token)
                    var ready = false
                    for _ in 0..<120 {
                        try Task.checkCancellation()
                        guard self.tunnel?.isRunning == true else { throw DisplayError.message("SSH forwarding could not start. Check the server connection and key or SSH agent.") }
                        if Self.portIsOpen(port) { ready = true; break }
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                    guard ready else { throw DisplayError.message("SSH forwarding timed out. Check your VPN and server connection.") }
                    guard let local = self.profile.localURL(port: port) else { throw DisplayError.message("Invalid viewer URL.") }
                    url = local
                }
                try Task.checkCancellation()
                guard self.generation == token else { return }
                self.connectedURL = url; self.connecting = false; self.connected = true
                switch self.profile.client {
                case .embedded: self.resumeWeb()
                case .chromium: try self.openChromium(url); self.status = "Browser opened · Media connects in the viewer"
                case .vnc:
                    guard NSWorkspace.shared.open(url) else { throw DisplayError.message("Screen Sharing could not open this VNC address.") }
                    self.status = "Screen Sharing opened · Tunnel stays active"
                case .isaac: break
                }
            } catch is CancellationError { }
            catch {
                guard self.generation == token else { return }
                self.disconnect(); self.error = error.localizedDescription; self.status = "Connection failed"
            }
        }
    }
    private func startTunnel(server: ServerProfile, port: Int, token: UUID) throws {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = profile.tunnelArguments(server: server, localPort: port)
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = pipe
        // Drain SSH diagnostics without growing a retained log or blocking the child.
        pipe.fileHandleForReading.readabilityHandler = { _ = $0.availableData }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.disconnect(); self.error = "SSH display connection closed. Reconnect when your VPN/server is available. The simulator was not stopped."
                self.status = "Disconnected"
            }
        }
        tunnel = process; tunnelPipe = pipe
        try process.run()
    }
    func disconnect() {
        generation = UUID(); connectTask?.cancel(); connectTask = nil
        let process = tunnel; tunnel = nil; process?.terminationHandler = nil
        if let process, process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        }
        tunnelPipe?.fileHandleForReading.readabilityHandler = nil; tunnelPipe = nil
        releaseWeb(); connectedURL = nil; connected = false; connecting = false; status = "Disconnected"
        isaacViewer.stop()
        displayWindow?.close(); displayWindow = nil; detached = false
    }
    func resumeWeb() {
        guard profile.client == .embedded, connected, web == nil, let url = connectedURL else { return }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self; view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = false
        web = view; status = "Loading viewer…"; view.load(URLRequest(url: url))
    }
    func releaseWeb() {
        web?.stopLoading(); web?.navigationDelegate = nil; web?.uiDelegate = nil
        web?.loadHTMLString("", baseURL: nil); web?.removeFromSuperview(); web = nil
    }
    func pauseIfHidden() {
        guard !detached, profile.client == .embedded, connected else { return }
        releaseWeb(); status = "Viewer paused · SSH tunnel retained"
    }
    func reload() {
        error = nil
        if let web { status = "Loading viewer…"; web.reload() } else { resumeWeb() }
    }
    func openExternal() {
        guard let url = connectedURL else { return }
        do {
            if profile.client == .isaac { try openIsaacWindow(url) }
            else if profile.client == .chromium { try openChromium(url) }
            else { NSWorkspace.shared.open(url) }
        } catch { self.error = error.localizedDescription }
    }
    private func openChromium(_ url: URL) throws {
        let app = ["com.google.Chrome", "com.microsoft.edgemac", "org.chromium.Chromium"].compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
        guard let app else { throw DisplayError.message("Install Chrome or Edge to open this WebRTC viewer. The Isaac Sim viewer requires Chromium.") }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            if let error { Task { @MainActor in self?.error = error.localizedDescription } }
        }
    }
    func detachWindow() {
        guard profile.client == .embedded, connected else { return }
        if let displayWindow { displayWindow.makeKeyAndOrderFront(nil); return }
        detached = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "\(profile.name) · Harbor Remote Display"; window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary); window.delegate = self
        window.contentView = NSHostingView(rootView: RemoteDisplayCanvas(session: self, inWindow: true))
        displayWindow = window; window.center(); window.makeKeyAndOrderFront(nil)
    }
    func fullScreen() { detachWindow(); displayWindow?.toggleFullScreen(nil) }
    func windowWillClose(_ notification: Notification) {
        displayWindow = nil; detached = false
        if !mainVisible { pauseIfHidden() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { status = "Viewer loaded" }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { showWebError(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { showWebError(error) }
    private func showWebError(_ issue: Error) {
        guard (issue as NSError).code != NSURLErrorCancelled else { return }
        error = "Viewer could not load: \(issue.localizedDescription) Check that its service is running and this is the viewer page URL."; status = "Viewer unavailable"
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { error = "The viewer process stopped. Reload to reconnect."; status = "Viewer stopped" }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme ?? ""
        decisionHandler(["http", "https", "about", "blob"].contains(scheme) ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, ["http", "https"].contains(url.scheme ?? "") { webView.load(URLRequest(url: url)) }
        return nil
    }
    static func unusedPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { throw DisplayError.message("Cannot allocate a display port.") }; defer { Darwin.close(fd) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { throw DisplayError.message("Cannot bind a local display port.") }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
        return Int(UInt16(bigEndian: address.sin_port))
    }
    static func portIsOpen(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { return false }; defer { Darwin.close(fd) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(port).bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
    }
}

enum DisplayError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

struct RemoteWebSurface: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> DisplayWebHost { DisplayWebHost() }
    func updateNSView(_ host: DisplayWebHost, context: Context) { host.web = web; host.mount() }
}

final class DisplayWebHost: NSView {
    weak var web: WKWebView?
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer?.masksToBounds = true }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); mount() }
    override func layout() { super.layout(); if let web, web.superview === self { web.frame = bounds } }
    func mount() {
        guard window != nil, let web else { return }
        if web.superview !== self { web.removeFromSuperview(); addSubview(web) }
        web.translatesAutoresizingMaskIntoConstraints = true
        web.autoresizingMask = [.width, .height]; web.frame = bounds
    }
}

extension RemoteDisplaySession {
    private func simulationRequest(_ action: String, server: ServerProfile) async throws -> SimulationSnapshot {
        let resource = AppResources.directory("Simulation").appendingPathComponent("session.py")
        let script = try Data(contentsOf: resource).base64EncodedString()
        let payload: [String: Any] = ["id": profile.id.uuidString, "action": action, "port": profile.port,
                                      "directory": profile.launch?.directory ?? "", "command": profile.launch?.command ?? ""]
        let config = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        let code = "import base64;exec(compile(base64.b64decode('\(script)'),'<harbor-display>','exec'))"
        let command = "python3 -c \(quote(code)) \(quote(config))"
        let result = await ProcessRunner.run("/usr/bin/ssh", SSHArguments.connection(server) + ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "RemoteCommand=none", "--", server.host, command], timeout: 15)
        guard result.succeeded, let line = result.output.components(separatedBy: "\n").last(where: { $0.hasPrefix("HARBOR_DISPLAY=") }) else {
            throw DisplayError.message("Could not reach the simulation service. Check VPN / SSH. " + String(result.output.suffix(800)))
        }
        let snapshot = try JSONDecoder().decode(SimulationSnapshot.self, from: Data(line.dropFirst("HARBOR_DISPLAY=".count).utf8))
        if let error = snapshot.error { throw DisplayError.message(error) }
        return snapshot
    }
    private func connectIsaac(server: ServerProfile?) {
        let token = UUID(); generation = token; connecting = true; status = "Checking simulation…"
        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let server {
                    var snapshot = try await simulationRequest(profile.launch == nil ? "status" : "start", server: server)
                    for _ in 0..<180 {
                        try Task.checkCancellation(); guard generation == token else { return }
                        simulationOwned = snapshot.owned ?? false; simulationLog = snapshot.log ?? ""
                        if snapshot.ready == true { break }
                        guard snapshot.owned == true else { throw DisplayError.message("Simulation is not running. Check the launch settings and startup log.") }
                        status = "Starting simulation…"; try await Task.sleep(nanoseconds: 1_000_000_000)
                        snapshot = try await simulationRequest("status", server: server)
                    }
                    guard snapshot.ready == true else { throw DisplayError.message("Simulation is still starting. Check its log, then try Start & View again; Harbor will reuse the same job.") }
                }
                try Task.checkCancellation(); guard generation == token else { return }
                try await isaacViewer.start()
                try Task.checkCancellation(); guard generation == token else { return }
                guard let url = isaacViewer.url(profile: profile) else { throw DisplayError.message("Could not create the viewer address.") }
                connectedURL = url; try openIsaacWindow(url)
                connected = true; connecting = false; status = "Stream ready · Viewer opened"
                // Keep only a bounded log; no extra GPU process or local renderer while viewing.
                while let server, generation == token {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                    let snapshot = try await simulationRequest("status", server: server)
                    try Task.checkCancellation(); guard generation == token else { return }
                    simulationOwned = snapshot.owned ?? false; simulationLog = snapshot.log ?? ""
                    if snapshot.ready != true {
                        connected = false; status = snapshot.owned == true ? "Simulation is restarting" : "Simulation ended"; break
                    }
                }
            } catch is CancellationError { }
            catch {
                guard generation == token else { return }
                connecting = false; connected = false; self.error = error.localizedDescription; status = "Viewer unavailable"
            }
        }
    }
    func stopSimulation(server: ServerProfile?, force: Bool = false) {
        guard let server, simulationOwned else { return }
        disconnect(); error = nil; status = "Stopping simulation…"; connecting = true
        let token = generation
        connectTask = Task {
            do {
                let snapshot = try await simulationRequest(force ? "force-stop" : "stop", server: server)
                guard generation == token else { return }
                simulationOwned = snapshot.owned ?? false; status = snapshot.message ?? "Simulation stopped"; connecting = false
                simulationStopPending = simulationOwned
            } catch { guard generation == token else { return }; self.error = error.localizedDescription; connecting = false }
        }
    }
    private func openIsaacWindow(_ url: URL) throws {
        let app = ["com.google.Chrome", "com.microsoft.edgemac"].compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
        guard let app else { throw DisplayError.message("Install Chrome or Edge for the Harbor Isaac Viewer.") }
        // Launch Services ignores arguments when Chrome is already open. Chromium's
        // executable forwards --app to its existing instance without creating a profile.
        guard let executable = Bundle(url: app)?.executableURL else { throw DisplayError.message("The viewer browser executable is unavailable.") }
        let launcher = Process()
        launcher.executableURL = executable; launcher.arguments = ["--app=\(url.absoluteString)"]
        launcher.standardInput = FileHandle.nullDevice; launcher.standardOutput = FileHandle.nullDevice; launcher.standardError = FileHandle.nullDevice
        launcher.terminationHandler = { [weak self] process in
            if process.terminationStatus != 0 { Task { @MainActor in self?.error = "The viewer browser could not open. Try Open Viewer Again." } }
        }
        try launcher.run()
    }
}

private struct SimulationSnapshot: Decodable {
    var ready: Bool?
    var owned: Bool?
    var log: String?
    var message: String?
    var error: String?
}
