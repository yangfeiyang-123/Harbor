import Foundation

/// A value as settings.json holds it.
enum JSONValue: Hashable, Decodable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }
    init?(any: Any) {
        switch any {
        case is NSNull: self = .null
        case let number as NSNumber: self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let text as String: self = .string(text)
        case let list as [Any]: self = .array(list.compactMap(JSONValue.init(any:)))
        case let dictionary as [String: Any]: self = .object(dictionary.compactMapValues(JSONValue.init(any:)))
        default: return nil
        }
    }
    var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value.rounded() == value && abs(value) < 1e15 ? Int(value) as Any : value
        case .string(let value): return value
        case .array(let value): return value.map(\.any)
        case .object(let value): return value.mapValues(\.any)
        }
    }
    /// Compact JSON, as the value would appear in settings.json.
    var json: String {
        let data = try? JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }
    /// What a menu shows for this value.
    var label: String { if case .string(let text) = self { return text }; return json }
    var strings: [String]? {
        guard case .array(let items) = self else { return nil }
        let texts = items.compactMap { item -> String? in if case .string(let text) = item { return text }; return nil }
        return texts.count == items.count ? texts : nil
    }
}

/// One setting of the editor or of an extension.
struct CodeSetting: Identifiable, Decodable {
    enum Kind: Equatable { case toggle, choice, number(integer: Bool), text, list, json }
    let key: String
    let kind: Kind
    let fallback: JSONValue?
    let options: [JSONValue]
    let optionDescriptions: [String]
    let optionLabels: [String]
    let description: String
    let deprecated: String?
    let minimum: Double?
    let maximum: Double?
    let order: Double?
    let multiline: Bool
    /// "Editor › Minimap" for editor.minimap.enabled.
    let category: String
    /// "Enabled" for editor.minimap.enabled.
    let label: String
    /// Lowercased key and title, then description: what search looks through.
    let title: String
    let prose: String
    var id: String { key }

    private enum CodingKeys: String, CodingKey {
        case key, type, `default`, `enum`, enumDescriptions, enumItemLabels, description, deprecated, minimum, maximum, order, multiline, items
    }
    private struct Items: Decodable { var type: String? }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        let types = ((try? container.decode(String.self, forKey: .type)).map { [$0] } ?? (try? container.decode([String].self, forKey: .type)) ?? []).filter { $0 != "null" }
        fallback = try? container.decode(JSONValue.self, forKey: .default)
        options = (try? container.decode([JSONValue].self, forKey: .enum)) ?? []
        optionDescriptions = (try? container.decode([String].self, forKey: .enumDescriptions)) ?? []
        optionLabels = (try? container.decode([String].self, forKey: .enumItemLabels)) ?? []
        description = (try? container.decode(String.self, forKey: .description)) ?? ""
        deprecated = try? container.decode(String.self, forKey: .deprecated)
        minimum = try? container.decode(Double.self, forKey: .minimum)
        maximum = try? container.decode(Double.self, forKey: .maximum)
        order = try? container.decode(Double.self, forKey: .order)
        multiline = (try? container.decode(Bool.self, forKey: .multiline)) ?? false
        let items = try? container.decode(Items.self, forKey: .items)
        if !options.isEmpty { kind = .choice }
        else {
            switch types {
            case ["boolean"]: kind = .toggle
            case ["number"]: kind = .number(integer: false)
            case ["integer"]: kind = .number(integer: true)
            case ["string"]: kind = .text
            case ["array"]: kind = items?.type == "string" ? .list : .json
            case []:
                // Several shapes are allowed; offer the one the default uses.
                switch fallback {
                case .bool: kind = .toggle
                case .number: kind = .number(integer: false)
                case .string: kind = .text
                default: kind = .json
                }
            default: kind = .json
            }
        }
        let parts = key.split(separator: ".").map(String.init)
        category = parts.dropLast().map(CodeSetting.words).joined(separator: " › ")
        label = CodeSetting.words(parts.last ?? key)
        title = (key + " " + category + ": " + label).lowercased()
        prose = (description + " " + options.map(\.label).joined(separator: " ")).lowercased()
    }

    /// Whether this setting's control can show `value`; otherwise it is edited as JSON.
    func shows(_ value: JSONValue?) -> Bool {
        guard let value else { return kind != .json }
        switch (kind, value) {
        case (.toggle, .bool), (.number, .number), (.text, .string), (.text, .null): return true
        case (.choice, .bool), (.choice, .number), (.choice, .string), (.choice, .null): return true
        case (.list, _): return value.strings != nil
        default: return false
        }
    }

    private static let acronyms: Set<String> = ["css", "html", "scss", "less", "json", "js", "ts", "id", "php", "scm", "url", "ui", "ai", "mcp", "npm", "http", "ssh", "ie"]
    /// "fontSize" becomes "Font Size", the way the editor titles its settings.
    static func words(_ key: String) -> String {
        var out = "", previous: Character?
        for character in key {
            if let last = previous, character.isUppercase, last.isLowercase || last.isNumber { out.append(" ") }
            out.append(character); previous = character
        }
        return out.split(separator: " ").map { word -> String in
            acronyms.contains(word.lowercased()) ? word.uppercased() : word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }
}

