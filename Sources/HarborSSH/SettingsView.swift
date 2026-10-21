import SwiftUI
import AppKit

/// The one place for settings, shown inside the workbench window. Harbor's own preferences
/// and the editor and terminal options people change most have pages with a live miniature;
/// they apply to every window and server. Under them is everything else the editor and its
/// extensions offer, by category and through the search box, saved with each server's editor.
struct SettingsView: View {
    /// Present when the panel can fill its window, and when it can be dismissed.
    private let maximized: Binding<Bool>?
    private let close: (() -> Void)?
    init(maximized: Binding<Bool>? = nil, close: (() -> Void)? = nil) { self.maximized = maximized; self.close = close }
    @EnvironmentObject var store: AppStore
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var code = CodeSettingsModel()
    @State private var query = ""
    private var defaults: UserDefaults { .standard }
    @AppStorage("appearance") var appearance = HarborTheme.defaultAppearance
    @AppStorage("interfaceFontSize") var interfaceFont = 13.0
    @AppStorage("editorFontSize") var editorFont = 13.0
    @AppStorage("terminalFontSize") var terminalFont = 13.0
    @AppStorage("editorWrap") var editorWrap = false
    @AppStorage(WorkbenchPreferences.activityBarCountKey) private var activityCount = 4
    @AppStorage("liquidGlassEnabled") private var liquidGlass = true
    @AppStorage(HarborMotion.preferenceKey) private var motion = HarborMotion.Level.full.rawValue
    @AppStorage(WorkspaceShortcut.preferenceKey) private var modeShortcut = WorkspaceShortcut.standard.encoded
    @AppStorage("settingsTab") private var tab = "appearance"
    @State private var shortcutError: String?
    /// A theme under the pointer is previewed without being applied.
    @State private var peek: ThemeChoice?
    @State private var replay = 0
    /// Bumped whenever a stored option changes, here or from an editor.
    @State private var revision = 0

    struct ThemeChoice: Hashable, Identifiable {
        let family: HarborTheme.Family
        let dark: Bool
        var id: String { selection }
        var selection: String { HarborTheme.compose(family: family, mode: dark ? "dark" : "light") }
        var title: String { family.title + (dark ? " Dark" : " Light") }
        /// Every family, light then dark: two families to a row of four swatches.
        static let all: [ThemeChoice] = HarborTheme.families.flatMap { [ThemeChoice(family: $0, dark: false), ThemeChoice(family: $0, dark: true)] }
    }
    private struct Pane: Identifiable {
        let id: String, title: String, symbol: String
        static let all = [Pane(id: "appearance", title: "Appearance", symbol: "paintpalette"), Pane(id: "editor", title: "Editor", symbol: "curlybraces"),
                          Pane(id: "terminal", title: "Terminal", symbol: "terminal"), Pane(id: "workbench", title: "Workbench", symbol: "macwindow"),
                          Pane(id: "shortcuts", title: "Shortcuts", symbol: "keyboard"), Pane(id: "advanced", title: "Advanced", symbol: "gearshape.2")]
    }

    /// The family by its id, keeping the mode.
    private var themeFamily: Binding<String> {
        Binding(get: { HarborTheme.family(appearance).id },
                set: { id in
                    let chosen = HarborTheme.families.first(where: { $0.id == id }) ?? HarborTheme.standard
                    appearance = HarborTheme.compose(family: chosen, mode: HarborTheme.mode(appearance))
                })
    }
    private var mode: Binding<String> {
        Binding(get: { HarborTheme.mode(appearance) },
                set: { appearance = HarborTheme.compose(family: HarborTheme.family(appearance), mode: $0) })
    }
    private var applied: ThemeChoice { ThemeChoice(family: HarborTheme.family(appearance), dark: colorScheme == .dark) }
    private var shown: ThemeChoice { peek ?? applied }

