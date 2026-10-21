import AppKit
import WebKit
import SwiftUI
import CryptoKit
import HarborCore

/// One authenticated runtime per server, one workbench per directory. Services
/// and web views are created lazily; the existing PTYs never depend on them.
@MainActor final class CodeWorkbenchController {
    let root: URL
    let owner: String
    private var sessions: [String: CodeWorkbenchSession] = [:]
    /// Where this window's editors are shown, one giving way to the next.
    let stage = WorkbenchStage(frame: .zero)
    init(root: URL) {
        self.root = root
        owner = SHA256.hash(data: Data(root.path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
    func session(for workspace: FileWorkspace) -> CodeWorkbenchSession {
        if let session = sessions[workspace.key] { return session }
        let session = CodeWorkbenchSession(workspace: workspace, root: root, owner: owner)
        sessions[workspace.key] = session; return session
    }
    func existing(for workspace: FileWorkspace) -> CodeWorkbenchSession? { sessions[workspace.key] }
    /// The editors of this window that are starting or loaded, on the screen or off it.
    var running: [CodeWorkbenchSession] { sessions.values.filter(\.running) }
    /// An editor of this window is starting or running there (nil is this Mac). A session that was
    /// only asked about, and never started, does not count.
    func runs(profileID: UUID?) -> Bool { sessions.values.contains { $0.workspace.profile?.id == profileID && $0.running } }
    func runs(_ workspace: FileWorkspace) -> Bool { sessions[workspace.key]?.running == true }
    func terminalCount(for profileID: UUID?) -> Int {
        sessions.values.filter { $0.workspace.profile?.id == profileID }.reduce(0) { $0 + $1.terminalCount }
    }
    var hasUnsavedFiles: Bool { sessions.values.contains { !$0.dirtyPaths.isEmpty } }
    func hasUnsavedFiles(profileID: UUID?) -> Bool {
        sessions.values.contains { $0.workspace.profile?.id == profileID && !$0.dirtyPaths.isEmpty }
    }
    /// An editor of this window has unsaved changes in that folder (a server and a path).
    func hasUnsavedFiles(claimKey: String) -> Bool {
        sessions.values.contains { !$0.dirtyPaths.isEmpty && $0.workspace.claimKey == claimKey }
    }
    func close(_ workspace: FileWorkspace) { sessions.removeValue(forKey: workspace.key)?.disconnect() }
    /// While a native panel lies over the editor, the page beneath must not follow the pointer
    /// (hover highlights, and its cursor replacing the panel's). Every editor is released again,
    /// whichever one is in front by then.
    func setCovered(_ covered: Bool) {
        stage.setCovered(covered)
        for session in sessions.values {
            session.web?.evaluateJavaScript("document.documentElement.style.pointerEvents = '\(covered ? "none" : "")'", completionHandler: nil)
        }
    }
    func shutdown() { sessions.values.forEach { $0.disconnect() }; sessions.removeAll() }
}

@MainActor final class CodeWorkbenchSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let workspace: FileWorkspace
    let root: URL
    let owner: String
    @Published var phase = "Ready to start"
    /// How much of a transfer is done, while one is under way.
    @Published var progress: Double? { didSet { paceTransfer() } }
    /// How far along opening is, for the line on the opening page: paced by how long this
    /// server took the last time, measured while the editor itself is being sent.
    @Published private(set) var pace: HarborProgressBar.Pace?
    private var openBegan = Date(), loadBegan: Date?, transferBase: Double?
    private var paceKey: String { "openingPace." + (workspace.profile?.id.uuidString ?? "local") }
    /// Seconds to reach the server and start the editor there, then for the editor to load here.
    private var usualTimes: (connect: Double, load: Double) {
        let saved = UserDefaults.standard.array(forKey: paceKey) as? [Double] ?? []
        guard saved.count == 2, saved.allSatisfy({ $0 > 0.05 && $0 < 600 }) else { return workspace.profile == nil ? (0.5, 3) : (3, 6) }
        return (saved[0], saved[1])
    }
    private func beginPace() {
        let usual = usualTimes
        openBegan = Date(); loadBegan = nil; transferBase = nil
        pace = HarborProgressBar.Pace(from: 0, to: min(max(0.97 * usual.connect / (usual.connect + usual.load), 0.08), 0.6), began: openBegan, expected: usual.connect)
    }
    /// The editor is on its way to the server: the line follows the bytes, up to four fifths.
    private func paceTransfer() {
        guard starting, let progress, let current = pace else { return }
        let now = Date(), base = transferBase ?? min(current.value(at: now), 0.3)
        transferBase = base
        pace = .fixed(max(current.value(at: now), base + (0.8 - base) * min(max(progress, 0), 1)))
    }
    private func paceLoading() {
        let now = Date()
        loadBegan = now
        pace = HarborProgressBar.Pace(from: pace?.value(at: now) ?? 0, to: 0.97, began: now, expected: usualTimes.load)
    }
    private func paceDone() {
        let now = Date()
        // An opening that had to send the editor says nothing about the usual one.
        if transferBase == nil, let loadBegan {
            let usual = usualTimes, known = UserDefaults.standard.object(forKey: paceKey) != nil
            let connect = loadBegan.timeIntervalSince(openBegan), load = now.timeIntervalSince(loadBegan)
            UserDefaults.standard.set(known ? [usual.connect * 0.4 + connect * 0.6, usual.load * 0.4 + load * 0.6] : [connect, load], forKey: paceKey)
        }
        pace = .fixed(1)
    }
    /// What a long step is doing right now, e.g. "12.4 of 218 MB · 31 KB/s · about 1 h 50 min left".
    @Published var detail: String?
    private var staticProxy: WorkbenchStaticProxy?
    @Published var error: String?
    @Published var web: WKWebView?
    @Published var starting = false
    var running: Bool { starting || web != nil }
    /// The opening page is carrying this workspace's title up to the bar, which leaves its own out until it arrives.
    @Published var titleInFlight = false
    @Published var ready = false
    @Published var commandsReady = false
    /// The editor is on the screen before Harbor's command service has answered: it has drawn
    /// itself, can be used, and what it asks (whether to trust the folder) can be answered there.
    @Published var revealed = false
    /// Said beside a revealed editor: why Harbor's part of it is not there yet.
    @Published var notice: String?
    /// Why this Mac sends the editor to a server that was also timed downloading it.
    private var deliveryNote: String?
    @Published var terminalFrame: CGRect = .zero
    @Published var layoutOpacity = 1.0
    @Published var terminalOccluded = false
    @Published var terminalFocused = false
    private(set) var terminalCount = 0
    private var pendingTerminal = false
    private var appliedTerminalMode = false
    private var reportedPanelVisible = false
    private var reportedPanelMaximized = false
    private var panelInitialized = false
    private var changingPanel = false
    private var panelTask: Task<Void, Never>?
    @Published var documentStatus = "Code-OSS · Open VSX"
    @Published var downloadProgress: Progress?
    @Published var downloadName = ""
    @Published var downloadNotice = ""
    private var downloads: [WKDownload] = []
    private var downloadDestinations: [ObjectIdentifier: URL] = [:]
    private(set) var dirtyPaths: [String] = []
    private var generation = UUID()
    private var startTask: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var nativeEvents: Task<Void, Never>?
    private weak var store: AppStore?
    private var lastNativeState = ""
    private var nativeStateRequestGeneration: UUID?
    private var pendingSettings: String?
    private var pendingFiles: [String] = []
    private var connection: WorkspaceSSHConnection?
    private var forwards: [(ServerProfile, String, String)] = []
    /// Liveness checks in a row that the editor's command service did not answer.
    private(set) var missedBeats = 0
    #if DEBUG
    /// The last reload of the page that Harbor turned into a connection from the start, for the probe.
    nonisolated(unsafe) static var lastReload = ""
    #endif
    private var repairing = false
    private var endpoint: URL?
    private var bridgeURL: URL?
    /// The port the editor's command service listens on, on its own machine.
    private var bridgePort: Int?
    private var bridgeToken = ""
    // Loopback commands must not inherit system proxy settings or browser cookies.
    private let commandSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }()
    private var storageID: UUID {
        let digest = SHA256.hash(data: Data((root.path + "|" + workspace.key).utf8))
        let bytes = Array(digest.prefix(16))
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    private var lastTheme = ""
    private var openedFolder = ""
    /// When the editor left the screen; nil while it is on it.
    private(set) var hiddenSince: Date?
    /// How many editors that are off the screen stay loaded, over all of Harbor's windows. Going
    /// back to one of them is at once, with the page as it was: the folders of a window are worked
    /// on in turn, and an editor that was let go of after a while off the screen (five minutes, it
    /// used to be) loaded again from nothing at every return. Beyond this many, the one that left
    /// the screen longest ago is let go of, so what Harbor keeps has a bound. The default
    /// "hiddenEditorsKept" changes it.
    static var hiddenKept: Int {
        guard let stored = UserDefaults.standard.object(forKey: "hiddenEditorsKept") as? Int else { return 3 }
        return max(0, stored)
    }
    var foreground = false {
        didSet {
            guard foreground != oldValue else { return }
            hiddenSince = foreground ? nil : Date()
            if !foreground { Self.releaseHidden() }
        }
    }
    /// Lets go of the editors off the screen beyond the number kept, the one that left it longest
    /// ago first. One with unsaved changes stays, whatever its place. One that is still starting
    /// is left to finish: stopping it cancelled the editor's download or its upload to the server,
    /// which then began again (the download from nothing) whenever the page was next shown.
    static func releaseHidden(keeping limit: Int? = nil, among candidates: [CodeWorkbenchSession]? = nil) {
        let hidden = (candidates ?? AppStore.all.flatMap { $0.codeWorkbench.running })
            .filter { !$0.foreground && $0.running }
            .sorted { ($0.hiddenSince ?? .distantPast) < ($1.hiddenSince ?? .distantPast) }
        var over = hidden.count - (limit ?? hiddenKept)
        for session in hidden where over > 0 {
            guard !session.starting, session.dirtyPaths.isEmpty else { continue }
            session.disconnect(); over -= 1
        }
    }
    var focused: Bool {
        guard let web,
              let view = NSApp.keyWindow?.firstResponder as? NSView else { return false }
        return view === web || view.isDescendant(of: web)
    }
    init(workspace: FileWorkspace, root: URL, owner: String) {
        self.workspace = workspace; self.root = root; self.owner = owner
    }
    var themeName: String {
        HarborTheme.editorThemeName(dark: HarborTheme.isDark())
    }
    func start(store: AppStore) {
        self.store = store
        foreground = true
        guard Self.launchesService, !starting, web == nil || openedFolder != workspace.root else { return }
        disconnect(); starting = true; error = nil; phase = "Preparing editor…"
        beginPace()
        let token = generation
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let profile = workspace.profile {
                    connection = WorkspaceSSHConnection(profile: profile, socket: try await store.resolveSocket(profile))
                }
                // Harbor's extensions travel once per version; afterwards only their digest does.
                let bundles = try bundledExtensions()
                var launch: [String: Any] = ["op": "start", "folder": workspace.root.isEmpty ? "~" : workspace.root,
                    "extensionsDigest": Self.digest(of: bundles), "settings": initialSettings()]
                // A server first says what it is missing; then this Mac sends it, or the server downloads
                // it, whichever is faster there (fasterDownload).
                if workspace.profile != nil { launch["download"] = false }
                var runtime = try await invoke(launch, reportsProgress: true)
                var delivered = 0, failed = 0, chosen = false
                // Bounded, but long enough to wait while another window sends the same package.
                for _ in 0..<2_000 {
                    if let need = runtime["needsArchive"] as? [String: Any] {
                        // Once: sent from this Mac, or downloaded there, whichever is faster for this server.
                        if !chosen, workspace.profile != nil, launch["download"] as? Bool != true {
                            chosen = true
                            if try await fasterDownload(need, launch: &launch) { launch["download"] = true }
                            try Task.checkCancellation()
                            runtime = try await invoke(launch, reportsProgress: true)
                            continue
                        }
                        do {
                            let package = try await deliverRuntime(need)
                            launch["slimDigest"] = package.digest; launch["slimSize"] = package.size
                            if package.sent { delivered += 1; failed = 0 }
                            if let failure = package.failure {
                                // An upload that broke off continues from what the server holds now. If the
                                // connection itself is gone, asking the server says so; giving up on sending
                                // (and making the server fetch the release) takes three failures in a row.
                                failed += 1
                                if failed >= 3 { throw failure }
                            }
                            // A package that arrived whole and still does not verify is discarded by the
                            // server and sent once more. Only after that may the server fetch the full
                            // release itself, which on a slow path takes hours.
                            launch["download"] = delivered >= 2
                        }
                        catch is CancellationError { throw CancellationError() }
                        catch {
                            // This Mac could not get or send the package; let the server try GitHub, resuming as before.
                            phase = "Downloading Code-OSS"; progress = nil; detail = "This Mac could not send it (\(error.localizedDescription)); the server downloads it instead"
                            launch["download"] = true
                        }
                    } else if runtime["needsExtensions"] as? Bool == true { launch["extensions"] = bundles }
                    else { break }
                    try Task.checkCancellation()
                    runtime = try await invoke(launch, reportsProgress: true)
                }
                try Task.checkCancellation()
                guard generation == token else { return }
                // Said, not waited on: without this the opening page stayed on its last line for good.
                guard let port = runtime["port"] as? Int, let password = runtime["password"] as? String else {
                    throw WorkspaceError.message("The editor service did not say where it listens. Reconnect to try again.")
                }
                bridgeToken = runtime["token"] as? String ?? ""
                openedFolder = runtime["folder"] as? String ?? workspace.root
                if workspace.root != openedFolder { workspace.root = openedFolder; store.updateWorkspaceClaim() }
                paceLoading()
                let localPort = try await originPort(for: port, runtime: runtime)
                let base = URL(string: "http://127.0.0.1:\(localPort)")!
                endpoint = base
                let config = WKWebViewConfiguration()
                config.websiteDataStore = WKWebsiteDataStore(forIdentifier: storageID)
                let cacheKey = "codeWorkbench.hostLayout.4." + storageID.uuidString
                if !UserDefaults.standard.bool(forKey: cacheKey) {
                    // Reload the verified host-layout patch, retaining cookies,
                    // workspace state, unsaved backups and installed extensions.
                    await config.websiteDataStore.removeData(ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache], modifiedSince: .distantPast)
                    UserDefaults.standard.set(true, forKey: cacheKey)
                }
                config.preferences.javaScriptCanOpenWindowsAutomatically = false
                config.mediaTypesRequiringUserActionForPlayback = []
                config.userContentController.add(WeakWorkbenchLayout(self), name: "harborLayout")
                config.userContentController.addScriptMessageHandler(WorkbenchClipboard(self), contentWorld: .page, name: "harborClipboard")
                config.userContentController.addUserScript(WKUserScript(source: WorkbenchClipboard.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
                config.userContentController.addUserScript(WKUserScript(source: "globalThis.__harborEmbeddedWorkbench = true; globalThis.__harborMotion = '\(HarborMotion.current.rawValue)'; globalThis.__harborActivityCount = \(WorkbenchPreferences.activityBarCount());", injectionTime: .atDocumentStart, forMainFrameOnly: true))
                config.userContentController.addUserScript(WKUserScript(source: Self.chromeStyle, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
                let view = WorkbenchWebView(frame: .zero, configuration: config)
                view.navigationDelegate = self; view.uiDelegate = self
                view.foldersDropped = { [weak self] urls, point in self?.dropped(urls, at: point) }
                view.allowsBackForwardNavigationGestures = false
                try await authenticate(base, password: password, cookies: config.websiteDataStore.httpCookieStore)
                try Task.checkCancellation()
                guard generation == token else { return }
                var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
                components.queryItems = [URLQueryItem(name: "folder", value: openedFolder)]
                // A plus is left as it is by URLComponents and read as a space by the page: "c++" opened "c  ".
                components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
                web = view; view.load(URLRequest(url: components.url!))
                NotificationCenter.default.post(name: .harborServersChanged, object: nil)
                phase = "Loading Code-OSS…"; starting = false
                // Restricted Mode turns off every extension stored inside the folder, and this folder
                // (a login directory, say) holds Harbor's: its command service comes only once the
                // folder is trusted, in the editor, which therefore has to be seen.
                let dataInside = runtime["dataInside"] as? Bool == true
                let loadingBegan = Date()
                // The extension host starts after the workbench establishes its
                // websocket. Retry only discovery; never duplicate an action.
                var discoveredPort: Int?
                var discoveryError = "The workspace extension has not started."
                var attempt = 0, lookupFailures = 0
                // When the editor came on the screen, and whether it has been loaded again for being stuck.
                var revealedAt: Date?, reloadedStuck = false
                while true {
                    // The first looks come quickly: an editor that is up should not wait a second to be noticed.
                    try await Task.sleep(nanoseconds: attempt < 6 ? 350_000_000 : revealed ? 3_000_000_000 : 1_000_000_000)
                    attempt += 1
                    guard generation == token else { return }
                    // An editor that has drawn itself is not kept behind the opening page while Harbor's part
                    // of it is missing: over a slow path that took minutes, and in Restricted Mode for ever,
                    // with the question that would end it out of sight.
                    if revealed || dataInside || Date().timeIntervalSince(loadingBegan) > 8 {
                        let page = await workbenchState()
                        guard generation == token else { return }
                        if !revealed, page.drawn { revealed = true; revealedAt = Date() }
                        if revealed {
                            // What the editor shows now: Restricted Mode only while it is in fact in it (a
                            // folder trusted before opens trusted).
                            notice = dataInside && page.restricted ? Self.restrictedNotice
                                : "Harbor\u{2019}s commands in this editor are still starting on \(workspace.profile?.name ?? LocalMachine.name). The editor can be used meanwhile."
                            // An editor whose extensions never start: drawn, trusted, nothing activating, and no
                            // command service of Harbor's after two minutes. Its extension host was seen to wait
                            // like this for good after a first install; loading the page again started it.
                            if !reloadedStuck, discoveredPort == nil, !page.restricted, !page.busy,
                               let shown = revealedAt, Date().timeIntervalSince(shown) > 120, let web {
                                reloadedStuck = true; revealedAt = Date()
                                web.reload(); continue
                            }
                        }
                    }
                    // One that never drew itself is reported, as before; one on the screen is waited for longer.
                    if (!revealed ? attempt > 56 : Date().timeIntervalSince(loadingBegan) > 1_800) { break }
                    // While the editor loads, its own traffic fills a slow path, and a small request
                    // waits behind it in the same connection: a lookup that takes too long is asked again,
                    // and ends the opening only before the editor is on the screen.
                    let bridge: [String: Any]
                    do { bridge = try await invoke(["op": "bridge", "folder": openedFolder], limit: attempt <= 6 ? 20 : 60) }
                    catch is CancellationError { throw CancellationError() }
                    catch {
                        discoveryError = error.localizedDescription; lookupFailures += 1
                        if !revealed && lookupFailures >= 3 { throw error }
                        continue
                    }
                    lookupFailures = 0
                    if let remotePort = bridge["port"] as? Int, remotePort > 0 {
                        if discoveredPort != remotePort {
                            bridgeURL = URL(string: "http://127.0.0.1:\(try await forward(remotePort))")
                            discoveredPort = remotePort; bridgePort = remotePort
                        }
                        // A surviving extension host can answer status while its old
                        // browser connection is still detached. Wait for a command
                        // acknowledged by the current workbench before enabling keys.
                        // Over a slow path the round trip takes longer than the first tries allow.
                        let wait: TimeInterval = attempt < 12 ? 3 : 10
                        do {
                            _ = try await request("workbench.action.focusActiveEditorGroup", timeout: wait)
                            _ = try await request("status", timeout: wait)
                        } catch { discoveryError = error.localizedDescription; continue }
                        commandsReady = true
                        await syncTheme()
                        guard generation == token else { return }
                        // An opening that was shown before it was ready says nothing about the usual one.
                        if revealed { pace = .fixed(1) } else { paceDone() }
                        ready = true; revealed = false; notice = nil; phase = "Code-OSS · Open VSX"
                        if pendingTerminal { pendingTerminal = false; _ = try await request("newTerminal") }
                        await updateTerminalPanel(force: true)
                        await flushPendingFiles()
                        beginHeartbeat(); flushPendingSettings(); return
                    }
                }
                if revealed {
                    // The editor stays usable; what is missing is said beside it.
                    notice = (dataInside ? Self.restrictedNotice : "Harbor\u{2019}s commands in this editor did not start (\(discoveryError)).") + " Reconnect Editor tries again."
                    return
                }
                if dataInside { throw WorkspaceError.message(Self.restrictedNotice + " Or open a folder inside it instead; Settings ▸ Workbench can turn the trust question off.") }
                throw WorkspaceError.message("The editor opened, but its command service did not respond. " + discoveryError)
            } catch is CancellationError { }
            catch {
                guard generation == token else { return }
                starting = false; self.error = error.localizedDescription; phase = "Editor connection unavailable"
            }
        }
    }
    static let restrictedNotice = "This folder holds Harbor\u{2019}s own files (the editor and its extensions), so until you trust it the editor keeps every extension in it off, Harbor\u{2019}s too. Click \u{201C}Restricted Mode\u{201D} in the status bar and choose Trust: Harbor connects as soon as you do."
    /// The editor has drawn itself: its status bar is there.
    /// What the editor's page shows: whether it has drawn itself (its status bar is there), is in
    /// Restricted Mode (the status bar item the editor shows only then), and is still starting its
    /// extensions ("Activating Extensions…").
    private func workbenchState() async -> (drawn: Bool, restricted: Bool, busy: Bool) {
        guard let web, let text = (try? await web.evaluateJavaScript(Self.workbenchStateScript)) as? String,
              let state = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Bool] else { return (false, false, false) }
        return (state["drawn"] == true, state["restricted"] == true, state["busy"] == true)
    }
    static let workbenchStateScript = """
    (() => {
      const bar = document.querySelector('.monaco-workbench .part.statusbar');
      const items = bar ? Array.from(bar.querySelectorAll('.statusbar-item'), item => item.textContent || '') : [];
      return JSON.stringify({drawn: !!bar,
        restricted: !!document.getElementById('status.workspaceTrust') || items.some(text => /Restricted Mode/i.test(text)),
        busy: items.some(text => /Activating Extensions|Installing|Initializing/i.test(text))});
    })()
    """
    static func digest(of bundles: [String: [String: String]]) -> String {
        var hasher = SHA256()
        for name in bundles.keys.sorted() {
            for file in bundles[name]!.keys.sorted() { hasher.update(data: Data((name + "\u{0}" + file + "\u{0}" + bundles[name]![file]! + "\u{0}").utf8)) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    /// Sends the trimmed editor package the server asked for. `sent` is false when it did not all get
    /// there: another upload of it is under way (this waits a little), the server already has every
    /// byte, or the upload broke off (`failure`); the caller then asks the server what it holds.
    /// With `limit`, the upload stops after that many seconds (what arrived is kept, and continued);
    /// `began` says when the bytes started to go and from which offset, to time it.
    private func deliverRuntime(_ need: [String: Any], limit: TimeInterval? = nil) async throws
        -> (digest: String, size: Int64, sent: Bool, failure: Error?, began: (date: Date, offset: Int64)?) {
        guard let connection, let profile = workspace.profile, let name = need["name"] as? String, let target = need["target"] as? String,
              let directory = need["directory"] as? String, directory.hasPrefix("/") else { throw WorkspaceError.message("The server did not say which editor package it needs.") }
        let script = try String(contentsOf: AppResources.directory("CodeWorkbench").appendingPathComponent("bootstrap.py"), encoding: .utf8)
        let manifest = try CodeRuntimePackage.manifest(script: script)
        phase = "Preparing the editor package"; progress = nil; detail = nil
        let token = generation
        let update: @Sendable (String, Double?, String?) -> Void = { [weak self] phase, progress, detail in
            Task { @MainActor in
                // What a start that has since been stopped still reports is not this one's to show.
                guard let self, self.generation == token else { return }
                self.phase = phase; self.progress = progress; self.detail = detail
            }
        }
        let slim = try await CodeRuntimePackage.slim(target: target, manifest: manifest, xz: need["xz"] as? Bool ?? false, report: update)
        try Task.checkCancellation()
        // Continue an upload of this same package; anything else on the server starts over.
        var offset = (need["slimDigest"] as? String) == slim.digest ? min(Int64(need["slimHave"] as? Int ?? 0), slim.size) : 0
        let output = root.appendingPathComponent("CodeWorkbenchRequests").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        // A server behind the managed tunnel gets the bytes at the pace its path carries.
        let relay = await ManagedRelay.port(for: profile)
        var sent = false
        var began: (date: Date, offset: Int64)?
        for attempt in 0..<2 where offset < slim.size {
            let from = offset, started = Date()
            if began == nil { began = (started, from) }
            // The server continues only from this package's own first bytes, checked by digest.
            let source = slim.url
            let prefix = from > 0 ? try await Task.detached(priority: .utility) { try CodeRuntimePackage.sha256(of: source, upTo: from) }.value : ""
            // Why this Mac sends it, when the server was timed as well: said beside the progress.
            let sending = "Sending Code-OSS to " + profile.name + (deliveryNote.map { " · " + $0 } ?? "")
            let report: @Sendable (FileProcessProgress) -> Void = { value in
                let sent = max(from, value.inputBytes), elapsed = Date().timeIntervalSince(started)
                update(sending, Double(sent) / Double(max(slim.size, 1)),
                       CodeRuntimePackage.describe(sent: sent, total: slim.size, rate: elapsed >= 3 ? Double(sent - from) / elapsed : 0))
            }
            do {
                try await connection.run(command: CodeRuntimePackage.uploadCommand(directory: directory, name: name, digest: slim.digest, offset: from, prefix: prefix)) { arguments in
                    try await FileProcess.run("/usr/bin/ssh", arguments: arguments, input: Data(), output: output, timeout: limit ?? 86_400, inputFile: slim.url, inputOffset: UInt64(from),
                                              pacer: relay.map { TransferPacer(port: $0) }, stallTimeout: relay == nil ? 300 : 900, progress: report)
                }
                offset = slim.size; sent = true
            } catch {
                if !Task.isCancelled, error.localizedDescription.contains(CodeRuntimePackage.uploadBusy) {
                    // Another window, or another Mac, is writing this package there right now. Two writers
                    // would spoil the file; wait for that one and let the server say what is still missing.
                    phase = "Waiting for Code-OSS on " + profile.name; progress = nil; detail = "Another Harbor window is already sending it"
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    return (slim.digest, slim.size, false, nil, nil)
                }
                try Task.checkCancellation()
                // The server's copy is not the start of this package: send it whole, once.
                if attempt == 0, from > 0, error.localizedDescription.contains(CodeRuntimePackage.uploadMismatch) { offset = 0; continue }
                return (slim.digest, slim.size, false, error, began)
            }
        }
        phase = "Installing Code-OSS"; progress = nil; detail = nil
        return (slim.digest, slim.size, sent, nil, began)
    }
    /// A server without the editor gets it the faster way: this Mac sends its trimmed package
    /// (about 66 MB), or the server downloads the release (about 230 MB) from GitHub or a relay of
    /// it, whichever is fastest from there (bootstrap.py, DOWNLOAD_MIRRORS). The server times its
    /// downloads for a few seconds; this Mac's upload is timed on the package itself, and what it
    /// sent meanwhile is kept. Either arrives checked against the release's SHA-256.
    /// True when downloading there is faster; `launch` then names the relay.
    private func fasterDownload(_ need: [String: Any], launch: inout [String: Any]) async throws -> Bool {
        guard let profile = workspace.profile else { return false }
        phase = "Finding the fastest way to bring Code-OSS to " + profile.name; progress = nil; detail = "Timing downloads on the server"
        deliveryNote = nil
        // Given the long limit of a start: on a slow path the request alone takes seconds.
        guard let probe = try? await invoke(["op": "probe"], reportsProgress: true), let rates = probe["rates"] as? [String: Double],
              let best = rates.max(by: { $0.value < $1.value }), best.value > 0 else {
            deliveryNote = "the server could not download it from GitHub or a relay"; return false
        }
        // Also used if sending from here fails later and the server downloads after all.
        launch["mirror"] = best.key
        let reported = probe["size"] as? Double ?? 0
        let size = reported > 0 ? reported : 240_000_000
        try Task.checkCancellation()
        // Downloaded there within a minute: timing this Mac's upload could only win back seconds.
        if size / best.value < 60 { return announce(best.key, rate: best.value, against: nil, on: profile) }
        detail = "Timing the upload from this Mac"
        let package: (digest: String, size: Int64, sent: Bool, failure: Error?, began: (date: Date, offset: Int64)?)
        do { package = try await deliverRuntime(need, limit: 15) }
        catch is CancellationError { throw CancellationError() }
        // This Mac could not make its package: the server downloads it, from the fastest place.
        catch { return true }
        launch["slimDigest"] = package.digest; launch["slimSize"] = package.size
        // All of it went in those seconds, or another window is sending it: nothing to choose.
        guard !package.sent, let began = package.began else { return false }
        // What arrived, as the server counts it: bytes still in this Mac's buffers have not been sent.
        // Megabytes of them can still be queued in the connection ahead of this request, on a slow
        // path for minutes: it has the long limit of a start, and failing it only means sending on.
        let check: [String: Any]
        do { check = try await invoke(launch, reportsProgress: true) }
        catch is CancellationError { throw CancellationError() }
        catch { return false }
        // Up to the answer: the queued bytes arrived in this time too.
        let seconds = max(1, Date().timeIntervalSince(began.date))
        guard let again = check["needsArchive"] as? [String: Any] else { return false }
        let have = Int64(again["slimHave"] as? Int ?? 0)
        let rate = Double(max(0, have - began.offset)) / seconds
        let uploading = rate > 0 ? Double(max(0, package.size - have)) / rate : .infinity
        let downloading = size / best.value
        // A near tie goes to sending from here: it is a third of the bytes, through no one else's server.
        guard downloading < uploading * 0.8 else {
            let source = best.key.isEmpty ? "GitHub" : (URL(string: best.key)?.host() ?? best.key)
            deliveryNote = "faster than the server downloading it (\(source), \(CodeRuntimePackage.describeRate(best.value)))"
            return false
        }
        return announce(best.key, rate: best.value, against: rate, on: profile)
    }
    private func announce(_ mirror: String, rate: Double, against upload: Double?, on profile: ServerProfile) -> Bool {
        let source = mirror.isEmpty ? "GitHub" : (URL(string: mirror)?.host() ?? mirror)
        phase = "Downloading Code-OSS on " + profile.name
        detail = "From \(source) at \(CodeRuntimePackage.describeRate(rate))" + (upload.map { ", faster than sending it from this Mac (\(CodeRuntimePackage.describeRate($0)))" } ?? "")
        return true
    }
    /// `limit` overrides how long a request without progress may take (20 seconds).
    func invoke(_ values: [String: Any], reportsProgress: Bool = false, limit: TimeInterval? = nil) async throws -> [String: Any] {
        let bundle = AppResources.directory("CodeWorkbench")
        let script = try String(contentsOf: bundle.appendingPathComponent("bootstrap.py"), encoding: .utf8)
        let cache = root.appendingPathComponent("CodeWorkbenchRequests")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let output = cache.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        var payload = values; payload["owner"] = owner
        if workspace.profile == nil {
            payload["storage"] = root.appendingPathComponent("CodeOSS").path
            #if DEBUG
            if let archive = ProcessInfo.processInfo.environment["HARBOR_CODE_ARCHIVE"] { payload["archive"] = archive }
            #endif
        }
        let input = try JSONSerialization.data(withJSONObject: payload)
        let watcher = reportsProgress ? Task { [weak self] in
            while !Task.isCancelled {
                if let contents = try? String(contentsOf: output, encoding: .utf8),
                   let line = contents.split(separator: "\n").last,
                   let data = String(line).data(using: .utf8),
                   let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let phase = status["phase"] as? String {
                    self?.phase = phase; self?.progress = status["progress"] as? Double; self?.detail = status["detail"] as? String
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        } : nil
        defer { watcher?.cancel(); if reportsProgress { detail = nil } }
        do {
            if let connection {
                // Starting can include a first download of about 230 MB over a path that carries a few
                // kilobytes per second. It reports every second, so it is bounded by silence, not by total time.
                let timeout: TimeInterval = limit ?? (reportsProgress ? Self.startLimit : 20)
                func remote(_ command: String, _ data: Data, _ limit: TimeInterval) async throws {
                    try await connection.run(command: command) { args in
                        try await FileProcess.run("/usr/bin/ssh", arguments: args, input: data, output: output, timeout: limit,
                                                  stallTimeout: limit == Self.startLimit ? Self.startStall : nil)
                    }
                }
                // The service script is about 40 KB. Keep one verified-by-name copy
                // on the server so each request sends a short command instead of
                // the whole script; fall back to sending it inline if that fails.
                let digest = SHA256.hash(data: Data(script.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
                try await remote(Self.cachedBootstrapCommand(digest), input, timeout)
                if (try? Self.lastReply(output))?["missing"] as? Bool == true {
                    if (try? await remote(Self.installBootstrapCommand(digest), Self.sealedBootstrap(script, digest: digest), 60)) != nil,
                       (try? Self.lastReply(output))?["installed"] as? Bool == true {
                        try await remote(Self.cachedBootstrapCommand(digest), input, timeout)
                    } else {
                        try await remote("python3 -c " + SSHArguments.quote(script), input, timeout)
                    }
                }
            } else {
                try await FileProcess.run("/usr/bin/env", arguments: ["python3", "-c", script], input: input, output: output, timeout: reportsProgress ? Self.startLimit : 20,
                                          stallTimeout: reportsProgress ? Self.startStall : nil)
            }
        } catch {
            if let reply = try? Self.lastReply(output), let message = reply["error"] as? String { throw WorkspaceError.message(message) }
            throw error
        }
        let reply = try Self.lastReply(output)
        if let message = reply["error"] as? String { throw WorkspaceError.message(message) }
        guard let result = reply["result"] as? [String: Any] else { throw WorkspaceError.message("Editor returned an incomplete reply.") }
        return result
    }
    static let startLimit: TimeInterval = 86_400, startStall: TimeInterval = 300
    static let bootstrapDirectory = "$HOME/.local/share/harbor"
    /// The last line of an installed script. An interrupted upload ends early (ssh closing is
    /// just end of input to `cat`), so a copy counts only when this line arrived.
    static func bootstrapSeal(_ digest: String) -> String { "# harbor-bootstrap-end " + digest }
    static func sealedBootstrap(_ script: String, digest: String) -> Data {
        Data((script + (script.hasSuffix("\n") ? "" : "\n") + bootstrapSeal(digest) + "\n").utf8)
    }
    private static func sealed(_ file: String, _ digest: String) -> String {
        "[ \"$(tail -n 1 \(file) 2>/dev/null)\" = '\(bootstrapSeal(digest))' ]"
    }
    /// Runs the cached service script, or reports that a complete copy is not installed yet.
    /// Wrapped in `sh -c` so the user's login shell (fish, csh) does not matter.
    static func cachedBootstrapCommand(_ digest: String) -> String {
        "sh -c " + SSHArguments.quote("f=\"\(bootstrapDirectory)/bootstrap-\(digest).py\"; if \(sealed("\"$f\"", digest)); then exec python3 \"$f\"; else cat >/dev/null; echo '{\"missing\":true}'; fi")
    }
    /// Receives the sealed script on stdin, installs it atomically when it arrived whole and keeps the three newest copies.
    static func installBootstrapCommand(_ digest: String) -> String {
        "sh -c " + SSHArguments.quote("umask 077; d=\"\(bootstrapDirectory)\"; t=\"$d/bootstrap-\(digest).py.$$\"; mkdir -p \"$d\" && cat > \"$t\" && \(sealed("\"$t\"", digest)) && mv \"$t\" \"$d/bootstrap-\(digest).py\" && { ls -t \"$d\"/bootstrap-*.py 2>/dev/null | tail -n +4 | while IFS= read -r old; do rm -f \"$old\"; done; echo '{\"installed\":true}'; } || { rm -f \"$t\"; echo '{\"installed\":false}'; }")
    }
    private static func lastReply(_ url: URL) throws -> [String: Any] {
        guard let line = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").last,
              let result = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { throw WorkspaceError.message("No response from editor service.") }
        return result
    }
    /// The local port the web view loads from. For a server it is, when this Mac has the same
    /// editor build, a proxy that answers the editor's program files locally and forwards the
    /// rest; the port stays the same across restarts so the page keeps its origin and storage.
    private func originPort(for remotePort: Int, runtime: [String: Any]) async throws -> Int {
        #if DEBUG
        let everywhere = UserDefaults.standard.bool(forKey: "qaStaticProxy")
        #else
        let everywhere = false
        #endif
        guard workspace.profile != nil || everywhere else { return remotePort }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "qaNoStaticProxy") { return try await forward(remotePort, stable: true) }
        #endif
        if localAssets(runtime: runtime) == nil { await installLocalRuntime(); try Task.checkCancellation() }
        guard let assets = localAssets(runtime: runtime) else { return try await forward(remotePort, stable: true) }
        let upstream = workspace.profile == nil ? remotePort : try await forward(remotePort)
        let port = try stablePort()
        do { staticProxy = try WorkbenchStaticProxy(port: port, upstream: upstream, assets: assets); rememberStablePort(port); return port }
        catch { return workspace.profile == nil ? remotePort : try await forward(remotePort, stable: true) }
    }
    /// Gives this Mac the editor build its servers run. Usually a copy of the build it already
    /// has; if it takes long, this connection goes on without it and the next one uses it.
    private func installLocalRuntime() async {
        guard let script = try? String(contentsOf: AppResources.directory("CodeWorkbench").appendingPathComponent("bootstrap.py"), encoding: .utf8),
              let input = try? JSONSerialization.data(withJSONObject: ["op": "install", "owner": owner, "storage": root.appendingPathComponent("CodeOSS").path]) else { return }
        phase = "Preparing the editor on this Mac"; progress = nil; detail = nil
        let output = root.appendingPathComponent("CodeWorkbenchRequests").appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: output) }
        try? await FileProcess.run("/usr/bin/env", arguments: ["python3", "-c", script], input: input, output: output, timeout: 60)
    }
    /// This Mac's copy of the editor build the server runs, if it has one.
    private func localAssets(runtime: [String: Any]) -> URL? {
        guard let version = runtime["version"] as? String, let revision = runtime["layoutRevision"] as? String,
              !version.contains("/"), !revision.contains("/") else { return nil }
        #if arch(arm64)
        let machine = "arm64"
        #else
        let machine = "amd64"
        #endif
        let assets = root.appendingPathComponent("CodeOSS/runtimes/\(revision)/code-server-\(version)-macos-\(machine)/lib/vscode", isDirectory: true)
        return FileManager.default.fileExists(atPath: assets.appendingPathComponent("out/vs/code/browser/workbench/workbench.js").path) ? assets : nil
    }
    private var stablePortFile: URL { root.appendingPathComponent("CodeWorkbenchOrigins", isDirectory: true).appendingPathComponent(storageID.uuidString) }
    private func stablePort() throws -> Int {
        if let previous = (try? String(contentsOf: stablePortFile, encoding: .utf8)).flatMap(Int.init), (1024...65535).contains(previous), !RemoteDisplaySession.portIsOpen(previous) { return previous }
        return try RemoteDisplaySession.unusedPort()
    }
    private func rememberStablePort(_ port: Int) {
        try? FileManager.default.createDirectory(at: stablePortFile.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? String(port).write(to: stablePortFile, atomically: true, encoding: .utf8)
    }
    private func forward(_ remotePort: Int, stable: Bool = false) async throws -> Int {
        guard let profile = workspace.profile, let connection else { return remotePort }
        let port = stable ? try stablePort() : try RemoteDisplaySession.unusedPort()
        let socket = FileManager.default.fileExists(atPath: connection.sharedSocket) ? connection.sharedSocket : connection.fileSocket
        let spec = "127.0.0.1:\(port):127.0.0.1:\(remotePort)"
        let token = generation
        // Explicit mux forwarding allocates no MaxSessions channel and has a
        // matching cancel operation. Never close the shared terminal master.
        let result = await ProcessRunner.run("/usr/bin/ssh", Self.control(profile, socket: socket, "forward", spec), timeout: 15)
        guard generation == token, !Task.isCancelled else {
            // Stopped while ssh was asked: the forward is not this session's any more, and is taken back.
            if result.succeeded { Self.cancelForward(profile, socket: socket, spec: spec) }
            throw CancellationError()
        }
        guard result.succeeded else { throw WorkspaceError.message(result.output) }
        forwards.append((profile, socket, spec))
        if stable { rememberStablePort(port) }
        return port
    }
    /// The arguments of a request to a running ssh connection ("forward", "cancel", "check").
    /// Without the user's ssh configuration: the socket says which connection is meant, and with
    /// the configuration read, ssh asks for (and on "cancel" takes away) every LocalForward and
    /// RemoteForward the alias names beside the one given here. One of those that could not be
    /// bound failed the request, and the editor could not open on that server.
    static func control(_ profile: ServerProfile, socket: String, _ operation: String, _ spec: String? = nil) -> [String] {
        var arguments = ["-F", "none", "-S", socket, "-O", operation]
        if operation == "forward" { arguments += ["-o", "ExitOnForwardFailure=yes"] }
        if let spec { arguments += ["-L", spec] }
        return arguments + ["--", profile.host]
    }
    static func cancelForward(_ profile: ServerProfile, socket: String, spec: String) {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = control(profile, socket: socket, "cancel", spec)
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try? process.run()
    }
    private func authenticate(_ base: URL, password: String, cookies: WKHTTPCookieStore) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        var request = URLRequest(url: base.appendingPathComponent("login")); request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(("password=" + password).utf8); request.timeoutInterval = 20
        let (_, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let authCookies = session.configuration.httpCookieStorage?.cookies, !authCookies.isEmpty else {
            throw WorkspaceError.message("Could not authenticate Harbor's private editor service.")
        }
        for cookie in authCookies { await cookies.setCookie(cookie) }
    }
    func request(_ command: String, extra: [String: Any] = [:], timeout: TimeInterval = 30) async throws -> Any? {
        guard let bridgeURL else { throw WorkspaceError.message("Editor commands are still starting.") }
        var body = extra; body["command"] = command
        var request = URLRequest(url: bridgeURL); request.httpMethod = "POST"
        request.setValue("Bearer " + bridgeToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("close", forHTTPHeaderField: "Connection")
        request.httpBody = try JSONSerialization.data(withJSONObject: body); request.timeoutInterval = timeout
        let data: Data, response: URLResponse
        do { (data, response) = try await commandSession.data(for: request) }
        catch {
            let detail = error as NSError
            throw WorkspaceError.message("Editor transport \(command): \(detail.domain) (\(detail.code)) \(detail.localizedDescription)")
        }
        let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw WorkspaceError.message("Editor command \(command): " + (reply?["error"] as? String ?? "Connection closed.")) }
        if command == "status", let status = reply?["result"] as? [String: Any] { apply(status: status) }
        return reply?["result"]
    }
    func apply(status: [String: Any]) {
        dirtyPaths = status["dirty"] as? [String] ?? []
        terminalCount = status["terminalCount"] as? Int ?? 0
        let label = status["label"] as? String ?? "Code-OSS · Open VSX"
        let value = (dirtyPaths.isEmpty ? "" : "Unsaved · ") + label
        if documentStatus != value { documentStatus = value }
    }
    func openSettings(store: AppStore, keybindings: Bool = false) {
        // A menu request can arrive before the SwiftUI editor surface mounts or
        // while its extension host is connecting. Keep one intent, not a retry
        // loop that could repeatedly open Settings after a slow response.
        pendingSettings = keybindings ? "workbench.action.openGlobalKeybindings" : "workbench.action.openSettings"
        start(store: store)
        flushPendingSettings()
    }
    private func flushPendingSettings() {
        guard let pending = pendingSettings, commandsReady, foreground else { return }
        pendingSettings = nil
        command(pending)
    }
    /// Opens a file in this workbench now, or as soon as its commands are ready.
    func open(path: String) {
        if commandsReady { Task { _ = try? await request("openFile", extra: ["path": path]) } }
        else if !pendingFiles.contains(path) { pendingFiles.append(path) }
    }
    private func flushPendingFiles() async {
        let paths = pendingFiles; pendingFiles.removeAll()
        for path in paths { _ = try? await request("openFile", extra: ["path": path]) }
    }
    func newTerminal(store: AppStore) {
        if commandsReady { command("workbench.action.terminal.new") }
        else { pendingTerminal = true; start(store: store) }
    }
    /// Renderer layout actions stay local; no SSH round trip or native PTY layer.
    func command(_ name: String) {
        guard commandsReady else { return }
        let actions = ["workbench.action.toggleSidebarVisibility": "toggleSidebar",
            "workbench.action.togglePanel": "toggleTerminal",
            "workbench.action.terminal.focus": "focusTerminal",
            "workbench.action.terminal.new": "newTerminal",
            "workbench.action.terminal.split": "splitTerminal",
            "workbench.action.focusActiveEditorGroup": "focusEditor"]
        if let action = actions[name] {
            Task {
                let animated = action == "toggleSidebar" || action == "toggleTerminal"
                if animated { beginLayoutTransition() }
                defer { if animated { endLayoutTransition() } }
                do {
                    if !(try await localLayout(action, options: ["preserveFocus": terminalFocused])) { _ = try await request(name) }
                } catch { report(error) }
            }
        } else {
            if let web { web.window?.makeFirstResponder(web) }
            Task { do { _ = try await request(name) } catch { report(error) } }
        }
    }
    private func localLayout(_ action: String, options: [String: Any] = [:]) async throws -> Bool {
        guard let web else { return false }
        let result = try await web.callAsyncJavaScript(
            "if (!window.__harborWorkbenchCommand) return {unavailable:true}; return await window.__harborWorkbenchCommand(action, options);",
            arguments: ["action": action, "options": options], in: nil, contentWorld: .page) as? [String: Any]
        if result?["unavailable"] as? Bool == true { return false }
        guard result?["ok"] as? Bool == true else {
            throw WorkspaceError.message(result?["error"] as? String ?? "The editor could not update its layout.")
        }
        return true
    }
    /// Mirrors the native motion preference into the workbench's CSS.
    func syncMotion() {
        guard let web else { return }
        web.evaluateJavaScript("window.__harborSetMotion && window.__harborSetMotion('\(HarborMotion.current.rawValue)')", completionHandler: nil)
    }
    /// Applies the number of views pinned above Explorer and the matching minimum sidebar width.
    func syncActivityBar() {
        guard let web else { return }
        web.evaluateJavaScript("window.__harborSetActivityCount && window.__harborSetActivityCount(\(WorkbenchPreferences.activityBarCount()))", completionHandler: nil)
    }
    private func beginLayoutTransition() {
        guard HarborMotion.current != .off else { return }
        // Animate opacity, not PTY geometry: continuous terminal resizing forces
        // full-screen CLI programs to redraw on every animation frame.
        layoutOpacity = 0.94
    }
    private func endLayoutTransition() {
        withAnimation(HarborMotion.current == .off ? nil : .easeOut(duration: 0.12)) { layoutOpacity = 1 }
    }
    func syncTheme() async {
        let name = themeName, expected = HarborTheme.editorBackground(name)
        // An editor shown before Harbor's commands in it answer cannot be told yet. If the window
        // has changed theme meanwhile, its note says the editor follows once they answer, which
        // it then does by dissolving, not at a stroke.
        guard commandsReady else {
            if revealed, let expected, !(web?.isLoading ?? true) { themeWaiting = await pageThemeMark() != expected }
            return
        }
        guard lastTheme != name else { return }
        let before = await pageThemeMark()
        // Wearing it already (an editor started with the theme it was last given): it is only told.
        // Nothing is waited for, and opening goes on at once.
        if expected == nil && lastTheme.isEmpty || expected != nil && before == expected {
            do { _ = try await request("theme", extra: ["value": name]); lastTheme = name; themeWaiting = false } catch { }
            return
        }
        let change = { [weak self] () async -> Void in
            guard let self else { return }
            do { _ = try await self.request("theme", extra: ["value": name]); self.lastTheme = name; self.themeWaiting = false } catch { return }
            // The setting is written; the page puts the new colors on a moment later.
            for _ in 0..<30 {
                let mark = await self.pageThemeMark()
                if let expected { if mark == expected { return } } else if mark != before { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        // The editor on screen dissolves into its new colors instead of repainting in view. (One
        // still behind its opening page does too, unseen; the page goes once the colors are on.)
        if let web, let stage = store?.codeWorkbench.stage, stage.current === web { await stage.dissolve(during: change) }
        else { await change() }
    }
    /// The editor wears another theme than the window and cannot be told yet (its commands are
    /// still starting): said in its note.
    @Published private(set) var themeWaiting = false
    static let themeWaitingNote = "Its colors follow the new theme once they answer."
    /// The editor's background as its page has it now (lowercase #rrggbb): it changes when a new
    /// theme has been put on, and is the theme's own (HarborTheme.editorBackground) once it is.
    private static let themeMarkScript = "(() => { const w = document.querySelector('.monaco-workbench'); return w ? getComputedStyle(w).getPropertyValue('--vscode-editor-background').trim().toLowerCase() : ''; })()"
    private func pageThemeMark() async -> String {
        guard let web else { return "" }
        return (try? await web.evaluateJavaScript(Self.themeMarkScript)) as? String ?? ""
    }
    private func syncNativeState() async {
        guard let store, foreground, commandsReady, nativeStateRequestGeneration == nil else { return }
        let state = store.workbenchNavigationState()
        guard let encoded = try? Self.json(state), encoded != lastNativeState else { return }
        let token = generation
        nativeStateRequestGeneration = token
        defer { if nativeStateRequestGeneration == token { nativeStateRequestGeneration = nil } }
        do {
            _ = try await request("nativeState", extra: ["state": state])
            guard generation == token, !Task.isCancelled else { return }
            lastNativeState = encoded
        } catch { }
    }
    private func beginHeartbeat() {
        nativeEvents?.cancel()
        nativeEvents = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let events = try await request("events") as? [[String: String]] ?? []
                    guard !Task.isCancelled else { return }
                    for event in events {
                        // The extension host pushes unsaved-file and terminal
                        // changes; they apply in background windows as well.
                        if event["action"] == "status" {
                            if let data = event["value"]?.data(using: .utf8), let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { apply(status: status) }
                        } else if foreground { store?.handleWorkbenchAction(event) }
                    }
                } catch { if Task.isCancelled { return }; try? await Task.sleep(nanoseconds: 2_000_000_000) }
            }
        }
        Task { await syncNativeState() }
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            var failures = 0, elapsed = 0.0
            while !Task.isCancelled {
                // Native state is compared locally every two seconds and sent
                // only when it changed. The status request is a liveness check;
                // file and terminal changes arrive through the event channel.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled else { return }
                elapsed += 2
                if foreground { await syncNativeState() }
                guard elapsed >= (failures > 0 ? 2 : foreground ? Self.livenessInterval : Self.backgroundLivenessInterval) else { continue }
                elapsed = 0
                // A notice about a command goes once the editor answers again. One about the page
                // itself (its renderer stopped) stays: the service still answers then, and taking
                // the notice away left a dead page behind an opening line with nothing to press.
                do { _ = try await request("status"); failures = 0; missedBeats = 0; if foreground, ready { error = nil } }
                catch {
                    failures += 1; missedBeats = failures
                    // Nothing is said here. The editor says so itself when it has lost its server
                    // ("Attempting to reconnect…") and tries again on its own; a notice of Harbor's
                    // beside it, with a Reconnect button of its own, only said the same thing twice.
                    // Harbor's part is the connection underneath, which it puts back, and knowing
                    // where the editor's command service is, which it looks up again.
                    if failures >= 2, failures % 3 == 2 {
                        let restored = await repairTransport()
                        if !restored { await rediscoverBridge() }
                    }
                }
            }
        }
    }
    /// The page loads through port forwards of the server's shared ssh connection. When that
    /// connection dies (a path that was silent for over a minute ends it), the forwards go with it,
    /// and the editor's own attempts to reconnect can not succeed until they are back. They are put
    /// back on the same local ports, so the page reconnects by itself, without being loaded again.
    /// A path that only stalls leaves them in place, and there is nothing to do.
    @discardableResult func repairTransport() async -> Bool {
        guard !repairing, !forwards.isEmpty else { return false }
        repairing = true; defer { repairing = false }
        let token = generation
        var restored = 0
        for (profile, socket, spec) in forwards {
            guard let port = Self.localPort(of: spec), !RemoteDisplaySession.portIsOpen(port) else { continue }
            let alive = await ProcessRunner.run("/usr/bin/ssh", Self.control(profile, socket: socket, "check"), timeout: 5)
            guard generation == token else { return false }
            if !alive.succeeded {
                // Another connection on the same path; for a server that takes a password, with the
                // one Harbor keeps for it.
                let persist = socket == connection?.fileSocket ? ["-o", "ControlPersist=60"] : []
                let up = await ServerPasswords.runQuietly(["-o", "BatchMode=yes"] + persist + SSHArguments.common(profile, socket: socket) + ["-T", "--", profile.host, "true"], server: profile.id, timeout: 45)
                guard up.succeeded, generation == token else { return false }
            }
            let result = await ProcessRunner.run("/usr/bin/ssh", Self.control(profile, socket: socket, "forward", spec), timeout: 15)
            guard result.succeeded, generation == token else { return false }
            restored += 1
        }
        return restored > 0
    }
    /// The editor's extension host can start again without the page loading again ("Restart
    /// Extensions" after an update, or a crash it recovers from). Its command service then listens
    /// on another port, and Harbor went on asking the old one for good: unsaved files and terminals
    /// were no longer known, and nothing sent from Harbor arrived. The port is looked up again and
    /// forwarded in place of the old one.
    func rediscoverBridge() async {
        guard ready, !repairing, bridgeURL != nil, !openedFolder.isEmpty else { return }
        repairing = true; defer { repairing = false }
        let token = generation
        guard let bridge = try? await invoke(["op": "bridge", "folder": openedFolder]), generation == token,
              let remotePort = bridge["port"] as? Int, remotePort > 0, remotePort != bridgePort else { return }
        let stale = forwards.first { entry in bridgePort.map { entry.2.hasSuffix(":127.0.0.1:\($0)") } ?? false }
        guard let local = try? await forward(remotePort), generation == token else { return }
        bridgeURL = URL(string: "http://127.0.0.1:\(local)"); bridgePort = remotePort
        if let stale, let index = forwards.firstIndex(where: { $0.2 == stale.2 }) {
            forwards.remove(at: index); Self.cancelForward(stale.0, socket: stale.1, spec: stale.2)
        }
        // What has started again there knows nothing of what the one before it was told: the
        // theme, and the state without which it reports no change of a setting.
        lastNativeState = ""; lastTheme = ""
        await syncTheme(); await syncNativeState()
    }
    /// Whether an address is the one this editor's page was loaded from.
    func serves(host: String, port: Int) -> Bool {
        guard let endpoint, let own = endpoint.host, let ownPort = endpoint.port else { return false }
        return host == own && port == ownPort
    }
    /// A command that did not get through. When it is the connection that is down, the editor is
    /// already saying so and has its own way back; only what is wrong with a command is shown.
    private func report(_ error: Error) {
        let message = error.localizedDescription
        if !Self.isTransportFailure(message) { self.error = message }
    }
    static func isTransportFailure(_ message: String) -> Bool { message.hasPrefix("Editor transport ") }
    /// The local port of a forward written as "127.0.0.1:port:127.0.0.1:port".
    static func localPort(of spec: String) -> Int? {
        let parts = spec.split(separator: ":")
        return parts.count == 4 ? Int(parts[1]) : nil
    }
    /// Starts over: a new connection, the editor's service made sure of, the page loaded again.
    /// What the editor's "Reload Window" means while its connection is gone.
    private func reconnect() {
        guard let store else { return }
        DispatchQueue.main.async { [weak self] in self?.disconnect(); self?.start(store: store) }
    }
    func disconnect() {
        nativeEvents?.cancel(); nativeEvents = nil; lastNativeState = ""; nativeStateRequestGeneration = nil
        generation = UUID(); panelTask?.cancel(); panelTask = nil; startTask?.cancel(); startTask = nil; heartbeat?.cancel(); heartbeat = nil
        pace = nil
        web?.stopLoading(); web?.navigationDelegate = nil; web?.uiDelegate = nil
        staticProxy?.stop(); staticProxy = nil
        // SwiftUI or an in-flight callback can retain the detached WKWebView.
        // Unload its document so the old extension-host websocket cannot keep
        // answering commands after reconnect; the remote PTYs remain alive.
        web?.loadHTMLString("", baseURL: nil)
        web?.removeFromSuperview(); web = nil
        for (profile, socket, spec) in forwards { Self.cancelForward(profile, socket: socket, spec: spec) }
        forwards.removeAll()
        terminalFrame = .zero; terminalOccluded = false; terminalFocused = false; panelInitialized = false; changingPanel = false; appliedTerminalMode = false; layoutOpacity = 1
        reportedPanelVisible = false; reportedPanelMaximized = false
        bridgeURL = nil; bridgePort = nil; endpoint = nil; bridgeToken = ""; lastTheme = ""; ready = false; commandsReady = false; starting = false
        revealed = false; notice = nil; deliveryNote = nil; themeWaiting = false
        missedBeats = 0
        NotificationCenter.default.post(name: .harborServersChanged, object: nil)
    }
    /// A running editor that was asked to load again and could not: its service, or the way to it, is gone.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === web, ready || revealed, (error as NSError).code != NSURLErrorCancelled else { return }
        reconnect()
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false; error = "The editor renderer stopped. Reconnect to recover your workspace from its saved backup."
        // Off the screen, nobody is there to press Reconnect: the editor is let go of now, and it
        // loads again from the start when it is next shown, instead of showing its notice then.
        if !foreground { DispatchQueue.main.async { [weak self] in if let self, !self.foreground { self.disconnect() } } }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        // "Reload Window": from the editor's notice that it lost its server, after an extension was
        // installed, from the Command Palette. A page that only loads again comes up with a new
        // extension host, whose command service Harbor would not know (it then went unanswered until
        // Harbor's own Reconnect was clicked), and through the same connection, which may be the
        // thing that broke. Harbor connects from the start instead: one reload, and all of it works.
        if ready, navigationAction.targetFrame?.isMainFrame == true, url.host == endpoint?.host, url.port == endpoint?.port,
           navigationAction.navigationType == .reload || missedBeats > 0 {
            #if DEBUG
            Self.lastReload = "type \(navigationAction.navigationType.rawValue), missed \(missedBeats)"
            #endif
            decisionHandler(.cancel); reconnect(); return
        }
        if navigationAction.shouldPerformDownload && (url.scheme == "blob" || url.host == endpoint?.host && url.port == endpoint?.port) {
            decisionHandler(.download); return
        }
        if navigationAction.targetFrame?.isMainFrame != false && (url.host != endpoint?.host || url.port != endpoint?.port) {
            if navigationAction.navigationType == .linkActivated && ["https", "http"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { attach(download) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { attach(download) }
    private func attach(_ download: WKDownload) { download.delegate = self; downloads.append(download) }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = (suggestedFilename as NSString).lastPathComponent
        let completed: (NSApplication.ModalResponse) -> Void = { [weak self] result in
            if result == .OK, let url = panel.url {
                self?.downloadDestinations[ObjectIdentifier(download)] = url
                self?.downloadNotice = ""
                self?.downloadName = url.lastPathComponent; self?.downloadProgress = download.progress
                completionHandler(url)
            } else { completionHandler(nil); self?.finishDownload(download) }
        }
        if let window = web?.window { panel.beginSheetModal(for: window, completionHandler: completed) }
        else { panel.begin(completionHandler: completed) }
    }
    func downloadDidFinish(_ download: WKDownload) {
        if let url = downloadDestinations[ObjectIdentifier(download)] { downloadNotice = "Downloaded: " + url.path }
        finishDownload(download)
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if (error as NSError).code != NSURLErrorCancelled { self.error = "Download failed: " + error.localizedDescription }
        finishDownload(download)
    }
    private func finishDownload(_ download: WKDownload) {
        downloads.removeAll { $0 === download }
        downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
        if downloadProgress === download.progress { downloadProgress = downloads.last?.progress }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url, ["https", "http"].contains(url.scheme ?? "") else { return nil }
        // The editor's own "New Window" asks for another page of this very server. Handed to the
        // browser it lands on the server's sign-in page; what was meant is another Harbor window.
        if let page = webView.url, url.host == page.host, url.port == page.port {
            guard navigationAction.sourceFrame.isMainFrame else { return nil }
            let folder = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "folder" }?.value ?? ""
            if folder.hasPrefix("/"), !folder.contains("\0"), folder.utf8.count < 4096, let store {
                let profile = workspace.profile
                Task { await store.openFolderWorkspace(folder, profile: profile, newWindow: true) }
            } else { store?.workbenchUIRequest = "newWindow" }
            return nil
        }
        NSWorkspace.shared.open(url); return nil
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = parameters.allowsMultipleSelection; panel.canChooseDirectories = parameters.allowsDirectories
        panel.begin { completionHandler($0 == .OK ? panel.urls : nil) }
    }
    func receiveLayout(_ body: Any) {
        if let event = body as? [String: Any], let path = event["openFolder"] as? String {
            // Only folders shown in this workspace's own Explorer can be opened this way.
            let root = openedFolder.hasSuffix("/") ? openedFolder : openedFolder + "/"
            guard let store, path.hasPrefix(root), !path.contains("\0"), path.utf8.count < 4096,
                  !path.split(separator: "/").contains("..") else { return }
            let profile = workspace.profile, newWindow = event["newWindow"] as? Bool ?? false
            Task { await store.openFolderWorkspace(path, profile: profile, newWindow: newWindow) }
            return
        }
        if let event = body as? [String: Any], event["settingsEditor"] as? Bool == true {
            store?.presentSettings(fromEditor: event["query"] as? String)
            return
        }
        if let event = body as? [String: Any], let paths = event["terminalDrop"] as? [String] {
            // Paths dragged from the Explorer onto a terminal: typed there, quoted, not run.
            let safe = paths.prefix(64).filter { $0.hasPrefix("/") && $0.utf8.count < 4096 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }
            guard !safe.isEmpty, safe.count == paths.count else { return }
            let text = safe.map(SSHArguments.quote).joined(separator: " ") + " "
            Task { _ = try? await request("terminalInput", extra: ["text": text]) }
            return
        }
        if let event = body as? [String: Any], let focused = event["terminalFocused"] as? Bool {
            terminalFocused = focused
            workspace.focusArea = focused ? .terminal : .editor
            return
        }
        guard let value = body as? [String: Any], let visible = value["visible"] as? Bool else { return }
        let x = value["x"] as? Double ?? 0, y = value["y"] as? Double ?? 0
        let width = value["width"] as? Double ?? 0, height = value["height"] as? Double ?? 0
        let frame = visible ? CGRect(x: x, y: y, width: width, height: height) : .zero
        if terminalFrame != frame { terminalFrame = frame }
        let occluded = value["occluded"] as? Bool ?? false
        if terminalOccluded != occluded {
            terminalOccluded = occluded
            // A web dialog may open without a native mouse/key event. Never
            // let an invisible terminal continue to receive dialog input.
            if occluded, let web, let window = web.window,
               window.firstResponder is CapturingTerminal || window.firstResponder is TerminalListKeyView {
                window.makeFirstResponder(web)
            }
        }
        reportedPanelVisible = visible
        reportedPanelMaximized = value["maximized"] as? Bool ?? false
        guard workspace.enabled, panelInitialized, !changingPanel else { return }
        if workspace.terminalVisible != visible { workspace.terminalVisible = visible }
        if visible, workspace.terminalMaximized != reportedPanelMaximized { workspace.terminalMaximized = reportedPanelMaximized }
    }
    func updateTerminalPanel(force: Bool = false) async {
        // SwiftUI changes and keyboard actions can arrive in the same run loop.
        // Every caller awaits the final layout, rather than returning early while
        // a previous request is still changing the panel.
        let token = generation
        if let running = panelTask {
            await running.value
            guard generation == token, !Task.isCancelled else { return }
            // A request may arrive during the final focus command. Re-evaluate
            // the desired state after the preceding transition has completed.
            await updateTerminalPanel(force: force)
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if generation == token { panelTask = nil } }
            await applyTerminalPanel(force: force)
        }
        panelTask = task
        await task.value
    }
    private func applyTerminalPanel(force: Bool) async {
        guard commandsReady, !changingPanel else { return }
        var desired = (!workspace.enabled, workspace.terminalVisible, workspace.terminalMaximized)
        guard force || desired.0 != appliedTerminalMode || !desired.0 && (desired.1 != reportedPanelVisible || desired.1 && desired.2 != reportedPanelMaximized) else { return }
        let token = generation
        changingPanel = true
        beginLayoutTransition()
        defer {
            if generation == token { changingPanel = false; panelInitialized = true; endLayoutTransition() }
        }
        do {
            repeat {
                desired = (!workspace.enabled, workspace.terminalVisible, workspace.terminalMaximized)
                if desired.0 != appliedTerminalMode {
                    // The same WKWebView and PTYs stay mounted in both modes.
                    // Only the Code-OSS grid changes; editor tabs are not reloaded.
                    _ = try await localLayout(desired.0 ? "enterTerminalMode" : "leaveTerminalMode")
                    appliedTerminalMode = desired.0
                }
                if !desired.0 {
                    if !(try await localLayout("setTerminalPanel", options: ["visible": desired.1, "maximized": desired.2])) {
                        _ = try await request("terminalPanel", extra: ["visible": desired.1,
                            "toggleMaximized": desired.1 && desired.2 != reportedPanelMaximized])
                    }
                    reportedPanelVisible = desired.1
                    if desired.1 { reportedPanelMaximized = desired.2 }
                }
                guard generation == token, !Task.isCancelled else { return }
                _ = try await localLayout(desired.0 || workspace.focusArea == .terminal ? "focusTerminal" : "focusEditor")
                guard generation == token, !Task.isCancelled else { return }
            } while desired.0 != !workspace.enabled || desired.1 != workspace.terminalVisible || desired.2 != workspace.terminalMaximized
        } catch { if generation == token { report(error) } }
    }
    private func initialSettings() -> [String: Any] {
        ["workbench.colorTheme": themeName, "window.menuBarVisibility": "hidden", "window.commandCenter": false,
         "workbench.layoutControl.enabled": false, "workbench.startupEditor": "none", "workbench.tips.enabled": false,
         "workbench.experimental.modernUI": false,
         "workbench.shadows": false,
         "workbench.secondarySideBar.defaultVisibility": "hidden", "workbench.activityBar.location": "top",
         "workbench.activityBar.compact": true, "breadcrumbs.filePath": "last",
         "workbench.statusBar.visible": true, "workbench.panel.defaultLocation": "bottom", "workbench.editor.showTabs": "multiple", "workbench.editor.tabSizing": "shrink",
         "editor.fontSize": HarborTypography.value("editorFontSize"), "editor.fontFamily": "Menlo, Monaco, monospace",
         "terminal.integrated.enablePersistentSessions": true, "terminal.integrated.persistentSessionReviveProcess": "onExitAndWindowClose",
         "terminal.integrated.splitCwd": "inherited", "terminal.integrated.tabs.title": "${cwdFolder}",
         "terminal.integrated.enableBell": false, "terminal.integrated.smoothScrolling": false,
         "terminal.integrated.fontSize": HarborTypography.value("terminalFontSize"),
         "editor.minimap.enabled": false, "editor.stickyScroll.enabled": false, "editor.smoothScrolling": false,
         "editor.wordWrap": UserDefaults.standard.bool(forKey: "editorWrap") ? "on" : "off",
         "editor.quickSuggestions": ["other": "on", "comments": "off", "strings": "on"], "editor.suggest.preview": true,
         "editor.wordBasedSuggestions": "matchingDocuments", "files.hotExit": "onExitAndWindowClose",
         "telemetry.telemetryLevel": "off", "workbench.enableExperiments": false, "security.workspace.trust.enabled": true,
         "extensions.ignoreRecommendations": false,
         // Built-in assistant surfaces stay off; word and language-server completion stay on.
         "chat.disableAIFeatures": true, "chat.agent.enabled": false, "editor.inlineSuggest.enabled": false,
         "workbench.editor.empty.hint": "hidden", "terminal.integrated.initialHint": false, "chat.tips.enabled": false,
         "workbench.settings.showAISearchToggle": false, "chat.agentsControl.enabled": "hidden", "editor.aiStats.enabled": false,
         "search.followSymlinks": false,
         "files.watcherExclude": Self.watcherExclude]
    }
    /// Folders that tools fill and nobody edits (environments, caches, installed packages) are not
    /// watched: every watched folder costs one of the watches a server allows an account, and a
    /// project with a few environments in it has more folders than there are watches. The same
    /// list as the bridge's, which adds it to a profile that exists already.
    static let watcherExclude: [String: Bool] = Dictionary(uniqueKeysWithValues: [".venv", "venv", ".venvs", ".conda", ".tox", "site-packages", "node_modules",
        "__pycache__", ".cache", ".mypy_cache", ".pytest_cache", ".ruff_cache", ".ipynb_checkpoints", ".eggs", ".omc", "wandb"].map { ("**/" + $0 + "/**", true) })
    private func bundledExtensions() throws -> [String: [String: String]] {
        let bridge = try String(contentsOf: AppResources.directory("CodeWorkbench").appendingPathComponent("bridge.js"), encoding: .utf8)
        let configuration = try JSONSerialization.jsonObject(with: Data(contentsOf: AppResources.directory("CodeWorkbench").appendingPathComponent("harbor-settings-schema.json")))
        var result: [String: [String: String]] = ["harbor.workbench-" + Self.workbenchVersion: ["extension.js": bridge,
            "harbor-terminal.js": try String(contentsOf: AppResources.directory("CodeWorkbench").appendingPathComponent("harbor-terminal.js"), encoding: .utf8),
            "harbor-catalog.js": try String(contentsOf: AppResources.directory("CodeWorkbench").appendingPathComponent("harbor-catalog.js"), encoding: .utf8),
            "harbor-settings.js": try String(contentsOf: AppResources.directory("CodeWorkbench").appendingPathComponent("harbor-settings.js"), encoding: .utf8),
            "harbor-settings-schema.json": try String(contentsOf: AppResources.directory("CodeWorkbench").appendingPathComponent("harbor-settings-schema.json"), encoding: .utf8),
            "harbor-synced-settings.json": try String(contentsOf: AppResources.directory("CodeWorkbench").appendingPathComponent("harbor-synced-settings.json"), encoding: .utf8),
            "legacy-terminal-host.py": try String(contentsOf: AppResources.directory("WorkspaceRuntime").appendingPathComponent("terminal_host.py"), encoding: .utf8),
            "harbor-commands.js": try String(contentsOf: AppResources.directory("CodeWorkbench").appendingPathComponent("harbor-commands.js"), encoding: .utf8),
            "terminal.svg": "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\"><path fill=\"none\" stroke=\"#aaa\" stroke-width=\"1.5\" d=\"M3 5h18v14H3z M6 9l3 3-3 3 M12 15h5\"/></svg>",
            "package.json": try Self.json(["name": "workbench", "publisher": "harbor", "version": Self.workbenchVersion, "displayName": "Harbor Workbench",
                "engines": ["vscode": "^1.90.0"], "activationEvents": ["onStartupFinished"],
                // Harbor's places are commands (the Command Palette, the bar's menu); there is no view of its own in the sidebar.
                "contributes": ["configuration": configuration,
                    "commands": [["command": "harbor.addServer", "title": "Add Server…", "category": "Harbor", "icon": "$(add)"],
                        ["command": "harbor.settings", "title": "Settings", "category": "Harbor", "icon": "$(settings-gear)"],
                        ["command": "harbor.openFolder", "title": "Open Folder…", "category": "Harbor", "icon": "$(folder-opened)"],
                        ["command": "harbor.closeFolder", "title": "Close Folder", "category": "Harbor"],
                        ["command": "harbor.switchFolder", "title": "Switch Folder…", "category": "Harbor"],
                        ["command": "harbor.foldersInWindows", "title": "Folders in Windows…", "category": "Harbor"],
                        ["command": "harbor.startPage", "title": "Start Page", "category": "Harbor"],
                        ["command": "harbor.reverseProxy", "title": "Reverse Proxy", "category": "Harbor"],
                        ["command": "harbor.remoteDisplay", "title": "Remote Display", "category": "Harbor"],
                        ["command": "harbor.terminalMode", "title": "Terminal Mode", "category": "Harbor"],
                        ["command": "harbor.newTerminal", "title": "New Terminal", "category": "Harbor", "icon": "$(add)"],
                        ["command": "harbor.splitTerminal", "title": "Split Terminal", "category": "Harbor", "icon": "$(split-horizontal)"],
                        ["command": "harbor.toggleTerminal", "title": "Toggle Terminal", "category": "Harbor"],
                        ["command": "harbor.resumePreviousSession", "title": "Resume Previous Session…", "category": "Harbor"],
                        ["command": "harbor.renameTerminal", "title": "Rename Terminal…", "category": "Harbor"]]],
                "extensionKind": ["workspace"], "main": "./extension.js",
                "capabilities": ["untrustedWorkspaces": ["supported": true]]])]]
        let cursor = try JSONDecoder().decode([String: HarborTheme.Palette].self, from: Data(contentsOf: AppResources.directory("Themes").appendingPathComponent("cursor.json")))
        var files: [String: String] = [:], themes: [[String: String]] = []
        // The neutral pair, then a light and a dark theme for every family with palettes of its own.
        var entries: [(String, String, HarborTheme.Palette, Bool)] = [
            (HarborTheme.standard.editor + " Light", "vs", cursor["light"]!, false), (HarborTheme.standard.editor + " Dark", "vs-dark", cursor["dark"]!, false)]
        for family in HarborTheme.families where family.file != nil {
            let pair = HarborTheme.lightAndDark(of: family)
            entries.append((family.editor + " Light", "vs", pair["light"]!, true))
            entries.append((family.editor + " Dark", "vs-dark", pair["dark"]!, true))
        }
        for (name, style, palette, detailed) in entries {
            let filename = name + ".json"
            themes.append(["label": name, "uiTheme": style, "path": "./" + filename])
            files[filename] = try Self.json(["name": name, "type": style == "vs" ? "light" : "dark", "colors": palette.colors,
                "tokenColors": Self.tokenColors(palette, detailed: detailed), "semanticHighlighting": true])
        }
        files["package.json"] = try Self.json(["name": "themes", "publisher": "harbor", "version": Self.themesVersion, "displayName": "Harbor Themes", "engines": ["vscode": "^1.90.0"], "contributes": ["themes": themes]])
        result["harbor.themes-" + Self.themesVersion] = files; return result
    }
    /// Unit tests host the workbench view without launching a real editor
    /// service; integration tests start their session explicitly.
    static var launchesService = NSClassFromString("XCTestCase") == nil
    static let livenessInterval = 12.0, backgroundLivenessInterval = 30.0
    /// Must equal TERMINAL_RAIL_WIDTH in bootstrap.py.
    static let terminalRailWidth = 6
    static let workbenchVersion = "1.8.0"
    static let themesVersion = "1.3.0"
    /// TextMate rules for a palette. The neutral themes keep their original
    /// compact mapping; Claude and Harbor's own families add structure, properties and Markdown.
    static func tokenColors(_ palette: HarborTheme.Palette, detailed: Bool) -> [[String: Any]] {
        var rules: [(String, String, String?)] = [
            ("comment", "comment", nil), ("keyword", "keyword,storage", nil), ("string", "string", nil),
            ("number", "constant.numeric", nil), ("type", "entity.name.type,support.type", nil),
            ("function", "entity.name.function,support.function", nil), ("tag", "entity.name.tag", nil),
            ("constant", "constant", nil), ("variable", "variable", nil), ("heading", "markup.heading", nil),
            ("link", "markup.underline.link", nil)]
        if detailed {
            rules = [
                ("variable", "variable,variable.parameter,meta.definition.variable", nil),
                ("comment", "comment,punctuation.definition.comment,string.quoted.docstring,markup.quote", "italic"),
                ("keyword", "keyword,storage,storage.type,storage.modifier,keyword.operator.logical.python,keyword.operator.new,keyword.operator.expression,keyword.operator.wordlike,variable.language", nil),
                ("operator", "keyword.operator,punctuation,meta.brace,punctuation.separator,punctuation.terminator", nil),
                ("string", "string,markup.inline.raw,markup.fenced_code", nil),
                ("property", "string.regexp,constant.character.escape,variable.other.property,variable.other.object.property,variable.other.member,support.type.property-name,meta.object-literal.key,entity.other.attribute-name", nil),
                ("number", "constant.numeric", nil), ("constant", "constant.language,constant.other,support.constant,variable.other.constant", nil),
                ("type", "entity.name.type,entity.name.class,entity.other.inherited-class,support.type,support.class,entity.name.namespace", nil),
                ("function", "entity.name.function,support.function,meta.function-call.generic,entity.name.function.decorator,punctuation.definition.decorator", nil),
                ("tag", "entity.name.tag,punctuation.definition.tag", nil),
                ("heading", "markup.heading,entity.name.section", "bold"), ("variable", "markup.bold", "bold"), ("variable", "markup.italic", "italic"),
                ("link", "markup.underline.link,string.other.link", nil), ("invalid", "invalid", nil)]
        }
        return rules.map { key, scopes, style in
            var settings = ["foreground": palette.syntax[key] ?? "#808080"]
            if let style { settings["fontStyle"] = style }
            return ["scope": scopes.components(separatedBy: ","), "settings": settings]
        }
    }
    private static func json(_ value: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self) }
    private static let chromeStyle = """
        const s = document.createElement('style'); s.textContent = `
        .monaco-workbench .global-activity-actionbar { display: none !important; }
        .monaco-modal-editor-block:not(.harbor-shown):has(.settings-editor) { visibility: hidden !important; }
        .monaco-workbench .monaco-editor .find-widget { min-width: 460px; max-width: calc(100% - 24px); }
        .monaco-workbench .monaco-editor .find-widget .monaco-inputbox { font-size: 13px !important; }
        .monaco-workbench .monaco-editor .find-widget .monaco-inputbox textarea { min-height: 24px; }
        .monaco-workbench .terminal-editor .terminal-wrapper:not(.fixed-dims) .xterm-viewport,
        .monaco-workbench .pane-body.integrated-terminal .terminal-wrapper:not(.fixed-dims) .xterm-viewport { right: \(terminalRailWidth)px; }
        html.harbor-sash-dragging .webview-overlay-content > iframe.webview { width: var(--harbor-frozen-width, 100%) !important; }
        .harbor-folder-drop { position: absolute; inset: 10px; z-index: 60; display: flex; align-items: center; justify-content: center;
          pointer-events: none; border: 1.5px dashed var(--vscode-focusBorder); border-radius: 10px;
          background: color-mix(in srgb, var(--vscode-editor-background) 88%, transparent);
          color: var(--vscode-foreground); font-size: 13px; animation: harbor-fade 140ms ease-out; }
        @keyframes harbor-pop { from { opacity: 0; transform: translateY(-6px) scale(.985); } to { opacity: 1; transform: none; } }
        @keyframes harbor-fade { from { opacity: 0; } to { opacity: 1; } }
        html.harbor-motion-full .quick-input-widget { animation: harbor-pop 220ms cubic-bezier(.16, 1, .3, 1); }
        html.harbor-motion-full .monaco-dialog-box { animation: harbor-pop 260ms cubic-bezier(.16, 1, .3, 1); }
        html.harbor-motion-full .context-view .monaco-menu,
        html.harbor-motion-full .monaco-hover:not(.hidden) { animation: harbor-fade 140ms ease-out; }
        html.harbor-motion-subtle .quick-input-widget,
        html.harbor-motion-subtle .monaco-dialog-box { animation: harbor-fade 120ms ease-out; }
        html.harbor-motion-full .monaco-workbench .tabs-container > .tab,
        html.harbor-motion-full .monaco-workbench .action-item > .action-label,
        html.harbor-motion-full .monaco-workbench .monaco-button,
        html.harbor-motion-full .monaco-workbench .statusbar-item > a {
          transition: background-color 140ms ease-out, color 140ms ease-out, border-color 140ms ease-out;
        }
        /* A checkbox answers in 50 ms, as in the Claude kit (see HarborMotion.Feedback). */
        html:not(.harbor-motion-off) .monaco-workbench .monaco-custom-toggle.monaco-checkbox {
          transition: background-color 50ms ease-out, border-color 50ms ease-out;
        }
        `; document.head.appendChild(s);
        // The sidebar's minimum width is exactly the pinned activity row:
        // N icons plus the overflow arrow. Sizes come from the rendered row.
        const applyActivityWidth = () => {
          const count = Math.max(1, Math.min(12, globalThis.__harborActivityCount | 0 || 4));
          const item = document.querySelector('.part.sidebar .composite-bar .action-item');
          const size = item && item.offsetWidth > 0 ? item.offsetWidth : 26;
          const width = Math.round(count * size + 30 + 20);
          if (globalThis.__harborSidebarMinimumWidth === width) return false;
          globalThis.__harborSidebarMinimumWidth = width; return true;
        };
        window.__harborSetActivityCount = count => {
          globalThis.__harborActivityCount = count;
          applyActivityWidth();
          if (globalThis.__harborRelayoutActivity) globalThis.__harborRelayoutActivity();
        };
        applyActivityWidth();
        setTimeout(applyActivityWidth, 4000);
        // Extension panels are separate documents that re-lay out on every
        // width change. While a divider is dragged, hold each one at its width
        // and let it catch up when the pointer pauses or is released, so a
        // heavy panel cannot stall the drag.
        let frozenFrames = [], thawTimer = 0;
        const freezeFrames = () => {
          for (const frame of document.querySelectorAll('.webview-overlay-content > iframe.webview')) {
            const width = frame.parentElement.offsetWidth;
            if (width > 0) frame.style.setProperty('--harbor-frozen-width', width + 'px');
          }
        };
        const endSashDrag = () => {
          clearTimeout(thawTimer);
          document.documentElement.classList.remove('harbor-sash-dragging');
          for (const frame of frozenFrames) frame.style.removeProperty('--harbor-frozen-width');
          frozenFrames = [];
          window.removeEventListener('pointermove', onSashMove, true);
          window.removeEventListener('pointerup', endSashDrag, true);
          window.removeEventListener('pointercancel', endSashDrag, true);
        };
        const onSashMove = () => { clearTimeout(thawTimer); thawTimer = setTimeout(freezeFrames, 140); };
        document.addEventListener('pointerdown', event => {
          if (!(event.target instanceof Element) || !event.target.closest('.monaco-sash')) return;
          frozenFrames = [...document.querySelectorAll('.webview-overlay-content > iframe.webview')];
          if (!frozenFrames.length) return;
          freezeFrames();
          document.documentElement.classList.add('harbor-sash-dragging');
          window.addEventListener('pointermove', onSashMove, true);
          window.addEventListener('pointerup', endSashDrag, true);
          window.addEventListener('pointercancel', endSashDrag, true);
        }, true);
        window.__harborSetMotion = level => {
          const root = document.documentElement;
          if (!root || !root.classList) return;
          for (const name of ['full', 'subtle', 'off']) root.classList.toggle('harbor-motion-' + name, name === level);
        };
        window.__harborSetMotion(['full', 'subtle', 'off'].includes(globalThis.__harborMotion) ? globalThis.__harborMotion : 'full');
        let queued = false, last = '';
        const report = () => {
          queued = false;
          const panel = document.querySelector('.part.panel');
          const rect = panel?.getBoundingClientRect();
          const editor = document.querySelector('.part.editor')?.getBoundingClientRect();
          const visible = !!(rect && rect.width > 0 && rect.height > 0 && panel.checkVisibility());
          const value = {visible, x:rect?.x || 0,y:rect?.y || 0,width:rect?.width || 0,height:rect?.height || 0,
                         maximized:visible && (!editor || editor.height < 5)};
          const key = JSON.stringify(value);
          if (key !== last) { last = key; window.webkit.messageHandlers.harborLayout.postMessage(value); }
        };
        const schedule = () => { if (!queued) { queued = true; requestAnimationFrame(report); } };
        const observed = new WeakSet();
        const resize = new ResizeObserver(schedule);
        const attributes = new MutationObserver(schedule);
        const discover = () => {
          const parts = document.querySelectorAll('.part.panel,.part.editor,.part.sidebar');
          for (const element of parts) {
            if (observed.has(element)) continue;
            observed.add(element); resize.observe(element);
            attributes.observe(element, {attributes:true,attributeFilter:['style','class']});
          }
          schedule();
          return parts.length >= 3;
        };
        // Only discover stable grid parts during startup. Observing every editor
        // text/Markdown mutation caused repeated full-DOM scans while scrolling.
        if (!discover()) {
          const startup = new MutationObserver(() => { if (discover()) startup.disconnect(); });
          startup.observe(document.body, {subtree:true,childList:true});
          setTimeout(() => startup.disconnect(), 30000);
        }
        resize.observe(document.documentElement);
        window.addEventListener('harbor-layout', schedule);
        // Dragging a folder from Explorer onto the editor area opens it as its
        // own workspace (Option: in a new window). Files keep Code-OSS's behavior.
        let draggedFolder = null, dropHint = null;
        const editorPart = target => target instanceof Element ? target.closest('.part.editor') : null;
        const hideHint = () => { if (dropHint) { dropHint.remove(); dropHint = null; } };
        document.addEventListener('dragstart', event => {
          draggedFolder = null;
          const row = event.target instanceof Element ? event.target.closest('.explorer-folders-view .monaco-list-row') : null;
          const label = row && row.querySelector('.monaco-icon-label');
          if (!label || !label.classList.contains('folder-icon')) return;
          draggedFolder = {name: (row.querySelector('.label-name') || label).textContent || ''};
        }, true);
        document.addEventListener('dragend', () => { draggedFolder = null; draggedRow = false; hideHint(); }, true);
        // Explorer rows dropped on a terminal type their paths there, quoted for the shell.
        // WebKit withholds the resource list the editor's own handler reads, so the paths are
        // taken from the URI lists it does expose and the terminal is fed through Harbor.
        let draggedRow = false;
        document.addEventListener('dragstart', event => {
          draggedRow = !!(event.target instanceof Element && event.target.closest('.explorer-folders-view .monaco-list-row'));
        }, true);
        const terminalPart = target => target instanceof Element ? target.closest('.terminal-wrapper, .terminal-outer-container, .xterm') : null;
        const droppedPaths = transfer => {
          const resources = [];
          try { resources.push(...JSON.parse(transfer.getData('ResourceURLs') || '[]')); } catch (error) {}
          for (const type of ['application/vnd.code.uri-list', 'text/uri-list', 'text/plain']) {
            resources.push(...transfer.getData(type).split(/\\r?\\n/).filter(Boolean));
          }
          const paths = resources.map(value => {
            if (typeof value !== 'string') return '';
            if (value.startsWith('/')) return value;
            try { return decodeURIComponent(new URL(value).pathname); } catch (error) { return ''; }
          }).filter(path => path.startsWith('/'));
          return [...new Set(paths)];
        };
        for (const type of ['dragenter', 'dragover']) {
          document.addEventListener(type, event => {
            if (!draggedRow || !terminalPart(event.target)) return;
            event.preventDefault(); event.stopPropagation();
            if (event.dataTransfer) event.dataTransfer.dropEffect = 'copy';
          }, true);
        }
        document.addEventListener('drop', event => {
          const part = draggedRow && terminalPart(event.target);
          if (!part) return;
          event.preventDefault(); event.stopPropagation(); draggedRow = false;
          const paths = droppedPaths(event.dataTransfer);
          window.__harborLastDrop = paths;
          if (!paths.length) return;
          // The terminal dropped on becomes the active one before the text is sent.
          const input = (part.closest('.terminal-wrapper') || part).querySelector('.xterm-helper-textarea');
          if (input) input.focus();
          window.webkit.messageHandlers.harborLayout.postMessage({terminalDrop: paths.slice(0, 64)});
        }, true);
        for (const type of ['dragenter', 'dragover']) {
          document.addEventListener(type, event => {
            const part = draggedFolder && editorPart(event.target);
            if (!part) { if (type === 'dragover') hideHint(); return; }
            event.preventDefault(); event.stopPropagation();
            if (event.dataTransfer) event.dataTransfer.dropEffect = 'copy';
            if (!dropHint) { dropHint = document.createElement('div'); dropHint.className = 'harbor-folder-drop'; part.appendChild(dropHint); }
            const text = 'Open “' + draggedFolder.name + (event.altKey ? '” in a new window' : '” as a workspace');
            if (dropHint.textContent !== text) dropHint.textContent = text;
          }, true);
        }
        document.addEventListener('drop', event => {
          const part = draggedFolder && editorPart(event.target);
          if (!part) return;
          event.preventDefault(); event.stopPropagation();
          const name = draggedFolder.name; draggedFolder = null; hideHint();
          // Explorer publishes the dragged resources as URI lists; the plain
          // text form already holds file-system paths.
          const transfer = event.dataTransfer, resources = [];
          try { resources.push(...JSON.parse(transfer.getData('ResourceURLs') || '[]')); } catch (error) {}
          for (const type of ['application/vnd.code.uri-list', 'text/uri-list', 'text/plain']) {
            resources.push(...transfer.getData(type).split(/\\r?\\n/).filter(Boolean));
          }
          const paths = resources.map(value => {
            if (typeof value !== 'string') return '';
            if (value.startsWith('/')) return value;
            try { return decodeURIComponent(new URL(value).pathname); } catch (error) { return ''; }
          }).filter(path => path.startsWith('/') && path.split('/').pop() === name);
          if (paths.length) window.webkit.messageHandlers.harborLayout.postMessage({openFolder: paths[0], newWindow: event.altKey === true});
        }, true);
        // Input methods in the terminal. Pressing a key the input method does not consume while it
        // is composing (Caps Lock or Globe to switch the input source) makes xterm.js send the
        // composition at once, and WebKit then ends the composition with the same text, which
        // xterm.js sends again: typing "ls" in pinyin and switching became "l sl s". Such keys are
        // kept from xterm.js, so the text is sent once, when the composition ends. Unconverted
        // pinyin committed by the switch also loses the syllable spaces, as it does with Return.
        const imeLog = window.__harborImeLog = [];
        let imeSwitchAt = -1;
        const terminalInput = target => !!(target && target.classList && target.classList.contains('xterm-helper-textarea'));
        // Text an input method inserts without composing (full-width punctuation in pinyin) reaches
        // WebKit before the key that produced it. xterm.js takes such text only while it believes no
        // key is down, and a held Shift counts: "？" and "：" were dropped until the key was pressed
        // again. When text arrives that no ordinary key press announced, xterm.js is told the keys
        // are up (a key-up it alone sees), so it accepts the text. Ordinary typing announces itself
        // with its key first and is left alone.
        let announced = false, releasing = false;
        const modifierCodes = [16, 17, 18, 20, 91, 93];
        for (const type of ['compositionstart', 'compositionupdate', 'compositionend', 'input', 'keydown', 'keyup']) {
          document.addEventListener(type, event => {
            if (!terminalInput(event.target) || releasing) return;
            if (type === 'keyup') { announced = false; return; }
            if (type === 'keydown' && !event.isComposing && event.keyCode !== 229 && !modifierCodes.includes(event.keyCode)) announced = true;
            if (type === 'input') {
              const direct = event.inputType === 'insertText' && !!event.data && !event.isComposing && !announced;
              announced = false;
              if (direct) {
                releasing = true;
                try { event.target.dispatchEvent(new KeyboardEvent('keyup', {key: 'Unidentified', bubbles: false, cancelable: false})); } finally { releasing = false; }
              }
            }
            const now = performance.now();
            if (imeLog.push([type, event.inputType || event.key || '', event.data == null ? null : String(event.data), !!event.isComposing, event.keyCode || 0, Math.round(now)]) > 80) imeLog.shift();
            if (type === 'keydown' && event.isComposing && event.keyCode !== 229 && ![16, 17, 18].includes(event.keyCode)) {
              imeSwitchAt = now; event.stopImmediatePropagation();
            } else if (type === 'compositionend' && now - imeSwitchAt < 1000) {
              imeSwitchAt = -1;
              const text = event.data || '', field = event.target;
              if (/^[A-Za-z']+( [A-Za-z']+)+$/.test(text) && typeof field.value === 'string' && field.value.endsWith(text)) {
                field.value = field.value.slice(0, -text.length) + text.split(' ').join('');
              }
            }
          }, true);
        }
        // Harbor's Settings panel stands in for the editor's own Settings editor, which opens in a
        // modal block. Hold each new block back until it shows something else, so that editor is
        // never drawn; tell Harbor at once and close the block here, not after a trip to the server.
        const holdModal = block => {
          block.style.visibility = 'hidden';
          let handled = false;
          const reveal = () => { block.style.visibility = ''; };
          const timer = setTimeout(reveal, 1200);
          const inspect = () => {
            const settings = block.querySelector('.settings-editor');
            if (!settings) { handled = false; if (block.querySelector('.editor-instance > *')) { clearTimeout(timer); reveal(); } return; }
            if (handled) return;
            handled = true; clearTimeout(timer);
            window.webkit.messageHandlers.harborLayout.postMessage({settingsEditor: true});
            setTimeout(() => {
              // An extension's gear opens it filtered to that extension; the panel takes the filter over.
              const query = (settings.querySelector('.settings-header .view-lines')?.textContent || '').replace(/\\u00a0/g, ' ').trim();
              if (query.startsWith('@')) window.webkit.messageHandlers.harborLayout.postMessage({settingsEditor: true, query: query.slice(0, 200)});
              block.querySelector('.modal-editor-header .codicon-close')?.click();
            }, 80);
            // Should neither this click nor the extension close it, an unseen block must not
            // keep the workbench out of reach: show it after all.
            setTimeout(() => { if (block.isConnected && block.querySelector('.settings-editor')) block.classList.add('harbor-shown'); }, 5000);
          };
          const watcher = new MutationObserver(inspect);
          watcher.observe(block, {subtree: true, childList: true});
          inspect();
        };
        const watchModals = () => {
          const workbench = document.querySelector('.monaco-workbench');
          if (!workbench) return false;
          new MutationObserver(records => {
            for (const record of records) for (const node of record.addedNodes) {
              if (node.classList?.contains('monaco-modal-editor-block')) holdModal(node);
            }
          }).observe(workbench, {childList: true});
          return true;
        };
        // Only the workbench element's own children are watched; it exists a moment after the page.
        const awaitWorkbench = tries => { if (!watchModals() && tries > 0) setTimeout(() => awaitWorkbench(tries - 1), 500); };
        awaitWorkbench(120);
        let terminalFocused = false;
        document.addEventListener('focusin', () => {
          const focused = !!document.activeElement?.closest('.terminal-wrapper,.terminal-outer-container,.terminal-tabs-list,.xterm');
          if (terminalFocused !== focused) {
            terminalFocused = focused;
            window.webkit.messageHandlers.harborLayout.postMessage({terminalFocused:focused});
          }
        }, true);

        """
}

/// The editor's clipboard is this Mac's pasteboard.
///
/// A web page may read the clipboard only with a permission that an embedded view has no way to
/// give: for text that came from another application WebKit wants its own "Paste" bubble
/// clicked, and refuses the read otherwise. The editor's terminal pastes by reading the
/// clipboard, so Command+V there ended in "Unable to read from the browser's clipboard" whenever
/// the text had been copied anywhere else. The page is Harbor's own editor, not a website: it
/// reads and writes the pasteboard as a desktop editor does. Only its top frame on its own
/// address is answered, so nothing an extension shows inside a frame can ask.
final class WorkbenchClipboard: NSObject, WKScriptMessageHandlerWithReply {
    weak var session: CodeWorkbenchSession?
    init(_ session: CodeWorkbenchSession) { self.session = session }
    /// More than anyone copies; a page that sends more than this is not copying text.
    static let limit = 32 * 1024 * 1024
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        let origin = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame, let session, session.serves(host: origin.host, port: origin.port), let body = message.body as? [String: Any] else {
            replyHandler(nil, "refused"); return
        }
        let answer = Self.answer(body, pasteboard: Self.pasteboard)
        replyHandler(answer.value, answer.error)
    }
    /// The Mac's pasteboard. (A debug build can be pointed at one of its own, so that looking at
    /// this does not put anything on the clipboard of whoever is at the Mac.)
    static var pasteboard: NSPasteboard {
        #if DEBUG
        if let name = UserDefaults.standard.string(forKey: "qaPasteboard"), !name.isEmpty { return NSPasteboard(name: NSPasteboard.Name(name)) }
        #endif
        return .general
    }
    /// What the page asked for: {"action": "read"} is answered with the text on the pasteboard
    /// ("" when it holds none), {"action": "write", "text": …} puts the text there.
    static func answer(_ request: [String: Any], pasteboard: NSPasteboard) -> (value: Any?, error: String?) {
        switch request["action"] as? String {
        case "read": return (pasteboard.string(forType: .string) ?? "", nil)
        case "write":
            guard let text = request["text"] as? String, text.utf8.count <= limit else { return (nil, "refused") }
            pasteboard.clearContents()
            return pasteboard.setString(text, forType: .string) ? (true, nil) : (nil, "the pasteboard did not take the text")
        default: return (nil, "unknown")
        }
    }
    /// Before the page's own scripts: reading and writing text go to the app. Pictures and other
    /// kinds (`read`, `write`) stay the page's own, as does a paste the keyboard delivers as an event.
    /// The workbench is patched to use these two for the terminal's own copies as well (bootstrap.py):
    /// Command+C and Copy there, and what a program in the terminal copies with OSC 52.
    static let script = """
        (() => {
          const bridge = globalThis.webkit?.messageHandlers?.harborClipboard, clipboard = navigator.clipboard;
          if (!bridge || !clipboard) return;
          const define = (name, value) => { try { Object.defineProperty(clipboard, name, {value, configurable: true, writable: true}); } catch {} };
          define('readText', () => bridge.postMessage({action: 'read'}).then(text => typeof text === 'string' ? text : ''));
          define('writeText', text => bridge.postMessage({action: 'write', text: String(text)}).then(() => undefined));
        })();
        """
}

