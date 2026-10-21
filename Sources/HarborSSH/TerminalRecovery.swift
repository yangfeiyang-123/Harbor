import AppKit
import HarborCore
import SwiftTerm

struct RecoveredTerminal: Codable {
    var id: UUID
    var serverID: UUID?
    var title: String
    var customTitle: String?
    var initialDirectoryTitle: String?
    var directory: String?
    var directoryWorkspaceID: UUID?
    var windowID: UUID?
    /// The plain terminal page it belongs to (a server's identifier): it comes back on that page, not as a window.
    var home: String? = nil
    var tmuxName: String?
    var remotePTYID: UUID? = nil
    var remotePTYStarted: Bool? = nil
    var tabWidth: Double?
    var columns: Int
    var rows: Int
}
struct TerminalRecoveryManifest: Codable {
    var version = 1
    var terminals: [RecoveredTerminal]
    var layouts: [TerminalScope: TerminalArrangement]
    var selected: UUID?
}

/// One bounded rendered snapshot per open terminal, not an unbounded command log.
/// A serial queue writes snapshots before the manifest and prunes only after commit.
final class TerminalRecoveryStore: @unchecked Sendable {
    static let outputLimit = 8 * 1024 * 1024
    let root: URL
    private let queue = DispatchQueue(label: "app.harbor.terminal-recovery", qos: .utility)
    init(root: URL) { self.root = root }
    func load() throws -> (TerminalRecoveryManifest?, [UUID: String]) {
        try queue.sync {
            let url = root.appendingPathComponent("manifest.json")
            guard FileManager.default.fileExists(atPath: url.path) else { return (nil, [:]) }
            let manifest = try JSONDecoder().decode(TerminalRecoveryManifest.self, from: Data(contentsOf: url))
            guard manifest.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
            var output: [UUID: String] = [:]
            for item in manifest.terminals {
                let file = root.appendingPathComponent(item.id.uuidString + ".txt")
                // Missing/corrupt snapshots must not be silently replaced with empty output.
                let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
                let size = try handle.seekToEnd()
                if size > Self.outputLimit { throw CocoaError(.fileReadTooLarge) }
                try handle.seek(toOffset: 0)
                output[item.id] = String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
            }
            return (manifest, output)
        }
    }
    func save(_ manifest: TerminalRecoveryManifest, output: [UUID: String], synchronously: Bool, completion: @escaping (Error?) -> Void) -> Bool {
        let work = { [self] in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for (id, text) in output { try write(Data(text.utf8), to: root.appendingPathComponent(id.uuidString + ".txt")) }
            try write(JSONEncoder().encode(manifest), to: root.appendingPathComponent("manifest.json"))
            let keep = Set(manifest.terminals.map { $0.id.uuidString + ".txt" })
            for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where url.pathExtension == "txt" && !keep.contains(url.lastPathComponent) {
                try FileManager.default.removeItem(at: url)
            }
        }
        if synchronously {
            do { try queue.sync(execute: work); return true }
            catch { completion(error); return false }
        }
        queue.async { do { try work(); completion(nil) } catch { completion(error) } }
        return true
    }
    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

extension TerminalSession {
    /// Snapshot rendered text rather than replaying PTY escape sequences: reconnect
    /// must never repeat OSC clipboard operations, queries or terminal resets.
    func recoveryOutput() -> String {
        let model = terminal.getTerminal()
        var text = model.getRecoveryText(kind: .normal)
        if model.isCurrentBufferAlternate {
            let alternate = model.getRecoveryText(kind: .alt)
            if !alternate.isEmpty { text += "\n\n[Last application screen]\n" + alternate }
        }
        // An application can clear its terminal on attach. Keep the previous
        // disconnect snapshot available separately through View Saved Output.
        if !savedOutput.isEmpty && !text.contains(savedOutput) {
            text = savedOutput + "\n\n[Following connection]\n" + text
        }
        let bytes = Data(text.utf8)
        if bytes.count > TerminalRecoveryStore.outputLimit {
            text = "[Earlier output exceeded the 8 MB recovery limit.]\n" + String(decoding: bytes.suffix(TerminalRecoveryStore.outputLimit - 128), as: UTF8.self)
        }
        return text
    }
    func restoreOutput(_ text: String) {
        savedOutput = text
        // Do not interpret control characters present in a saved text file.
        let safe = String(text.unicodeScalars.filter { ($0.value >= 0x20 && !(0x7f...0x9f).contains($0.value)) || $0 == "\n" || $0 == "\t" })
        terminal.feed(text: safe.replacingOccurrences(of: "\n", with: "\r\n") + (safe.isEmpty ? "" : "\r\n"))
        terminal.scheduleDisplayRepair()
        recoveryDirty = true
    }
    /// Replayed raw output is bounded on the server. Put any missing earlier
    /// snapshot into real scrollback, rather than an in-band "saved" message.
    func finishHistoryReplay() {
        let model = terminal.getTerminal()
        let current = model.getRecoveryText(kind: .normal)
        let missing = Self.historyPrefix(saved: savedOutput, replayed: current)
        model.prependRecoveryScrollback(missing)
        recoveryDirty = true
    }
    static func historyPrefix(saved: String, replayed: String) -> String {
        guard !saved.isEmpty, !replayed.contains(saved) else { return "" }
        guard !replayed.isEmpty else { return saved }
        // Longest overlap between the saved suffix and replayed prefix, in O(n).
        let previous = saved.components(separatedBy: "\n")
        let current = replayed.components(separatedBy: "\n")
        let lines: [String?] = current.map(Optional.some) + [nil] + previous.map(Optional.some)
        var lengths = [Int](repeating: 0, count: lines.count)
        for i in 1..<lines.count {
            var j = lengths[i - 1]
            while j > 0 && lines[i] != lines[j] { j = lengths[j - 1] }
            if lines[i] == lines[j] { j += 1 }
            lengths[i] = j
        }
        return previous.dropLast(min(previous.count, lengths.last ?? 0)).joined(separator: "\n")
    }
    func showSavedOutput() {
        let text = savedOutput.isEmpty ? recoveryOutput() : savedOutput
        let window = savedOutputWindow ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "Saved Output · " + displayTitle
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        let view = NSTextView(); view.isEditable = false; view.isSelectable = true
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.string = text; view.textContainerInset = NSSize(width: 12, height: 12)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        scroll.documentView = view; window.contentView = scroll
        view.frame = scroll.contentView.bounds; savedOutputWindow = window
        window.center(); window.makeKeyAndOrderFront(nil)
    }
}

extension AppStore {
    func startRecoveryCheckpoints() {
        guard recoveryTimer == nil else { return }
        recoveryTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkpointTerminals() }
        }
    }
    @discardableResult func checkpointTerminals(synchronously: Bool = false) -> Bool {
        guard recoveryWritable, !shuttingDown else { return recoveryWritable }
        var output: [UUID: String] = [:], items: [RecoveredTerminal] = [], layouts: [TerminalScope: TerminalArrangement] = [:]
        // Every terminal that can be returned to is kept. A plain terminal (Start page ▸ New
        // Terminal) on a server is one: its shell goes on there, and its page comes back to it.
        // One on this Mac ends with Harbor. A further window has no saved state of its own, so
        // what it holds is written here as well and comes back as a terminal window.
        for store in [self] + Self.all.filter({ $0.primary === self && !$0.shuttingDown }) {
            let homes = Dictionary(store.homeTerminalScopes.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
            var kept = Set<TerminalScope>()
            for session in store.sessions {
                let home = session.windowID.flatMap { homes[$0] }
                if home != nil, session.remotePTYID == nil { continue }
                if store !== self, home == nil { continue }
                if session.recoveryDirty || synchronously {
                    output[session.id] = session.recoveryOutput(); session.recoveryDirty = false
                }
                let model = session.terminal.getTerminal()
                items.append(RecoveredTerminal(id: session.id, serverID: session.profile?.id, title: session.title,
                    customTitle: session.customTitle, initialDirectoryTitle: session.initialDirectoryTitle,
                    directory: session.effectiveDirectory, directoryWorkspaceID: session.directoryWorkspaceID,
                    windowID: session.windowID, home: store === self ? home : nil, tmuxName: session.tmuxName,
                    // A shell the server no longer has is not asked for again after a restart either.
                    remotePTYID: session.remotePTYGone ? session.nextPTYID : session.remotePTYID,
                    remotePTYStarted: !session.remotePTYGone && session.remotePTYReconnect, tabWidth: session.tabWidth,
                    columns: model.cols, rows: model.rows))
                kept.insert(store.terminalScope(of: session))
            }
            for (scope, layout) in store.terminalLayouts where kept.contains(scope) { layouts[scope] = layout }
        }
        let manifest = TerminalRecoveryManifest(terminals: items, layouts: layouts, selected: selectedSessionID)
        return recoveryStore.save(manifest, output: output, synchronously: synchronously) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                guard let self else { return }
                for store in self.family { store.sessions.forEach { $0.recoveryDirty = true } }
                self.errorMessage = "Unable to save terminal output: " + error.localizedDescription
            }
        }
    }
    /// Whether quitting has to be asked about because the terminals could not be saved. With the
    /// recovery files unreadable nothing is written at all (they are kept as they are, which was
    /// said at launch), and that is no reason to refuse to quit.
    func terminalsUnsavedAtQuit() -> Bool { recoveryWritable && !checkpointTerminals(synchronously: true) }
    func restoreTerminals() async {
        guard sessions.isEmpty else { return }
        do {
            let disk = recoveryStore
            let (manifest, output) = try await Task.detached(priority: .utility) { try disk.load() }.value
            guard let manifest else { return }
            for item in manifest.terminals {
                let profile = profiles.first { $0.id == item.serverID }
                guard item.serverID == nil || profile != nil else { continue }
                let session = try TerminalSession(id: item.id, profile: profile, title: item.title, detached: item.windowID != nil, history: history, tmuxName: item.tmuxName, workingDirectory: item.directory, remotePTYID: item.remotePTYID)
                // Old plain SSH sessions have no remote host to reconnect to.
                session.remotePTYID = item.remotePTYID
                session.remotePTYReconnect = item.remotePTYID != nil && (item.remotePTYStarted ?? true)
                session.directoryWorkspaceID = item.directoryWorkspaceID; session.windowID = item.windowID
                // A plain terminal of a server's page: New Terminal for that server returns to it.
                if let home = item.home, let scope = item.windowID, profile != nil { homeTerminalScopes[home] = scope }
                session.customTitle = item.customTitle; session.initialDirectoryTitle = item.initialDirectoryTitle
                session.tabWidth = item.tabWidth; session.currentDirectory = item.directory
                session.terminal.getTerminal().resize(cols: min(max(item.columns, 2), 1000), rows: min(max(item.rows, 2), 500))
                session.restoreOutput(output[item.id] ?? "")
                session.ended = true; session.status = "Disconnected · Reconnect to continue"
                session.terminal.fileDropAllowed = false
                session.onEnd = { [weak self] s, code in self?.finish(s, code: code) }
                session.terminal.onDropError = { [weak self] text in self?.errorMessage = text }
                sessions.append(session); registerTerminal(session)
            }
            for (scope, original) in manifest.layouts {
                var layout = original
                let available = Set(terminalSessions(in: scope).map(\.id))
                for id in layout.sessionIDs where !available.contains(id) { layout.remove(id) }
                for id in available where !layout.sessionIDs.contains(id) { layout.insert(id) }
                terminalLayouts[scope] = layout
            }
            if let selected = sessions.first(where: { $0.id == manifest.selected && !$0.detached }) ?? attachedSessions.first { selectSession(selected, requestFocus: false) }
        } catch {
            recoveryWritable = false
            errorMessage = "Saved terminals could not be read. The recovery files have been kept unchanged: " + error.localizedDescription
        }
    }
}