/// Every setting, arranged the way the editor's own Settings editor arranges them.
struct SettingsCatalog {
    struct Group: Decodable {
        let owner: String, name: String, title: String, order: Double, settings: [CodeSetting]
        private enum CodingKeys: String, CodingKey { case owner = "extension", name, title, order, settings }
    }
    struct Section: Identifiable {
        let id: String, title: String
        /// The extension a section belongs to, when its title alone does not say.
        var detail: String?
        let settings: [CodeSetting]
    }
    struct Category: Identifiable {
        let id: String, title: String, symbol: String
        let sections: [Section]
        var count: Int { sections.reduce(0) { $0 + $1.settings.count } }
    }
    struct Bundled: Decodable { let runtime: String, editor: String, settings: [CodeSetting], groups: [Group] }

    static let bundled: Bundled = {
        let url = AppResources.directory("CodeWorkbench").appendingPathComponent("code-settings-catalog.json")
        return try! JSONDecoder().decode(Bundled.self, from: Data(contentsOf: url))
    }()

    let categories: [Category]
    /// Each setting once, in the order of the categories.
    let all: [CodeSetting]
    let keys: Set<String>
    /// The extension that contributes a setting, lowercased; the editor's own have none.
    let owners: [String: String]

    /// `installed` are the settings of extensions installed on the server at hand.
    init(installed: [Group] = []) {
        let builtin = Self.bundled.groups, mine = Set(builtin.map(\.owner))
        let groups = (builtin + installed.filter { !mine.contains($0.owner) }).sorted {
            ($0.name.lowercased(), $0.order, $0.title) < ($1.name.lowercased(), $1.order, $1.title)
        }
        let extensions = Category(id: "extensions", title: "Extensions", symbol: "puzzlepiece.extension", sections: groups.enumerated().map { index, group in
            Section(id: "extensions/\(group.owner)/\(index)", title: group.title, detail: group.title == group.name ? nil : group.name,
                    settings: group.settings.sorted { ($0.order ?? .infinity, $0.key) < ($1.order ?? .infinity, $1.key) })
        })
        categories = Self.core + [extensions]
        var owners: [String: String] = [:]
        for group in groups { for setting in group.settings { owners[setting.key] = group.owner.lowercased() } }
        self.owners = owners
        var seen = Set<String>(), ordered: [CodeSetting] = []
        for category in categories where category.id != "commonlyUsed" {
            for section in category.sections { for setting in section.settings where seen.insert(setting.key).inserted { ordered.append(setting) } }
        }
        all = ordered; keys = seen
    }

    func section(_ id: String) -> (category: Category, sections: [Section])? {
        for category in categories {
            if category.id == id { return (category, category.sections) }
            if let section = category.sections.first(where: { $0.id == id }) { return (category, [section]) }
        }
        return nil
    }

