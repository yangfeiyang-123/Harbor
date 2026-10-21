import SwiftUI
import AppKit

/// The settings of the editor and its extensions, one row each, for a category or a search.
struct CodeSettingsList: View {
    @ObservedObject var model: CodeSettingsModel
    let title: String
    let sections: [SettingsCatalog.Section]
    /// Where these values are kept, in the user's words ("2A6000", "This Mac").
    let place: String
    let folder: String
    var retry: () -> Void
    var openJSON: (String?) -> Void

    private var count: Int { sections.reduce(0) { $0 + $1.settings.count } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(title).harborFont(15, weight: .semibold, design: .serif).lineLimit(1)
                Text(count == 1 ? "1 setting" : "\(count) settings").harborFont(11).foregroundStyle(Color.harborMuted).lineLimit(1)
                Spacer(minLength: 8)
                Picker("Scope", selection: $model.scope) {
                    Text("User").tag(CodeSettingsModel.Scope.user); Text("Workspace").tag(CodeSettingsModel.Scope.workspace)
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
                    .help("User settings apply to every folder opened on \(place). Workspace settings are saved in \(folder)/.vscode and apply to that folder only.")
            }.padding(.horizontal, 18).frame(height: 46)
            Rectangle().fill(Color.harborBorder).frame(height: 1)
            if let banner { bannerView(banner) }
            if count == 0 {
                VStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 22)).foregroundStyle(Color.harborMuted)
                    Text("No settings found").harborFont(13, weight: .medium)
                    Text("Try fewer words, or the name of an extension.").harborFont(11).foregroundStyle(Color.harborMuted)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections) { section in
                            Section {
                                ForEach(section.settings) { setting in
                                    CodeSettingRow(setting: setting, model: model, openJSON: openJSON)
                                }
                            } header: { if sections.count > 1 { header(section) } }
                        }
                    }.padding(.vertical, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.harborBackground)
    }

    private func header(_ section: SettingsCatalog.Section) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(section.title).harborFont(11, weight: .semibold).textCase(.uppercase).kerning(0.6)
            if let detail = section.detail { Text(detail).harborFont(11) }
            Spacer()
        }.foregroundStyle(Color.harborMuted).padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 6)
            .frame(maxWidth: .infinity).background(Color.harborBackground)
    }

    private var banner: (text: String, action: String?)? {
        switch model.status {
        case .unavailable: return ("Open a folder to change these. They are saved with the editor of the server the folder is on, and its values appear here.", "Check Again")
        case .loading: return ("Reading the settings of \(place)…", nil)
        case .failed(let reason): return ("The settings of \(place) could not be read: \(reason)", "Try Again")
        case .ready: return model.notice.map { ($0, nil) }
        }
    }
    private func bannerView(_ banner: (text: String, action: String?)) -> some View {
        HStack(spacing: 10) {
            Image(systemName: model.status == .loading ? "arrow.triangle.2.circlepath" : "info.circle").foregroundStyle(Color.harborAccent)
            Text(banner.text).harborFont(11.5).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let action = banner.action { Button(action, action: retry).controlSize(.small) }
        }.padding(.horizontal, 18).padding(.vertical, 9).background(Color.harborSidebar)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.harborBorder).frame(height: 1) }
    }
}

/// One setting: its name, what it does, and the control for its kind of value.
struct CodeSettingRow: View {
    let setting: CodeSetting
    @ObservedObject var model: CodeSettingsModel
    var openJSON: (String?) -> Void
    @State private var hovering = false

