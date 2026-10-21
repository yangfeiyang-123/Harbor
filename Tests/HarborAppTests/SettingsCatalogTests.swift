import XCTest
import SwiftUI
@testable import HarborSSH

final class SettingsCatalogTests: XCTestCase {
    private func setting(_ key: String, in catalog: SettingsCatalog = SettingsCatalog()) throws -> CodeSetting {
        try XCTUnwrap(catalog.all.first { $0.key == key }, key)
    }
    private func group(_ json: String) throws -> [SettingsCatalog.Group] {
        try JSONDecoder().decode([SettingsCatalog.Group].self, from: Data(json.utf8))
    }

    func testShippedCatalogBelongsToTheBundledEditorAndPlacesEverySettingOnce() throws {
        // The catalog is generated from a running editor (scripts/build-settings-catalog.py);
        // moving bootstrap.py to another code-server must come with a new one.
        let script = try String(contentsOf: AppResources.directory("CodeWorkbench").appendingPathComponent("bootstrap.py"), encoding: .utf8)
        XCTAssertEqual(SettingsCatalog.bundled.runtime, try CodeRuntimePackage.manifest(script: script).version)
        let catalog = SettingsCatalog()
        XCTAssertEqual(catalog.categories.map(\.title), ["Commonly Used", "Text Editor", "Workbench", "Window", "Chat", "Features", "Application", "Security", "Extensions"])
        XCTAssertGreaterThan(catalog.all.count, 1_500)
        let placed = catalog.categories.dropFirst().flatMap { $0.sections.flatMap(\.settings) }.map(\.key)
        XCTAssertEqual(placed.count, Set(placed).count, "a setting belongs to one section")
        XCTAssertEqual(Set(placed), Set(SettingsCatalog.bundled.settings.map(\.key) + SettingsCatalog.bundled.groups.flatMap { $0.settings.map(\.key) }))
        func home(_ key: String) -> String? { catalog.categories.dropFirst().flatMap(\.sections).first { $0.settings.contains { $0.key == key } }?.id }
        XCTAssertEqual(home("editor.cursorStyle"), "editor/cursor"); XCTAssertEqual(home("editor.tabSize"), "editor")
        XCTAssertEqual(home("files.autoSave"), "editor/files"); XCTAssertEqual(home("editor.suggest.preview"), "editor/suggestions")
        XCTAssertEqual(home("breadcrumbs.enabled"), "workbench/breadcrumbs"); XCTAssertEqual(home("zenMode.fullScreen"), "workbench/zenmode")
        XCTAssertEqual(home("terminal.integrated.fontSize"), "features/terminal"); XCTAssertEqual(home("accessibility.signals.terminalBell"), "features/accessibilitySignals")
        XCTAssertEqual(home("http.proxy"), "application/http"); XCTAssertEqual(home("security.workspace.trust.enabled"), "security/workspace")
        XCTAssertEqual(home("launch"), "features/debug")
        XCTAssertEqual(catalog.categories[0].sections[0].settings.first?.key, "files.autoSave")
        XCTAssertTrue(catalog.categories.last!.sections.contains { $0.title == "SCSS (Sass)" && $0.detail == "CSS Language Features" })
        XCTAssertEqual(catalog.section("editor/cursor")?.sections.count, 1); XCTAssertGreaterThan(catalog.section("editor")?.sections.count ?? 0, 5)
        XCTAssertNil(catalog.section("nowhere"))
    }

    func testHarborPagesShowWhatAnEditorActuallyUsesUntilAValueIsChosen() throws {
        // An option that is not always sent leaves each editor on its own value, so the default
        // Harbor shows for it must be the editor's: what a new profile is seeded with, else the
        // setting's default. (An option the editor does not register cannot be applied at all.)
        let seeded: [String: JSONValue] = ["editor.fontFamily": .string("Menlo, Monaco, monospace"), "editor.minimap.enabled": .bool(false),
                                           "editor.stickyScroll.enabled": .bool(false), "terminal.integrated.fontSize": .number(13)]
        for option in WorkbenchPreferences.synced {
            let registered = try setting(option.key)
            if option.always == true { continue }
            XCTAssertEqual(JSONValue(any: option.default.any), seeded[option.key] ?? registered.fallback, option.key)
        }
    }