    /// Settings matching every word of `query`, best matches first. `@modified` keeps only `modified`,
    /// `@ext:publisher.name` one extension's settings and `@id:key` one setting, as in the editor.
    func search(_ query: String, modified: Set<String> = []) -> [CodeSetting] {
        var words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let onlyModified = words.contains("@modified"); words.removeAll { $0 == "@modified" }
        func filter(_ prefix: String) -> Set<String> {
            let found = words.filter { $0.hasPrefix(prefix) }.flatMap { $0.dropFirst(prefix.count).split(separator: ",").map(String.init) }
            words.removeAll { $0.hasPrefix(prefix) }
            return Set(found)
        }
        let extensions = filter("@ext:"), ids = filter("@id:")
        guard onlyModified || !words.isEmpty || !extensions.isEmpty || !ids.isEmpty else { return [] }
        var found: [(setting: CodeSetting, score: Int, index: Int)] = []
        let phrase = words.joined(separator: " ")
        for (index, setting) in all.enumerated() {
            if onlyModified, !modified.contains(setting.key) { continue }
            if !extensions.isEmpty, !(owners[setting.key].map(extensions.contains) ?? false) { continue }
            if !ids.isEmpty, !ids.contains(setting.key.lowercased()) { continue }
            let label = setting.label.lowercased()
            var score = 0, matched = true
            for word in words {
                if setting.title.contains(word) { score += label.contains(word) ? 3 : 2 }
                else if setting.prose.contains(word) { score += 1 }
                else { matched = false; break }
            }
            // "font size" should find Font Size before Code Lens Font Size; a pasted key finds its setting.
            if matched, !phrase.isEmpty {
                if label == phrase || setting.key.lowercased() == phrase { score += 20 }
                else if label.hasPrefix(phrase) { score += 6 }
                else if setting.title.contains(phrase) { score += 3 }
            }
            if matched { found.append((setting, score, index)) }
        }
        // Among equals the plainer setting comes first: editor.fontSize before editor.inlayHints.fontSize.
        func depth(_ setting: CodeSetting) -> Int { setting.key.reduce(0) { $1 == "." ? $0 + 1 : $0 } }
        return found.sorted { ($1.score, depth($0.setting), $0.index) < ($0.score, depth($1.setting), $1.index) }.map(\.setting)
    }