private final class WeakWorkbenchLayout: NSObject, WKScriptMessageHandler {
    weak var session: CodeWorkbenchSession?
    init(_ session: CodeWorkbenchSession) { self.session = session }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else { return }
        session?.receiveLayout(message.body)
    }
}

@MainActor extension AppStore {
    /// ⌘, is Harbor's wherever the keyboard is. Left to the page, the editor would first load and
    /// show its own Settings editor, and only then could the panel take its place.
    func handleSettingsKey(_ event: NSEvent) -> Bool {
        // By what is on the key: on Dvorak the key in the comma's place is W, and ⌘W is not Settings.
        guard event.modifierFlags.intersection(WorkspaceShortcut.modifierMask) == .command,
              TerminalKeyboardCommand.isKey(event, ",", code: 43) else { return false }
        if !event.isARepeat { settingsVisible.toggle() }
        return true
    }
    /// ⇧⌘N is another Harbor window (the editor's own would be a browser page), ⇧⌘H is Harbor's
    /// start page (the editor would open Replace in Files on it), and ⌘1…⌘9 choose among windows
    /// gathered as tabs of one. With a single window ⌘1… keep their other meanings.
    func handleWindowKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(WorkspaceShortcut.modifierMask)
        if flags == [.command, .shift], TerminalKeyboardCommand.isKey(event, "n", code: 45) {
            if !event.isARepeat { workbenchUIRequest = "newWindow" }
            return true
        }
        if flags == [.command, .shift], TerminalKeyboardCommand.isKey(event, "h", code: 4) {
            if !event.isARepeat { page = .recent }
            return true
        }
        guard flags == .command, let index = TerminalKeyboardCommand.groupIndex(for: event.keyCode),
              let tabs = (event.window ?? window)?.tabbedWindows, tabs.count > 1 else { return false }
        // As in a browser, ⌘9 is the last tab however many there are.
        if !event.isARepeat, let tab = index == 8 ? tabs.last : (index < tabs.count ? tabs[index] : nil) { tab.makeKeyAndOrderFront(nil) }
        return true
    }
    /// The page saw the editor's own Settings editor about to appear (Command Palette, an
    /// extension's gear) and held it back. `query` is the filter it was opened with.
    func presentSettings(fromEditor query: String?) {
        settingsEditorSeen = Date()
        if let query, !query.isEmpty, query.count <= 200 { settingsQuery = query }
        settingsVisible = true
    }
    func handleCodeWorkbenchKey(_ event: NSEvent) -> Bool {
        guard page == .workspace,
              workspaceOwner == nil else { return false }
        let flags = event.modifierFlags.intersection(WorkspaceShortcut.modifierMask)
        if event.keyCode == 11, flags == .command {
            if !event.isARepeat { codeWorkbench.existing(for: currentFiles)?.command("workbench.action.toggleSidebarVisibility") }
            return true
        }
        let responder = event.window?.firstResponder ?? NSApp.keyWindow?.firstResponder
        if let editor = codeWorkbench.existing(for: currentFiles), editor.focused,
           editor.terminalFocused, flags == .command, (event.keyCode == 2 || event.keyCode == 4) {
            if !event.isARepeat { editor.command("workbench.action.terminal.split") }
            return true
        }
        if flags == .command, (event.keyCode == 2 || event.keyCode == 4) {
            let scope = currentTerminalScope
            let source: TerminalSession?
            if let list = responder as? TerminalListKeyView, list.store === self, list.scope == scope,
               currentFiles.enabled, currentFiles.terminalVisible {
                source = selectedTerminal(in: scope)
            } else if let view = responder as? NSView {
                source = terminalSessions(in: scope).first {
                    isTerminalPresented($0, in: scope) && (view === $0.terminal || view.isDescendant(of: $0.terminal))
                }
            } else { source = nil }
            guard let source else { return false }
            if !event.isARepeat { splitTerminal(event.keyCode == 2 ? .columns : .rows, session: source) }
            return true
        }
        if event.keyCode == 38, flags == .command {
            if !event.isARepeat { toggleTerminalPanel() }; return true
        }
        if event.keyCode == 50, flags == .control {
            if !event.isARepeat { toggleWorkspaceFocus() }; return true
        }
        return false
    }
}

