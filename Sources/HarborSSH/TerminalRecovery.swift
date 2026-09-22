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
        let safe = String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" })
        terminal.feed(text: safe.replacingOccurrences(of: "\n", with: "\r\n") + (safe.isEmpty ? "" : "\r\n"))
        recoveryDirty = true
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
        var output: [UUID: String] = [:]
        let items = sessions.map { session in
            if session.recoveryDirty || synchronously {
                output[session.id] = session.recoveryOutput(); session.recoveryDirty = false
            }
            let model = session.terminal.getTerminal()
            return RecoveredTerminal(id: session.id, serverID: session.profile?.id, title: session.title,
                customTitle: session.customTitle, initialDirectoryTitle: session.initialDirectoryTitle,
                directory: session.effectiveDirectory, directoryWorkspaceID: session.directoryWorkspaceID,
                windowID: session.windowID, tmuxName: session.tmuxName, remotePTYID: session.remotePTYID, remotePTYStarted: session.remotePTYReconnect, tabWidth: session.tabWidth,
                columns: model.cols, rows: model.rows)
        }
        let manifest = TerminalRecoveryManifest(terminals: items, layouts: terminalLayouts, selected: selectedSessionID)
        return recoveryStore.save(manifest, output: output, synchronously: synchronously) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                guard let self else { return }
                self.sessions.forEach { $0.recoveryDirty = true }
                self.errorMessage = "Unable to save terminal output: " + error.localizedDescription
            }
        }
    }
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
                session.customTitle = item.customTitle; session.initialDirectoryTitle = item.initialDirectoryTitle
                session.tabWidth = item.tabWidth; session.currentDirectory = item.directory
                session.terminal.getTerminal().resize(cols: min(max(item.columns, 2), 1000), rows: min(max(item.rows, 2), 500))
                session.restoreOutput(output[item.id] ?? "")
                session.ended = true; session.status = "Saved output restored · Reconnect to continue"
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
