import AppKit
import SwiftUI
import SwiftTerm
import HarborCore

enum TerminalTheme {
    static func background(dark: Bool) -> NSColor {
        HarborTheme.native("terminal.background", dark: dark)
    }
    static func apply(to terminal: CapturingTerminal, dark: Bool) {
        terminal.nativeBackgroundColor = background(dark: dark)
        terminal.nativeForegroundColor = HarborTheme.native("terminal.foreground", dark: dark)
        terminal.caretColor = HarborTheme.native("terminalCursor.foreground", dark: dark)
        terminal.caretTextColor = HarborTheme.native("terminalCursor.background", dark: dark)
        terminal.selectedTextBackgroundColor = HarborTheme.native("terminal.selectionBackground", dark: dark)
        terminal.selectedTextForegroundColor = terminal.nativeForegroundColor
        terminal.installColors(HarborTheme.palette(dark: dark).ansi.map {
            let rgb = UInt32($0.dropFirst(), radix: 16)!
            return SwiftTerm.Color(red8: UInt16((rgb >> 16) & 255), green8: UInt16((rgb >> 8) & 255), blue8: UInt16(rgb & 255))
        })
        terminal.needsDisplay = true
    }
}

final class CapturingTerminal: LocalProcessTerminalView {
    var onDisplayRestore: (() -> Void)?
    private var restoreRemoteDisplay = false
    private var displayRepair: DispatchWorkItem?
    private var displayObservers: [NSObjectProtocol] = []
    /// Coalesce output bursts; no repeating timers, resize tricks or input sent
    /// to the shell. AppKit invalidations can be lost while a surface is moved.
    func scheduleDisplayRepair(restoreRemote: Bool = false) {
        restoreRemoteDisplay = restoreRemoteDisplay || restoreRemote
        guard displayRepair == nil, window != nil, !isHiddenOrHasHiddenAncestor else { return }
        let repair = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.displayRepair = nil
            guard self.window != nil, !self.isHiddenOrHasHiddenAncestor else { return }
            self.refreshDisplay()
            if self.restoreRemoteDisplay { self.restoreRemoteDisplay = false; self.onDisplayRestore?() }
        }
        displayRepair = repair
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: repair)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayObservers.forEach(NotificationCenter.default.removeObserver); displayObservers.removeAll()
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification] {
                displayObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.scheduleDisplayRepair(restoreRemote: true) })
            }
            scheduleDisplayRepair(restoreRemote: true)
        } else { displayRepair?.cancel(); displayRepair = nil }
    }
    override func viewDidUnhide() { super.viewDidUnhide(); scheduleDisplayRepair(restoreRemote: true) }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); scheduleDisplayRepair() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); scheduleDisplayRepair() }
    deinit { displayRepair?.cancel(); displayObservers.forEach(NotificationCenter.default.removeObserver) }

    var onOutput: ((Data) -> Void)?
    var onFocus: (() -> Void)?
    var onShowSavedOutput: (() -> Void)?
    var fileDropProfileID: UUID?
    var fileDropAllowed = true
    var onDropError: ((String) -> Void)?
    override func mouseDown(with event: NSEvent) {
        // A native terminal can be clicked while the explorer/list still owns
        // keyboard focus. Selection and Copy must target this pane together.
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
    override func copy(_ sender: Any) {
        guard selection.active else { return }
        super.copy(sender)
    }
    func handleCopyKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection(WorkspaceShortcut.modifierMask) == .command,
              event.charactersIgnoringModifiers?.lowercased() == "c" else { return false }
        copy(self)
        return true
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        let menu = NSMenu()
        for (title, action, key): (String, Selector, String) in [
            ("Copy", #selector(copy(_:)), "c"),
            ("Paste", #selector(paste(_:)), "v"),
            ("Select All", #selector(selectAll(_:)), "a")
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self; menu.addItem(item)
        }
        if onShowSavedOutput != nil {
            menu.addItem(.separator())
            let item = NSMenuItem(title: "View Saved Output…", action: #selector(showSavedOutput(_:)), keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }
        return menu
    }
    @objc func showSavedOutput(_ sender: Any?) { onShowSavedOutput?() }
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(showSavedOutput(_:)) { return onShowSavedOutput != nil }
        return super.validateUserInterfaceItem(item)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard fileDropAllowed, let items = try? WorkspaceDragDrop.items(from: sender.draggingPasteboard),
              (try? WorkspaceDragDrop.terminalText(items, profileID: fileDropProfileID)) != nil else { return [] }
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard fileDropAllowed else { return false }
        do {
            let text = try WorkspaceDragDrop.terminalText(WorkspaceDragDrop.items(from: sender.draggingPasteboard), profileID: fileDropProfileID)
            window?.makeFirstResponder(self)
            let bracketed = getTerminal().bracketedPasteMode
            send(txt: (bracketed ? "\u{1b}[200~" : "") + text + (bracketed ? "\u{1b}[201~" : ""))
            return true
        } catch { onDropError?(error.localizedDescription); return false }
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            DispatchQueue.main.async { [weak self] in
                guard let self, let responder = self.window?.firstResponder as? NSView,
                      responder === self || responder.isDescendant(of: self) else { return }
                self.onFocus?()
            }
        }
        return accepted
    }
    override func dataReceived(slice: ArraySlice<UInt8>) { onOutput?(Data(slice)); super.dataReceived(slice: slice); scheduleDisplayRepair() }
    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
}

@MainActor
final class TerminalSession: NSObject, ObservableObject, Identifiable, @preconcurrency LocalProcessTerminalViewDelegate {
    let id: UUID
    let profile: ServerProfile?
    let terminal: CapturingTerminal
    weak var surfaceHost: TerminalContainer?
    var tmuxName: String?
    let writer: TranscriptWriter?
    let workingDirectory: String?
    var currentDirectory: String?
    let directoryToken: String
    var remotePTYID: UUID?
    var remotePTYReconnect = false
    var remoteShellPID: Int32?
    var directoryCheckNeeded = true
    var directoryWorkspaceID: UUID?
    var detached: Bool
    var windowID: UUID?
    var socket: String?
    @Published var title: String
    @Published var customTitle: String?
    @Published var initialDirectoryTitle: String?
    @Published var tabWidth: Double?
    var tabTitle: String { customTitle ?? initialDirectoryTitle ?? "Terminal \(title.components(separatedBy: " · ").last ?? title)" }
    var displayTitle: String { "\(tabTitle) · \(profile?.name ?? "Local")" }
    static func directoryTitle(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let name = (path as NSString).lastPathComponent.components(separatedBy: .controlCharacters).joined()
        guard !name.isEmpty, !["~", ".", ".."].contains(name) else { return nil }
        return String(name.prefix(120))
    }
    func rename(to value: String) {
        let cleaned = value.components(separatedBy: .controlCharacters).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        customTitle = cleaned.isEmpty ? nil : String(cleaned.prefix(120))
        tabWidth = max(tabWidth ?? 150, WorkspaceTabLayout.fittedWidth(tabTitle))
    }
    func promptForName() {
        let alert = NSAlert(); alert.messageText = "Rename Terminal"
        alert.informativeText = "Leave blank to restore the default name."
        let field = NSTextField(string: customTitle ?? tabTitle)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 26)
        alert.accessoryView = field; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn { rename(to: field.stringValue) }
    }
    @Published var status = "Preparing connection"
    @Published var ended = false
    @Published var started = false
    @Published var ready = false
    @Published var searching = false
    var onEnd: ((TerminalSession, Int32?) -> Void)?
    var recoveryDirty = true
    var savedOutput = ""
    var savedOutputWindow: NSWindow?
    private var darkTheme: Bool?
    func applyTheme(dark: Bool) {
        guard darkTheme != dark else { return }
        darkTheme = dark; TerminalTheme.apply(to: terminal, dark: dark)
    }
    init(id: UUID = UUID(), profile: ServerProfile?, title: String, detached: Bool = false, history: HistoryStore, tmuxName: String? = nil, workingDirectory: String? = nil, remotePTYID: UUID? = nil) throws {
        self.id = id; self.profile = profile; self.title = title; self.detached = detached; self.workingDirectory = workingDirectory
        initialDirectoryTitle = Self.directoryTitle(workingDirectory ?? (profile == nil ? FileManager.default.homeDirectoryForCurrentUser.path : nil))
        windowID = detached ? id : nil
        self.tmuxName = tmuxName
        self.remotePTYID = profile != nil && tmuxName == nil ? (remotePTYID ?? UUID()) : nil
        directoryToken = self.remotePTYID?.uuidString ?? UUID().uuidString
        var options = TerminalOptions(); options.scrollback = 20_000
        terminal = CapturingTerminal(frame: NSRect(x: 0, y: 0, width: 920, height: 580), font: .monospacedSystemFont(ofSize: HarborTypography.value("terminalFontSize"), weight: .regular), options: options)
        writer = nil
        super.init()
        terminal.processDelegate = self
        let appearance = UserDefaults.standard.string(forKey: "appearance") ?? "system"
        applyTheme(dark: appearance == "dark" || (appearance == "system" && NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua))
        terminal.fileDropProfileID = profile?.id
        terminal.fileDropAllowed = profile == nil
        terminal.registerForDraggedTypes([.fileURL, .init(WorkspaceDropItem.typeIdentifier)])
        terminal.getTerminal().registerOscHandler(code: 7777) { [weak self] bytes in
            guard let self else { return }
            let parts = String(decoding: bytes, as: UTF8.self).split(separator: ";")
            if parts.count == 2, parts[0] == self.directoryToken, let pid = Int32(parts[1]), pid > 0 {
                self.remoteShellPID = pid
                if self.remotePTYID != nil { self.remotePTYReconnect = true; self.recoveryDirty = true }
            }
        }
        terminal.getTerminal().registerOscHandler(code: 7778) { [weak self] bytes in
            guard let self else { return }
            if String(decoding: bytes, as: UTF8.self) == self.directoryToken + ";0" { self.tmuxName = nil }
        }
        terminal.onOutput = { [weak self] data in self?.writer?.append(data); self?.directoryCheckNeeded = true; self?.recoveryDirty = true }
        terminal.onShowSavedOutput = { [weak self] in self?.showSavedOutput() }
        terminal.onDisplayRestore = { [weak self] in
            guard let self, self.remotePTYID != nil, self.ready, self.terminal.process.running else { return }
            // The relay forwards even an unchanged size to the remote TUI. No
            // synthetic keystrokes, no font changes, no shell command execution.
            kill(self.terminal.process.shellPid, SIGWINCH)
        }
    }
    func start(executable: String, arguments: [String]) {
        guard !started, !ended else { return }
        started = true; status = profile == nil ? "Local Terminal" : "Connecting · Complete authentication below"
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"; env["COLORTERM"] = "truecolor"; env["TERM_PROGRAM"] = "HarborSSH"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let useTransport = profile != nil && remotePTYID != nil && executable == "/usr/bin/ssh"
        let binary = useTransport ? TerminalTransport.executable : executable
        let args = useTransport ? ["--terminal-transport", directoryToken] + arguments : arguments
        terminal.startProcess(executable: binary, args: args, environment: env.map { "\($0.key)=\($0.value)" }, currentDirectory: profile == nil ? (workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path) : FileManager.default.homeDirectoryForCurrentUser.path)
        if profile == nil { ready = true }
    }
    func show(_ message: String) { terminal.feed(text: "\r\n\(message)\r\n") }
    func stop() {
        guard !ended else { return }
        if started && terminal.process.running { terminal.terminate() }
        ended = true; ready = false; terminal.fileDropAllowed = false; status = "Closed"; writer?.close()
    }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) { acceptDirectory(directory) }
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard !ended else { return }
        _ = effectiveDirectory
        ended = true; ready = false; terminal.fileDropAllowed = false; status = exitCode == 0 ? "Session ended" : "Connection interrupted"
        writer?.close(); onEnd?(self, exitCode)
    }
}