    func testEachSettingGetsTheControlItsValuesNeed() throws {
        XCTAssertEqual(try setting("editor.minimap.enabled").kind, .toggle)
        XCTAssertEqual(try setting("editor.tabSize").kind, .number(integer: false))
        XCTAssertEqual(try setting("http.proxy").kind, .text)
        XCTAssertEqual(try setting("files.candidateGuessEncodings").kind, .list)
        XCTAssertEqual(try setting("files.exclude").kind, .json); XCTAssertEqual(try setting("editor.rulers").kind, .json)
        let style = try setting("editor.cursorStyle")
        XCTAssertEqual(style.kind, .choice); XCTAssertEqual(style.fallback, .string("line")); XCTAssertTrue(style.options.contains(.string("block")))
        XCTAssertEqual(style.category, "Editor"); XCTAssertEqual(style.label, "Cursor Style")
        XCTAssertEqual(try setting("editor.minimap.enabled").category, "Editor › Minimap")
        XCTAssertEqual(CodeSetting.words("cssVariables"), "CSS Variables"); XCTAssertEqual(CodeSetting.words("tabSize2x"), "Tab Size2x")
        // Ligatures may be a boolean or a font-feature string: a checkbox while it is a boolean.
        let ligatures = try setting("editor.fontLigatures")
        XCTAssertEqual(ligatures.kind, .toggle)
        XCTAssertTrue(ligatures.shows(.bool(true))); XCTAssertFalse(ligatures.shows(.string("'ss01'")))
        XCTAssertTrue(try setting("files.candidateGuessEncodings").shows(.array([.string("utf8")])))
        XCTAssertFalse(try setting("files.candidateGuessEncodings").shows(.array([.number(1)])))
        XCTAssertFalse(try setting("files.exclude").shows(.object([:])))
    }

    func testPatternsSearchAndProse() throws {
        XCTAssertTrue(SettingsCatalog.matches("editor.cursorStyle", pattern: "editor.cursor*"))
        XCTAssertTrue(SettingsCatalog.matches("workbench.statusBar.visible", pattern: "workbench.*.visible"))
        XCTAssertTrue(SettingsCatalog.matches("window.openFoldersInNewWindow", pattern: "window.*newwindow*"))
        XCTAssertTrue(SettingsCatalog.matches("launch", pattern: "launch")); XCTAssertFalse(SettingsCatalog.matches("launcher", pattern: "launch"))
        XCTAssertFalse(SettingsCatalog.matches("diffEditor.wordWrap", pattern: "editor.*"))
        let catalog = SettingsCatalog()
        XCTAssertEqual(catalog.search("font size").first?.key, "editor.fontSize")
        XCTAssertEqual(catalog.search("terminal.integrated.fontSize").first?.key, "terminal.integrated.fontSize")
        XCTAssertTrue(catalog.search("minimap").prefix(5).allSatisfy { $0.key.lowercased().contains("minimap") }, "\(catalog.search("minimap").prefix(5).map(\.key))")
        XCTAssertTrue(catalog.search("zzzz-no-such-setting").isEmpty); XCTAssertTrue(catalog.search("  ").isEmpty)
        XCTAssertEqual(catalog.search("@modified", modified: ["editor.tabSize", "files.exclude"]).map(\.key), ["editor.tabSize", "files.exclude"])
        XCTAssertEqual(catalog.search("@modified tab", modified: ["editor.tabSize", "files.exclude"]).map(\.key), ["editor.tabSize"])
        // An extension's gear in the editor asks for "@ext:publisher.name"; "@id:" names one setting.
        let css = catalog.search("@ext:vscode.css-language-features")
        XCTAssertGreaterThan(css.count, 50); XCTAssertTrue(css.allSatisfy { setting in ["css.", "scss.", "less."].contains { setting.key.hasPrefix($0) } })
        XCTAssertTrue(catalog.search("@ext:vscode.css-language-features lint").count < css.count)
        XCTAssertEqual(catalog.search("@id:editor.tabSize").map(\.key), ["editor.tabSize"])
        XCTAssertTrue(catalog.search("@ext:nobody.nothing").isEmpty)
        let prose = String(SettingsCatalog.prose("Lines wrap at `#editor.wordWrapColumn#`, see [docs](https://example.com).").characters)
        XCTAssertEqual(prose, "Lines wrap at Editor: Word Wrap Column, see docs.")
    }