/// The editor's web view. Folders dragged in from Finder are taken here: the page is given no
/// paths for them, so it could do nothing with them, while Harbor can.
final class WorkbenchWebView: WKWebView {
    /// The folders and where they were let go, in the page's own coordinates.
    var foldersDropped: (([URL], CGPoint) -> Void)?
    private func folders(_ sender: NSDraggingInfo) -> [URL]? {
        // A drag that began inside the page (an Explorer row) stays the page's.
        guard foldersDropped != nil, sender.draggingSource == nil else { return nil }
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty, urls.count <= 16, urls.allSatisfy({ (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) else { return nil }
        return urls
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { folders(sender) != nil ? .copy : super.draggingEntered(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { folders(sender) != nil ? .copy : super.draggingUpdated(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { if sender.flatMap(folders) == nil { super.draggingExited(sender) } }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { folders(sender) != nil || super.prepareForDragOperation(sender) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = folders(sender) else { return super.performDragOperation(sender) }
        let point = convert(sender.draggingLocation, from: nil)
        let zoom = max(pageZoom, 0.01)
        foldersDropped?(urls, CGPoint(x: point.x / zoom, y: (isFlipped ? point.y : bounds.height - point.y) / zoom))
        return true
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { if sender.flatMap(folders) == nil { super.concludeDragOperation(sender) } }
}

@MainActor extension CodeWorkbenchSession {
    /// Folders from Finder let go over the editor. On a terminal their paths are typed, quoted, as
    /// Terminal does; anywhere else they open as this window's workspace.
    func dropped(_ urls: [URL], at point: CGPoint) {
        guard let web, let store else { return }
        let script = """
        (() => { const e = document.elementFromPoint(\(point.x), \(point.y));
          const part = e && e.closest('.terminal-wrapper, .terminal-outer-container, .xterm');
          if (!part) return false;
          const input = (part.closest('.terminal-wrapper') || part).querySelector('.xterm-helper-textarea');
          if (input) input.focus();
          return true; })()
        """
        web.evaluateJavaScript(script) { [weak self] result, _ in
            Task { @MainActor in
                if result as? Bool == true {
                    let paths = urls.map(\.path).filter { !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }
                    guard paths.count == urls.count else { return }
                    _ = try? await self?.request("terminalInput", extra: ["text": paths.map(SSHArguments.quote).joined(separator: " ") + " "])
                } else { store.openLocal(urls: urls) }
            }
        }
    }
}
