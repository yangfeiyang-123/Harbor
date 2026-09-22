import SwiftUI
import HarborCore

enum WorkspaceSidebarMode { case explorer, search }
enum WorkspaceNavigatorMode: String, Identifiable {
    case files, commands, symbols, line
    var id: String { rawValue }
    var title: String {
        switch self { case .files: return "Quick Open"; case .commands: return "Command Palette"; case .symbols: return "Go to Symbol"; case .line: return "Go to Line" }
    }
}
struct CodeSymbol: Identifiable {
    let name: String
    let line: Int
    var id: Int { line }
    static func parse(_ text: String, markdown: Bool = false) -> [CodeSymbol] {
        // Lightweight document outline; no language server or remote index required.
        let pattern = #"^\s*(?:(?:public|private|protected|static|export|default|async|final|open)\s+)*(?:def|class|struct|enum|protocol|func|function|interface|type)\s+([\p{L}_$][\p{L}\p{N}_$]*)|^\s*(?:export\s+)?(?:const|let|var)\s+([\p{L}_$][\p{L}\p{N}_$]*)\s*=.*(?:=>|function)|^(#{1,6})\s+(.+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return text.components(separatedBy: "\n").prefix(10_000).enumerated().compactMap { offset, line in
            let ns = line as NSString
            guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
            guard (match.range(at: 4).location != NSNotFound) == markdown else { return nil }
            let name = [1, 2, 4].first(where: { match.range(at: $0).location != NSNotFound }).map { ns.substring(with: match.range(at: $0)) } ?? line
            return CodeSymbol(name: name, line: offset + 1)
        }
    }
}

extension FileWorkspace {
    func handleEditorKey(_ event: NSEvent) -> Bool {
        // Consume Close File before AppKit's standard Close Window command.
        // Inspect the actual responder, since clicking into WebKit need not
        // update SwiftUI's focus state (for example after a project search).
        guard event.type == .keyDown, event.keyCode == 13,
              event.modifierFlags.intersection(WorkspaceShortcut.modifierMask) == .command,
              enabled, !terminalMaximized, navigator == nil,
              let document = currentDocument, let web = document.editor?.web,
              let window = web.window, event.window === window,
              let responder = window.firstResponder as? NSView,
              responder === web || responder.isDescendant(of: web) else { return false }
        if !event.isARepeat { close(document) }
        return true
    }
    func openSearchHit(_ hit: WorkspaceSearchHit) async {
        await open(hit.entry)
        guard let document = currentDocument, let line = hit.line else { return }
        document.preview = false; document.pendingPosition = (line, hit.column ?? 1)
        document.editor?.reveal(line: line, column: hit.column ?? 1)
    }
    func goToLine(_ line: Int) {
        guard let document = currentDocument else { return }
        document.preview = false; document.pendingPosition = (max(1, line), 1)
        document.editor?.reveal(line: max(1, line)); requestFocus(.editor)
    }
    func revealInExplorer(_ path: String) async {
        explorerVisible = true; sidebarMode = .explorer
        let parent = (path as NSString).deletingLastPathComponent
        guard parent == root || parent.hasPrefix(root == "/" ? "/" : root + "/") else { return }
        var chain: [String] = []; var next = parent
        while next != root && next != "/" { chain.append(next); next = (next as NSString).deletingLastPathComponent }
        for folder in chain.reversed() { expanded.insert(folder); await loadChildren(folder) }
        selectedEntryPath = path; updateDirectoryWatchers(); requestFocus(.explorer)
    }
    func closeOtherDocuments(keeping document: WorkspaceDocument) {
        for other in documents where other.id != document.id { close(other) }
    }
}

