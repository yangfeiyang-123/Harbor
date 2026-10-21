import XCTest
@testable import HarborSSH

final class WorkbenchPreferencesTests: XCTestCase {
    private func fixture() throws -> UserDefaults {
        let suite = "app.harbor.preferences." + UUID().uuidString
        let defaults = try XCTUnwrap(TestDefaults.suite(suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
    private func event(_ key: String, _ value: Any, id: String = UUID().uuidString) throws -> [String: String] {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return ["action": "preference", "key": key, "value": String(decoding: data, as: UTF8.self), "id": id]
    }
    func testSnapshotMigratesExistingPreferencesWithoutWritingDefaultsOrExposingSecrets() throws {
        let defaults = try fixture()
        defaults.set("anthropic", forKey: "appearance"); defaults.set(19, forKey: "terminalFontSize")
        defaults.set(false, forKey: "liquidGlassEnabled"); defaults.set(true, forKey: "editorWrap")
        defaults.set("ssh-secret.invalid", forKey: "serverHost"); defaults.set("secret", forKey: "password")
        let before = defaults.dictionaryRepresentation()
        let state = WorkbenchPreferences.payload(defaults: defaults)
        let values = try XCTUnwrap(state["values"] as? [String: Any])
        // Harbor's own options and the ones whose Harbor default differs from the editor's are
        // always sent; any other editor or terminal option only once a value has been chosen for it.
        XCTAssertEqual(Set(values.keys), WorkbenchPreferences.harborKeys.union(["editor.fontSize", "editor.wordWrap", "terminal.integrated.fontSize", "terminal.integrated.scrollback"]))
        XCTAssertTrue(Set(values.keys).isSubset(of: WorkbenchPreferences.keys))
        XCTAssertEqual(values["harbor.appearance"] as? String, "anthropic")
        XCTAssertEqual(values["terminal.integrated.fontSize"] as? Double, 19)
        XCTAssertEqual(values["editor.fontSize"] as? Double, 13)
        XCTAssertEqual(values["terminal.integrated.scrollback"] as? Int, 20_000); XCTAssertNil(values["editor.cursorStyle"])
        XCTAssertEqual(values["harbor.liquidGlassEnabled"] as? Bool, false)
        XCTAssertEqual(values["editor.wordWrap"] as? String, "on")
        XCTAssertEqual(values["harbor.modeSwitchShortcut"] as? String, "alt+z")
        XCTAssertTrue(NSDictionary(dictionary: before).isEqual(to: defaults.dictionaryRepresentation()))
        let json = String(decoding: try JSONSerialization.data(withJSONObject: state), as: UTF8.self)
        XCTAssertFalse(json.contains("secret")); XCTAssertFalse(json.contains("serverHost"))
    }
    func testUserEditsPersistInNativeKeysAndRoundTripTheirAcknowledgement() throws {
        let defaults = try fixture(), id = UUID().uuidString
        XCTAssertTrue(WorkbenchPreferences.apply(event: try event("terminal.integrated.scrollback", 35_000, id: id), defaults: defaults))
        XCTAssertTrue(WorkbenchPreferences.apply(event: try event("terminal.integrated.copyOnSelection", true), defaults: defaults))
        XCTAssertTrue(WorkbenchPreferences.apply(event: try event("editor.wordWrap", "bounded"), defaults: defaults))
        XCTAssertEqual(defaults.integer(forKey: "terminalScrollback"), 35_000)
        XCTAssertTrue(defaults.bool(forKey: "terminalCopyOnSelection")); XCTAssertTrue(defaults.bool(forKey: "editorWrap"))
        let state = WorkbenchPreferences.payload(defaults: defaults)
        XCTAssertEqual((state["values"] as? [String: Any])?["editor.wordWrap"] as? String, "bounded")
        XCTAssertEqual((state["acknowledgements"] as? [String: String])?["terminal.integrated.scrollback"], id)
        // An older native toggle still changes wrap, without losing richer modes
        // when they agree with the boolean lightweight-editor preference.
        defaults.set(false, forKey: "editorWrap")
        XCTAssertEqual((WorkbenchPreferences.payload(defaults: defaults)["values"] as? [String: Any])?["editor.wordWrap"] as? String, "off")
    }
    func testEditorAndTerminalOptionsAreStoredValidatedAndSentOnceChosen() throws {
        let defaults = try fixture()
        XCTAssertGreaterThanOrEqual(WorkbenchPreferences.synced.count, 25)
        XCTAssertEqual(Set(WorkbenchPreferences.synced.map(\.defaultsKey)).count, WorkbenchPreferences.synced.count, "every option has its own preference key")
        for setting in WorkbenchPreferences.synced { XCTAssertNotNil(setting.normalized(setting.default.any), setting.key + " default must be valid") }
        for (key, value) in [("editor.cursorStyle", "block" as Any), ("editor.cursorBlinking", "smooth" as Any), ("editor.fontFamily", "JetBrains Mono, Menlo, monospace" as Any),
                             ("editor.tabSize", 2 as Any), ("editor.minimap.enabled", true as Any), ("terminal.integrated.cursorStyle", "underline" as Any),
                             ("terminal.integrated.cursorBlinking", true as Any), ("terminal.integrated.lineHeight", 1.2 as Any)] {
            XCTAssertTrue(WorkbenchPreferences.apply(event: try event(key, value), defaults: defaults), key)
        }
        for (key, value) in [("editor.cursorStyle", "beam" as Any), ("editor.tabSize", 2.5 as Any), ("editor.tabSize", 40 as Any), ("editor.minimap.enabled", "yes" as Any),
                             ("editor.fontFamily", "Menlo\nrm -rf" as Any), ("editor.fontFamily", String(repeating: "a", count: 400) as Any), ("terminal.integrated.lineHeight", 9 as Any)] {
            XCTAssertFalse(WorkbenchPreferences.apply(event: try event(key, value), defaults: defaults), key)
        }
        let values = try XCTUnwrap(WorkbenchPreferences.payload(defaults: defaults)["values"] as? [String: Any])
        XCTAssertEqual(values["editor.cursorStyle"] as? String, "block"); XCTAssertEqual(values["editor.tabSize"] as? Int, 2)
        XCTAssertEqual(values["editor.minimap.enabled"] as? Bool, true); XCTAssertEqual(values["terminal.integrated.lineHeight"] as? Double, 1.2)
        XCTAssertEqual(values["editor.fontFamily"] as? String, "JetBrains Mono, Menlo, monospace")
        XCTAssertNil(values["editor.lineNumbers"], "an option nobody chose is left to each editor")
        XCTAssertEqual(WorkbenchPreferences.synced("editor.lineNumbers").value(defaults) as? String, "on")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: values))
    }
    func testMalformedOutOfRangeAndNonScalarEventsCannotWriteNativePreferences() throws {
        let defaults = try fixture()
        defaults.set(20_000, forKey: "terminalScrollback"); defaults.set(false, forKey: "terminalCopyOnSelection")
        for (key, value) in [("terminal.integrated.scrollback", true as Any), ("terminal.integrated.scrollback", 10 as Any),
                             ("terminal.integrated.scrollback", 3000.5 as Any), ("terminal.integrated.copyOnSelection", 1 as Any),
                             ("harbor.appearance", "untrusted" as Any), ("terminal.integrated.fontSize", [20] as Any)] {
            XCTAssertFalse(WorkbenchPreferences.apply(event: try event(key, value), defaults: defaults))
        }
        XCTAssertFalse(WorkbenchPreferences.apply(event: try event("password", "new password"), defaults: defaults))
        XCTAssertFalse(WorkbenchPreferences.apply(event: try event("harbor.appearance", "dark", id: "../outside"), defaults: defaults))
        XCTAssertEqual(defaults.integer(forKey: "terminalScrollback"), 20_000); XCTAssertFalse(defaults.bool(forKey: "terminalCopyOnSelection"))
        XCTAssertNil(defaults.object(forKey: "appearance")); XCTAssertNil(defaults.object(forKey: "password"))
    }
    func testModeShortcutRoundTripsAndRejectsReservedBindings() throws {
        let defaults = try fixture()
        XCTAssertTrue(WorkbenchPreferences.apply(event: try event("harbor.modeSwitchShortcut", "ctrl+alt+z"), defaults: defaults))
        let shortcut = WorkspaceShortcut.decode(try XCTUnwrap(defaults.string(forKey: WorkspaceShortcut.preferenceKey)))
        XCTAssertEqual(shortcut.keyCode, 6); XCTAssertEqual(WorkbenchPreferences.shortcutString(shortcut), "ctrl+alt+z")
        for invalid in ["cmd+d", "alt+x", "shift+z", "alt+alt+z", "ctrl+shift+`", "cmd+1", "cmd+f", "run something"] {
            XCTAssertNil(WorkbenchPreferences.parseShortcut(invalid), invalid)
        }
        XCTAssertEqual(WorkbenchPreferences.parseShortcut("alt+z"), .standard)
    }
}
