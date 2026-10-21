import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        #if DEBUG
        // A preview that is looked at through its probe stays behind whatever is being worked in.
        if UserDefaults.standard.bool(forKey: "HarborQABackground") { WorkspaceSwitcher.shared.install(); AppStore.installTabRename(); return }
        #endif
        NSApp.activate(ignoringOtherApps: true)
        WorkspaceSwitcher.shared.install()
        AppStore.installTabRename()
        // Opening Settings should not wait for the catalog to be read or the fonts to be looked at.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) {
            SettingsCatalog.prepare(); _ = HarborTypography.monospacedFamilies
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// File ▸ New Window, kept so the Dock menu and a dropped folder can open a window with none on screen.
    static var openMainWindow: (() -> Void)?
    private static let launched = Date()
    static var sinceLaunch: Double { Date().timeIntervalSince(launched) }
    func applicationWillFinishLaunching(_ notification: Notification) { _ = Self.launched }
    static func activate() {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "HarborQABackground") { return }
        #endif
        NSApp.activate(ignoringOtherApps: true)
    }
    /// The Dock menu lists the open windows by itself; this adds the way to another one.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "New Window", action: #selector(newWindowFromDock), keyEquivalent: "")
        item.target = self; menu.addItem(item)
        return menu
    }
    @objc func newWindowFromDock() { Self.openMainWindow?(); Self.activate() }
    /// Folders dropped on the Dock icon, or opened with Harbor in Finder.
    func application(_ application: NSApplication, open urls: [URL]) { AppStore.openFromOutside(urls) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if AppStore.all.contains(where: \.hasUnsavedFiles) {
            let alert = NSAlert(); alert.messageText = "You have unsaved changes"
            alert.informativeText = "Cancel quitting and use ⌘S in each file tab to save your changes."
            alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Discard and Quit")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        if let store, AppStore.all.contains(where: { $0.activeCount > 0 }) || store.rules.contains(where: { store.proxy.isRunning($0.id) }) {
            let alert = NSAlert(); alert.messageText = "Quit Harbor?"
            alert.informativeText = "Terminal output and layouts will be saved. Remote sessions will keep running so you can reconnect. Local shells and app-managed forwarding will close."
            alert.addButton(withTitle: "Quit"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        // Only a save that was tried and failed is a reason to stop, and then it is asked about.
        // (This used to refuse without a word whenever the recovery files could not be written
        // at all, which is the state after they could not be read at launch: Harbor could then
        // only be force-quit.)
        if let store, store.terminalsUnsavedAtQuit() {
            let alert = NSAlert(); alert.messageText = "Terminal output could not be saved"
            alert.informativeText = "Harbor could not write what the terminals show to its recovery files. Remote sessions keep running either way; after quitting now, what is on screen in the terminals will not be there to scroll back to."
            alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Quit Anyway")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        store?.shutdown(); return .terminateNow
    }
}

struct HarborApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = AppStore.launchStore()
    init() { HarborTheme.adoptDefaultAppearance(); AppStore.installPasswordSignIn(); ThemeTransition.install() }
    var body: some Scene {
        // Each workbench window has its own page, server and folder selection.
        WindowGroup("Harbor", id: "main") {
            WindowRoot(primary: store).onAppear { delegate.store = store }
        }
        .defaultSize(width: 1240, height: 800)
        .windowStyle(.hiddenTitleBar)
        // A folder given to Harbor goes where Harbor decides (a start page, or a new window); without
        // this every one of them would also open a window of its own.
        .handlesExternalEvents(matching: [])
        .commands { HarborCommands(primary: store) }
        WindowGroup("Harbor Terminal", id: "terminal", for: UUID.self) { $id in
            if let id {
                TerminalWindowView(windowID: id).environmentObject(AppStore.owner(ofTerminalWindow: id) ?? store)
            } else { Text("This terminal is closed").frame(width: 500, height: 300) }
        }.defaultSize(width: 1000, height: 660).handlesExternalEvents(matching: [])
    }
}

struct HarborCommands: Commands {
    /// Commands act on the focused window's store. From a terminal window that is the store its
    /// terminal belongs to (a second window's terminals are not the first window's); the primary
    /// store answers when neither is there.
    @ObservedObject var primary: AppStore
    @FocusedObject private var focusedStore: AppStore?
    private var store: AppStore {
        focusedStore ?? focusedSession.flatMap { session in AppStore.all.first { $0.sessions.contains { $0 === session } } } ?? primary
    }
    /// A workspace or a terminal is what the keys would act on. Elsewhere (the start page, Reverse
    /// Proxy, Remote Display) there is nothing to split.
    private var terminalInReach: Bool { focusedSession?.detached == true || store.page == .workspace || store.page == .terminal }
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.harborSession) private var focusedSession
    @FocusedValue(\.harborWorkspace) private var workspaceFocused
    @AppStorage(WorkspaceShortcut.preferenceKey) private var modeShortcut = WorkspaceShortcut.standard.encoded
    @AppStorage(WindowChrome.ChromeAnchor.alwaysShowKey) private var alwaysShowTabBar = false
    private var session: TerminalSession? { focusedSession ?? store.activeSession }
    private var codeEditor: CodeWorkbenchSession? {
        guard focusedSession?.detached != true, store.page == .workspace else { return nil }
        return store.codeWorkbench.existing(for: store.currentFiles)
    }
    private func changeFont(_ delta: Double) {
        if let codeEditor, codeEditor.focused {
            codeEditor.command(codeEditor.terminalFocused
                ? (delta > 0 ? "workbench.action.terminal.fontZoomIn" : "workbench.action.terminal.fontZoomOut")
                : (delta > 0 ? "editor.action.fontZoomIn" : "editor.action.fontZoomOut")); return
        }
        // Outside the editor this adjusts Harbor's own terminal windows.
        UserDefaults.standard.set(min(max(HarborTypography.value("terminalFontSize") + delta, 9), 32), forKey: "terminalFontSize")
    }
    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                // The panel belongs to a workbench window; from a terminal window, use the last one.
                let target = focusedStore ?? AppStore.lastActive ?? primary
                if focusedStore == nil { target.showWindow(openWindow); target.settingsVisible = true } else { target.settingsVisible.toggle() }
            }.keyboardShortcut(",")

        }
        CommandGroup(replacing: .appVisibility) {
            Button("Hide Harbor") { NSApp.hide(nil) }
            Button("Hide Others") { NSApp.hideOtherApplications(nil) }.keyboardShortcut("h", modifiers: [.command, .option])
            Button("Show All") { NSApp.unhideAllApplications(nil) }
        }
        CommandMenu("Terminal") {
            Button("New Terminal Workspace") {
                store.openIndependentTerminal(in: focusedSession?.windowID.map { .window($0) })
                if focusedSession?.windowID == nil { store.showWindow(openWindow) }
            // Written as the character Shift gives. As "`" with Shift, the menu took a plain ⌃` for
            // this command too: in a plain terminal it opened a new tab.
            }.keyboardShortcut("~", modifiers: [.control])
            Divider().overlay(Color.harborBorder)
            Button("Split Right / Select Next Match") {
                if let codeEditor, codeEditor.focused { codeEditor.command(codeEditor.terminalFocused ? "workbench.action.terminal.split" : "editor.action.addSelectionToNextFindMatch") }
                else { store.splitTerminal(.columns, session: session) }
            }.keyboardShortcut("d")
            Button(codeEditor == nil ? "Split Down" : "Split Terminal") {
                // ⌘H is Hide everywhere else on a Mac. Where there is nothing to split it is here too;
                // on the start page it used to start the selected server's editor in the background.
                if !terminalInReach { NSApp.hide(nil) }
                else if let codeEditor, codeEditor.terminalFocused { codeEditor.command("workbench.action.terminal.split") }
                else { store.splitTerminal(.rows, session: session) }
            }.keyboardShortcut("h")
        }
        CommandGroup(replacing: .newItem) {
            let _ = { AppDelegate.openMainWindow = { openWindow(id: "main") } }()
            Button("New Window") { openWindow(id: "main") }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Show Workbench") { store.showWindow(openWindow) }.keyboardShortcut("0")
            Button("New Terminal Tab") {
                if let codeEditor, codeEditor.focused { codeEditor.command(codeEditor.terminalFocused ? "workbench.action.terminal.new" : "workbench.action.showAllSymbols"); return }
                // The plain terminal page adds a tab to itself, as a terminal window does.
                if store.page == .terminal, focusedSession.map(store.isHomeTerminal) != false { store.openIndependentTerminal(); return }
                // In a terminal window it is a tab of that window. (It used to start a shell that no
                // window shows, and take the first window to a workspace.)
                if let window = focusedSession?.windowID, focusedSession?.detached == true { store.openIndependentTerminal(in: .window(window)); return }
                // With no workspace on screen (the start page) there is no panel to add a terminal to.
                else if store.page == .workspace { store.openWorkspaceTerminal() }
                else { store.openHomeTerminal(nil) }
                store.showWindow(openWindow)
            }.keyboardShortcut("t")
            Button("New Terminal Window") {
                if let codeEditor, codeEditor.focused { codeEditor.command("workbench.action.files.newUntitledFile"); return }
                // A terminal window is nobody's but the application's: it stays when the window it was
                // asked for from is closed, and is saved with the first window's.
                // It starts where this window's folder on that server is, as before.
                let profile = session == nil ? store.selectedProfile : session?.profile, root = store.files(for: profile).root
                if let id = (store.primary ?? store).openTerminal(profile, detached: true, workingDirectory: root.isEmpty ? nil : root, useWorkspaceDirectory: false) { openWindow(id: "terminal", value: id) }
            }.keyboardShortcut("n")
            Button("Local Terminal / Select All Matches") {
                if let codeEditor, codeEditor.focused { codeEditor.command("editor.action.selectHighlights") }
                else { store.openHomeTerminal(nil); store.showWindow(openWindow) }
            }.keyboardShortcut("l", modifiers: [.command, .shift])
            Divider().overlay(Color.harborBorder)
            Button("Rename Current Terminal…") { if let codeEditor { codeEditor.command("workbench.action.terminal.rename") } else if let session { store.promptForTerminalName(session) } }.disabled(codeEditor == nil && session == nil)
            Button("Close Terminal / All Editors") {
                if let codeEditor, codeEditor.focused { codeEditor.command(codeEditor.terminalFocused ? "workbench.action.terminal.kill" : "workbench.action.closeAllEditors") }
                else if let s = session { store.close(s) }
            }.keyboardShortcut("w", modifiers: [.command, .shift])
            Divider().overlay(Color.harborBorder)
            Button("Save File") { codeEditor?.command("workbench.action.files.save") }.keyboardShortcut("s").disabled(codeEditor == nil)
            Button("Open Folder…") {
                // Away from a workspace this is the start page's own row, which shows this key: a
                // folder on this Mac, chosen in the system's panel. (It used to open Harbor's
                // browser on whichever server was selected, and connect to it.)
                if store.page != .workspace { store.chooseLocal(directories: true); return }
                store.currentFiles.enabled = true; store.objectWillChange.send()
                store.chooseDirectoryWorkspace()
            }.keyboardShortcut("o", modifiers: [.command, .option])
            Button("Open File…") {
                if let codeEditor, codeEditor.focused { codeEditor.command("workbench.action.files.openFile") }
                else { store.chooseLocal(directories: false) }
            }.keyboardShortcut("o")
        }
        CommandGroup(after: .windowArrangement) {
            Button("Rename Window…") { (focusedStore ?? AppStore.lastActive ?? primary).promptForWindowName() }
            // Harbor's windows are tabs of one window (Command+1…9); this one stands on its own.
            Toggle("Keep Window Separate", isOn: Binding(get: { (focusedStore ?? AppStore.lastActive ?? primary).separate },
                                                         set: { (focusedStore ?? AppStore.lastActive ?? primary).setSeparate($0) }))
            Button("Folders in Windows…") {
                let target = focusedStore ?? AppStore.lastActive ?? primary
                if focusedStore == nil { target.showWindow(openWindow) }
                target.organizerVisible.toggle()
            }.keyboardShortcut("w", modifiers: [.command, .option, .shift])
            Toggle("Always Show Tab Bar", isOn: Binding(get: { alwaysShowTabBar }, set: { alwaysShowTabBar = $0; NotificationCenter.default.post(name: .harborTabBarPolicyChanged, object: nil) }))
        }
        CommandMenu("Connection") {
            Button("Import from SSH Config") { Task { await store.importSSHConfig() } }
            Button("Refresh Connections") { Task { await store.refreshConnections() } }
            Divider().overlay(Color.harborBorder)
            Button("Start Page") { store.page = .recent }.keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Reverse Proxy") { store.page = .proxy }
            Button("Remote Display") { store.page = .display }
        }
        CommandGroup(after: .textEditing) {
            Button("Find…") {
                if let codeEditor, codeEditor.focused { codeEditor.command(codeEditor.terminalFocused ? "workbench.action.terminal.focusFind" : "actions.find") }
                else if focusedSession?.detached == true || store.page == .workspace { session?.searching = true }
                else if store.page == .recent { NotificationCenter.default.post(name: .harborFindRecent, object: nil) }
            }.keyboardShortcut("f")
        }
        CommandMenu("Workspace") {
            Button("Switch Folder (⌥⇥)…") { WorkspaceSwitcher.shared.present(sticky: true) }
            Button("Quick Open…") { showNavigator(.files) }.keyboardShortcut("p").disabled(workspaceFocused != true)
            Button("Command Palette…") { showNavigator(.commands) }.keyboardShortcut("p", modifiers: [.command, .shift]).disabled(workspaceFocused != true)
            Button("Search in Project") {
                codeEditor?.command("workbench.action.findInFiles")
            }.keyboardShortcut("f", modifiers: [.command, .shift]).disabled(workspaceFocused != true)
            Button("Go to Symbol…") { showNavigator(.symbols) }.keyboardShortcut("o", modifiers: [.command, .shift]).disabled(codeEditor == nil)
            Button("Go to Line…") { showNavigator(.line) }.keyboardShortcut("g", modifiers: .control).disabled(codeEditor == nil)
            Button("Extensions") { codeEditor?.command("workbench.view.extensions") }.keyboardShortcut("x", modifiers: [.command, .shift]).disabled(codeEditor == nil)
            Button("Toggle Sidebar") { codeEditor?.command("workbench.action.toggleSidebarVisibility") }.keyboardShortcut("b").disabled(codeEditor == nil)
            // On the terminal page the same key closes the pane in use.
            Button(store.page == .terminal ? "Close Terminal Pane" : "Close Active File") {
                if store.page == .terminal { if let pane = store.homeTerminal { store.close(pane) } }
                else { codeEditor?.command("workbench.action.closeActiveEditor") }
            }.keyboardShortcut("w").disabled(store.page == .terminal ? store.homeTerminal == nil : codeEditor?.focused != true)
            Divider()
            // Both belong to a workspace that is on screen. Anywhere else they change nothing: in a
            // plain terminal ⌥Z is typed into the shell, and neither key leaves it for an editor.
            Button("Switch Files / Terminal Mode") { store.toggleFiles() }
                .keyboardShortcut(KeyEquivalent(Character(WorkspaceShortcut.decode(modeShortcut).key)), modifiers: WorkspaceShortcut.decode(modeShortcut).swiftModifiers)
                .disabled(workspaceFocused != true || store.page != .workspace)
            // Left enabled where it does nothing: disabled, the system gave ⌃` to the next command
            // with that key (⌃⇧`, a new terminal).
            Button("Switch Editor / Terminal Focus") {
                guard store.page == .workspace else { return }
                store.showWindow(openWindow); store.toggleWorkspaceFocus()
            }.keyboardShortcut("`", modifiers: [.control])
            Button("Maximize / Restore Terminal Panel") { store.toggleTerminalMaximized() }.keyboardShortcut("x", modifiers: .option)
                .disabled(workspaceFocused != true || store.page != .workspace || !store.currentFiles.enabled)
            Button("Toggle Terminal Panel") { store.toggleTerminalPanel() }.keyboardShortcut("j")
            Divider().overlay(Color.harborBorder)
            Button("Increase Font Size") { changeFont(1) }.keyboardShortcut("=")
            Button("Decrease Font Size") { changeFont(-1) }.keyboardShortcut("-")
            Button("Reset Font Size") {
                if let codeEditor, codeEditor.focused { codeEditor.command(codeEditor.terminalFocused ? "workbench.action.terminal.fontZoomReset" : "editor.action.fontZoomReset") }
                else { UserDefaults.standard.set(13.0, forKey: "terminalFontSize") }
            }.keyboardShortcut("0", modifiers: [.command, .shift])
        }
    }
    private enum Navigator { case files, commands, symbols, line }
    private func showNavigator(_ mode: Navigator) {
        let command: String
        switch mode {
        case .files: command = "workbench.action.quickOpen"
        case .commands: command = "workbench.action.showCommands"
        case .symbols: command = "workbench.action.gotoSymbol"
        case .line: command = "workbench.action.gotoLine"
        }
        codeEditor?.command(command)
    }
}
struct HarborSessionKey: FocusedValueKey { typealias Value = TerminalSession }
struct HarborWorkspaceKey: FocusedValueKey { typealias Value = Bool }
extension FocusedValues {
    var harborWorkspace: Bool? {
        get { self[HarborWorkspaceKey.self] }
        set { self[HarborWorkspaceKey.self] = newValue }
    }
    var harborSession: TerminalSession? {
        get { self[HarborSessionKey.self] }
        set { self[HarborSessionKey.self] = newValue }
    }
}
final class FindSender: NSObject { static let shared = FindSender(); @objc var tag = 1 }