struct WorkspaceNavigator: View {
    @ObservedObject var workspace: FileWorkspace
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let mode: WorkspaceNavigatorMode
    @State private var query = ""
    @State private var hits: [WorkspaceSearchHit] = []
    @State private var selection = 0
    @State private var busy = false
    @State private var message = ""
    @FocusState private var focused: Bool
    private let commands: [(String, String)] = [
        ("Quick Open File", "⌘P"), ("Search in Project", "⇧⌘F"), ("Go to Symbol", "⇧⌘O"), ("Go to Line", "⌃G"),
        ("Find / Replace in File", "⌘F"), ("Save File", "⌘S"), ("Toggle Word Wrap", ""),
        ("Toggle Explorer", "⌘B"), ("Toggle Outline", ""), ("Toggle Terminal Panel", "⌘J"),
        ("Maximize / Restore Terminal", "⌥X"), ("New Terminal Workspace", "⌃⇧`"),
        ("New File", ""), ("New Folder", ""), ("Open Folder Workspace", "⌥⌘O"),
        ("Collapse All Folders", ""), ("Refresh Explorer", ""), ("Reveal Active File in Explorer", ""),
        ("Close Active File", ""), ("Close Other Files", ""), ("Switch Files / Terminal Mode", "⌥Z")
    ]
    private var matchingCommands: [(String, String)] { commands.filter { query.isEmpty || $0.0.localizedCaseInsensitiveContains(query) } }
    private var symbols: [CodeSymbol] { CodeSymbol.parse(workspace.currentDocument?.text ?? "", markdown: workspace.currentDocument?.kind == .markdown).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) } }
    private var count: Int { mode == .files ? hits.count : mode == .commands ? matchingCommands.count : mode == .symbols ? symbols.count : 1 }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: mode == .files ? "doc.text.magnifyingglass" : "chevron.right")
                TextField(mode == .line ? "Line number" : mode.title, text: $query)
                    .textFieldStyle(.plain).focused($focused).onSubmit { choose() }
                    .onKeyPress(.downArrow) { selection = min(max(0, count - 1), selection + 1); return .handled }
                    .onKeyPress(.upArrow) { selection = max(0, selection - 1); return .handled }
                if busy { ProgressView().controlSize(.small) }
                Button("Esc") { dismiss() }.buttonStyle(.plain).foregroundStyle(WorkspaceTheme.muted)
            }.padding(14)
            Divider().overlay(WorkspaceTheme.border)
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        if mode == .files {
                            ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                                resultRow(index, title: hit.entry.name, detail: hit.relative, symbol: "doc", filePath: hit.entry.path)
                            }
                        } else if mode == .commands {
                            ForEach(Array(matchingCommands.enumerated()), id: \.offset) { index, command in
                                resultRow(index, title: command.0, detail: command.1, symbol: "chevron.right")
                            }
                        } else if mode == .symbols {
                            ForEach(Array(symbols.enumerated()), id: \.element.id) { index, symbol in
                                resultRow(index, title: symbol.name, detail: "Line \(symbol.line)", symbol: "curlybraces")
                            }
                        } else { Text("Enter a line number and press Return").foregroundStyle(WorkspaceTheme.muted).padding(22) }
                        if count == 0 && !busy { Text(mode == .symbols ? "No document symbols found" : "No results").foregroundStyle(WorkspaceTheme.muted).padding(22) }
                    }.padding(5)
                }.onChange(of: selection) { _, value in reader.scrollTo(value) }
            }.frame(height: mode == .line ? 65 : 300)
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(WorkspaceTheme.muted).padding(10).frame(maxWidth: .infinity, alignment: .leading) }
        }.frame(width: 600).background(WorkspaceTheme.sidebar).foregroundStyle(WorkspaceTheme.foreground)
            .onAppear { focused = true }.onExitCommand { dismiss() }
            .onChange(of: query) { _, _ in
                selection = 0
                if mode == .files { hits = []; busy = true }
            }
            .task(id: query) {
                guard mode == .files else { return }
                busy = true; message = ""
                do {
                    try await Task.sleep(nanoseconds: 180_000_000)
                    await workspace.prepare(store: store)
                    guard let service = workspace.service else { throw WorkspaceError.message(workspace.error ?? "Connect to load files.") }
                    let result = try await service.search(query, root: workspace.root, content: false, hidden: workspace.showHidden)
                    try Task.checkCancellation(); hits = result.hits
                    message = result.truncated ? "Showing the first matches. Narrow your search to find more." : "↑ ↓ to select · Return to open · Esc to close"
                    busy = false
                } catch is CancellationError { } catch { if !Task.isCancelled { message = error.localizedDescription; hits = []; busy = false } }
            }
    }
    private func resultRow(_ index: Int, title: String, detail: String, symbol: String, filePath: String? = nil) -> some View {
        Button { selection = index; choose() } label: {
            HStack(spacing: 10) {
                if let filePath { WorkspaceFileIcon(path: filePath) }
                else { Image(systemName: symbol).foregroundStyle(WorkspaceTheme.muted).frame(width: 18) }
                Text(title).lineLimit(1)
                Spacer(minLength: 10)
                Text(detail).font(.caption).foregroundStyle(WorkspaceTheme.muted).lineLimit(1).truncationMode(.middle)
            }.padding(.horizontal, 10).frame(height: 32).contentShape(Rectangle())
                .background(index == selection ? WorkspaceTheme.selection : .clear, in: RoundedRectangle(cornerRadius: 4))
        }.buttonStyle(.plain).id(index)
    }
    private func choose() {
        if mode == .files {
            guard !busy, hits.indices.contains(selection) else { return }; let hit = hits[selection]; dismiss(); Task { await workspace.openSearchHit(hit) }
        } else if mode == .symbols {
            guard symbols.indices.contains(selection) else { return }; let line = symbols[selection].line; dismiss(); workspace.goToLine(line)
        } else if mode == .line {
            guard let line = Int(query), line > 0 else { message = "Enter a positive line number."; return }; dismiss(); workspace.goToLine(line)
        } else {
            guard matchingCommands.indices.contains(selection) else { return }; let command = matchingCommands[selection].0
            switch command {
            case "Quick Open File": workspace.nextNavigator = .files
            case "Go to Symbol": workspace.nextNavigator = .symbols
            case "Go to Line": workspace.nextNavigator = .line
            default: break
            }
            dismiss()
            if workspace.nextNavigator == nil { Task { await Task.yield(); run(command) } }
        }
    }
    private func run(_ command: String) {
        switch command {
        case "Quick Open File": workspace.navigator = .files
        case "Search in Project": workspace.focusSearch()
        case "Go to Symbol": workspace.navigator = .symbols
        case "Go to Line": workspace.navigator = .line
        case "Find / Replace in File": workspace.currentDocument?.editor?.find()
        case "Save File": if let doc = workspace.currentDocument { Task { await workspace.save(doc) } }
        case "Toggle Word Wrap": UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "editorWrap"), forKey: "editorWrap")
        case "Toggle Explorer": workspace.explorerVisible.toggle()
        case "Toggle Outline": workspace.outlineVisible.toggle()
        case "Toggle Terminal Panel": store.toggleTerminalPanel()
        case "Maximize / Restore Terminal": store.toggleTerminalMaximized()
        case "New Terminal Workspace": store.openIndependentTerminal()
        case "New File": workspace.create(directory: false)
        case "New Folder": workspace.create(directory: true)
        case "Open Folder Workspace": store.chooseDirectoryWorkspace(from: workspace)
        case "Collapse All Folders": workspace.collapseFolders()
        case "Refresh Explorer": Task { await workspace.refreshExpanded(force: true) }
        case "Reveal Active File in Explorer": if let doc = workspace.currentDocument { Task { await workspace.revealInExplorer(doc.entry.path) } }
        case "Close Active File": if let doc = workspace.currentDocument { workspace.close(doc) }
        case "Close Other Files": if let doc = workspace.currentDocument { workspace.closeOtherDocuments(keeping: doc) }
        case "Switch Files / Terminal Mode": store.toggleFiles()
        default: break
        }
    }
}

