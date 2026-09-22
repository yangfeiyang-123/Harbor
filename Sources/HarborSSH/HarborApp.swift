import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let store, store.hasUnsavedFiles {
            let alert = NSAlert(); alert.messageText = "You have unsaved changes"
            alert.informativeText = "Cancel quitting and use ⌘S in each file tab to save your changes."
            alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Discard and Quit")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        if let store, store.activeCount > 0 || store.rules.contains(where: { store.proxy.isRunning($0.id) }) {
            let alert = NSAlert(); alert.messageText = "Quit Harbor?"
            alert.informativeText = "Terminal output and layouts will be saved. Remote sessions will keep running so you can reconnect. Local shells and app-managed forwarding will close."
            alert.addButton(withTitle: "Quit"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        if let store, !store.checkpointTerminals(synchronously: true) { return .terminateCancel }
        store?.shutdown(); return .terminateNow
    }
}

struct HarborApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = AppStore.launchStore()
    var body: some Scene {
        Window("Harbor · SSH Workbench", id: "main") {
            ContentView().environmentObject(store).onAppear { delegate.store = store }.task { await store.loadForLaunch() }
                .focusedSceneValue(\.harborSession, store.activeSession)
        }
        .defaultSize(width: 1240, height: 800)
        .windowStyle(.hiddenTitleBar)
        .commands { HarborCommands(store: store) }
        WindowGroup("Harbor Terminal", id: "terminal", for: UUID.self) { $id in
            if let id {
                TerminalWindowView(windowID: id).environmentObject(store)
            } else { Text("This terminal is closed").frame(width: 500, height: 300) }
        }.defaultSize(width: 1000, height: 660)
        Settings { SettingsView().environmentObject(store) }
    }
}

