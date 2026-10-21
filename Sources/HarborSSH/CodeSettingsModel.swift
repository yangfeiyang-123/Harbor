import Foundation
import HarborCore

/// What the Settings panel knows about one window's editor: the settings its extensions
/// add, and the values set for the user and for the folder. Every change is one request
/// over the editor's command channel; nothing is polled.
@MainActor
final class CodeSettingsModel: ObservableObject {
    enum Scope: String { case user, workspace }
    enum Status: Equatable { case unavailable, loading, ready, failed(String) }
    typealias Transport = (_ command: String, _ extra: [String: Any]) async throws -> Any?

    @Published private(set) var catalog = SettingsCatalog()
    @Published private(set) var user: [String: JSONValue] = [:]
    @Published private(set) var workspace: [String: JSONValue] = [:]
    @Published private(set) var status = Status.unavailable
    @Published var scope = Scope.user
    @Published var notice: String?
    private var transport: Transport?
    private var owner: ObjectIdentifier?
    private var work: Task<Void, Never>?
    private var extended = false

    /// Follows `session`'s editor, or none when no editor is ready in this window.
    func attach(_ session: CodeWorkbenchSession?) {
        guard let session, session.commandsReady else { detach(); return }
        if owner == ObjectIdentifier(session), status == .ready || status == .loading { refresh(); return }
        owner = ObjectIdentifier(session)
        attach { [weak session] command, extra in
            guard let session else { throw WorkspaceError.message("The editor was closed.") }
            return try await session.request(command, extra: extra)
        }
    }
    func attach(transport: @escaping Transport) {
        self.transport = transport; status = .loading; notice = nil
        enqueue { [weak self] in
            guard let self else { return }
            do {
                let reply = try await transport("settingsCatalog", [:]) as? [String: Any]
                let data = try JSONSerialization.data(withJSONObject: reply?["groups"] ?? [])
                let installed = (try? JSONDecoder().decode([SettingsCatalog.Group].self, from: data)) ?? []
                if !installed.isEmpty || self.extended { self.catalog = SettingsCatalog(installed: installed); self.extended = !installed.isEmpty }
                self.apply(try await transport("settingsValues", [:]))
                self.status = .ready
            } catch { self.status = .failed(error.localizedDescription) }
        }
    }
    func detach() {
        transport = nil; owner = nil; work?.cancel(); work = nil
        status = .unavailable; user = [:]; workspace = [:]
        if extended { catalog = SettingsCatalog(); extended = false }
    }
    /// Picks up values changed elsewhere, such as in settings.json.
    func refresh() {
        guard let transport, status == .ready else { return }
        enqueue { [weak self] in if let reply = try? await transport("settingsValues", [:]) { self?.apply(reply) } }
    }
    func settled() async { await work?.value }

    private func enqueue(_ operation: @escaping () async -> Void) {
        let previous = work
        work = Task { await previous?.value; if !Task.isCancelled { await operation() } }
    }
    private func apply(_ reply: Any?) {
        guard let reply = reply as? [String: Any] else { return }
        user = catalog.flatten(reply["user"] as? [String: Any] ?? [:])
        workspace = catalog.flatten(reply["workspace"] as? [String: Any] ?? [:])
    }

    private var chosen: [String: JSONValue] { scope == .user ? user : workspace }
    /// What the setting is in the chosen scope: its own value there, else what it inherits.
    func value(_ setting: CodeSetting) -> JSONValue? {
        if scope == .workspace, let value = workspace[setting.key] { return value }
        return user[setting.key] ?? setting.fallback
    }
    func isModified(_ setting: CodeSetting) -> Bool { chosen[setting.key] != nil }
    /// Set in the other scope, which a reader of this one would otherwise not learn.
    func isModifiedElsewhere(_ setting: CodeSetting) -> Bool { (scope == .user ? workspace : user)[setting.key] != nil }
    var modified: Set<String> { Set(chosen.keys) }

    func set(_ setting: CodeSetting, to value: JSONValue) {
        // Choosing the default again clears the entry, as the editor's own Settings does.
        let inherited = scope == .workspace ? user[setting.key] ?? setting.fallback : setting.fallback
        if value == inherited { reset(setting); return }
        if chosen[setting.key] == value { return }
        write(setting.key, value)
    }
    func reset(_ setting: CodeSetting) {
        guard chosen[setting.key] != nil else { return }
        write(setting.key, nil)
    }
    private func write(_ key: String, _ value: JSONValue?) {
        guard let transport, status == .ready else { return }
        let scope = scope
        if scope == .user { user[key] = value } else { workspace[key] = value }
        var extra: [String: Any] = ["key": key, "scope": scope.rawValue]
        if let value { extra["value"] = value.any } else { extra["remove"] = true }
        enqueue { [weak self] in
            do { self?.apply(try await transport("settingsUpdate", extra)); self?.notice = nil }
            catch {
                self?.notice = "\(key) was not changed: \(error.localizedDescription)"
                if let reply = try? await transport("settingsValues", [:]) { self?.apply(reply) }
            }
        }
    }
    /// Opens the chosen scope's settings.json in the editor, at `key` if given.
    func openJSON(key: String? = nil) async -> Bool {
        guard let transport, status == .ready else { return false }
        await settled()
        var extra: [String: Any] = ["scope": scope.rawValue]
        if let key { extra["key"] = key }
        do { _ = try await transport("settingsJson", extra); return true }
        catch { notice = "settings.json could not be opened: \(error.localizedDescription)"; return false }
    }
}