struct WorkspaceBreadcrumbs: View {
    @ObservedObject var workspace: FileWorkspace
    @ObservedObject var document: WorkspaceDocument
    private var components: [(name: String, path: String)] {
        let relative = document.entry.path.hasPrefix(workspace.root + "/") ? String(document.entry.path.dropFirst(workspace.root.count + 1)) : document.entry.name
        var path = workspace.root
        return [((workspace.root as NSString).lastPathComponent, workspace.root)] + relative.split(separator: "/").map { part in
            path += "/" + part; return (String(part), path)
        }
    }
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(components.enumerated()), id: \.offset) { index, part in
                    if index > 0 { Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(WorkspaceTheme.muted) }
                    Button(part.name) { Task { await workspace.revealInExplorer(part.path == workspace.root ? document.entry.path : part.path) } }
                        .buttonStyle(.plain).lineLimit(1).help(part.path)
                }
                if document.text != nil {
                    Image(systemName: "chevron.right").font(.system(size: 8))
                    Button { workspace.navigator = .symbols } label: { Image(systemName: "curlybraces") }.buttonStyle(.plain).help("Go to Symbol · ⇧⌘O")
                }
            }.padding(.horizontal, 12).frame(height: 21)
        }.font(.system(size: 11)).foregroundStyle(WorkspaceTheme.muted).background(WorkspaceTheme.background)
    }
}