    /// settings.json nests "editor.fontSize" as editor → fontSize; this undoes it. A known
    /// setting keeps its whole value, so objects such as files.exclude stay in one piece.
    func flatten(_ tree: [String: Any]) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        func walk(_ value: Any, _ path: String) {
            let dictionary = value as? [String: Any]
            // An empty object is what the editor reports for launch and tasks when nothing is set.
            if dictionary?.isEmpty == true { return }
            if !keys.contains(path), let dictionary {
                for (name, child) in dictionary { walk(child, path.isEmpty ? name : path + "." + name) }
            } else if !path.isEmpty, let value = JSONValue(any: value) { out[path] = value }
        }
        walk(tree, "")
        return out
    }

    // MARK: The editor's table of contents

    private struct Node {
        let id: String, title: String
        var symbol = ""
        var patterns: [String] = []
        var children: [Node] = []
    }
    private static let commonlyUsed = ["files.autoSave", "editor.fontSize", "editor.fontFamily", "editor.tabSize", "editor.renderWhitespace", "editor.cursorStyle",
                                       "editor.multiCursorModifier", "editor.insertSpaces", "editor.wordWrap", "files.exclude", "files.associations", "workbench.editor.enablePreview"]
    private static let contents: [Node] = [
        Node(id: "editor", title: "Text Editor", symbol: "text.alignleft", patterns: ["editor.*"], children: [
            Node(id: "editor/cursor", title: "Cursor", patterns: ["editor.cursor*"]),
            Node(id: "editor/find", title: "Find", patterns: ["editor.find.*"]),
            Node(id: "editor/font", title: "Font", patterns: ["editor.font*"]),
            Node(id: "editor/format", title: "Formatting", patterns: ["editor.format*"]),
            Node(id: "editor/diffEditor", title: "Diff Editor", patterns: ["diffEditor.*", "multiDiffEditor.*"]),
            Node(id: "editor/minimap", title: "Minimap", patterns: ["editor.minimap.*"]),
            Node(id: "editor/suggestions", title: "Suggestions", patterns: ["editor.*suggest*"]),
            Node(id: "editor/files", title: "Files", patterns: ["files.*"])]),
        Node(id: "workbench", title: "Workbench", symbol: "macwindow", patterns: ["workbench.*"], children: [
            Node(id: "workbench/appearance", title: "Appearance", patterns: ["workbench.activityBar.*", "workbench.*color*", "workbench.fontAliasing", "workbench.iconTheme",
                "workbench.sidebar.location", "workbench.*.visible", "workbench.tips.enabled", "workbench.tree.*", "workbench.view.*"]),
            Node(id: "workbench/breadcrumbs", title: "Breadcrumbs", patterns: ["breadcrumbs.*"]),
            Node(id: "workbench/editor", title: "Editor Management", patterns: ["workbench.editor.*"]),
            Node(id: "workbench/settings", title: "Settings Editor", patterns: ["workbench.settings.*"]),
            Node(id: "workbench/zenmode", title: "Zen Mode", patterns: ["zenmode.*"]),
            Node(id: "workbench/screencastmode", title: "Screencast Mode", patterns: ["screencastMode.*"])]),
        Node(id: "window", title: "Window", symbol: "rectangle.on.rectangle", patterns: ["window.*"], children: [
            Node(id: "window/newWindow", title: "New Window", patterns: ["window.*newwindow*"])]),
        Node(id: "chat", title: "Chat", symbol: "bubble.left", patterns: ["chat.*", "inlineChat.*", "mcp", "agents.*", "sessions.*", "github.copilot.*"]),
        Node(id: "features", title: "Features", symbol: "square.grid.2x2", children: [
            Node(id: "features/accessibilitySignals", title: "Accessibility Signals", patterns: ["accessibility.signal*"]),
            Node(id: "features/accessibility", title: "Accessibility", patterns: ["accessibility.*", "dictation.*"]),
            Node(id: "features/explorer", title: "Explorer", patterns: ["explorer.*", "outline.*"]),
            Node(id: "features/search", title: "Search", patterns: ["search.*"]),
            Node(id: "features/debug", title: "Debug", patterns: ["debug.*", "launch"]),
            Node(id: "features/testing", title: "Testing", patterns: ["testing.*"]),
            Node(id: "features/scm", title: "Source Control", patterns: ["scm.*"]),
            Node(id: "features/extensions", title: "Extensions", patterns: ["extensions.*"]),
            Node(id: "features/terminal", title: "Terminal", patterns: ["terminal.*"]),
            Node(id: "features/task", title: "Task", patterns: ["task.*"]),
            Node(id: "features/problems", title: "Problems", patterns: ["problems.*"]),
            Node(id: "features/output", title: "Output", patterns: ["output.*"]),
            Node(id: "features/comments", title: "Comments", patterns: ["comments.*"]),
            Node(id: "features/remote", title: "Remote", patterns: ["remote.*"]),
            Node(id: "features/timeline", title: "Timeline", patterns: ["timeline.*"]),
            Node(id: "features/notebook", title: "Notebook", patterns: ["notebook.*", "interactiveWindow.*"]),
            Node(id: "features/mergeEditor", title: "Merge Editor", patterns: ["mergeEditor.*"]),
            Node(id: "features/issueReporter", title: "Issue Reporter", patterns: ["issueReporter.*"])]),
        Node(id: "application", title: "Application", symbol: "app.badge", children: [
            Node(id: "application/http", title: "Proxy", patterns: ["http.*", "network.*"]),
            Node(id: "application/keyboard", title: "Keyboard", patterns: ["keyboard.*"]),
            Node(id: "application/update", title: "Update", patterns: ["update.*"]),
            Node(id: "application/telemetry", title: "Telemetry", patterns: ["telemetry.*"]),
            Node(id: "application/settingsSync", title: "Settings Sync", patterns: ["settingsSync.*"]),
            Node(id: "application/experimental", title: "Experimental", patterns: ["application.experimental.*"])]),
        Node(id: "security", title: "Security", symbol: "lock.shield", patterns: ["security.*"], children: [
            Node(id: "security/workspace", title: "Workspace", patterns: ["security.workspace.*"])])
    ]

    /// `*` stands for any run of characters; everything else matches literally, ignoring case.
    static func matches(_ key: String, pattern: String) -> Bool {
        let parts = pattern.lowercased().components(separatedBy: "*")
        var rest = Substring(key.lowercased())
        for (index, part) in parts.enumerated() {
            if index == 0 { guard rest.hasPrefix(part) else { return false }; rest = rest.dropFirst(part.count); continue }
            if index == parts.count - 1 { return part.isEmpty || rest.hasSuffix(part) }
            if part.isEmpty { continue }
            guard let range = rest.range(of: part) else { return false }
            rest = rest[range.upperBound...]
        }
        return rest.isEmpty
    }

    /// Reads and arranges the shipped catalog ahead of the first time Settings is opened.
    /// Safe to call from any thread; the work happens once.
    static func prepare() { _ = core }

    /// The editor's own settings never change for a runtime; arrange them once.
    private static let core: [Category] = {
        var remaining = bundled.settings
        func claim(_ patterns: [String]) -> [CodeSetting] {
            guard !patterns.isEmpty else { return [] }
            var taken: [CodeSetting] = []
            remaining.removeAll { setting in
                guard patterns.contains(where: { matches(setting.key, pattern: $0) }) else { return false }
                taken.append(setting); return true
            }
            return taken.sorted { ($0.order ?? .infinity, $0.key) < ($1.order ?? .infinity, $1.key) }
        }
        let byKey = Dictionary(bundled.settings.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var result = [Category(id: "commonlyUsed", title: "Commonly Used", symbol: "star", sections: [
            Section(id: "commonlyUsed", title: "Commonly Used", settings: commonlyUsed.compactMap { byKey[$0] })])]
        var built: [(node: Node, sections: [Section])] = []
        for node in contents {
            // A narrower subsection takes its settings before the section it sits in.
            let children = node.children.map { Section(id: $0.id, title: $0.title, settings: claim($0.patterns)) }.filter { !$0.settings.isEmpty }
            let own = claim(node.patterns)
            built.append((node, (own.isEmpty ? [] : [Section(id: node.id, title: node.title, settings: own)]) + children))
        }
        let leftover = remaining.sorted { $0.key < $1.key }
        for (node, sections) in built {
            var sections = sections
            if node.id == "application", !leftover.isEmpty { sections.append(Section(id: "application/other", title: "Other", settings: leftover)) }
            result.append(Category(id: node.id, title: node.title, symbol: node.symbol, sections: sections))
        }
        return result
    }()

    // MARK: Descriptions

    private final class Prose { let value: AttributedString; init(_ value: AttributedString) { self.value = value } }
    private static let cache = NSCache<NSString, Prose>()
    /// Descriptions are Markdown; `#editor.fontSize#` names another setting.
    static func prose(_ text: String) -> AttributedString {
        if let cached = cache.object(forKey: text as NSString) { return cached.value }
        var source = text
        if let reference = try? NSRegularExpression(pattern: "`?#([A-Za-z0-9_.\\-]+)#`?") {
            let whole = NSRange(source.startIndex..., in: source)
            for match in reference.matches(in: source, range: whole).reversed() {
                guard let range = Range(match.range, in: source), let key = Range(match.range(at: 1), in: source) else { continue }
                let parts = source[key].split(separator: ".").map(String.init)
                let name = parts.dropLast().map(CodeSetting.words).joined(separator: " › ") + (parts.count > 1 ? ": " : "") + CodeSetting.words(parts.last ?? "")
                source.replaceSubrange(range, with: "**" + name + "**")
            }
        }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        let result = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(text)
        cache.setObject(Prose(result), forKey: text as NSString)
        return result
    }
}
