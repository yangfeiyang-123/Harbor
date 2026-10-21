import SwiftUI
import AppKit
import HarborCore

/// One folder on one machine: the identity the editor, its terminals and the
/// recents list hang off. Code-OSS owns files, tabs and unsaved edits; this
/// model keeps only what Harbor itself decides — which folder, whether the
/// window is in terminal mode, and a directory service for the folder browser.
@MainActor final class FileWorkspace: ObservableObject {
    enum FocusArea { case editor, terminal, terminalList, servers }
    @Published var focusRequest = UUID()
    var focusArea = FocusArea.editor
    func requestFocus(_ area: FocusArea) {
        if area == .editor { terminalMaximized = false }
        focusArea = area; focusRequest = UUID()
    }
    private(set) var profile: ServerProfile?
    /// The server's settings were edited. The folder is the same one (its identity is the
    /// server's, not its address); whatever connects for it from now on uses the new settings.
    func adopt(_ edited: ServerProfile) {
        guard profile?.id == edited.id, profile != edited else { return }
        profile = edited; service = nil
    }
    /// Server and folder: what a window shows, and what only one window shows at a time.
    var claimKey: String { WorkspaceSwitcher.identity(profileID: profile?.id, root: root, fallback: key) }
    let directoryID: UUID?
    let key: String
    @Published var root = ""
    @Published var recent: [String] = []
    /// False while the window shows terminal mode (the editor column is hidden).
    @Published var enabled = false { didSet { if enabled && !oldValue { terminalVisible = true }; persist() } }
    @Published var terminalVisible = true
    @Published var terminalMaximized = false
    func setTerminalMaximized(_ maximized: Bool) {
        if maximized { terminalVisible = true }
        terminalMaximized = maximized
        requestFocus(maximized ? .terminal : .editor)
    }
    @Published var busy = false
    @Published var error: String?
    @Published var showHidden = false
    var service: WorkspaceFileService?
    var onNavigate: ((String) -> Void)?
    private var navigating = UUID()
    private let defaults: UserDefaults
    private let cache: URL

    init(profile: ServerProfile?, defaults: UserDefaults = .standard, directoryID: UUID? = nil) {
        self.profile = profile; self.directoryID = directoryID
        key = "workspace." + (profile?.id.uuidString ?? "local") + (directoryID.map { ".directory." + $0.uuidString } ?? "")
        self.defaults = defaults
        root = defaults.string(forKey: key + ".root") ?? ""
        recent = defaults.stringArray(forKey: key + ".recent") ?? []
        enabled = defaults.bool(forKey: key + ".enabled")
        cache = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-workspace-" + UUID().uuidString)
    }
    deinit { try? FileManager.default.removeItem(at: cache) }
    func cleanCache() { try? FileManager.default.removeItem(at: cache) }
    func persist() {
        defaults.set(enabled, forKey: key + ".enabled")
        defaults.set(root, forKey: key + ".root")
        defaults.set(recent, forKey: key + ".recent")
    }
    /// Connects the directory service used to validate and browse folders.
    func prepare(store: AppStore) async {
        guard service == nil else { return }
        do {
            let socket = try await profile.mapAsync { try await store.resolveSocket($0) }
            let runtime = AppResources.directory("WorkspaceRuntime").appendingPathComponent("files.py")
            let script = try await Task.detached { try String(contentsOf: runtime, encoding: .utf8) }.value
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let relay: TransferRelayLookup? = profile.map { server in { @Sendable in await ManagedRelay.port(for: server) } }
            service = WorkspaceFileService(profile: profile, socket: socket, script: script, cache: cache, relay: relay)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func navigate(_ path: String) async {
        guard let service else { return }
        let request = UUID(); navigating = request; busy = true; error = nil
        do {
            let listing = try await service.list(path, showHidden: showHidden)
            guard navigating == request else { return }
            adoptRootListing(listing)
        } catch { if navigating == request { self.error = friendly(error) } }
        if navigating == request { busy = false }
    }
    func adoptRootListing(_ listing: WorkspaceListing) {
        root = listing.path
        recent = [root] + recent.filter { $0 != root }.prefix(11); persist(); onNavigate?(root)
    }
    func forget(_ path: String) { recent.removeAll { $0 == path }; persist() }
    private func friendly(_ error: Error) -> String {
        let message = error.localizedDescription
        if WorkspaceSSHConnection.refusedBeforeExecution(message) {
            return "The server refused a new file session. Existing terminals are still connected. Retry to open a separate file connection."
        }
        if message.contains("Connection") || message.contains("mux_client") || message.contains("closed by") {
            return "The file connection is not ready. Open a terminal to complete SSH authentication, then retry.\n" + message
        }
        if message.contains("python3") && message.contains("not found") { return "Browsing folders on this server requires Python 3. Terminals are still available." }
        return message
    }
}
extension Optional {
    func mapAsync<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        if let value = self { return try await transform(value) }; return nil
    }
}
