import Foundation
import AppKit

/// The complete allowlist for preferences shared with the extension host. This
/// deliberately excludes connection settings, local paths, and credentials.
enum WorkbenchPreferences {
    private static let acknowledgementsKey = "workbenchPreferenceAcknowledgements"
    static let harborKeys: Set<String> = ["harbor.appearance", "harbor.motion", "harbor.activityBar.visibleItems", "harbor.interfaceFontSize",
                                          "harbor.liquidGlassEnabled", "harbor.modeSwitchShortcut"]
    static let keys: Set<String> = harborKeys.union(synced.map(\.key))

    /// An editor or terminal option that Harbor's Settings window owns and sends to every
    /// server's Code-OSS. The list is harbor-synced-settings.json, shared with the extension.
    struct Synced: Decodable {
        let key: String
        let type: String
        var min: Double?
        var max: Double?
        var integer: Bool?
        var values: [String]?
        let `default`: Value
        /// An older preference key that already holds this value.
        var native: String?
        /// Sent even before the user has chosen a value.
        var always: Bool?

        enum Value: Decodable, Equatable {
            case bool(Bool), number(Double), text(String)
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let value = try? container.decode(Bool.self) { self = .bool(value) }
                else if let value = try? container.decode(Double.self) { self = .number(value) }
                else { self = .text(try container.decode(String.self)) }
            }
            var any: Any {
                switch self { case .bool(let value): return value; case .number(let value): return value; case .text(let value): return value }
            }
        }
        var defaultsKey: String { native ?? "code_" + key.replacingOccurrences(of: ".", with: "_") }
        /// The stored value if it is valid for this option, otherwise nil.
        func stored(_ defaults: UserDefaults) -> Any? { defaults.object(forKey: defaultsKey).flatMap(normalized) }
        func value(_ defaults: UserDefaults) -> Any { stored(defaults) ?? normalized(`default`.any) ?? `default`.any }
        func normalized(_ raw: Any) -> Any? {
            switch type {
            case "boolean":
                guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
                return number.boolValue
            case "number":
                guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                      number.doubleValue >= min ?? -.infinity, number.doubleValue <= max ?? .infinity,
                      integer != true || floor(number.doubleValue) == number.doubleValue else { return nil }
                return integer == true ? number.intValue as Any : number.doubleValue
            case "choice":
                guard let text = raw as? String, values?.contains(text) == true else { return nil }
                return text
            default:
                guard let text = raw as? String, text.count <= Int(max ?? 200), !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return nil }
                return text
            }
        }
    }
    static let synced: [Synced] = {
        let url = AppResources.directory("CodeWorkbench").appendingPathComponent("harbor-synced-settings.json")
        return try! JSONDecoder().decode([Synced].self, from: Data(contentsOf: url))
    }()
    static func synced(_ key: String) -> Synced { synced.first { $0.key == key }! }

    static let activityBarCountKey = "activityBarVisibleCount"
    /// Views shown in the row above Explorer before the chevron menu.
    static func activityBarCount(defaults: UserDefaults = .standard) -> Int {
        let value = defaults.object(forKey: activityBarCountKey) as? NSNumber
        return value.map { min(max($0.intValue, 1), 12) } ?? 4
    }

    static func terminalScrollback(defaults: UserDefaults = .standard) -> Int {
        let value = defaults.object(forKey: "terminalScrollback") as? NSNumber
        return value.map { min(max($0.intValue, 1_000), 100_000) } ?? 20_000
    }

    static func payload(defaults: UserDefaults = .standard) -> [String: Any] {
        let wrap = defaults.bool(forKey: "editorWrap")
        let storedMode = defaults.string(forKey: "editorWordWrapMode")
        let mode = storedMode.flatMap { ["on", "off", "wordWrapColumn", "bounded"].contains($0) && ($0 != "off") == wrap ? $0 : nil } ?? (wrap ? "on" : "off")
        let shortcut = WorkspaceShortcut.decode(defaults.string(forKey: WorkspaceShortcut.preferenceKey) ?? WorkspaceShortcut.standard.encoded)
        var values: [String: Any] = [
            "harbor.appearance": choice(defaults.string(forKey: "appearance"), HarborTheme.appearances, fallback: HarborTheme.defaultAppearance),
            "harbor.motion": choice(defaults.string(forKey: HarborMotion.preferenceKey), HarborMotion.levels, fallback: "full"),
            "harbor.activityBar.visibleItems": activityBarCount(defaults: defaults),
            "harbor.interfaceFontSize": number(defaults, "interfaceFontSize", range: 11...20),
            "harbor.liquidGlassEnabled": defaults.object(forKey: "liquidGlassEnabled") == nil ? true : defaults.bool(forKey: "liquidGlassEnabled"),
            "harbor.modeSwitchShortcut": shortcutString(shortcut)
        ]
        // An option is sent once the user has chosen a value for it; until then each editor
        // keeps its own. The two that Harbor always shared are sent regardless.
        for setting in synced {
            if setting.key == "editor.wordWrap" { values[setting.key] = mode }
            else if setting.always == true { values[setting.key] = setting.value(defaults) }
            else if let stored = setting.stored(defaults) { values[setting.key] = stored }
        }
        let acknowledgements = (defaults.dictionary(forKey: acknowledgementsKey) as? [String: String] ?? [:]).filter { keys.contains($0.key) }
        return ["values": values, "acknowledgements": acknowledgements]
    }

    /// Returns false for malformed or unsupported values, without changing the
    /// preference. Valid request IDs are still acknowledged so the UI can restore
    /// the actual value instead of retaining an unconfirmed local edit forever.
    @discardableResult static func apply(event: [String: String], defaults: UserDefaults = .standard) -> Bool {
        guard event["action"] == "preference", let key = event["key"], keys.contains(key),
              let id = event["id"], UUID(uuidString: id) != nil,
              let raw = event["value"], raw.utf8.count <= 1024 else { return false }
        defer {
            var acknowledgements = defaults.dictionary(forKey: acknowledgementsKey) as? [String: String] ?? [:]
            acknowledgements = acknowledgements.filter { keys.contains($0.key) }
            acknowledgements[key] = id
            defaults.set(acknowledgements, forKey: acknowledgementsKey)
        }
        guard let value = try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed]) else { return false }
        switch key {
        case "harbor.appearance": return setChoice(value, key: "appearance", allowed: HarborTheme.appearances, defaults: defaults)
        case "harbor.activityBar.visibleItems": return setNumber(value, key: activityBarCountKey, range: 1...12, integer: true, defaults: defaults)
        case "harbor.motion": return setChoice(value, key: HarborMotion.preferenceKey, allowed: HarborMotion.levels, defaults: defaults)
        case "harbor.interfaceFontSize": return setNumber(value, key: "interfaceFontSize", range: 11...20, defaults: defaults)
        case "harbor.liquidGlassEnabled": return setBool(value, key: "liquidGlassEnabled", defaults: defaults)
        case "editor.wordWrap":
            guard let mode = value as? String, ["on", "off", "wordWrapColumn", "bounded"].contains(mode) else { return false }
            defaults.set(mode, forKey: "editorWordWrapMode"); defaults.set(mode != "off", forKey: "editorWrap"); return true
        case "harbor.modeSwitchShortcut":
            guard let raw = value as? String, let shortcut = parseShortcut(raw) else { return false }
            defaults.set(shortcut.encoded, forKey: WorkspaceShortcut.preferenceKey); return true
        default:
            guard let setting = synced.first(where: { $0.key == key }), let normalized = setting.normalized(value) else { return false }
            defaults.set(normalized, forKey: setting.defaultsKey); return true
        }
    }

    static func shortcutString(_ value: WorkspaceShortcut) -> String {
        var parts: [String] = []
        if value.flags.contains(.control) { parts.append("ctrl") }
        if value.flags.contains(.option) { parts.append("alt") }
        if value.flags.contains(.shift) { parts.append("shift") }
        if value.flags.contains(.command) { parts.append("cmd") }
        parts.append(value.key.lowercased())
        return parts.joined(separator: "+")
    }

    static func parseShortcut(_ text: String) -> WorkspaceShortcut? {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard (2...5).contains(parts.count), let key = parts.last, let keyCode = shortcutKeyCodes[key] else { return nil }
        var flags: NSEvent.ModifierFlags = []
        let modifiers: [String: NSEvent.ModifierFlags] = ["cmd": .command, "alt": .option, "ctrl": .control, "shift": .shift]
        for part in parts.dropLast() {
            guard let flag = modifiers[part], !flags.contains(flag) else { return nil }
            flags.insert(flag)
        }
        let shortcut = WorkspaceShortcut(key: key, keyCode: keyCode, modifiers: flags.rawValue)
        return shortcut.validationError == nil ? shortcut : nil
    }

    private static let shortcutKeyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50
    ]
    private static func choice(_ value: String?, _ allowed: [String], fallback: String) -> String { value.flatMap { allowed.contains($0) ? $0 : nil } ?? fallback }
    private static func number(_ defaults: UserDefaults, _ key: String, range: ClosedRange<Double>) -> Double {
        guard let value = defaults.object(forKey: key) as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return 13 }
        return min(max(value.doubleValue, range.lowerBound), range.upperBound)
    }
    private static func setChoice(_ value: Any, key: String, allowed: [String], defaults: UserDefaults) -> Bool {
        guard let text = value as? String, allowed.contains(text) else { return false }
        defaults.set(text, forKey: key); return true
    }
    private static func setNumber(_ value: Any, key: String, range: ClosedRange<Double>, integer: Bool = false, defaults: UserDefaults) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, range.contains(number.doubleValue), !integer || floor(number.doubleValue) == number.doubleValue else { return false }
        defaults.set(number, forKey: key); return true
    }
    private static func setBool(_ value: Any, key: String, defaults: UserDefaults) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        defaults.set(number.boolValue, forKey: key); return true
    }
}