    var body: some View {
        let value = model.value(setting), modified = model.isModified(setting)
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 1).fill(modified ? Color.harborAccent : .clear).frame(width: 2)
                .accessibilityLabel(modified ? "Modified" : "").accessibilityHidden(!modified)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    if !setting.category.isEmpty { Text(setting.category + ": ").harborFont(12.5).foregroundStyle(Color.harborMuted) }
                    Text(setting.label).harborFont(12.5, weight: .semibold)
                    if model.isModifiedElsewhere(setting) {
                        Text(model.scope == .user ? "  also set for this folder" : "  also set for the user").harborFont(11).italic().foregroundStyle(Color.harborMuted)
                    }
                }.lineLimit(1).truncationMode(.middle)
                if let deprecated = setting.deprecated, !deprecated.isEmpty {
                    Text(SettingsCatalog.prose(deprecated)).harborFont(11.5).foregroundStyle(Color.harborWarning).fixedSize(horizontal: false, vertical: true)
                }
                control(value)
            }
            Spacer(minLength: 0)
            Menu {
                Button("Reset Setting") { model.reset(setting) }.disabled(!modified || model.status != .ready)
                Divider()
                Button("Copy Setting ID") { copy(setting.key) }
                Button("Copy Setting as JSON") { copy("\"\(setting.key)\": " + (value ?? .null).json) }
                Button("Edit in settings.json") { openJSON(setting.key) }.disabled(model.status != .ready)
            } label: { Image(systemName: "gearshape").font(.system(size: 12)).foregroundStyle(Color.harborIcon).frame(width: 24, height: 22) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().opacity(hovering ? 1 : 0)
                .accessibilityLabel("More actions for " + setting.label)
        }
        .padding(.leading, 8).padding(.trailing, 12).padding(.vertical, 9)
        .background(hovering ? Color.harborHover.opacity(0.55) : .clear)
        .contentShape(Rectangle()).onHover { hovering = $0 }
        .contextMenu {
            Button("Reset Setting") { model.reset(setting) }.disabled(!modified || model.status != .ready)
            Button("Copy Setting ID") { copy(setting.key) }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("setting-" + setting.key)
    }

    private var ready: Bool { model.status == .ready }
    private var prose: Text { Text(SettingsCatalog.prose(setting.description)) }

    @ViewBuilder private func control(_ value: JSONValue?) -> some View {
        if !setting.shows(value) {
            description
            HStack(spacing: 8) {
                if let value, value != .null {
                    Text(value.json).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.harborMuted).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: 320, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                }
                Button("Edit in settings.json") { openJSON(setting.key) }.buttonStyle(.link).harborFont(12).disabled(!ready)
            }
        } else {
            switch setting.kind {
            case .toggle:
                Toggle(isOn: Binding(get: { value == .bool(true) }, set: { model.set(setting, to: .bool($0)) })) {
                    prose.harborFont(12).foregroundStyle(Color.harborForeground.opacity(0.86)).fixedSize(horizontal: false, vertical: true)
                }.toggleStyle(.checkbox).disabled(!ready)
            case .choice:
                description
                choice(value)
            case .number(let integer):
                description
                SettingField(text: value.map { $0.label } ?? "", width: 120, enabled: ready) { text in
                    let trimmed = text.trimmingCharacters(in: .whitespaces)
                    guard let number = Double(trimmed), number.isFinite, !integer || number.rounded() == number,
                          number >= setting.minimum ?? -.infinity, number <= setting.maximum ?? .infinity else { return false }
                    model.set(setting, to: .number(number)); return true
                }
            case .text:
                description
                SettingField(text: value == .null ? "" : value?.label ?? "", width: 340, enabled: ready, multiline: setting.multiline) { text in
                    model.set(setting, to: .string(text)); return true
                }
            case .list:
                description
                SettingList(items: value?.strings ?? [], enabled: ready) { model.set(setting, to: .array($0.map(JSONValue.string))) }
            case .json: EmptyView()
            }
        }
    }
    @ViewBuilder private var description: some View {
        if !setting.description.isEmpty {
            prose.harborFont(12).foregroundStyle(Color.harborForeground.opacity(0.86)).fixedSize(horizontal: false, vertical: true)
        }
    }
    @ViewBuilder private func choice(_ value: JSONValue?) -> some View {
        let options = setting.options + (value.map { setting.options.contains($0) ? [] : [$0] } ?? [])
        let selected = value ?? setting.options.first ?? .null
        Picker(setting.label, selection: Binding(get: { selected }, set: { model.set(setting, to: $0) })) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let label = index < setting.optionLabels.count && !setting.optionLabels[index].isEmpty ? setting.optionLabels[index] : option.label
                Text(option == setting.fallback ? label + "  (default)" : label).tag(option)
            }
        }.labelsHidden().frame(maxWidth: 340, alignment: .leading).fixedSize().disabled(!ready)
        if let index = setting.options.firstIndex(of: selected), index < setting.optionDescriptions.count, !setting.optionDescriptions[index].isEmpty {
            Text(SettingsCatalog.prose(setting.optionDescriptions[index])).harborFont(11).foregroundStyle(Color.harborMuted).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
}

/// A text box that writes when Return is pressed or the box is left, and says so when
/// what was typed is not a value the setting takes.
private struct SettingField: View {
    let text: String
    let width: CGFloat
    let enabled: Bool
    var multiline = false
    let commit: (String) -> Bool
    @State private var draft = ""
    @State private var rejected = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("", text: $draft, axis: multiline ? .vertical : .horizontal).textFieldStyle(.roundedBorder).harborFont(12)
                .lineLimit(multiline ? 6 : 1).frame(width: width).focused($focused).disabled(!enabled)
                .onSubmit(apply)
            if rejected { Text("Not a value this setting takes").harborFont(11).foregroundStyle(Color.harborWarning) }
        }
        .onAppear { draft = text }
        .onChange(of: text) { _, value in if !focused || !rejected { draft = value; rejected = false } }
        .onChange(of: focused) { _, now in if !now { apply() } }
    }
    private func apply() {
        guard draft != text else { rejected = false; return }
        rejected = !commit(draft)
    }
}

/// A list of text items: remove any, add one at the end.
private struct SettingList: View {
    let items: [String]
    let enabled: Bool
    let commit: ([String]) -> Void
    @State private var addition = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(spacing: 6) {
                    Text(item).font(.system(size: 11.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    Button { var next = items; next.remove(at: index); commit(next) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                        .buttonStyle(.plain).foregroundStyle(Color.harborMuted).disabled(!enabled).accessibilityLabel("Remove " + item)
                }.padding(.horizontal, 8).frame(width: 340, height: 22)
                    .background(Color.harborInput, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            HStack(spacing: 6) {
                TextField("Add an item", text: $addition).textFieldStyle(.roundedBorder).harborFont(12).frame(width: 268).disabled(!enabled).onSubmit(add)
                Button("Add", action: add).disabled(!enabled || addition.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
    private func add() {
        let item = addition.trimmingCharacters(in: .whitespaces)
        guard !item.isEmpty else { return }
        commit(items + [item]); addition = ""
    }
}
