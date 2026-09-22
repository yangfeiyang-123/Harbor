import SwiftUI
import HarborCore

/// Browsing never changes a workspace. Only the final Open action commits it.
@MainActor
final class DirectoryBrowser: ObservableObject, Identifiable {
    let id = UUID()
    let profile: ServerProfile?
    @Published private(set) var path: String
    @Published private(set) var currentPath = ""
    @Published private(set) var folders: [WorkspaceEntry] = []
    @Published private(set) var candidatePath: String?
    @Published private(set) var loading = false
    @Published var error: String?
    @Published var opening = false
    @Published private(set) var truncated = false
    private let list: (String) async throws -> WorkspaceListing
    private var request: Task<Void, Never>?
    private var generation = UUID()

    init(profile: ServerProfile?, path: String, list: @escaping (String) async throws -> WorkspaceListing) {
        self.profile = profile
        self.path = path.isEmpty ? "~/" : (path.hasSuffix("/") ? path : path + "/")
        self.list = list
    }
    deinit { request?.cancel() }
    var canOpen: Bool { candidatePath != nil && !loading && !opening && error == nil }
    var parentPath: String { currentPath.isEmpty ? "~" : (currentPath as NSString).deletingLastPathComponent }
    func cancel() { generation = UUID(); request?.cancel(); request = nil; loading = false }
    func browse(_ value: String) { schedule(directory: resolved(value), prefix: "", delay: false, replacePath: true) }
    func submitPath() { browse(candidatePath ?? path) }
    func editPath(_ value: String) {
        // A TextField may echo its value while mounting. Keep the initial
        // directory request instead of interpreting that echo as a search.
        guard value != path else { return }
        path = value
        let input = resolved(value)
        if input.hasSuffix("/") || input == "~" {
            schedule(directory: input, prefix: "", delay: true, replacePath: false)
        } else {
            schedule(directory: (input as NSString).deletingLastPathComponent,
                     prefix: (input as NSString).lastPathComponent, delay: true, replacePath: false)
        }
    }
    private func resolved(_ value: String) -> String {
        if value.isEmpty { return "~" }
        if value.hasPrefix("/") || value.hasPrefix("~") { return value }
        return ((currentPath.isEmpty ? "~" : currentPath) as NSString).appendingPathComponent(value)
    }
    private func schedule(directory: String, prefix: String, delay: Bool, replacePath: Bool) {
        request?.cancel()
        let token = UUID(); generation = token
        loading = true; candidatePath = nil; error = nil
        if replacePath { path = directory }
        request = Task { [weak self, list] in
            do {
                if delay { try await Task.sleep(for: .milliseconds(240)) }
                let listing = try await list(directory.isEmpty ? "/" : directory)
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                let directories = listing.entries.filter(\.directory)
                self.currentPath = listing.path
                self.folders = directories.filter { prefix.isEmpty || $0.name.localizedStandardContains(prefix) }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                self.candidatePath = prefix.isEmpty ? listing.path : directories.first(where: { $0.name == prefix })?.path
                if replacePath { self.path = listing.path == "/" ? "/" : listing.path + "/" }
                self.truncated = listing.truncated; self.loading = false
            } catch {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.folders = []; self.candidatePath = nil; self.loading = false; self.error = error.localizedDescription
            }
        }
    }
}

struct DirectoryBrowserView: View {
    @ObservedObject var browser: DirectoryBrowser
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var pathFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Open Folder").harborFont(20, weight: .semibold)
                    Label(browser.profile?.name ?? "Local", systemImage: browser.profile?.displayIcon ?? "laptopcomputer")
                        .harborFont(12).foregroundStyle(Color.harborMuted)
                }
                Spacer()
                Button { browser.browse("~") } label: { HarborSymbol(systemName: "house").frame(width: 28, height: 28) }
                    .buttonStyle(HarborGlassButtonStyle()).help("Home directory").accessibilityLabel("Home directory")
            }
            HStack(spacing: 10) {
                TextField("Folder path", text: Binding(get: { browser.path }, set: browser.editPath))
                    .textFieldStyle(HarborTextFieldStyle()).focused($pathFocused).onSubmit { browser.submitPath() }
                    .accessibilityIdentifier("directory-browser-path")
                if browser.loading { ProgressView().controlSize(.small).frame(width: 22) }
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    if !browser.currentPath.isEmpty && browser.currentPath != "/" {
                        folderRow("..", detail: "Parent directory", symbol: "arrow.up") { browser.browse(browser.parentPath) }
                    }
                    ForEach(browser.folders) { entry in
                        folderRow(entry.name, detail: entry.path, symbol: "folder") { browser.browse(entry.path) }
                    }
                    if let error = browser.error {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(error).foregroundStyle(Color.harborMuted).textSelection(.enabled)
                            Button("Try Again") { browser.submitPath() }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    } else if !browser.loading && browser.folders.isEmpty {
                        Text(browser.canOpen ? "No subfolders. You can open this folder." : "No matching folders.")
                            .foregroundStyle(Color.harborMuted).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }
                    if browser.truncated {
                        Text("This folder contains many items. Enter a more specific path to continue.")
                            .foregroundStyle(Color.harborMuted).padding(12)
                    }
                }.padding(5)
            }.background(Color.harborEditor, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.harborBorder, lineWidth: 1))
                .accessibilityIdentifier("directory-browser-folders")
            HStack {
                Text("Browse folders, then confirm to open a workspace.").harborFont(11).foregroundStyle(Color.harborMuted)
                Spacer()
                Button("Cancel") { browser.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button(browser.opening ? "Opening…" : "Open Folder") { confirm() }.buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).disabled(!browser.canOpen).accessibilityIdentifier("directory-browser-confirm")
            }
        }.padding(22).frame(width: 620, height: 520).harborFont(12)
            .foregroundStyle(Color.harborForeground).background(Color.harborBackground).tint(.harborButton)
            .environment(\.locale, Locale(identifier: "en"))
            .disabled(browser.opening).interactiveDismissDisabled(browser.opening)
            .onAppear { browser.browse(browser.path) }.onDisappear { browser.cancel() }
    }
    private func folderRow(_ title: String, detail: String, symbol: String, action: @escaping () -> Void) -> some View {
        DirectoryBrowserRow(title: title, detail: detail, symbol: symbol, action: action)
    }
    private func confirm() {
        guard browser.canOpen, let path = browser.candidatePath else { return }
        browser.opening = true
        Task {
            let opened = await store.openDirectoryWorkspace(path, profile: browser.profile)
            browser.opening = false
            if opened != nil { dismiss() }
            else { browser.error = store.errorMessage ?? "Unable to open this folder."; store.errorMessage = nil }
        }
    }
}

private struct DirectoryBrowserRow: View {
    let title: String, detail: String, symbol: String
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                HarborSymbol(systemName: symbol).foregroundStyle(Color.harborAccent).frame(width: 20)
                Text(title).lineLimit(1).truncationMode(.middle)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Color.harborMuted)
            }.padding(.horizontal, 10).frame(height: 32).contentShape(Rectangle())
        }.buttonStyle(.plain).background(hovered ? Color.harborHover : .clear, in: RoundedRectangle(cornerRadius: 6))
            .onHover { hovered = $0 }.help(detail).accessibilityLabel(title)
    }
}