    // Options shared with every editor (harbor-synced-settings.json).
    private func stored<Value>(_ key: String, as type: Value.Type) -> Value? {
        _ = revision
        return WorkbenchPreferences.synced(key).value(defaults) as? Value
    }
    private func write(_ key: String, _ value: Any) {
        let setting = WorkbenchPreferences.synced(key)
        guard let normalized = setting.normalized(value) else { return }
        defaults.set(normalized, forKey: setting.defaultsKey); revision += 1
    }
    private func flag(_ key: String) -> Binding<Bool> { Binding(get: { stored(key, as: Bool.self) ?? false }, set: { write(key, $0) }) }
    private func choice(_ key: String) -> Binding<String> { Binding(get: { stored(key, as: String.self) ?? "" }, set: { write(key, $0) }) }
    private func number(_ key: String) -> Binding<Double> {
        Binding(get: { (stored(key, as: Double.self) ?? stored(key, as: Int.self).map(Double.init)) ?? 0 },
                set: { write(key, WorkbenchPreferences.synced(key).integer == true ? Int($0.rounded()) as Any : (($0 * 100).rounded() / 100) as Any) })
    }
    private var wrapMode: Binding<String> {
        Binding(get: {
            let saved = defaults.string(forKey: "editorWordWrapMode") ?? ""
            return ["on", "wordWrapColumn", "bounded"].contains(saved) && editorWrap ? saved : (editorWrap ? "on" : "off")
        }, set: { defaults.set($0, forKey: "editorWordWrapMode"); editorWrap = $0 != "off" })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.harborBorder).frame(height: 1)
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    sidebar.frame(width: 190)
                    Rectangle().fill(Color.harborBorder).frame(width: 1)
                    if let browsing {
                        CodeSettingsList(model: code, title: browsing.title, sections: browsing.sections, place: place,
                                         folder: URL(fileURLWithPath: store.currentFiles.root).lastPathComponent, retry: attach, openJSON: openJSON)
                    } else {
                        // The miniature needs room; a narrow window keeps only the controls.
                        let preview = geometry.size.width >= 880
                        controls.frame(width: preview ? min(max(414, (geometry.size.width - 191) * 0.44), 540) : nil).frame(maxWidth: preview ? nil : .infinity)
                        if preview {
                            Rectangle().fill(Color.harborBorder).frame(width: 1)
                            previewPane.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                        }
                    }
                }
            }
        }
        .frame(minWidth: 600, maxWidth: .infinity, minHeight: 380, maxHeight: .infinity)
        .background(Color.harborBackground).foregroundStyle(Color.harborForeground).tint(.harborButton).harborFont().harborTypography()
        .environment(\.locale, Locale(identifier: "en"))
        .preferredColorScheme(HarborTheme.scheme(appearance))
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in revision &+= 1 }
        .onAppear { attach(); adoptFilter() }
        .onChange(of: store.settingsQuery) { _, _ in adoptFilter() }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .harborQASettings)) { note in
            if let text = note.userInfo?["query"] as? String { query = text }
            if let scope = (note.userInfo?["scope"] as? String).flatMap(CodeSettingsModel.Scope.init) { code.scope = scope }
        }
        #endif
    }

    private var place: String { store.selectedProfile?.name ?? "this Mac" }
    /// A filter the panel was asked to open with, such as "@ext:publisher.name".
    private func adoptFilter() {
        guard let filter = store.settingsQuery else { return }
        store.settingsQuery = nil; query = filter
    }
    /// The editor of this window, once its commands answer.
    private func attach() { code.attach(store.codeWorkbench.existing(for: store.currentFiles)) }

    /// What the right side lists when it is not one of Harbor's own pages.
    private var browsing: (title: String, sections: [SettingsCatalog.Section])? {
        let words = query.trimmingCharacters(in: .whitespaces)
        if !words.isEmpty {
            return ("Search Results", [SettingsCatalog.Section(id: "search", title: "", settings: code.catalog.search(words, modified: code.modified))])
        }
        guard current.hasPrefix("all:"), let found = code.catalog.section(String(current.dropFirst(4))) else { return nil }
        let single = found.sections.count == 1 ? found.sections[0] : nil
        return (single.map { $0.id == found.category.id ? $0.title : found.category.title + " › " + $0.title } ?? found.category.title, found.sections)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Settings").harborFont(16, weight: .semibold, design: .serif).frame(width: 170, alignment: .leading)
            SettingsSearchField(text: $query, autofocus: close != nil)
            Button { query = query.contains("@modified") ? query.replacingOccurrences(of: "@modified", with: "").trimmingCharacters(in: .whitespaces) : ("@modified " + query) } label: {
                Image(systemName: query.contains("@modified") ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 14)).frame(width: 28, height: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(query.contains("@modified") ? Color.harborAccent : Color.harborIcon)
                .help("Show only the settings you have changed").accessibilityLabel("Show modified settings")
            Spacer(minLength: 0)
            tool("Open Settings (JSON)", symbol: "curlybraces.square", identifier: "settings-json") { openJSON(nil) }.disabled(code.status != .ready)
            if let maximized {
                tool(maximized.wrappedValue ? "Restore" : "Maximize", symbol: maximized.wrappedValue ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                     identifier: "settings-maximize") { maximized.wrappedValue.toggle() }
            }
            if let close { tool("Close", symbol: "xmark", identifier: "settings-close", action: close) }
        }.padding(.leading, 18).padding(.trailing, 10).frame(height: 46).background(Color.harborSidebar)
    }
    private func tool(_ title: String, symbol: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 13)).frame(width: 28, height: 28).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(Color.harborIcon).help(title).accessibilityLabel(title).accessibilityIdentifier(identifier)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    caption("Harbor")
                    ForEach(Pane.all) { pane in row(pane.id, title: pane.title, symbol: pane.symbol) }
                    caption("All settings").padding(.top, 12)
                    ForEach(code.catalog.categories) { category in
                        row("all:" + category.id, title: category.title, symbol: category.symbol)
                        if query.isEmpty, current.hasPrefix("all:" + category.id), category.sections.count > 1 {
                            ForEach(category.sections.filter { $0.id != category.id }) { section in
                                row("all:" + section.id, title: section.title, symbol: nil).help(section.detail ?? section.title)
                            }
                        }
                    }
                }.padding(.horizontal, 8).padding(.vertical, 10)
            }
            Rectangle().fill(Color.harborBorder).frame(height: 1)
            Text(query.trimmingCharacters(in: .whitespaces).isEmpty && !current.hasPrefix("all:") ? "Harbor’s pages apply to every window and server." : "Saved with the editor on \(place).").harborFont(10.5).foregroundStyle(Color.harborMuted)
                .fixedSize(horizontal: false, vertical: true).padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxHeight: .infinity, alignment: .top).background(Color.harborSidebar)
    }
    private func caption(_ text: String) -> some View {
        Text(text).harborFont(10.5, weight: .semibold).foregroundStyle(Color.harborMuted).textCase(.uppercase).kerning(0.6)
            .padding(.horizontal, 10).padding(.bottom, 3)
    }
    /// A page in the sidebar. Rows without a symbol are the sections of the category above them.
    private func row(_ id: String, title: String, symbol: String?) -> some View {
        let selected = query.isEmpty && current == id
        return Button { tab = id; peek = nil; query = "" } label: {
            HStack(spacing: 9) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 13)).frame(width: 18).foregroundStyle(selected ? Color.harborAccent : Color.harborIcon)
                } else { Color.clear.frame(width: 18) }
                Text(title).harborFont(symbol == nil ? 12 : 13, weight: selected ? .medium : .regular).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: symbol == nil ? 25 : 30).contentShape(Rectangle())
            .background(selected ? Color.harborSelection : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    /// Older builds stored "text", "data" and a different "editor"; land them where their options went.
    private var current: String {
        if tab.hasPrefix("all:") { return code.catalog.section(String(tab.dropFirst(4))) == nil ? "appearance" : tab }
        switch tab { case "text": return "editor"; case "data": return "advanced"; default: return Pane.all.contains { $0.id == tab } ? tab : "appearance" }
    }

    private var controls: some View {
        Form {
            switch current {
            case "editor": editorSection
            case "terminal": terminalSection
            case "workbench": workbenchSection
            case "shortcuts": shortcutSection
            case "advanced": advancedSection
            default: appearanceSection
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden)
    }

    @ViewBuilder private var appearanceSection: some View {
        Section("Theme") {
            Picker("Theme", selection: themeFamily) {
                ForEach(HarborTheme.families) { family in Text(family.title).tag(family.id) }
            }
            Picker("Mode", selection: mode) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }.pickerStyle(.segmented)
            // Four to a row: each family's light and dark side by side, two families a row.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 10) {
                ForEach(ThemeChoice.all) { choice in
                    ThemeSwatch(choice: choice, selected: peek == nil && choice == applied && HarborTheme.mode(appearance) != "system" || peek == choice)
                        .onHover { inside in if inside { peek = choice } else if peek == choice { peek = nil } }
                        .onTapGesture { appearance = choice.selection; peek = nil }
                        .accessibilityAddTraits(.isButton).accessibilityLabel("Use " + choice.title)
                }
            }
            hint("Hover a theme to preview it; click to use it. " + shown.family.note)
        }
        Section("Start page dolls") {
            ForEach(AgentHarborAnimation.agents, id: \.self) { agent in dollRow(agent) }
            hint("Each agent on the start page has a doll. Choose a picture of your own to stand in for one; Harbor makes it land, hop and breathe like the others.")
        }
        Section("Interface") {
            sizeRow("Interface text", size: $interfaceFont, range: 11...20)
            Toggle("Liquid Glass", isOn: $liquidGlass).disabled(!HarborTheme.isStandard(appearance))
            Picker("Motion", selection: $motion) { Text("Full").tag("full"); Text("Subtle").tag("subtle"); Text("Off").tag("off") }
                .onChange(of: motion) { _, _ in replay += 1 }
            hint("Full adds staggered reveals and eased panels. Subtle keeps short fades and color changes; Off stops those too. macOS Reduce Motion always limits Harbor to Subtle.")
        }
    }

    @ViewBuilder private var editorSection: some View {
        Section("Font") {
            familyPicker("Font", key: "editor.fontFamily", inherit: nil)
            sizeRow("Size", size: $editorFont, range: 9...32)
            Picker("Line height", selection: number("editor.lineHeight")) {
                Text("Automatic").tag(0.0); Text("1.3").tag(1.3); Text("1.5").tag(1.5); Text("1.7").tag(1.7); Text("2.0").tag(2.0)
            }
            Toggle("Font ligatures", isOn: flag("editor.fontLigatures"))
        }
        Section("Cursor") {
            Picker("Style", selection: choice("editor.cursorStyle")) {
                Text("Line").tag("line"); Text("Thin line").tag("line-thin"); Text("Block").tag("block")
                Text("Block outline").tag("block-outline"); Text("Underline").tag("underline"); Text("Thin underline").tag("underline-thin")
            }
            Picker("Blinking", selection: choice("editor.cursorBlinking")) {
                Text("Blink").tag("blink"); Text("Smooth").tag("smooth"); Text("Phase").tag("phase"); Text("Expand").tag("expand"); Text("Solid").tag("solid")
            }
            Toggle("Glide between positions", isOn: Binding(get: { choice("editor.cursorSmoothCaretAnimation").wrappedValue == "on" },
                                                           set: { write("editor.cursorSmoothCaretAnimation", $0 ? "on" : "off") }))
        }
        Section("Text") {
            Picker("Word wrap", selection: wrapMode) {
                Text("Off").tag("off"); Text("At the window edge").tag("on"); Text("At the wrap column").tag("wordWrapColumn"); Text("Whichever is narrower").tag("bounded")
            }
            Stepper(value: number("editor.tabSize"), in: 1...8, step: 1) { LabeledContent("Tab size", value: "\(Int(number("editor.tabSize").wrappedValue))") }
            Toggle("Indent with spaces", isOn: flag("editor.insertSpaces"))
            Picker("Line numbers", selection: choice("editor.lineNumbers")) {
                Text("On").tag("on"); Text("Relative").tag("relative"); Text("Every tenth").tag("interval"); Text("Off").tag("off")
            }
            Picker("Show whitespace", selection: choice("editor.renderWhitespace")) {
                Text("Never").tag("none"); Text("In the selection").tag("selection"); Text("Between words").tag("boundary"); Text("At line ends").tag("trailing"); Text("Always").tag("all")
            }
            Toggle("Color matching brackets", isOn: flag("editor.bracketPairColorization.enabled"))
        }
        Section("Behavior") {
            Toggle("Minimap", isOn: flag("editor.minimap.enabled"))
            Toggle("Sticky scroll", isOn: flag("editor.stickyScroll.enabled"))
            Toggle("Smooth scrolling", isOn: flag("editor.smoothScrolling"))
            Toggle("Format on save", isOn: flag("editor.formatOnSave"))
            Picker("Auto save", selection: choice("files.autoSave")) {
                Text("Off").tag("off"); Text("After a delay").tag("afterDelay"); Text("When the editor loses focus").tag("onFocusChange"); Text("When the window loses focus").tag("onWindowChange")
            }
        }
    }

    @ViewBuilder private var terminalSection: some View {
        Section("Font") {
            familyPicker("Font", key: "terminal.integrated.fontFamily", inherit: "Same as the editor")
            sizeRow("Size", size: $terminalFont, range: 9...32)
            Picker("Line height", selection: number("terminal.integrated.lineHeight")) {
                Text("1.0").tag(1.0); Text("1.1").tag(1.1); Text("1.2").tag(1.2); Text("1.4").tag(1.4)
            }
        }
        Section("Cursor") {
            Picker("Style", selection: choice("terminal.integrated.cursorStyle")) { Text("Block").tag("block"); Text("Line").tag("line"); Text("Underline").tag("underline") }
                .pickerStyle(.segmented)
            Toggle("Blinking", isOn: flag("terminal.integrated.cursorBlinking"))
        }
        Section("Behavior") {
            Picker("Scrollback", selection: number("terminal.integrated.scrollback")) {
                Text("5,000 lines").tag(5_000.0); Text("10,000 lines").tag(10_000.0); Text("20,000 lines").tag(20_000.0)
                Text("50,000 lines").tag(50_000.0); Text("100,000 lines").tag(100_000.0)
                let value = number("terminal.integrated.scrollback").wrappedValue
                if ![5_000, 10_000, 20_000, 50_000, 100_000].contains(value) { Text("\(Int(value)) lines").tag(value) }
            }
            Toggle("Copy on selection", isOn: flag("terminal.integrated.copyOnSelection"))
            Toggle("Option key is Meta", isOn: flag("terminal.integrated.macOptionIsMeta"))
            hint("These apply to terminals in the editor and to Harbor’s own terminal windows.")
        }
    }

    @ViewBuilder private var workbenchSection: some View {
        Section("Sidebar") {
            Stepper(value: $activityCount, in: 1...12) { LabeledContent("Views above the sidebar", value: "\(activityCount)") }
            hint("The first views stay in the row above Explorer; the rest open from the arrow after them. Drag icons to reorder. The sidebar cannot be dragged narrower than this row; close it with ⌘B.")
        }
        Section("Editor area") {
            Picker("Tabs", selection: choice("workbench.editor.showTabs")) { Text("All open files").tag("multiple"); Text("Only the current file").tag("single"); Text("Hidden").tag("none") }
            Toggle("Breadcrumbs", isOn: flag("breadcrumbs.enabled"))
        }
        Section("Folders") {
            Toggle("Ask before trusting a folder", isOn: flag("security.workspace.trust.enabled"))
            hint("While on, a folder you have not trusted opens in Restricted Mode: tasks, debugging and most extensions wait for your answer. Turn it off if you only open folders on your own machines.")
        }
        Section("Assistant") {
            LabeledContent("Built-in AI suggestions", value: "Off")
            hint("Harbor ships without the editor’s built-in assistant. Typed completion and the extensions you install (Claude Code, Codex and others) are unaffected.")
        }
    }

    @ViewBuilder private var shortcutSection: some View {
        Section("Harbor") {
            HStack {
                Text("Terminal / Files & Code")
                Spacer()
                ShortcutRecorder(value: $modeShortcut) { shortcutError = $0 }.frame(width: 170, height: 28)
            }
            hint(shortcutError ?? "Click the box to record another shortcut; Esc cancels. ⌥X maximizes or restores the terminal panel.", warning: shortcutError != nil)
            Button("Reset to Option+Z") { modeShortcut = WorkspaceShortcut.standard.encoded; shortcutError = nil }
            LabeledContent("Switch folder in this window", value: "⌥⇥")
            LabeledContent("New window", value: "⇧⌘N")
            LabeledContent("Start page", value: "⇧⌘H")
        }
        Section("Terminal page") {
            LabeledContent("New terminal tab / close pane", value: "⌘T / ⌘W")
            LabeledContent("Split right / down", value: "⌘D / ⇧⌘D")
            LabeledContent("Previous / next pane", value: "⌥⌘← / ⌥⌘→")
            LabeledContent("Previous / next tab", value: "⇧⌘[ / ⇧⌘]")
            hint("For the terminal that Start ▸ New Terminal opens. In the editor these keys are its own terminal's.")
        }
        Section("Editor") {
            LabeledContent("Quick Open / Command Palette", value: "⌘P / ⇧⌘P")
            LabeledContent("Search in project", value: "⇧⌘F")
            LabeledContent("Go to symbol / line", value: "⇧⌘O / ⌃G")
            LabeledContent("Toggle sidebar / terminal", value: "⌘B / ⌘J")
            LabeledContent("Open folder / file", value: "⌥⌘O / ⌘O")
            Button("All Keyboard Shortcuts…") { openEditor("editorKeybindings") }
        }
    }

    @ViewBuilder private var advancedSection: some View {
        Section("Everything else") {
            hint("Every option of the editor and of the extensions you install is under All Settings in the sidebar, and the search box looks through all of them. Those are saved with each server’s editor; the pages above them apply everywhere.")
            Button("Browse All Settings") { tab = "all:commonlyUsed"; query = "" }
            Button("Open settings.json") { openJSON(nil) }.disabled(code.status != .ready)
        }
        Section("Data") {
            LabeledContent("Connection retention", value: "8 hours after the last terminal closes")
            LabeledContent("Recents", value: "12 recent servers and folders")
            Button("Open Local Data Folder") { NSWorkspace.shared.open(store.history.root) }
        }
        Section("Reset") {
            Button("Reset Editor and Terminal Options") {
                for setting in WorkbenchPreferences.synced where setting.key != "editor.wordWrap" { defaults.set(setting.default.any, forKey: setting.defaultsKey) }
                wrapMode.wrappedValue = "off"; interfaceFont = 13; revision += 1
            }
            hint("Themes, servers, folders and installed extensions are not touched.")
        }
        Section {
            Text("Harbor \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · SwiftUI / OpenSSH / SwiftTerm / Code-OSS")
                .harborFont(11).foregroundStyle(Color.harborMuted)
        }
    }

    private var options: PreviewOptions {
        var value = PreviewOptions()
        value.focus = current == "editor" ? .editor : current == "terminal" ? .terminal : .workbench
        value.selection = shown.selection; value.dark = shown.dark; value.glass = liquidGlass && shown.family.file == nil
        value.interfaceFont = interfaceFont; value.activityCount = activityCount
        value.breadcrumbs = flag("breadcrumbs.enabled").wrappedValue; value.tabs = choice("workbench.editor.showTabs").wrappedValue
        value.editorFamily = choice("editor.fontFamily").wrappedValue; value.editorFont = editorFont
        value.editorLineHeight = number("editor.lineHeight").wrappedValue
        value.cursorStyle = choice("editor.cursorStyle").wrappedValue; value.cursorBlinking = choice("editor.cursorBlinking").wrappedValue
        value.wrap = editorWrap; value.tabSize = Int(number("editor.tabSize").wrappedValue)
        value.lineNumbers = choice("editor.lineNumbers").wrappedValue; value.minimap = flag("editor.minimap.enabled").wrappedValue
        value.whitespace = choice("editor.renderWhitespace").wrappedValue; value.bracketColors = flag("editor.bracketPairColorization.enabled").wrappedValue
        value.terminalFamily = choice("terminal.integrated.fontFamily").wrappedValue; value.terminalFont = terminalFont
        value.terminalLineHeight = number("terminal.integrated.lineHeight").wrappedValue
        value.terminalCursor = choice("terminal.integrated.cursorStyle").wrappedValue; value.terminalBlink = flag("terminal.integrated.cursorBlinking").wrappedValue
        value.replay = replay
        return value
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Preview").harborFont(11, weight: .semibold).foregroundStyle(Color.harborMuted).textCase(.uppercase).kerning(0.6)
                Spacer()
                Text(shown.title + (peek == nil ? "" : " · not applied")).harborFont(11).foregroundStyle(Color.harborMuted)
            }
            SettingsPreview(options: options).frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Text("Changes apply to every Harbor window as you make them.").harborFont(11).foregroundStyle(Color.harborMuted)
                Spacer()
                Button("Replay Motion") { replay += 1 }.buttonStyle(.link).harborFont(11).disabled(motion == "off")
            }
        }.padding(20).background(Color.harborSidebar)
    }

    private func dollRow(_ agent: String) -> some View {
        let key = AgentHarborAnimation.dollKey(agent)
        _ = revision
        let path = defaults.string(forKey: key) ?? ""
        return HStack(spacing: 10) {
            Group {
                if let image = AgentHarborAnimation.pictures([path])[0] { Image(nsImage: image).resizable().interpolation(.high).scaledToFit() }
                else { Image(systemName: "figure.child").foregroundStyle(Color.harborMuted) }
            }.frame(width: 26, height: 26)
            Text(agent.capitalized)
            Spacer()
            Text(path.isEmpty ? "Built-in" : "Your picture").harborFont(11).foregroundStyle(Color.harborMuted)
            if !path.isEmpty { Button("Use Built-in") { defaults.removeObject(forKey: key); revision += 1 } }
            Button("Choose Picture…") { chooseDoll(agent) }
        }
    }
    /// Copies the chosen picture into Harbor's data folder, so it keeps working if the original moves.
    private func chooseDoll(_ agent: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.message = "Choose a picture for the \(agent.capitalized) doll"
        guard panel.runModal() == .OK, let source = panel.url, NSImage(contentsOf: source) != nil else { return }
        let folder = store.history.root.appendingPathComponent("Dolls", isDirectory: true)
        let target = folder.appendingPathComponent(agent + "-" + UUID().uuidString.prefix(8) + "." + (source.pathExtension.isEmpty ? "png" : source.pathExtension))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.copyItem(at: source, to: target)
            defaults.set(target.path, forKey: AgentHarborAnimation.dollKey(agent)); revision += 1
        } catch { store.errorMessage = "The picture could not be copied: \(error.localizedDescription)" }
    }

    private func openEditor(_ request: String) { store.workbenchUIRequest = request; close?() }
    /// Shows the settings file in the editor behind the panel, at one setting if given.
    private func openJSON(_ key: String?) {
        Task {
            guard await code.openJSON(key: key) else { return }
            store.page = .workspace; store.currentFiles.enabled = true; store.currentFiles.focusArea = .editor
            close?()
        }
    }

    private func hint(_ text: String, warning: Bool = false) -> some View {
        Text(text).harborFont(11).foregroundStyle(warning ? Color.orange : Color.harborMuted).fixedSize(horizontal: false, vertical: true)
    }

    private func sizeRow(_ title: String, size: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).frame(width: 96, alignment: .leading)
            Slider(value: size, in: range, step: 1).accessibilityLabel(title + " size")
            Text("\(Int(size.wrappedValue)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
            Stepper(title + " size", value: size, in: range, step: 1).labelsHidden().fixedSize()
        }
    }

    /// A family from this Mac's fixed-pitch fonts. The editor draws in Harbor's own window, so
    /// any font installed here works on every server.
    private func familyPicker(_ title: String, key: String, inherit: String?) -> some View {
        let list = choice(key).wrappedValue, selected = HarborTypography.family(in: list) ?? ""
        let families = HarborTypography.monospacedFamilies
        return Picker(title, selection: Binding(get: { list.isEmpty && inherit != nil ? "" : selected },
                                                set: { write(key, $0.isEmpty ? "" : ($0.contains(" ") ? "'\($0)'" : $0) + ", Menlo, Monaco, monospace") })) {
            if let inherit { Text(inherit).tag("") }
            ForEach(families, id: \.self) { family in Text(family).tag(family) }
            if !selected.isEmpty, !families.contains(selected) { Text(selected).tag(selected) }
            if selected.isEmpty, inherit == nil { Text("Menlo").tag("") }
        }
    }
}