struct WorkspaceOutline: View {
    @ObservedObject var workspace: FileWorkspace
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(WorkspaceTheme.border).frame(height: 1)
            Button { workspace.outlineVisible.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: workspace.outlineVisible ? "chevron.down" : "chevron.right").font(.system(size: 9))
                    Text("OUTLINE").font(.system(size: 10, weight: .medium))
                    Spacer()
                }.padding(.horizontal, 10).frame(height: 27).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Toggle Outline")
            if workspace.outlineVisible {
                if let document = workspace.currentDocument {
                    DocumentOutline(workspace: workspace, document: document)
                } else { Text("Open a code file to see its outline").font(.caption).foregroundStyle(WorkspaceTheme.muted).padding(12) }
            }
        }
    }
}
private struct DocumentOutline: View {
    @ObservedObject var workspace: FileWorkspace
    @ObservedObject var document: WorkspaceDocument
    @State private var symbols: [CodeSymbol] = []
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(symbols) { symbol in
                    Button { workspace.goToLine(symbol.line) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "curlybraces").foregroundStyle(WorkspaceTheme.muted)
                            Text(symbol.name).lineLimit(1)
                            Spacer()
                            Text(String(symbol.line)).foregroundStyle(WorkspaceTheme.muted)
                        }.font(.system(size: 11)).padding(.horizontal, 12).frame(height: 24).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                if symbols.isEmpty { Text("No document symbols").font(.caption).foregroundStyle(WorkspaceTheme.muted).padding(12) }
            }
        }.frame(height: min(180, max(50, Double(symbols.count * 24))))
            .task(id: document.text) {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }; symbols = CodeSymbol.parse(document.text ?? "", markdown: document.kind == .markdown)
            }
    }
}

struct WorkspaceProjectSearch: View {
    @ObservedObject var workspace: FileWorkspace
    @EnvironmentObject var store: AppStore
    private var query: String { workspace.searchQuery }
    private var caseSensitive: Bool { workspace.searchCaseSensitive }
    @State private var results: WorkspaceSearchResult?
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TextField("Search in files", text: $workspace.searchQuery).textFieldStyle(.plain).focused($focused)
                Button("Aa") { workspace.searchCaseSensitive.toggle() }.buttonStyle(.plain).padding(3)
                    .background(caseSensitive ? WorkspaceTheme.selection : .clear, in: RoundedRectangle(cornerRadius: 3))
                    .help("Match Case").accessibilityLabel("Match Case")
            }.padding(7).background(WorkspaceTheme.background, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(WorkspaceTheme.border)).padding(10)
            if busy { ProgressView().controlSize(.small).padding(.horizontal, 12) }
            if let error { Text(error).font(.caption).foregroundStyle(.orange).padding(10) }
            if let results {
                Text("\(results.hits.count) matches" + (results.truncated ? " · limited" : "")).font(.caption).foregroundStyle(WorkspaceTheme.muted).padding(.horizontal, 12).padding(.bottom, 8)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(results.hits) { hit in
                            Button { Task { await workspace.openSearchHit(hit) } } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        WorkspaceFileIcon(path: hit.entry.path)
                                        Text(hit.relative).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                                    }
                                    Text("\(hit.line ?? 1)  \(hit.preview?.trimmingCharacters(in: .whitespaces) ?? "")").font(.system(size: 10, design: .monospaced)).foregroundStyle(WorkspaceTheme.muted).lineLimit(2)
                                }.padding(.horizontal, 12).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain).help(hit.relative)
                        }
                    }
                }
                if results.truncated || results.skipped > 0 {
                    Text("Search is limited to text files under 2 MB. Generated folders are skipped. Narrow the query for more results.").font(.caption2).foregroundStyle(WorkspaceTheme.muted).padding(10)
                }
            } else if !busy { Text("Search this folder and its subfolders.").font(.caption).foregroundStyle(WorkspaceTheme.muted).padding(12) }
            Spacer(minLength: 0)
        }.task(id: workspace.focusRequest) {
                guard workspace.focusArea == .search else { return }
                await Task.yield(); focused = true
            }
            .onChange(of: focused) { _, value in if value { workspace.focusArea = .search } }
            .task(id: "\(workspace.root)|\(query)|\(caseSensitive)") {
                error = nil; results = nil
                guard !query.isEmpty else { busy = false; return }; busy = true
                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                    await workspace.prepare(store: store)
                    guard let service = workspace.service else { throw WorkspaceError.message(workspace.error ?? "Connect to search files.") }
                    let found = try await service.search(query, root: workspace.root, content: true, caseSensitive: caseSensitive, hidden: workspace.showHidden)
                    try Task.checkCancellation(); results = found; busy = false
                } catch is CancellationError { } catch { if !Task.isCancelled { self.error = error.localizedDescription; busy = false } }
            }
    }
}
