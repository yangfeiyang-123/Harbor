import XCTest
import AppKit
import SwiftUI
import HarborCore
@testable import HarborSSH

final class WindowThemeMotionTests: XCTestCase {
    private func luminance(_ hex: String) -> Double {
        let color = HarborTheme.hex(hex).usingColorSpace(.sRGB)!
        let channels = [color.redComponent, color.greenComponent, color.blueComponent].map { value -> Double in
            let c = Double(value); return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }
    private func contrast(_ a: String, _ b: String) -> Double {
        let values = [luminance(a), luminance(b)].sorted()
        return (values[1] + 0.05) / (values[0] + 0.05)
    }
    @MainActor private func fixture() throws -> (AppStore, UserDefaults) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-windows-" + UUID().uuidString)
        let suite = "app.harbor.windows." + UUID().uuidString, prefs = TestDefaults.suite(suite)!
        addTeardownBlock { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = AppStore(historyRoot: root.appendingPathComponent("data"), workspaceDefaults: prefs)
        try store.history.prepare(); store.loading = false
        return (store, prefs)
    }

    func testAppearanceCombinesPaletteFamilyAndMode() {
        for (selection, anthropic, mode, scheme) in [("system", false, "system", ColorScheme?.none), ("light", false, "light", .light), ("dark", false, "dark", .dark),
            ("anthropic", true, "system", nil), ("anthropic-light", true, "light", .light), ("anthropic-dark", true, "dark", .dark)] {
            XCTAssertTrue(HarborTheme.appearances.contains(selection))
            XCTAssertEqual(HarborTheme.isAnthropic(selection), anthropic, selection)
            XCTAssertEqual(HarborTheme.mode(selection), mode, selection)
            XCTAssertEqual(HarborTheme.scheme(selection), scheme, selection)
            XCTAssertEqual(HarborTheme.compose(anthropic: anthropic, mode: mode), selection)
        }
        XCTAssertEqual(HarborTheme.editorThemeName(dark: false, selection: "anthropic"), "Harbor Anthropic Light")
        XCTAssertEqual(HarborTheme.editorThemeName(dark: true, selection: "anthropic-dark"), "Harbor Anthropic Dark")
        XCTAssertEqual(HarborTheme.editorThemeName(dark: true, selection: "system"), "Harbor Dark")
        XCTAssertEqual(HarborTheme.palette(dark: true, selection: "anthropic").name, "Anthropic Dark")
        XCTAssertEqual(HarborTheme.palette(dark: false, selection: "anthropic-dark").name, "Anthropic Light", "the resolved scheme, not the label, picks the palette")
    }

    func testAnthropicPalettesCoverNativeRolesAndStayReadable() {
        let required = Set(HarborTheme.palettes["light"]!.colors.keys)
        for mode in ["light", "dark"] {
            let palette = HarborTheme.anthropicPalettes[mode]!
            XCTAssertTrue(required.isSubset(of: Set(palette.colors.keys)), "native surfaces force-unwrap these roles: \(required.subtracting(palette.colors.keys))")
            XCTAssertEqual(palette.ansi.count, 16)
            let canvas = palette.colors["editor.background"]!
            for (key, color) in palette.syntax {
                XCTAssertGreaterThanOrEqual(contrast(color, canvas), key == "comment" ? 3 : 4.5, "\(mode) \(key)")
            }
            for surface in ["editor.background", "sideBar.background", "editorWidget.background", "list.activeSelectionBackground"] {
                XCTAssertGreaterThanOrEqual(contrast(palette.colors["foreground"]!, palette.colors[surface]!), 7, "\(mode) text on \(surface)")
            }
            XCTAssertGreaterThanOrEqual(contrast(palette.colors["textLink.foreground"]!, canvas), 4.5)
            XCTAssertNotEqual(palette.colors["diffEditor.insertedLineBackground"], palette.colors["diffEditor.removedLineBackground"], "diffs must be distinguishable")
            XCTAssertNotEqual(palette.colors["gitDecoration.addedResourceForeground"], palette.colors["gitDecoration.deletedResourceForeground"])
        }
        XCTAssertNotEqual(HarborTheme.anthropicPalettes["light"]!.colors["editor.background"], HarborTheme.anthropicPalettes["dark"]!.colors["editor.background"])
    }

    func testEveryFamilyIsStoredAsItsNameAndAMode() {
        XCTAssertEqual(HarborTheme.families.map(\.title), ["Claude", "Standard", "Tide", "Kelp", "Dusk", "Fog", "Lighthouse"])
        XCTAssertEqual(Set(HarborTheme.families.map(\.id)).count, HarborTheme.families.count)
        for family in HarborTheme.families {
            // The mode is told by how the stored value ends, so a family's name must not end like one.
            XCTAssertFalse(family.id.hasSuffix("light") || family.id.hasSuffix("dark"), family.id)
            for (mode, scheme) in [("system", ColorScheme?.none), ("light", .light), ("dark", .dark)] {
                let selection = HarborTheme.compose(family: family, mode: mode)
                XCTAssertTrue(HarborTheme.appearances.contains(selection), selection)
                XCTAssertEqual(HarborTheme.family(selection), family, selection)
                XCTAssertEqual(HarborTheme.mode(selection), mode, selection)
                XCTAssertEqual(HarborTheme.scheme(selection), scheme, selection)
                XCTAssertEqual(HarborTheme.isStandard(selection), family.file == nil, selection)
                XCTAssertEqual(HarborTheme.isAnthropic(selection), family == HarborTheme.claude, selection)
            }
            XCTAssertEqual(HarborTheme.editorThemeName(dark: true, selection: HarborTheme.compose(family: family, mode: "system")), family.editor + " Dark")
            XCTAssertTrue(HarborTheme.editorThemeNames.contains(family.editor + " Light"))
        }
        XCTAssertEqual(HarborTheme.appearances.count, 3 * HarborTheme.families.count)
        XCTAssertEqual(HarborTheme.family("nothing-harbor-has"), HarborTheme.standard, "a value that names no family is the standard colors")
        XCTAssertEqual(HarborTheme.palette(dark: true, selection: "tide").name, "Tide Dark")
        XCTAssertEqual(HarborTheme.palette(dark: false, selection: "lighthouse-dark").name, "Lighthouse Light", "the resolved scheme, not the label, picks the palette")
        XCTAssertEqual(HarborTheme.editorThemeName(dark: false, selection: "fog-light"), "Harbor Fog Light")
    }

    func testHarborsOwnFamiliesCoverNativeRolesAndStayReadable() {
        let required = Set(HarborTheme.palettes["light"]!.colors.keys), claude = Set(HarborTheme.anthropicPalettes["light"]!.colors.keys)
        var papers = Set<String>()
        XCTAssertEqual(HarborTheme.designed.count, 5)
        for family in HarborTheme.designed {
            let pair = HarborTheme.lightAndDark(of: family)
            for mode in ["light", "dark"] {
                let palette = pair[mode]!
                XCTAssertEqual(palette.name, family.title + (mode == "dark" ? " Dark" : " Light"))
                XCTAssertTrue(required.isSubset(of: Set(palette.colors.keys)), "native surfaces force-unwrap these roles: \(required.subtracting(palette.colors.keys))")
                XCTAssertEqual(Set(palette.colors.keys), claude, "\(palette.name) has the roles Claude's palettes have, no more and no fewer")
                XCTAssertEqual(palette.ansi.count, 16)
                let canvas = palette.colors["editor.background"]!
                for (key, color) in palette.syntax {
                    XCTAssertGreaterThanOrEqual(contrast(color, canvas), key == "comment" ? 3 : 4.5, "\(palette.name) \(key)")
                }
                for surface in ["editor.background", "sideBar.background", "editorWidget.background", "list.activeSelectionBackground"] {
                    XCTAssertGreaterThanOrEqual(contrast(palette.colors["foreground"]!, palette.colors[surface]!), 7, "\(palette.name) text on \(surface)")
                }
                XCTAssertGreaterThanOrEqual(contrast(palette.colors["textLink.foreground"]!, canvas), 4.5, palette.name)
                XCTAssertGreaterThanOrEqual(contrast("#FFFFFF", palette.colors["button.background"]!), 4, "\(palette.name) button label")
                XCTAssertNotEqual(palette.colors["diffEditor.insertedLineBackground"], palette.colors["diffEditor.removedLineBackground"], "diffs must be distinguishable")
                XCTAssertNotEqual(palette.colors["gitDecoration.addedResourceForeground"], palette.colors["gitDecoration.deletedResourceForeground"])
                papers.insert(canvas)
            }
        }
        XCTAssertEqual(papers.count, HarborTheme.designed.count * 2, "no two palettes are the same paper")
    }

    func testTheSettingsSchemaListsEveryFamilyAndMode() throws {
        let url = AppResources.directory("CodeWorkbench").appendingPathComponent("harbor-settings-schema.json")
        let schema = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let appearance = try XCTUnwrap((schema["properties"] as? [String: Any])?["harbor.appearance"] as? [String: Any])
        XCTAssertEqual(appearance["enum"] as? [String], HarborTheme.appearances)
        XCTAssertEqual((appearance["enumDescriptions"] as? [String])?.count, HarborTheme.appearances.count)
        XCTAssertEqual(appearance["default"] as? String, HarborTheme.defaultAppearance)
    }

    @MainActor func testEditorThemeRulesResolveForEveryFamily() {
        for family in HarborTheme.designed {
            for palette in HarborTheme.lightAndDark(of: family).values {
                let rules = CodeWorkbenchSession.tokenColors(palette, detailed: true)
                XCTAssertFalse(rules.contains { ($0["settings"] as? [String: String])?["foreground"] == "#808080" }, "\(palette.name): every rule resolves to a palette color")
            }
        }
    }

    @MainActor func testEditorThemeRulesKeepNeutralMappingAndDetailAnthropic() {
        let neutral = CodeWorkbenchSession.tokenColors(HarborTheme.palettes["light"]!, detailed: false)
        XCTAssertEqual(neutral.count, 11)
        XCTAssertTrue(neutral.allSatisfy { ($0["settings"] as? [String: String])?["fontStyle"] == nil })
        let palette = HarborTheme.anthropicPalettes["dark"]!
        let detailed = CodeWorkbenchSession.tokenColors(palette, detailed: true)
        let comment = detailed.first { ($0["scope"] as? [String])?.contains("comment") == true }?["settings"] as? [String: String]
        XCTAssertEqual(comment?["fontStyle"], "italic"); XCTAssertEqual(comment?["foreground"], palette.syntax["comment"])
        let operators = detailed.first { ($0["scope"] as? [String])?.contains("keyword.operator") == true }?["settings"] as? [String: String]
        XCTAssertEqual(operators?["foreground"], palette.syntax["operator"])
        XCTAssertFalse(detailed.contains { ($0["settings"] as? [String: String])?["foreground"] == "#808080" }, "every rule resolves to a palette color")
    }

    func testMotionLevelRespectsPreferenceAndReduceMotion() {
        XCTAssertEqual(HarborMotion.level("full", reduceMotion: false), .full)
        XCTAssertEqual(HarborMotion.level("full", reduceMotion: true), .subtle)
        XCTAssertEqual(HarborMotion.level("off", reduceMotion: true), .off)
        XCTAssertEqual(HarborMotion.level("unknown", reduceMotion: false), .full)
        XCTAssertNil(HarborMotion.animation(level: .off))
        XCTAssertEqual(HarborMotion.travel(10, level: .full), 10); XCTAssertEqual(HarborMotion.travel(10, level: .subtle), 0)
    }

    func testWorkbenchPreferencesAcceptMotionAndPinnedAnthropicModes() throws {
        let suite = "app.harbor.motion." + UUID().uuidString, defaults = TestDefaults.suite(suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func event(_ key: String, _ value: String) -> [String: String] {
            ["action": "preference", "key": key, "value": "\"" + value + "\"", "id": UUID().uuidString]
        }
        XCTAssertTrue(WorkbenchPreferences.apply(event: event("harbor.motion", "subtle"), defaults: defaults))
        XCTAssertEqual(defaults.string(forKey: HarborMotion.preferenceKey), "subtle")
        XCTAssertFalse(WorkbenchPreferences.apply(event: event("harbor.motion", "wild"), defaults: defaults))
        XCTAssertEqual(defaults.string(forKey: HarborMotion.preferenceKey), "subtle")
        XCTAssertTrue(WorkbenchPreferences.apply(event: event("harbor.appearance", "anthropic-dark"), defaults: defaults))
        let values = try XCTUnwrap(WorkbenchPreferences.payload(defaults: defaults)["values"] as? [String: Any])
        XCTAssertEqual(values["harbor.appearance"] as? String, "anthropic-dark"); XCTAssertEqual(values["harbor.motion"] as? String, "subtle")
    }

    @MainActor func testAdditionalWindowSharesCatalogButKeepsItsOwnSelection() async throws {
        let (primary, prefs) = try fixture(); defer { primary.shutdown() }
        let alpha = ServerProfile(name: "Alpha", host: "alpha.invalid"), beta = ServerProfile(name: "Beta", host: "beta.invalid")
        primary.profiles = [alpha]; primary.selectWorkspace(alpha.id)
        let second = AppStore(workspaceDefaults: prefs, primary: primary)
        XCTAssertFalse(second.isPrimary); XCTAssertTrue(second.proxy === primary.proxy)
        XCTAssertTrue(second.remoteDisplays === primary.remoteDisplays)
        await second.load()
        XCTAssertFalse(second.loading); XCTAssertEqual(second.profiles, [alpha])
        XCTAssertEqual(second.page, .recent, "a new window starts on the start page")
        // A change saved in either window reaches the other.
        second.profiles.append(beta); second.save()
        XCTAssertEqual(primary.profiles.map(\.name), ["Alpha", "Beta"])
        primary.remember(profile: alpha, directory: "/srv/project")
        XCTAssertEqual(second.recents.map(\.directory), ["/srv/project"])
        // Selection and page are per window.
        second.selectWorkspace(beta.id)
        XCTAssertEqual(second.selectedProfileID, beta.id); XCTAssertEqual(primary.selectedProfileID, alpha.id)
        primary.page = .proxy
        XCTAssertEqual(second.page, .workspace)
        // The second window never writes the terminal recovery files.
        XCTAssertFalse(second.checkpointTerminals(synchronously: true))
        XCTAssertTrue(AppStore.all.contains { $0 === second })
        second.shutdown()
        XCTAssertFalse(AppStore.all.contains { $0 === second })
        XCTAssertFalse(primary.shuttingDown, "closing an additional window leaves shared services running")
    }

    @MainActor func testOneFolderIsShownByOneWindowAtATime() async throws {
        let (primary, prefs) = try fixture(); defer { primary.shutdown() }
        let second = AppStore(workspaceDefaults: prefs, primary: primary); await second.load()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-claim-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let windows = (0..<2).map { _ in NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true) }
        windows.forEach { $0.isReleasedWhenClosed = false }
        primary.attach(window: windows[0]); second.attach(window: windows[1])
        primary.selectWorkspace(nil); primary.currentFiles.root = folder.path; primary.updateWorkspaceClaim()
        XCTAssertNil(primary.workspaceOwner)
        second.selectWorkspace(nil); second.currentFiles.root = folder.path + "/"; second.updateWorkspaceClaim()
        XCTAssertTrue(second.workspaceOwner === primary, "the same folder path is one workspace, whichever slot holds it")
        XCTAssertNil(primary.workspaceOwner, "the window that showed the folder first keeps it")
        // A different folder is independent.
        second.currentFiles.root = folder.deletingLastPathComponent().path; second.updateWorkspaceClaim()
        XCTAssertNil(second.workspaceOwner)
        second.currentFiles.root = folder.path; second.updateWorkspaceClaim()
        XCTAssertTrue(second.workspaceOwner === primary)
        // Leaving the workspace, or closing its window, releases the folder.
        primary.page = .recent
        XCTAssertNil(second.workspaceOwner)
        primary.page = .workspace
        XCTAssertTrue(primary.workspaceOwner === second, "ownership follows who shows the folder now")
        second.windowWillClose()
        XCTAssertNil(primary.workspaceOwner)
        XCTAssertTrue(second.shuttingDown)
    }

    /// Option+Tab with exactly two folders: one press must land on the other folder, even when the
    /// same key event reaches the handler twice, and a held key must not keep stepping.
    @MainActor func testSwitcherStepsOncePerKeyPressBetweenTwoFolders() async throws {
        let (store, _) = try fixture(); defer { store.shutdown() }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-switch-" + UUID().uuidString).resolvingSymlinksInPath()
        let folders = ["one", "two"].map { base.appendingPathComponent($0) }
        for folder in folders { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: base) }
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; store.attach(window: window)
        for folder in folders { _ = await store.openDirectoryWorkspace(folder.path, profile: nil) }
        XCTAssertEqual(store.currentFiles.root, folders[1].path)
        let switcher = WorkspaceSwitcher.shared; defer { switcher.dismiss() }
        func key(_ code: UInt16, option: Bool, repeating: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: code == 58 ? .flagsChanged : .keyDown, location: .zero, modifierFlags: option ? .option : [], timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: repeating, keyCode: code)!
        }
        // Option+Q is no longer Harbor's: it reaches the terminal like any other key.
        let q = key(12, option: true)
        XCTAssertTrue(switcher.handle(q) === q); XCTAssertFalse(switcher.visible)
        try await Task.sleep(nanoseconds: 5_000_000)
        let press = key(48, option: true)
        XCTAssertNil(switcher.handle(press)); XCTAssertNil(switcher.handle(press), "the second delivery of one press is swallowed, not acted on")
        XCTAssertNil(switcher.handle(key(48, option: true, repeating: true)))
        XCTAssertTrue(switcher.visible)
        XCTAssertEqual(switcher.entries.first { $0.id == switcher.selectedID }?.path, folders[0].path)
        _ = switcher.handle(key(58, option: false))
        XCTAssertFalse(switcher.visible); XCTAssertEqual(store.currentFiles.root, folders[0].path)
        // And back again with the next press.
        try await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertNil(switcher.handle(key(48, option: true))); _ = switcher.handle(key(58, option: false))
        XCTAssertEqual(store.currentFiles.root, folders[1].path)
        // With nothing on screen (the start page) the first press chooses the most recent folder.
        store.page = .recent
        try await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertNil(switcher.handle(key(48, option: true)))
        XCTAssertEqual(switcher.entries.first { $0.id == switcher.selectedID }?.path, switcher.entries.first?.path)
        XCTAssertEqual(switcher.entries.map(\.path), [folders[1].path, folders[0].path], "the window's folders, the one shown last first")
    }

    /// The remote service script is installed once and then run by name.
    @MainActor func testRemoteBootstrapCacheInstallsOnceAndPassesInputThrough() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-bootstrap-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        func run(_ command: String, input: String) throws -> String {
            let process = Process(), stdin = Pipe(), stdout = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", command]
            process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
            process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
            try process.run()
            stdin.fileHandleForWriting.write(Data(input.utf8)); try stdin.fileHandleForWriting.close()
            let data = stdout.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, command)
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let script = "import sys, json\nprint(json.dumps({'result': json.load(sys.stdin)}))\n", request = "{\"op\": \"it's quoted\"}"
        XCTAssertEqual(try run(CodeWorkbenchSession.cachedBootstrapCommand("aaaa"), input: request), "{\"missing\":true}")
        // An upload cut short (ssh closed early) must never be installed or run.
        XCTAssertEqual(try run(CodeWorkbenchSession.installBootstrapCommand("aaaa"), input: ""), "{\"installed\":false}")
        XCTAssertEqual(try run(CodeWorkbenchSession.installBootstrapCommand("aaaa"), input: script), "{\"installed\":false}")
        XCTAssertEqual(try run(CodeWorkbenchSession.cachedBootstrapCommand("aaaa"), input: request), "{\"missing\":true}")
        // A truncated copy left by an earlier version is replaced, not executed.
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".local/share/harbor"), withIntermediateDirectories: true)
        try Data().write(to: home.appendingPathComponent(".local/share/harbor/bootstrap-aaaa.py"))
        XCTAssertEqual(try run(CodeWorkbenchSession.cachedBootstrapCommand("aaaa"), input: request), "{\"missing\":true}")
        let sealed = { (digest: String) in String(decoding: CodeWorkbenchSession.sealedBootstrap(script, digest: digest), as: UTF8.self) }
        XCTAssertEqual(try run(CodeWorkbenchSession.installBootstrapCommand("aaaa"), input: sealed("aaaa")), "{\"installed\":true}")
        XCTAssertEqual(try run(CodeWorkbenchSession.cachedBootstrapCommand("aaaa"), input: request), "{\"result\": {\"op\": \"it's quoted\"}}")
        let directory = home.appendingPathComponent(".local/share/harbor")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("bootstrap-aaaa.py").path)[.posixPermissions] as? Int, 0o600)
        // Older revisions are pruned; the newest three remain and no partial file is left behind.
        for digest in ["bbbb", "cccc", "dddd"] {
            Thread.sleep(forTimeInterval: 1.05)
            XCTAssertEqual(try run(CodeWorkbenchSession.installBootstrapCommand(digest), input: sealed(digest)), "{\"installed\":true}")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), ["bootstrap-bbbb.py", "bootstrap-cccc.py", "bootstrap-dddd.py"])
    }

    @MainActor func testStartAnimationRendersEveryPhaseForBothAnthropicPalettes() throws {
        for mode in ["light", "dark"] {
            let palette = HarborTheme.anthropicPalettes[mode]!
            for time in [0.0, 1.4, 3.3, AgentHarborAnimation.settled, AgentHarborAnimation.cycle - 0.3] {
                let renderer = ImageRenderer(content: Canvas { context, size in
                    AgentHarborAnimation.draw(&context, size: size, time: time, palette: palette)
                }.frame(width: 640, height: 132))
                let image = try XCTUnwrap(renderer.nsImage, "\(mode) at \(time)")
                XCTAssertEqual(image.size.width, 640)
            }
        }
        XCTAssertEqual(AgentHarborAnimation.agents, ["claude", "codex", "grok", "gemini"])
    }
    func testDollDragStaysInsideSceneAndReturnsHome() {
        let size = CGSize(width: 640, height: 188)
        for index in 0..<4 {
            let center = AgentHarborAnimation.dollCenter(index, size: size)
            let left = AgentHarborAnimation.constrainedDrag(CGSize(width: -1000, height: -1000), index: index, size: size)
            let right = AgentHarborAnimation.constrainedDrag(CGSize(width: 1000, height: 1000), index: index, size: size)
            XCTAssertEqual(center.x + left.width, 25)
            XCTAssertEqual(center.x + right.width, size.width - 25)
            XCTAssertEqual(left.height, -92, "as high as the scene is, over the cards")
            XCTAssertEqual(right.height, 0)
            XCTAssertEqual(AgentHarborAnimation.returnOffset(left, age: 0, reducedMotion: false), left)
            XCTAssertEqual(AgentHarborAnimation.returnOffset(left, age: 0.65, reducedMotion: false), .zero)
            XCTAssertEqual(AgentHarborAnimation.returnOffset(left, age: 0.1, reducedMotion: true), .zero)
        }
    }

    @MainActor func testDollInteractionRendersPastOriginalLoopAndDuringRelease() throws {
        for mode in ["light", "dark"] {
            for reduced in [false, true] {
                for index in 0..<4 {
                    let interaction = AgentHarborAnimation.Interaction(pointer: CGPoint(x: 320, y: 140), hovered: index,
                        ages: [index: 0.2], releases: [index: (CGSize(width: 30, height: -20), 0.15)], reducedMotion: reduced)
                    let renderer = ImageRenderer(content: Canvas { context, size in
                        AgentHarborAnimation.draw(&context, size: size, time: 32, palette: HarborTheme.anthropicPalettes[mode]!,
                                                  interaction: interaction, repeats: false)
                    }.frame(width: 640, height: 188))
                    let image = try XCTUnwrap(renderer.cgImage)
                    XCTAssertEqual(image.width, 640)
                    let bitmap = NSBitmapImageRep(cgImage: image)
                    XCTAssertGreaterThan(bitmap.colorAt(x: 80, y: 150)?.alphaComponent ?? 0, 0)
                }
            }
        }
    }

    /// The running scene is drawn as three sheets laid over one another. Together they are, pixel
    /// for pixel, the scene drawn in one pass, at any moment after the cards have settled.
    @MainActor func testTheSceneInSheetsIsTheSceneInOnePass() throws {
        let size = CGSize(width: 640, height: 188), scale = 2.0
        func picture(_ parts: AgentHarborAnimation.Parts, _ time: Double, _ palette: HarborTheme.Palette, _ interaction: AgentHarborAnimation.Interaction) throws -> CGImage {
            let renderer = ImageRenderer(content: Canvas { context, size in
                AgentHarborAnimation.draw(&context, size: size, time: time, palette: palette, interaction: interaction, repeats: false, parts: parts)
            }.frame(width: size.width, height: size.height))
            renderer.scale = scale
            return try XCTUnwrap(renderer.cgImage)
        }
        /// Laid over one another on an empty ground, as the layers are.
        func pixels(_ images: [CGImage]) throws -> [UInt8] {
            let width = Int(size.width * scale), height = Int(size.height * scale)
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            for image in images { context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)) }
            return Array(UnsafeBufferPointer(start: try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self), count: width * height * 4))
        }
        XCTAssertEqual(AgentHarborAnimation.cardsSettled, 5.95, accuracy: 0.001)
        for dark in [false, true] {
            let palette = HarborTheme.palette(dark: dark, selection: HarborTheme.selection)
            // At rest, mid-hop and mid-blink; with a doll greeted under the pointer; and just after a click.
            let cases: [(Double, AgentHarborAnimation.Interaction)] = [
                (AgentHarborAnimation.cardsSettled, .init()), (9, .init()), (12.34, .init()), (31.7, .init()),
                (14.2, .init(pointer: CGPoint(x: 200, y: 150), hovered: 1)), (20.05, .init(ages: [2: 0.3])),
                // A doll carried up and across, and one on its way back after it was let go.
                (16.6, .init(hovered: 3, dragging: 3, dragOffset: CGSize(width: -180, height: -33))), (18.3, .init(releases: [0: (CGSize(width: 90, height: -30), 0.2)])),
            ]
            for (time, interaction) in cases {
                let whole = try pixels([picture(.all, time, palette, interaction)])
                let sheets = try pixels([picture(.cards, time, palette, interaction), picture(.lines, time, palette, interaction), picture(.dolls, time, palette, interaction)])
                var worst = 0, drawn = 0
                for index in whole.indices { worst = max(worst, abs(Int(whole[index]) - Int(sheets[index]))); if whole[index] != 0 { drawn += 1 } }
                XCTAssertGreaterThan(drawn, 20_000, "the scene is there at \(time)")
                // Where a doll's soft edge lies over a card, eight bits a sheet round a little differently from one pass.
                XCTAssertLessThanOrEqual(worst, 4, "sheets differ from one pass at \(time), dark \(dark)")
            }
            // A doll that is carried upward is in front of the cards, not cut off by them: where it
            // covers its card, the scene is not the card's picture.
            let lifted = AgentHarborAnimation.Interaction(hovered: 0, dragging: 0, dragOffset: CGSize(width: 0, height: -33))
            let carried = try pixels([picture(.all, 15, palette, lifted)]), plain = try pixels([picture(.cards, 15, palette, lifted), picture(.lines, 15, palette, lifted)])
            let center = AgentHarborAnimation.dollCenter(0, size: size), width = Int(size.width * scale)
            // A point on the doll's body, inside the card's lower edge (the card ends 100 points down).
            let spot = (Int(92 * scale) * width + Int(center.x * scale)) * 4
            XCTAssertNotEqual(Array(carried[spot..<spot + 3]), Array(plain[spot..<spot + 3]), "the carried doll is drawn over its card")
            // The cards, once settled, are the same picture whenever they are drawn; so they are drawn once.
            let early = try pixels([picture(.cards, AgentHarborAnimation.cardsSettled, palette, .init())]), late = try pixels([picture(.cards, 47.3, palette, .init(hovered: 0))])
            XCTAssertEqual(early, late)
        }
    }

    @MainActor func testInteractiveDollViewHasVisibleCanvas() throws {
        let renderer = ImageRenderer(content: AgentHarborAnimation(frozenAt: 9).frame(width: 640, height: 188))
        let image = try XCTUnwrap(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        XCTAssertGreaterThan(bitmap.colorAt(x: 80, y: 150)?.alphaComponent ?? 0, 0)
    }

    func testDollsAppearWhenTimelineStartsInBackground() {
        XCTAssertEqual(AgentHarborAnimation.sceneTime(elapsed: 0, animated: true, active: false, frozenAt: nil), 9)
        XCTAssertEqual(AgentHarborAnimation.sceneTime(elapsed: 0, animated: false, active: true, frozenAt: nil), 9)
        XCTAssertEqual(AgentHarborAnimation.sceneTime(elapsed: 30, animated: true, active: true, frozenAt: nil), 30)
        XCTAssertEqual(AgentHarborAnimation.sceneTime(elapsed: 30, animated: true, active: false, frozenAt: 3), 3)
    }

    @MainActor func testApprovedCowboyAndTerminalRobotDesigns() throws {
        let renderer = ImageRenderer(content: Canvas { context, size in
            AgentHarborAnimation.draw(&context, size: size, time: 9,
                                      palette: HarborTheme.anthropicPalettes["light"]!, repeats: false)
        }.frame(width: 640, height: 188))
        renderer.scale = 1
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        // The wide brown brim distinguishes the approved cowboy from the old knitted cap.
        let brim = try XCTUnwrap(bitmap.colorAt(x: 49, y: 124)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(brim.alphaComponent, 0.9)
        XCTAssertGreaterThan(brim.redComponent, brim.greenComponent)
        XCTAssertLessThan(brim.redComponent / brim.greenComponent, 1.7)
        // The approved Codex has a navy screen; the old box robot had a white screen.
        let screen = try XCTUnwrap(bitmap.colorAt(x: 240, y: 134)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(screen.alphaComponent, 0.9)
        XCTAssertLessThan(screen.redComponent, 0.2)
        XCTAssertGreaterThan(screen.blueComponent, screen.redComponent * 2)
        if let path = ProcessInfo.processInfo.environment["HARBOR_DOLL_PREVIEW_PATH"] {
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    /// A theme change dissolves each window on screen from its old colors into its new ones;
    /// with motion off the colors change at once.
    @MainActor func testAThemeChangeDissolvesEachWindow() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        window.contentView?.wantsLayer = true
        ThemeTransition.begin(level: .full, windows: [window])
        let dissolve = window.contentView?.layer?.animation(forKey: ThemeTransition.key) as? CATransition
        XCTAssertEqual(dissolve?.type, .fade)
        XCTAssertEqual(dissolve?.duration ?? 0, 0.34, accuracy: 0.001)
        window.contentView?.layer?.removeAllAnimations()
        ThemeTransition.begin(level: .off, windows: [window])
        XCTAssertNil(window.contentView?.layer?.animation(forKey: ThemeTransition.key))
        XCTAssertEqual([ThemeTransition.duration(.full), ThemeTransition.duration(.subtle), ThemeTransition.duration(.off)], [0.34, 0.16, 0])
    }

    /// Each of Harbor's editor themes is told apart by its background as the page writes it: the
    /// palette it was made from, lowercase. No two share one.
    func testEachEditorThemeIsKnownByItsBackground() {
        var seen: [String: String] = [:]
        for family in HarborTheme.families {
            for dark in [false, true] {
                let name = HarborTheme.editorThemeName(dark: dark, selection: HarborTheme.compose(family: family, mode: dark ? "dark" : "light"))
                let pair = family.file == nil ? HarborTheme.cursorPalettes : HarborTheme.lightAndDark(of: family)
                let background = HarborTheme.editorBackground(name)
                XCTAssertEqual(background, pair[dark ? "dark" : "light"]?.colors["editor.background"]?.lowercased(), name)
                XCTAssertEqual(background?.count, 7, name)
                if let background { XCTAssertNil(seen[background], name + " shares its background with " + (seen[background] ?? "")); seen[background] = name }
            }
        }
        XCTAssertEqual(seen.count, HarborTheme.editorThemeNames.count)
        XCTAssertNil(HarborTheme.editorBackground("Default Dark Modern"))
        XCTAssertNil(HarborTheme.editorBackground("Harbor"))
    }
}
