import SwiftUI
import AppKit
import HarborCore
import PDFKit

@MainActor final class WorkspaceDocument: ObservableObject, Identifiable {
    let id = UUID()
    @Published var entry: WorkspaceEntry
    let kind: WorkspaceFileKind
    @Published var localURL: URL?
    @Published var text: String?
    @Published var savedText: String?
    @Published var loading = false
    @Published var error: String?
    @Published var preview = true
    @Published var saving = false
    @Published var revision = 0
    @Published var position = EditorPosition()
    @Published var tabWidth: Double?
    var pendingPosition: (line: Int, column: Int)?
    var digest = ""
    var editor: EditorBridge?
    var editorSnapshot: [String: Any]?
    var externallyChanged = false
    weak var pdfView: PDFView?
    var dirty: Bool { text != savedText }
    init(_ entry: WorkspaceEntry) { self.entry = entry; kind = .classify(entry.path) }
}

@MainActor final class FileWorkspace: ObservableObject {
    enum FocusArea { case editor, terminal, terminalList, explorer, servers, search }
    @Published var focusRequest = UUID()
    @Published var navigator: WorkspaceNavigatorMode?
    var nextNavigator: WorkspaceNavigatorMode?
    @Published var sidebarMode = WorkspaceSidebarMode.explorer
    @Published var searchQuery = ""
    @Published var searchCaseSensitive = false
    @Published var explorerVisible = true
    @Published var outlineVisible = false
    var focusArea = FocusArea.editor
    func focusSearch() {
        enabled = true; explorerVisible = true; sidebarMode = .search; requestFocus(.search)
    }
    func requestFocus(_ area: FocusArea) {
        if area == .editor { terminalMaximized = false }
        else { documents.forEach { $0.editor?.cancelPendingFocus() } }
        focusArea = area; focusRequest = UUID()
    }
    let profile: ServerProfile?
    let directoryID: UUID?
    let key: String
    @Published var root = ""
    @Published var recent: [String] = []
    @Published var enabled = false { didSet { if enabled && !oldValue { terminalVisible = true }; persist() } }
    @Published var terminalVisible = true
    @Published var terminalMaximized = false
    func setTerminalMaximized(_ maximized: Bool) {
        if maximized { terminalVisible = true }
        terminalMaximized = maximized
        requestFocus(maximized ? .terminal : .editor)
    }
    /// The view saves the returned normal ratio. Snapping to the top keeps the
    /// ratio from before the drag, so Option-X can restore a useful editor size.
    func resizeTerminalPanel(editorHeight: Double, totalHeight: Double, startingRatio: Double) -> Double {
        // Keep the snap range smaller than the handle's 10-point accessible
        // step, so a collapsed editor can also be expanded from the keyboard.
        if editorHeight <= 8 {
            if !terminalMaximized { setTerminalMaximized(true) }
            return startingRatio.isFinite && startingRatio > 0 ? min(startingRatio, 1) : 0.64
        }
        terminalMaximized = false
        let split = WorkspaceSplitLayout(height: totalHeight, ratio: editorHeight / max(totalHeight - WorkspaceSplitLayout.divider, 1))
        return split.editor / max(totalHeight - WorkspaceSplitLayout.divider, 1)
    }
    @Published var entries: [String: [WorkspaceEntry]] = [:]
    @Published var expanded = Set<String>()
    @Published var documents: [WorkspaceDocument] = []
    @Published var selection: UUID? { didSet { persist() } }
    @Published var busy = false
    @Published var error: String?
    @Published var notice: String?
    @Published var showHidden = false
    @Published var query = "" { didSet { reconcileExplorerSelection() } }
    @Published var explorerSelection = ExplorerSelection()
    var selectedEntryPath: String? {
        get { explorerSelection.focusedPath }
        set { explorerSelection.select(newValue) }
    }
    @Published var fileOperation = false
    @Published var transfer: FileTransferStatus?
    @Published var dropDestination: WorkspaceEntry?
    var service: WorkspaceFileService?
    var savedOpenPaths: [String] = []
    var onDocumentChange: (() -> Void)?
    var onNavigate: ((String) -> Void)?
    private var navigating = UUID()
    var directoryStamps: [String: String] = [:]
    var syncGeneration = UUID()
    var refreshInProgress = false
    var refreshAgain = false
    var monitorID: UUID?
    var localWatcher: WorkspaceDirectoryWatcher?
    var localRefreshTask: Task<Void, Never>?
    var pendingFileChanges: [String: WorkspaceEntry] = [:]
    var visibleDocumentID: UUID?
    var editorRecency: [UUID] = []
    var evictionTask: Task<Void, Never>?
    @Published var refreshingFiles = false
    private var openingDrop = false
    private var restoringDocuments = false
    private var pendingDrops: [WorkspaceDropPlan] = []
    private let defaults: UserDefaults
    var documentObservers: [UUID: Any] = [:]
    private let cache: URL
    var currentDocument: WorkspaceDocument? { documents.first { $0.id == selection } }
    var hasUnsavedChanges: Bool { documents.contains { $0.dirty } }
    init(profile: ServerProfile?, defaults: UserDefaults = .standard, directoryID: UUID? = nil) {
        self.profile = profile; self.directoryID = directoryID
        key = "workspace." + (profile?.id.uuidString ?? "local") + (directoryID.map { ".directory." + $0.uuidString } ?? "")
        self.defaults = defaults
        root = defaults.string(forKey: key + ".root") ?? ""
        recent = defaults.stringArray(forKey: key + ".recent") ?? []
        enabled = defaults.bool(forKey: key + ".enabled")
        savedOpenPaths = defaults.stringArray(forKey: key + ".tabs") ?? []
        cache = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-preview-" + UUID().uuidString)
    }
    deinit { try? FileManager.default.removeItem(at: cache) }
    func cleanCache() {
        stopMonitoring(); evictionTask?.cancel(); evictionTask = nil
        documents.forEach { $0.editor?.cancelPendingFocus(); $0.editor = nil; $0.editorSnapshot = nil }
        try? FileManager.default.removeItem(at: cache)
    }
    func persist() {
        defaults.set(enabled, forKey: key + ".enabled")
        defaults.set(root, forKey: key + ".root")
        defaults.set(recent, forKey: key + ".recent")
        // Put the selected file last so it restores as the active tab.
        if !documents.isEmpty || savedOpenPaths.isEmpty {
            defaults.set(documents.filter { $0.id != selection }.map { $0.entry.path } + documents.filter { $0.id == selection }.map { $0.entry.path }, forKey: key + ".tabs")
        }
    }
    func prepare(store: AppStore) async {
        guard service == nil else { return }
        do {
            let socket = try await profile.mapAsync { try await store.resolveSocket($0) }
            let runtime = AppResources.directory("WorkspaceRuntime").appendingPathComponent("files.py")
            let script = try await Task.detached { try String(contentsOf: runtime, encoding: .utf8) }.value
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let relay: TransferRelayLookup? = profile.map { server in { @Sendable in await ManagedRelay.port(for: server) } }
            service = WorkspaceFileService(profile: profile, socket: socket, script: script, cache: cache, relay: relay)
        } catch { self.error = error.localizedDescription }
    }
    func activate(store: AppStore) async {
        guard !openingDrop, !busy else { return }
        let generation = syncGeneration
        await prepare(store: store)
        guard !openingDrop, !busy, generation == syncGeneration else { return }
        if entries[root] == nil { await navigate(root.isEmpty ? "~" : root) }
        guard error == nil else { return }
        await restoreDocuments()
    }
    private func restoreDocuments() async {
        guard !restoringDocuments, !savedOpenPaths.isEmpty else { return }
        restoringDocuments = true; defer { restoringDocuments = false }
        let paths = savedOpenPaths; savedOpenPaths = []
        let generation = syncGeneration
        var restored: [WorkspaceEntry] = []
        for path in paths.suffix(12) {
            let parent = (path as NSString).deletingLastPathComponent
            if entries[parent] == nil { await loadChildren(parent) }
            guard generation == syncGeneration, !Task.isCancelled else { savedOpenPaths = paths; return }
            if let entry = entries[parent]?.first(where: { $0.path == path && !$0.directory }) { restored.append(entry) }
        }
        for entry in restored { appendDocument(entry) }
        if let currentDocument { await loadIfNeeded(currentDocument) }
        trimDirectoryCache()
    }
    func openDropped(_ plan: WorkspaceDropPlan, store: AppStore) async {
        pendingDrops.append(plan)
        guard !openingDrop else { return }
        openingDrop = true; defer { openingDrop = false }
        while !pendingDrops.isEmpty { await applyDrop(pendingDrops.removeFirst(), store: store) }
    }
    private func applyDrop(_ plan: WorkspaceDropPlan, store: AppStore) async {
        enabled = true; store.selectDirectoryWorkspace(self)
        await prepare(store: store)
        if plan.files.contains(where: { $0.name.hasPrefix(".") }) { showHidden = true }
        await navigate(plan.root)
        guard error == nil, service != nil else { return }
        await restoreDocuments()
        for entry in plan.files {
            if profile == nil { await open(entry) }
            else {
                let parent = (entry.path as NSString).deletingLastPathComponent
                if entries[parent] == nil { await loadChildren(parent) }
                if let fresh = entries[parent]?.first(where: { $0.path == entry.path && !$0.directory }) { await open(fresh) }
                else { error = "Cannot find \(entry.name). Refresh the folder and try again." }
            }
        }
        recent = Array((plan.recentRoots + recent.filter { !plan.recentRoots.contains($0) }).prefix(12))
        persist(); onDocumentChange?()
    }
    func navigate(_ path: String) async {
        guard let service else { return }
        syncGeneration = UUID()
        let request = UUID(); navigating = request; busy = true; error = nil; notice = nil
        do {
            let listing = try await service.list(path, showHidden: showHidden)
            guard navigating == request else { return }
            adoptRootListing(listing)
        } catch { if navigating == request { self.error = friendly(error) } }
        if navigating == request { busy = false }
    }
    func adoptRootListing(_ listing: WorkspaceListing) {
        syncGeneration = UUID(); root = listing.path; entries = [root: listing.entries]; expanded = []; query = ""
        explorerSelection.select(nil)
        directoryStamps = listing.stamp.map { [root: $0] } ?? [:]; updateDirectoryWatchers()
        recent = [root] + recent.filter { $0 != root }.prefix(11); persist(); onNavigate?(root)
        notice = listing.truncated ? "Showing the first 10,000 items. Open a subfolder to continue browsing." : nil
    }
    func loadChildren(_ path: String) async {
        guard let service else { return }
        let generation = syncGeneration
        do {
            let list = try await service.list(path, showHidden: showHidden)
            guard generation == syncGeneration else { return }
            entries[path] = list.entries; directoryStamps[path] = list.stamp
            reconcileExplorerSelection()
        }
        catch { self.error = friendly(error) }
    }
    func collapseFolders() { expanded.removeAll(); reconcileExplorerSelection(); trimDirectoryCache(); updateDirectoryWatchers() }
    func toggle(_ entry: WorkspaceEntry) async {
        if expanded.contains(entry.path) {
            expanded = expanded.filter { $0 != entry.path && !$0.hasPrefix(entry.path + "/") }
            trimDirectoryCache()
        } else { expanded.insert(entry.path); await loadChildren(entry.path) }
        reconcileExplorerSelection(); updateDirectoryWatchers()
    }
    func open(_ entry: WorkspaceEntry, loadPreview: Bool = true) async {
        if let existing = documents.first(where: { $0.entry.path == entry.path }) {
            selection = existing.id; if loadPreview { await loadIfNeeded(existing) }; requestFocus(.editor); return
        }
        let document = appendDocument(entry)
        if loadPreview && entry.size <= 25 * 1024 * 1024 { await load(document) }
        requestFocus(.editor)
    }
    @discardableResult func appendDocument(_ entry: WorkspaceEntry) -> WorkspaceDocument {
        if let existing = documents.first(where: { $0.entry.path == entry.path }) { selection = existing.id; return existing }
        let document = WorkspaceDocument(entry); documents.append(document); selection = document.id
        documentObservers[document.id] = document.$text.combineLatest(document.$savedText).map { $0 != $1 }.removeDuplicates().dropFirst().sink { [weak self] _ in
            self?.objectWillChange.send(); self?.onDocumentChange?()
        }
        return document
    }
    func load(_ document: WorkspaceDocument) async {
        guard let service, !document.loading else { return }
        if document.dirty && !confirmDiscard("Reload this file?") { return }
        let initialText = document.text, initialSavedText = document.savedText, initialRevision = document.revision
        document.loading = true; document.error = nil
        defer { document.loading = false }
        do {
            let isText = document.kind == .text || document.kind == .markdown
            let local = try await service.materialize(document.entry, limit: isText ? 2 * 1024 * 1024 : 512 * 1024 * 1024)
            var adopted = false
            defer { if !adopted { try? FileManager.default.removeItem(at: local) } }
            try Task.checkCancellation()
            guard documents.contains(where: { $0 === document }) else { return }
            if isText {
                let data = try await Task.detached { try Data(contentsOf: local) }.value
                try Task.checkCancellation()
                // A key event or pending editor message can arrive while the
                // file is being fetched. Never replace that newer draft.
                guard document.text == initialText, document.savedText == initialSavedText, document.revision == initialRevision else { return }
                guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
                    try? FileManager.default.removeItem(at: local)
                    throw WorkspaceError.message("This is a binary or non-UTF-8 file. It cannot be opened in the code editor.")
                }
                document.text = text; document.savedText = text; document.digest = WorkspacePath.digest(data); document.revision += 1
                document.editorSnapshot = nil
            }
            if let previous = document.localURL { try? FileManager.default.removeItem(at: previous) }
            document.localURL = local
            adopted = true
            document.externallyChanged = false
        } catch is CancellationError { }
        catch { document.error = friendly(error) }
    }
    func loadIfNeeded(_ document: WorkspaceDocument) async {
        if !document.dirty && (document.externallyChanged || (document.text == nil && document.localURL == nil)) && document.entry.size <= 25 * 1024 * 1024 {
            await load(document)
        }
    }
    func save(_ document: WorkspaceDocument) async {
        guard let service, let text = document.text, document.dirty, !document.saving else { return }
        document.saving = true; document.error = nil
        defer { document.saving = false }
        do {
            let digest = try await service.save(path: document.entry.path, text: text, expectedDigest: document.digest)
            document.digest = digest; document.savedText = text
        } catch { document.error = friendly(error) }
    }
    func close(_ document: WorkspaceDocument) {
        guard !document.saving, !document.dirty || confirmDiscard("Close the unsaved file?") else { return }
        documents.removeAll { $0.id == document.id }; documentObservers[document.id] = nil
        document.editor?.cancelPendingFocus(); document.editor = nil; document.editorSnapshot = nil
        pendingFileChanges[document.entry.path] = nil; editorRecency.removeAll { $0 == document.id }
        if selection == document.id { selection = documents.last?.id }
        if let url = document.localURL { try? FileManager.default.removeItem(at: url) }
        savedOpenPaths = []; persist()
    }
    func create(directory: Bool, parent: String? = nil) {
        guard !root.isEmpty, !busy, !fileOperation, let service else { return }
        let destination = parent ?? (selectedEntry?.directory == true ? selectedEntry!.path : root)
        let alert = NSAlert(); alert.messageText = directory ? "New Folder" : "New File"
        alert.informativeText = "Create in: " + destination
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 26))
        input.placeholderString = directory ? "Folder name" : "File name, e.g. main.py"
        alert.accessoryView = input; alert.addButton(withTitle: "Create"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = input.stringValue
        Task {
            do { try await service.create(name: name, parent: destination, directory: directory); await refreshExpanded(force: true) }
            catch { self.error = friendly(error) }
        }
    }
    func forget(_ path: String) { recent.removeAll { $0 == path }; persist() }
    func confirmDiscard(_ title: String) -> Bool {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = "Unsaved changes will be lost. Cancel and use ⌘S to save them first."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Discard Changes")
        return alert.runModal() == .alertSecondButtonReturn
    }
    private func friendly(_ error: Error) -> String {
        let message = error.localizedDescription
        if message.contains("Connection") || message.contains("mux_client") || message.contains("closed by") {
            return "The file connection is not ready. Open a terminal to complete SSH authentication, then refresh.\n" + message
        }
        if message.contains("python3") && message.contains("not found") { return "Remote file browsing requires Python 3 on the server. Terminals are still available." }
        return message
    }
}
extension Optional {
    func mapAsync<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        if let value = self { return try await transform(value) }; return nil
    }
}