    func testNestedValuesBecomeSettingsAndObjectSettingsStayWhole() throws {
        let tree: [String: Any] = ["editor": ["fontSize": 15, "minimap": ["enabled": false], "quickSuggestions": ["other": "on"]],
                                   "files": ["exclude": ["**/.git": true]], "launch": [String: Any](), "acme": ["deep": ["flag": true]], "mcp": [String: Any]()]
        let flat = SettingsCatalog().flatten(tree)
        XCTAssertEqual(flat, ["editor.fontSize": .number(15), "editor.minimap.enabled": .bool(false), "editor.quickSuggestions": .object(["other": .string("on")]),
                              "files.exclude": .object(["**/.git": .bool(true)]), "acme.deep.flag": .bool(true)])
        XCTAssertEqual(JSONValue.number(15).json, "15"); XCTAssertEqual(JSONValue.number(1.5).json, "1.5"); XCTAssertEqual(JSONValue.bool(true).json, "true")
        XCTAssertEqual(JSONValue(any: NSNumber(value: true)), .bool(true)); XCTAssertEqual(JSONValue(any: NSNumber(value: 1)), .number(1))
        XCTAssertEqual(JSONValue.array([.string("a/b")]).json, "[\"a/b\"]"); XCTAssertEqual(JSONValue.string("x").label, "x")
    }

    @MainActor func testModelReadsAnEditorAndWritesOneSettingAtATime() async throws {
        final class Editor {
            var user: [String: Any] = ["editor": ["fontSize": 15]], workspace: [String: Any] = [:]
            var calls: [(String, [String: Any])] = [], failNext = false
            func handle(_ command: String, _ extra: [String: Any]) throws -> Any? {
                calls.append((command, extra))
                if command == "settingsCatalog" {
                    return ["groups": [["extension": "acme.lint", "name": "Acme Lint", "title": "Rules", "order": 0,
                                        "settings": [["key": "acme.level", "type": "string", "enum": ["off", "warn"], "default": "warn"]]]]]
                }
                if command == "settingsUpdate" {
                    if failNext { failNext = false; throw WorkspaceTestError.refused }
                    let key = extra["key"] as! String, parts = key.split(separator: ".").map(String.init)
                    var target = extra["scope"] as? String == "workspace" ? workspace : user
                    var section = target[parts[0]] as? [String: Any] ?? [:]
                    section[parts.dropFirst().joined(separator: ".")] = extra["remove"] as? Bool == true ? nil : extra["value"]
                    target[parts[0]] = section
                    if extra["scope"] as? String == "workspace" { workspace = target } else { user = target }
                }
                return ["user": user, "workspace": workspace, "trusted": true]
            }
        }
        enum WorkspaceTestError: Error { case refused }
        let editor = Editor(), model = CodeSettingsModel()
        XCTAssertEqual(model.status, .unavailable)
        let tab = try setting("editor.tabSize"), size = try setting("editor.fontSize")
        model.set(tab, to: .number(2)); XCTAssertTrue(editor.calls.isEmpty, "nothing is written without an editor")
        model.attach { command, extra in try editor.handle(command, extra) }
        XCTAssertEqual(model.status, .loading)
        await model.settled()
        XCTAssertEqual(model.status, .ready)
        XCTAssertEqual(editor.calls.map(\.0), ["settingsCatalog", "settingsValues"])
        // An installed extension joins the shipped catalog.
        let level = try setting("acme.level", in: model.catalog)
        XCTAssertTrue(model.catalog.categories.last!.sections.contains { $0.title == "Rules" && $0.detail == "Acme Lint" })
        XCTAssertEqual(model.value(level), .string("warn")); XCTAssertFalse(model.isModified(level))
        XCTAssertEqual(model.value(size), .number(15)); XCTAssertTrue(model.isModified(size)); XCTAssertEqual(model.modified, ["editor.fontSize"])

        model.set(tab, to: .number(2))
        XCTAssertEqual(model.value(tab), .number(2), "the panel shows the choice at once")
        await model.settled()
        XCTAssertEqual(editor.calls.last?.0, "settingsUpdate")
        XCTAssertEqual(editor.calls.last?.1["key"] as? String, "editor.tabSize"); XCTAssertEqual(editor.calls.last?.1["value"] as? Int, 2)
        XCTAssertEqual(editor.calls.last?.1["scope"] as? String, "user")
        // Choosing the default again clears the entry instead of pinning the default.
        model.set(tab, to: tab.fallback!); await model.settled()
        XCTAssertEqual(editor.calls.last?.1["remove"] as? Bool, true); XCTAssertFalse(model.isModified(tab))
        let writes = editor.calls.count
        model.set(tab, to: tab.fallback!); model.reset(tab); await model.settled()
        XCTAssertEqual(editor.calls.count, writes, "an unchanged value is not written")

        // A folder inherits the user's value until it has its own.
        model.scope = .workspace
        XCTAssertEqual(model.value(size), .number(15)); XCTAssertFalse(model.isModified(size)); XCTAssertTrue(model.isModifiedElsewhere(size))
        model.set(size, to: .number(18)); await model.settled()
        XCTAssertEqual(editor.calls.last?.1["scope"] as? String, "workspace"); XCTAssertEqual(model.value(size), .number(18)); XCTAssertTrue(model.isModified(size))
        model.set(size, to: .number(15)); await model.settled()
        XCTAssertEqual(editor.calls.last?.1["remove"] as? Bool, true, "matching the user's value clears the folder's entry")
        model.scope = .user

        // A refused write says so and shows what the editor really has.
        editor.failNext = true
        model.set(size, to: .number(30)); await model.settled()
        XCTAssertNotNil(model.notice); XCTAssertEqual(model.value(size), .number(15))
        let opened = await model.openJSON(key: "editor.fontSize")
        XCTAssertTrue(opened); XCTAssertEqual(editor.calls.last?.0, "settingsJson"); XCTAssertEqual(editor.calls.last?.1["key"] as? String, "editor.fontSize")

        model.detach()
        XCTAssertEqual(model.status, .unavailable); XCTAssertNil(model.catalog.all.first { $0.key == "acme.level" })
        XCTAssertEqual(model.value(size), size.fallback)
    }