/// The search box keeps what is being typed to itself and hands it on once typing pauses, so a
/// keystroke redraws this field and not the whole panel with a new list of results.
private struct SettingsSearchField: View {
    @Binding var text: String
    let autofocus: Bool
    @State private var draft = ""
    @State private var pending: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Color.harborMuted)
            TextField("Search all settings", text: $draft).textFieldStyle(.plain).harborFont(13).focused($focused)
                .accessibilityIdentifier("settings-search").onSubmit(commit)
            if !draft.isEmpty {
                Button { draft = ""; commit() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color.harborMuted) }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 9).frame(height: 28).frame(maxWidth: 520)
        .background(Color.harborInput, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(focused ? Color.harborFocus : Color.harborInputBorder, lineWidth: 1))
        .onAppear { draft = text; if autofocus { focused = true } }
        .onChange(of: text) { _, value in if value != draft { draft = value } }
        .onChange(of: draft) { _, _ in
            pending?.cancel()
            pending = Task { try? await Task.sleep(nanoseconds: 140_000_000); if !Task.isCancelled { commit() } }
        }
    }
    private func commit() { pending?.cancel(); if text != draft { text = draft } }
}

#if DEBUG
extension Notification.Name { static let harborQASettings = Notification.Name("harbor.qa.settings") }
#endif