struct TerminalSurface: NSViewRepresentable {
    @ObservedObject var session: TerminalSession
    @AppStorage("terminalFontSize") private var fontSize = 13.0
    @Environment(\.colorScheme) private var colorScheme
    func makeNSView(context: Context) -> TerminalContainer {
        let container = TerminalContainer(); container.session = session
        container.attach(session); return container
    }
    func updateNSView(_ nsView: TerminalContainer, context: Context) {
        nsView.attach(session)
        session.applyTheme(dark: colorScheme == .dark)
        let size = min(max(fontSize, 9), 32)
        if session.terminal.font.pointSize != size { session.terminal.font = .monospacedSystemFont(ofSize: size, weight: .regular) }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TerminalContainer, context: Context) -> CGSize? { proposal.replacingUnspecifiedDimensions() }
}

final class TerminalContainer: NSView {
    weak var session: TerminalSession?
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let session else { return }
        // SwiftUI may create a retiring container after the visible one. Claim
        // the shared surface when mounted, not merely when constructed.
        session.surfaceHost = self
        attach(session)
    }
    func attach(_ session: TerminalSession) {
        if window != nil && session.surfaceHost?.window == nil { session.surfaceHost = self }
        // A retiring or cached offscreen host cannot steal the visible surface.
        guard session.surfaceHost === self else { return }
        let terminal = session.terminal
        guard terminal.superview !== self else { return }
        // The PTY lives in TerminalSession. Only its native surface moves when the
        // workspace changes presentation or a split tree acquires a new parent.
        wantsLayer = true; layer?.masksToBounds = true
        subviews.forEach { $0.removeFromSuperview() }
        terminal.removeFromSuperview(); terminal.translatesAutoresizingMaskIntoConstraints = false
        terminal.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        terminal.setContentCompressionResistancePriority(.init(1), for: .vertical)
        addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: topAnchor), terminal.bottomAnchor.constraint(equalTo: bottomAnchor),
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), terminal.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        ])
    }
}