struct HarborCommands: Commands {
    @ObservedObject var store: AppStore
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.harborSession) private var focusedSession
    @FocusedValue(\.harborWorkspace) private var workspaceFocused
    @AppStorage(WorkspaceShortcut.preferenceKey) private var modeShortcut = WorkspaceShortcut.standard.encoded
    private var session: TerminalSession? { focusedSession ?? store.activeSession }
    private var editorFocused: Bool {
        guard focusedSession?.detached != true, store.page == .workspace, store.currentFiles.enabled else { return false }
        if NSApp.keyWindow?.firstResponder is TerminalListKeyView { return false }
        if let terminal = session?.terminal, let responder = NSApp.keyWindow?.firstResponder as? NSView, responder === terminal || responder.isDescendant(of: terminal) { return false }
        return store.currentFiles.currentDocument?.text != nil
    }
    private func changeFont(_ delta: Double) {
        let key = editorFocused ? "editorFontSize" : "terminalFontSize"
        UserDefaults.standard.set(min(max(HarborTypography.value(key) + delta, 9), 32), forKey: key)
    }
    var body: some Commands {
        CommandGroup(replacing: .appVisibility) {
            Button("Hide Harbor") { NSApp.hide(nil) }
            Button("Hide Others") { NSApp.hideOtherApplications(nil) }.keyboardShortcut("h", modifiers: [.command, .option])
            Button("Show All") { NSApp.unhideAllApplications(nil) }
        }
        CommandMenu("Terminal") {
            Button("New Terminal Workspace") {
                store.openIndependentTerminal(in: focusedSession?.windowID.map { .window($0) })
                if focusedSession?.windowID == nil { openWindow(id: "main") }
            }.keyboardShortcut("`", modifiers: [.control, .shift])
            Divider().overlay(Color.harborBorder)
            Button("Split Right") { store.splitTerminal(.columns, session: session) }.keyboardShortcut("d")
            Button("Split Down") { store.splitTerminal(.rows, session: session) }.keyboardShortcut("h")
        }
        CommandGroup(replacing: .newItem) {
            Button("Open Workbench") { openWindow(id: "main") }.keyboardShortcut("0")
            Button("New Terminal Tab") {
                if focusedSession?.detached == true { store.openTerminal(session?.profile, workingDirectory: session?.workingDirectory) }
                else { store.openWorkspaceTerminal() }
                openWindow(id: "main")
            }.keyboardShortcut("t")
            Button("New Terminal Window") {
                if let id = store.openTerminal(session == nil ? store.selectedProfile : session?.profile, detached: true) { openWindow(id: "terminal", value: id) }
            }.keyboardShortcut("n")
            Button("Local Terminal") { store.openTerminal(nil) }.keyboardShortcut("l", modifiers: [.command, .shift])
            Divider().overlay(Color.harborBorder)
            Button("Rename Current Terminal…") { if let session { store.promptForTerminalName(session) } }.disabled(session == nil)
            Button("Close Current Terminal") { if let s = session { store.close(s) } }.keyboardShortcut("w", modifiers: [.command, .shift])
            Divider().overlay(Color.harborBorder)
            Button("Save File") { if let document = store.currentFiles.currentDocument { Task { await store.currentFiles.save(document) } } }
                .keyboardShortcut("s").disabled(!store.currentFiles.enabled || store.currentFiles.currentDocument?.dirty != true)
            Button("Open Folder…") {
                store.currentFiles.enabled = true; store.objectWillChange.send()
                store.chooseDirectoryWorkspace()
            }.keyboardShortcut("o", modifiers: [.command, .option])
        }
        CommandMenu("Connection") {
            Button("Import from SSH Config") { Task { await store.importSSHConfig() } }
            Button("Refresh Connections") { Task { await store.refreshConnections() } }
            Divider().overlay(Color.harborBorder)
            Button("Recents") { store.page = .recent }.keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Reverse Proxy") { store.page = .proxy }
        }
        CommandGroup(after: .textEditing) {
            Button("Find…") {
                if editorFocused { store.currentFiles.currentDocument?.editor?.find() }
                else if focusedSession?.detached == true || store.page == .workspace { session?.searching = true }
                else if store.page == .recent { NotificationCenter.default.post(name: .harborFindRecent, object: nil) }
            }.keyboardShortcut("f")
        }
        CommandMenu("Workspace") {
            Button("Quick Open…") { showNavigator(.files) }.keyboardShortcut("p").disabled(workspaceFocused != true)
            Button("Command Palette…") { showNavigator(.commands) }.keyboardShortcut("p", modifiers: [.command, .shift]).disabled(workspaceFocused != true)
            Button("Search in Project") {
                store.currentFiles.focusSearch()
                store.objectWillChange.send()
            }.keyboardShortcut("f", modifiers: [.command, .shift]).disabled(workspaceFocused != true)
            Button("Go to Symbol…") { showNavigator(.symbols) }.keyboardShortcut("o", modifiers: [.command, .shift]).disabled(!store.currentFiles.enabled)
            Button("Go to Line…") { showNavigator(.line) }.keyboardShortcut("g", modifiers: .control).disabled(!store.currentFiles.enabled)
            Button("Toggle Explorer") { store.currentFiles.explorerVisible.toggle() }.keyboardShortcut("b").disabled(!store.currentFiles.enabled)
            Button("Close Active File") {
                if let doc = store.currentFiles.currentDocument { store.currentFiles.close(doc) }
            }.keyboardShortcut("w").disabled(!store.currentFiles.enabled || store.currentFiles.currentDocument == nil || store.currentFiles.focusArea != .editor || store.currentFiles.navigator != nil)
            Divider()
            Button("Switch Files / Terminal Mode") { store.page = .workspace; store.toggleFiles() }
                .keyboardShortcut(KeyEquivalent(Character(WorkspaceShortcut.decode(modeShortcut).key)), modifiers: WorkspaceShortcut.decode(modeShortcut).swiftModifiers)
                .disabled(workspaceFocused != true)
            Button("Switch Editor / Terminal Focus") { openWindow(id: "main"); store.toggleWorkspaceFocus() }.keyboardShortcut("`", modifiers: [.control])
            Button("Maximize / Restore Terminal Panel") { store.toggleTerminalMaximized() }.keyboardShortcut("x", modifiers: .option)
                .disabled(workspaceFocused != true || store.page != .workspace || !store.currentFiles.enabled)
            Button("Toggle Terminal Panel") { store.toggleTerminalPanel() }.keyboardShortcut("j")
            Divider().overlay(Color.harborBorder)
            Button("Increase Font Size") { changeFont(1) }.keyboardShortcut("=")
            Button("Decrease Font Size") { changeFont(-1) }.keyboardShortcut("-")
            Button("Reset Font Size") { UserDefaults.standard.set(13.0, forKey: editorFocused ? "editorFontSize" : "terminalFontSize") }.keyboardShortcut("0", modifiers: [.command, .shift])
        }
    }
    private func showNavigator(_ mode: WorkspaceNavigatorMode) {
        store.page = .workspace; store.currentFiles.enabled = true
        store.currentFiles.navigator = mode; store.objectWillChange.send()
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

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @AppStorage("appearance") var appearance = "system"
    @AppStorage("interfaceFontSize") var interfaceFont = 13.0
    @AppStorage("editorFontSize") var editorFont = 13.0
    @AppStorage("terminalFontSize") var terminalFont = 13.0
    @AppStorage("editorWrap") var editorWrap = false
    @AppStorage("liquidGlassEnabled") private var liquidGlass = true
    @AppStorage(WorkspaceShortcut.preferenceKey) private var modeShortcut = WorkspaceShortcut.standard.encoded
    @State private var shortcutError: String?
    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }
            Text("Files & Code uses Cursor's neutral light and dark palette.").font(.caption).foregroundStyle(Color.harborMuted)
            Toggle("Liquid Glass", isOn: $liquidGlass)
            Text("Adds translucent highlights and a gentle spring to buttons, selections, and tooltips. Respects Reduce Motion and Reduce Transparency.")
                .harborFont(11).foregroundStyle(Color.harborMuted)
            Section("Fonts · Applied Immediately") {
                fontRow("Interface", size: $interfaceFont, range: 11...20)
                fontRow("Code & Markdown", size: $editorFont, range: 9...32)
                fontRow("Terminal", size: $terminalFont, range: 9...32)
                Text("⌘+ / ⌘− adjusts the editor or terminal font. ⇧⌘0 resets it. Use ⌘F to find and replace, and ⌘S to save code.").harborFont(11).foregroundStyle(Color.harborMuted)
                Toggle("Word Wrap", isOn: $editorWrap)
                Button("Reset Font Sizes") { interfaceFont = 13; editorFont = 13; terminalFont = 13 }
            }
            Section("Keyboard Shortcuts") {
                HStack {
                    Text("Terminal / Files & Code")
                    Spacer()
                    ShortcutRecorder(value: $modeShortcut) { shortcutError = $0 }.frame(width: 170, height: 28)
                }
                Text(shortcutError ?? "⌥X maximizes or restores the terminal panel. Click the shortcut box to change the mode shortcut; Esc cancels.")
                    .harborFont(11).foregroundStyle(shortcutError == nil ? Color.harborMuted : .orange)
                Button("Reset to Option+Z") { modeShortcut = WorkspaceShortcut.standard.encoded; shortcutError = nil }
                DisclosureGroup("Terminal Shortcuts") {
                    LabeledContent("New Terminal Workspace", value: "⌃⇧`")
                    LabeledContent("Close Selected Terminal", value: "⌘Delete")
                    LabeledContent("Switch Terminal Workspace", value: "⌘1 – ⌘9")
                    Text("In Files mode, select a terminal and use arrow keys to switch or Enter to rename. Press Esc or click its contents to type commands.")
                        .harborFont(11).foregroundStyle(Color.harborMuted)
                }
                DisclosureGroup("Files & Code Shortcuts") {
                    LabeledContent("Quick Open / Command Palette", value: "⌘P / ⇧⌘P")
                    LabeledContent("Search in Project", value: "⇧⌘F")
                    LabeledContent("Go to Symbol / Line", value: "⇧⌘O / ⌃G")
                    LabeledContent("Toggle Explorer / Terminal", value: "⌘B / ⌘J")
                    LabeledContent("Open Folder", value: "⌥⌘O")
                    LabeledContent("Select Individual Files / Range", value: "⌘ Click / ⇧ Click")
                    LabeledContent("Select All / Extend Selection", value: "⌘A / ⇧↑↓")
                    Text("Select files in the explorer to copy, move, download, or delete them together. Return renames a single selected item.").harborFont(11).foregroundStyle(Color.harborMuted)
                }
            }
            LabeledContent("Connection Retention", value: "8 hours after the last terminal closes")
            LabeledContent("Terminal Scrollback", value: "20,000 lines")
            LabeledContent("Recents", value: "12 recent servers and folders")
            Text("Recents keeps location shortcuts. Open terminals save a bounded output snapshot for recovery.")
                .font(.caption).foregroundStyle(Color.harborMuted)
            Button("Open Local Data Folder") { NSWorkspace.shared.open(store.history.root) }
            Text("Harbor \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.22.2") · SwiftUI / OpenSSH / SwiftTerm / CodeMirror\nPersonal edition · macOS 14 or later")
                .font(.caption).foregroundStyle(Color.harborMuted)
        }.formStyle(.grouped).scrollContentBackground(.hidden).background(Color.harborBackground).foregroundStyle(Color.harborForeground).tint(.harborButton).harborFont().padding().frame(width: 610, height: 740).background(Color.harborBackground)
            .environment(\.locale, Locale(identifier: "en"))
            .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
    }
    private func fontRow(_ title: String, size: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).frame(width: 135, alignment: .leading)
            Slider(value: size, in: range, step: 1).frame(width: 190).accessibilityLabel(title + " Font Size")
            Text("\(Int(size.wrappedValue)) pt").monospacedDigit().frame(width: 48)
            Stepper(title + " Font Size", value: size, in: range, step: 1).labelsHidden().fixedSize()
        }
    }
}