/// A palette in miniature: sidebar, paper, an accent line and two lines of ink.
private struct ThemeSwatch: View {
    let choice: SettingsView.ThemeChoice
    let selected: Bool
    var body: some View {
        let palette = HarborTheme.palette(dark: choice.dark, selection: choice.selection)
        func color(_ role: String) -> Color { Color(nsColor: HarborTheme.hex(palette.colors[role] ?? "#808080")) }
        return VStack(spacing: 5) {
            HStack(spacing: 0) {
                color("sideBar.background").frame(width: 20)
                ZStack(alignment: .topLeading) {
                    color("editor.background")
                    VStack(alignment: .leading, spacing: 4) {
                        Capsule().fill(color("focusBorder")).frame(width: 20, height: 3)
                        Capsule().fill(color("editor.foreground").opacity(0.75)).frame(width: 30, height: 3)
                        Capsule().fill(color("descriptionForeground").opacity(0.6)).frame(width: 24, height: 3)
                    }.padding(7)
                }
            }
            .frame(height: 44).clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(selected ? Color.harborFocus : Color.harborBorder, lineWidth: selected ? 2 : 1))
            Text(choice.title).harborFont(10).foregroundStyle(selected ? Color.harborForeground : Color.harborMuted).lineLimit(1).minimumScaleFactor(0.8)
        }.frame(maxWidth: .infinity).contentShape(Rectangle())
    }
}