    @MainActor func testSettingsPanelListsTheSettingsOfTheChosenSection() async throws {
        _ = NSApplication.shared
        let suite = "app.harbor.settings." + UUID().uuidString
        let prefs = TestDefaults.suite(suite)!
        prefs.set("dark", forKey: "appearance"); prefs.set("all:editor/cursor", forKey: "settingsTab")
        defer { prefs.removePersistentDomain(forName: suite) }
        let store = AppStore(workspaceDefaults: prefs)
        var maximized = false
        let view = SettingsView(maximized: Binding(get: { maximized }, set: { maximized = $0 }), close: {})
        let hosting = NSHostingView(rootView: view.environmentObject(store).defaultAppStorage(prefs))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(nanoseconds: 200_000_000); hosting.layoutSubtreeIfNeeded()
        func all<View: NSView>(_ type: View.Type, in view: NSView) -> [View] { (view as? View).map { [$0] } ?? [] + view.subviews.flatMap { all(type, in: $0) } }
        XCTAssertTrue(all(NSTextField.self, in: hosting).contains { $0.placeholderString == "Search all settings" })
        // The chosen section lists its settings, each with the control for its kind of value:
        // a menu for one with fixed choices, a text box for a number.
        let section = try XCTUnwrap(SettingsCatalog().section("editor/cursor")).sections[0].settings
        XCTAssertGreaterThanOrEqual(all(NSPopUpButton.self, in: hosting).count, section.filter { $0.kind == .choice }.count)
        XCTAssertGreaterThanOrEqual(all(NSTextField.self, in: hosting).filter(\.isEditable).count, 1 + section.filter { $0.kind == .number(integer: false) }.count)
        if let output = ProcessInfo.processInfo.environment["HARBOR_QA_OUTPUT"], let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output).appendingPathComponent("settings-all.png"))
        }
    }
}
