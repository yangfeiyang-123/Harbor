import AppKit
import HarborCore

extension AppStore {
    #if DEBUG
    private static var qaRoot: String? {
        ProcessInfo.processInfo.environment["HARBOR_QA_ROOT"] ?? (Bundle.main.bundleIdentifier?.hasSuffix(".preview") == true ? Bundle.main.object(forInfoDictionaryKey: "HarborQARoot") as? String : nil)
    }
    #endif
    static func launchStore() -> AppStore {
        #if DEBUG
        if let root = qaRoot {
            return AppStore(historyRoot: URL(fileURLWithPath: root).appendingPathComponent(".state"))
        }
        #endif
        return AppStore()
    }
    func loadForLaunch() async {
        #if DEBUG
        beginQAProbe()
        if let root = Self.qaRoot {
            if let host = Bundle.main.object(forInfoDictionaryKey: "HarborQACodeHost") as? String,
               let folder = Bundle.main.object(forInfoDictionaryKey: "HarborQACodeFolder") as? String {
                try? history.prepare(); loading = false
                let profile = ServerProfile(id: UUID(uuidString: "DA9B8705-85CD-46F3-9627-C64C7156C093")!, name: "Code Remote QA", host: host, imported: true)
                profiles = [profile]; selectWorkspace(profile.id)
                currentFiles.root = folder; currentFiles.enabled = true; currentFiles.terminalVisible = false
                return
            }
            if let address = ProcessInfo.processInfo.environment["HARBOR_QA_DISPLAY_URL"] {
                try? history.prepare(); loading = false
                let profile = ServerProfile(name: "2A6000 · Display QA", host: "2A6000", imported: true)
                profiles = [profile]; selectWorkspace(profile.id)
                var display = RemoteDisplayProfile(serverID: profile.id)
                display.name = "MuJoCo · Live Preview"; display.preset = .web; display.address = address
                remoteDisplays.load(); _ = remoteDisplays.save(display)
                page = .display
                return
            }
            if ProcessInfo.processInfo.environment["HARBOR_QA_RECOVERY"] == "1" {
                await load()
                if sessions.isEmpty {
                    selectWorkspace(nil); currentFiles.root = root + "/WorkSpace"
                    currentFiles.enabled = false; openWorkspaceTerminal()
                }
                return
            }
            do {
                try history.prepare(); loading = false
                profiles = [ServerProfile(name: "QA Alpha", host: "alpha.invalid"), ServerProfile(name: "QA Beta", host: "beta.invalid")]
                if ProcessInfo.processInfo.environment["HARBOR_QA_RECENTS"] == "1" {
                    remember(profile: profiles[0], directory: "/home/demo/WorkSpace/Project A")
                    remember(profile: profiles[1], directory: "/home/demo/Research")
                    remember(profile: profiles[0], directory: "/home/demo/WorkSpace/Project B")
                }
                selectWorkspace(nil)
                let files = currentFiles; files.root = root + "/WorkSpace"; files.enabled = true; files.terminalVisible = true
                await files.prepare(store: self); await files.navigate(root + "/WorkSpace")
                codeWorkbench.session(for: files).open(path: files.root + "/main.py")
                openWorkspaceTerminal()
            } catch { errorMessage = error.localizedDescription }
            return
        }
        #endif
        await load()
    }
}

#if DEBUG
import WebKit
import SwiftUI
import QuartzCore

/// Debug builds only. A preview bundle that names a probe directory accepts
/// small JSON requests there (inspect the embedded workbench, render windows to
/// PNG, change a preference), so layout work can be verified without driving
/// the pointer. Release builds contain none of this.
@MainActor extension AppStore {
    /// How often the probe was asked whether a window may close.
    static var qaCloseQuestions = 0
    /// A split tree written out: "(a | b)" side by side, "(a / b)" one above the other.
    static func shape(_ layout: TerminalLayout) -> String {
        switch layout {
        case .terminal: return "•"
        case .split(_, let axis, _, let first, let second): return "(" + shape(first) + (axis == .columns ? " | " : " / ") + shape(second) + ")"
        }
    }
    private static var qaProbeDirectory: URL? {
        let value = ProcessInfo.processInfo.environment["HARBOR_QA_PROBE"]
            ?? (Bundle.main.bundleIdentifier?.hasSuffix(".preview") == true ? Bundle.main.object(forInfoDictionaryKey: "HarborQAProbe") as? String : nil)
        return value.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    func beginQAProbe() {
        guard let directory = Self.qaProbeDirectory else { return }
        Task { [weak self] in
            let request = directory.appendingPathComponent("request.json")
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, let data = try? Data(contentsOf: request),
                      let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = body["id"] as? String else { continue }
                try? FileManager.default.removeItem(at: request)
                let reply = await answerQAProbe(body, id: id, directory: directory)
                let encoded = (try? JSONSerialization.data(withJSONObject: reply, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
                try? encoded.write(to: directory.appendingPathComponent("response-" + id + ".json"), options: .atomic)
            }
        }
    }
    private func answerQAProbe(_ body: [String: Any], id: String, directory: URL) async -> [String: Any] {
        if body["secondary"] as? Bool == true, isPrimary, let other = AppStore.all.first(where: { !$0.isPrimary }) {
            return await other.answerQAProbe(body, id: id, directory: directory)
        }
        let editor = codeWorkbench.existing(for: currentFiles)
        switch body["action"] as? String {
        case "switcher":
            let switcher = WorkspaceSwitcher.shared
            switch body["op"] as? String {
            case "present": switcher.present(sticky: true, window: window)
            case "move": switcher.move(body["delta"] as? Int ?? 1)
            case "trace": return ["trace": switcher.trace, "visible": switcher.visible]
            case "keys":
                // Real key events through the switcher's own handler: [[keyCode, "option"|"option+shift"|""]...]
                for step in body["keys"] as? [[Any]] ?? [] {
                    guard let code = step.first as? Int else { continue }
                    let names = (step.last as? String ?? "").split(separator: "+")
                    var flags: NSEvent.ModifierFlags = []
                    if names.contains("option") { flags.insert(.option) }
                    if names.contains("shift") { flags.insert(.shift) }
                    let type: NSEvent.EventType = code < 0 ? .flagsChanged : .keyDown
                    if let event = type == .flagsChanged
                        ? NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)
                        : NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(code)) {
                        _ = switcher.handle(event)
                    }
                }
            case "type":
                // Text typed into the open list, a key for each character.
                for character in body["text"] as? String ?? "" {
                    if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0, context: nil,
                                                    characters: String(character), charactersIgnoringModifiers: String(character), isARepeat: false, keyCode: 0) { _ = switcher.handle(event) }
                }
            case "commit": switcher.commit()
            case "dismiss": switcher.dismiss()
            default: break
            }
            return ["visible": switcher.visible, "selected": switcher.selectedID ?? "", "query": switcher.query,
                    "folder": switcher.entries.first { $0.id == switcher.selectedID }?.title ?? "", "window": switcher.windowTitle,
                    "entries": switcher.entries.map { ($0.id == switcher.firstOther ? "| " : "") + $0.server + "/" + $0.title + ($0.current ? " (current)" : "") + ($0.open ? " (open)" : "") + ($0.window.map { " (in " + $0 + ")" } ?? "") }]
        case "openFolder":
            guard let path = body["path"] as? String else { return ["error": "missing path"] }
            let profile = (body["server"] as? String).flatMap { name in profiles.first { $0.name == name } }
            if body["server"] != nil, profile == nil { return ["error": "unknown server"] }
            _ = await openDirectoryWorkspace(path, profile: profile); return ["root": currentFiles.root]
        case "state":
            return ["stores": AppStore.all.count, "primary": isPrimary, "elsewhere": workspaceOwner != nil, "page": page.rawValue, "phase": editor?.phase ?? "", "ready": editor?.ready ?? false, "error": editor?.error ?? errorMessage ?? "",
                    "windows": NSApp.windows.filter(\.isVisible).map { ["title": $0.title, "frame": NSStringFromRect($0.frame)] },
                    "root": currentFiles.root, "rss": Self.residentMemory(), "settings": settingsVisible, "attached": windowAttached, "hasWindow": window != nil, "loading": loading,
                    "all": NSApp.windows.map { String(describing: type(of: $0)) + ($0.isVisible ? " visible " : " hidden ") + $0.title + " " + NSStringFromRect($0.frame) },
                    "tabs": window?.tabbedWindows?.count ?? 1, "selectedTab": window?.tabGroup?.selectedWindow.flatMap { window?.tabbedWindows?.firstIndex(of: $0) } ?? 0]
        case "editor":
            // The editor's connection as Harbor sees it; "reload" asks the page to load again, as its "Reload Window" does.
            let session = codeWorkbench.session(for: currentFiles)
            if body["reload"] as? Bool == true { session.web?.reload() }
            if let script = body["js"] as? String { _ = try? await session.web?.evaluateJavaScript(script) }
            if body["repair"] as? Bool == true { return ["repaired": await session.repairTransport()] }
            try? await Task.sleep(for: .seconds(body["wait"] as? Double ?? 0.5))
            return ["ready": session.ready, "starting": session.starting, "missed": session.missedBeats, "error": session.error ?? "", "phase": session.phase, "web": session.web != nil, "lastReload": CodeWorkbenchSession.lastReload]
        case "bar":
            // The workbench bar's controls, shown as the pointer would show them; and where a side page leads back to.
            NotificationCenter.default.post(name: Notification.Name("harbor.qa.bar"), object: body["reveal"] as? Bool ?? true)
            if let action = body["workbench"] as? String { handleWorkbenchAction(["action": action]) }
            try? await Task.sleep(for: .seconds(0.4))
            return ["page": page.rawValue, "returns": pageReturn.rawValue, "organizer": organizerVisible, "previous": hasPreviousSessions]
        case "page":
            if let value = body["value"] as? String, let next = AppPage.allCases.first(where: { String(describing: $0) == value }) { page = next }
            return ["page": page.rawValue]
        case "defaults":
            guard let key = body["key"] as? String else { return ["error": "missing key"] }
            if let value = body["value"], !(value is NSNull) { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            return ["ok": true]
        case "key":
            // A key press as the keyboard would deliver it: through the event queue, monitors and menus.
            guard let code = body["code"] as? Int, let target = (body["tab"] as? Int).flatMap({ index in window?.tabbedWindows.flatMap { index < $0.count ? $0[index] : nil } }) ?? window else { return ["error": "no window"] }
            let names = (body["flags"] as? String ?? "").split(separator: "+")
            var flags: NSEvent.ModifierFlags = []
            for (name, flag) in [("command", NSEvent.ModifierFlags.command), ("shift", .shift), ("option", .option), ("control", .control)] where names.contains(Substring(name)) { flags.insert(flag) }
            let characters = body["chars"] as? String ?? ""
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: target.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                               isARepeat: false, keyCode: UInt16(code)) else { return ["error": "no event"] }
            NSApp.postEvent(event, atStart: false)
            try? await Task.sleep(nanoseconds: UInt64((body["wait"] as? Double ?? 0.4) * 1_000_000_000))
            return ["ok": true, "settings": settingsVisible, "stores": AppStore.all.count]
        case "dollCost":
            // What one frame of the start page's scene costs to draw, at its size on screen.
            let palette = HarborTheme.palette(dark: body["dark"] as? Bool ?? true, selection: HarborTheme.selection)
            let rounds = body["rounds"] as? Int ?? 30, width = body["width"] as? Double ?? 1100
            var time = body["from"] as? Double ?? 12
            let parts = AgentHarborAnimation.Parts(rawValue: body["parts"] as? Int ?? 7)
            let began = CFAbsoluteTimeGetCurrent()
            for _ in 0..<rounds {
                time += 1.0 / 60
                let at = time
                let view = Canvas { context, size in AgentHarborAnimation.draw(&context, size: size, time: at, palette: palette, parts: parts) }.frame(width: width, height: 188)
                let renderer = ImageRenderer(content: view); renderer.scale = 2; _ = renderer.cgImage
            }
            return ["msPerFrame": ((CFAbsoluteTimeGetCurrent() - began) / Double(rounds) * 10000).rounded() / 10, "rounds": rounds, "parts": parts.rawValue]
        case "modelCost":
            // What the organizer reads each time it is laid out, timed apart from the laying out.
            let rounds = body["rounds"] as? Int ?? 200
            func time(_ work: () -> Void) -> Double { let began = CFAbsoluteTimeGetCurrent(); for _ in 0..<rounds { work() }; return ((CFAbsoluteTimeGetCurrent() - began) / Double(rounds) * 1_000_000).rounded() }
            return ["known": time { _ = knownFolders() }, "library": time { _ = library() }, "kept": time { _ = windowStores.map(\.keptFolders) },
                    "recent": time { _ = recentWindows() }, "matches": time { _ = knownFolders().map(\.match) }, "folders": knownFolders().count, "unit": "µs"]
        case "scrollPulse":
            // Scrolls the leftmost list that has more than fits, up and down for a while, and says how busy
            // the main thread was meanwhile: what a scroll costs here, apart from what the window server does.
            guard let root = window?.contentView else { return ["error": "no window"] }
            var lists: [NSScrollView] = []
            func find(_ view: NSView) {
                if let scroll = view as? NSScrollView, let document = scroll.documentView, document.frame.height > scroll.contentSize.height + 20 { lists.append(scroll) }
                view.subviews.forEach(find)
            }
            find(root)
            // "widest" is the page's own list; otherwise the narrowest, which is the organizer's library when that is open.
            let widest = body["widest"] as? Bool == true
            guard let list = widest ? lists.max(by: { $0.frame.width < $1.frame.width }) : lists.min(by: { $0.frame.width < $1.frame.width }), let document = list.documentView else { return ["error": "no list", "lists": lists.count] }
            var views = 0
            func count(_ view: NSView) { views += 1; view.subviews.forEach(count) }
            count(document)
            let range = document.frame.height - list.contentSize.height, seconds = body["seconds"] as? Double ?? 2
            if let movable = body["movable"] as? Bool { window?.isMovable = movable }
            // The processor time of this (the main) thread, apart from time it only waited.
            func threadSeconds() -> Double {
                var info = thread_basic_info(), count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
                let thread = mach_thread_self(); defer { mach_port_deallocate(mach_task_self_, thread) }
                let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) } }
                guard result == KERN_SUCCESS else { return 0 }
                return Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1e6 + Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1e6
            }
            let processor = threadSeconds()
            var busy = 0.0, woke = CFAbsoluteTimeGetCurrent(), longest = 0.0, turns = 0, over = 0
            let evaluations = WindowOrganizer.evaluations, rows = WindowOrganizer.rowEvaluations
            let draws = AgentHarborAnimation.draws, drawSeconds = AgentHarborAnimation.drawSeconds
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, activity in
                let now = CFAbsoluteTimeGetCurrent()
                if activity == .afterWaiting { woke = now } else { let spent = now - woke; busy += spent; longest = max(longest, spent); turns += 1; if spent > 0.008 { over += 1 } }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            let began = CFAbsoluteTimeGetCurrent(); var steps = 0
            while CFAbsoluteTimeGetCurrent() - began < seconds {
                let phase = abs(sin((CFAbsoluteTimeGetCurrent() - began) * .pi * 1.5))
                if body["publish"] as? Bool == true { objectWillChange.send() }
                else if body["still"] as? Bool != true { list.contentView.scroll(to: NSPoint(x: 0, y: range * phase)); list.reflectScrolledClipView(list.contentView) }
                steps += 1
                try? await Task.sleep(for: .milliseconds(8))
            }
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            return ["steps": steps, "cpuMs": ((threadSeconds() - processor) * 1000).rounded(), "busyMs": (busy * 1000).rounded(), "longestMs": (longest * 10000).rounded() / 10, "turns": turns, "over8ms": over, "range": range, "lists": lists.count, "views": views, "width": list.frame.width,
                    "organizer": WindowOrganizer.evaluations - evaluations, "rows": WindowOrganizer.rowEvaluations - rows,
                    "sceneDraws": AgentHarborAnimation.draws - draws, "sceneDrawMs": ((AgentHarborAnimation.drawSeconds - drawSeconds) * 1000).rounded()]
        case "separate":
            // Keeps this window out of the tabs, or puts it back.
            if let value = body["value"] as? Bool { setSeparate(value) }
            try? await Task.sleep(for: .seconds(body["wait"] as? Double ?? 0.6))
            return ["separate": separate, "tabs": window?.tabbedWindows?.count ?? 1, "groups": AppStore.all.compactMap(\.window).map { $0.title + ": " + String($0.tabbedWindows?.count ?? 1) }]
        case "mergeTabs":
            // Gathers every workbench window into this one as tabs, as Window ▸ Merge All Windows does.
            guard let window else { return ["error": "no window"] }
            for other in AppStore.all.compactMap(\.window) where other !== window && other.tabbedWindows?.contains(window) != true {
                window.addTabbedWindow(other, ordered: .above)
            }
            return ["tabs": window.tabbedWindows?.count ?? 1]
        case "chrome":
            // What the system puts over the top of the window (title bar, tab bar), windowed or full screen.
            guard let window else { return ["error": "no window"] }
            if let full = body["fullScreen"] as? Bool, full != window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil); try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            var found: [[String: Any]] = []
            func walk(_ view: NSView, in host: NSWindow) {
                let name = String(describing: type(of: view))
                if name.contains("Tab") || name.contains("Titlebar") {
                    found.append(["class": name, "window": String(describing: type(of: host)), "hidden": view.isHiddenOrHasHiddenAncestor,
                                  "screen": NSStringFromRect(host.convertToScreen(view.convert(view.bounds, to: nil)))])
                }
                view.subviews.forEach { walk($0, in: host) }
            }
            for host in NSApp.windows where host.isVisible { if let root = host.contentView?.superview { walk(root, in: host) } }
            if body["layers"] as? Bool == true, let base = window.contentView?.layer {
                // What Harbor's own views draw in the top rows of the window.
                var lines: [String] = []
                func dump(_ layer: CALayer, _ depth: Int) {
                    let frame = layer.convert(layer.bounds, to: base)
                    guard depth < 40 else { return }
                    let top = base.isGeometryFlipped ? frame.minY : base.bounds.height - frame.maxY
                    if top < 70, frame.height < 80 || depth < 3 {
                        lines.append(String(repeating: " ", count: min(depth, 20)) + String(describing: type(of: layer)) + String(format: " x%.0f top%.0f w%.0f h%.0f o%.2f", frame.minX, top, frame.width, frame.height, layer.opacity)
                                     + (layer.isHidden ? " hidden" : "") + (layer.contents != nil ? " contents" : "") + (layer.mask != nil ? " mask" : "") + (layer.masksToBounds ? " clips" : "")
                                     + (layer.delegate.map { " <" + String(describing: type(of: $0)) + ">" } ?? ""))
                    }
                    layer.sublayers?.forEach { dump($0, depth + 1) }
                }
                dump(base, 0)
                return ["layers": lines]
            }
            if body["tree"] as? Bool == true, let root = window.contentView?.superview {
                // Everything the system adds around the content, to see what covers the title row.
                var lines: [String] = []
                func dump(_ view: NSView, _ depth: Int) {
                    guard view !== window.contentView, depth < 9 else { return }
                    let color = view.layer?.backgroundColor.map { String(format: "bg%.2f", $0.alpha) } ?? "-"
                    lines.append(String(repeating: " ", count: depth) + String(describing: type(of: view)) + " " + NSStringFromRect(view.convert(view.bounds, to: nil))
                                 + (view.isHidden ? " hidden" : "") + String(format: " a%.2f ", view.alphaValue) + color + (view.isOpaque ? " opaque" : ""))
                    view.subviews.forEach { dump($0, depth + 1) }
                }
                dump(root, 0)
                return ["tree": lines]
            }
            let insets = window.contentView?.safeAreaInsets ?? NSEdgeInsets()
            // Where Harbor put its own rows: each as [distance from the top of the window, height].
            var rows: [String: [[Double]]] = [:]
            func place(_ view: NSView) {
                let name = String(describing: type(of: view))
                if name == "DragArea" || name.hasSuffix("WebView"), !view.isHiddenOrHasHiddenAncestor {
                    let frame = view.convert(view.bounds, to: nil)
                    rows[name, default: []].append([Double(window.frame.height - frame.maxY), Double(frame.height)])
                }
                view.subviews.forEach(place)
            }
            if let content = window.contentView { place(content) }
            return ["rows": rows, "transparent": window.titlebarAppearsTransparent, "titleHidden": window.titleVisibility == .hidden, "fullSize": window.styleMask.contains(.fullSizeContentView),
                    "separator": window.titlebarSeparatorStyle.rawValue, "frame": NSStringFromRect(window.frame), "layout": NSStringFromRect(window.contentLayoutRect), "safeTop": insets.top,
                    "fullScreen": window.styleMask.contains(.fullScreen), "tabBar": window.tabGroup?.isTabBarVisible ?? false,
                    "tabs": window.tabbedWindows?.count ?? 1, "title": window.title, "views": body["views"] as? Bool == true ? found : [],
                    "windows": NSApp.windows.filter(\.isVisible).map { String(describing: type(of: $0)) + " " + NSStringFromRect($0.frame) }]
        case "window":
            // The window's name, and what Harbor leaves free at its top for the system.
            if let name = body["rename"] as? String { renameWindow(to: name) }
            if body["prompt"] as? Bool == true { promptForWindowName() }
            if let point = body["doubleClick"] as? [Double], point.count == 2, let window {
                // As the pointer would: presses at a point measured from the top left corner of the window,
                // or of the window that holds the tab bar in full screen. "count" sends one press of a pair.
                let toolbars = NSApp.windows.filter { $0.isVisible && String(describing: type(of: $0)) == "NSToolbarFullScreenWindow" }
                let index = body["toolbar"] as? Int
                let target = index.flatMap { $0 < toolbars.count ? toolbars[$0] : nil } ?? window
                for count in (body["count"] as? Int).map({ [$0] }) ?? [1, 2] {
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: point[0], y: target.frame.height - point[1]), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                          windowNumber: target.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: type == .leftMouseDown ? 1 : 0) { NSApp.postEvent(event, atStart: false) }
                    }
                }
            }
            try? await Task.sleep(nanoseconds: UInt64((body["wait"] as? Double ?? 0.5) * 1_000_000_000))
            let sheet = window?.attachedSheet
            if let sheet, body["endSheet"] as? Bool == true { window?.endSheet(sheet, returnCode: .cancel) }
            // The close question answered by the probe (and counted), and the close button pressed as the pointer would.
            if let answer = body["answerClose"] as? Bool { confirmWindowClose = { _ in AppStore.qaCloseQuestions += 1; return answer } }
            if body["closeInfo"] != nil {
                let button = window?.standardWindowButton(.closeButton)
                return ["button": (button?.action.map(NSStringFromSelector) ?? "-") + " → " + (button?.target.map { String(describing: type(of: $0)) } ?? "-"),
                        "window": window.map { String(describing: type(of: $0)) } ?? "-", "primary": isPrimary, "may": mayCloseWindow(), "asked": AppStore.qaCloseQuestions,
                        "delegate": window?.delegate.map { String(describing: type(of: $0)) } ?? "-",
                        "delegateAsks": window?.delegate?.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))) ?? false,
                        "windowAsks": window?.responds(to: NSSelectorFromString("windowShouldClose:")) ?? false]
            }
            if body["close"] as? Bool == true { window?.performClose(nil) }
            if body["closeButton"] as? Bool == true { window?.standardWindowButton(.closeButton)?.performClick(nil) }
            if body["closeQuestions"] != nil {
                let button = window?.standardWindowButton(.closeButton)
                return ["asked": AppStore.qaCloseQuestions, "open": window != nil, "primary": isPrimary,
                        "button": (button?.action.map(NSStringFromSelector) ?? "-") + " → " + (button?.target.map { String(describing: type(of: $0)) } ?? "-"),
                        "window": window.map { String(describing: type(of: $0)) } ?? "-"]
            }
            return ["name": windowName ?? NSNull(), "title": windowTitle, "windowTitle": window?.title ?? "", "sheet": sheet != nil,
                    "top": ["titleRow": windowTop.titleRow, "tabBar": windowTop.tabBar, "fullScreen": windowTop.fullScreen, "contentTop": windowTop.contentTop, "aboveBar": windowTop.aboveBar]]
        case "hitches":
            // How long the main thread is held after a change: sleeps of 4 ms that return late.
            let started = CACurrentMediaTime(); var last = started, gaps: [[Double]] = []
            if let visible = body["settings"] as? Bool { settingsVisible = visible }
            if let tab = body["tab"] as? String { UserDefaults.standard.set(tab, forKey: "settingsTab") }
            if let query = body["query"] as? String { NotificationCenter.default.post(name: .harborQASettings, object: nil, userInfo: ["query": query]) }
            if let size = body["resize"] as? [Double], size.count == 2, let window {
                window.setFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - size[1], width: size[0], height: size[1]), display: true)
            }
            while CACurrentMediaTime() - started < (body["seconds"] as? Double ?? 2) {
                try? await Task.sleep(nanoseconds: 4_000_000)
                let now = CACurrentMediaTime()
                if now - last > 0.02 { gaps.append([((last - started) * 1000).rounded(), ((now - last) * 1000).rounded()]) }
                last = now
            }
            return ["gaps": gaps, "held": gaps.reduce(0) { $0 + $1[1] }]
        case "settings":
            settingsVisible = body["visible"] as? Bool ?? true
            if let tab = body["tab"] as? String { UserDefaults.standard.set(tab, forKey: "settingsTab") }
            if let maximized = body["maximized"] as? Bool { UserDefaults.standard.set(maximized, forKey: "settingsMaximized") }
            try? await Task.sleep(nanoseconds: 200_000_000)
            NotificationCenter.default.post(name: .harborQASettings, object: nil, userInfo: body.filter { ["query", "scope"].contains($0.key) })
            return ["ok": true, "visible": settingsVisible]
        case "open":
            guard let editor, let path = body["path"] as? String else { return ["error": "no editor"] }
            editor.open(path: path); return ["ok": true]
        case "command":
            guard let editor, let name = body["name"] as? String else { return ["error": "no editor"] }
            do {
                let result = try await editor.request(name, extra: body["extra"] as? [String: Any] ?? [:])
                // A large reply (the settings catalog) goes to a file beside the probe.
                if let file = body["save"] as? String, let result {
                    try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]).write(to: URL(fileURLWithPath: file)); return ["ok": true, "saved": file]
                }
                return body["reply"] as? Bool == true ? ["ok": true, "result": result ?? NSNull()] : ["ok": true]
            } catch { return ["error": error.localizedDescription] }
        case "connections":
            // Whether Harbor holds a connection to each server, as every window shows it.
            await refreshConnections()
            return ["states": Dictionary(uniqueKeysWithValues: profiles.map { ($0.name, connectionStates[$0.id] ?? "unknown") }),
                    "open": profiles.filter { hasOpen($0.id) }.map(\.name) + (hasOpen(nil) ? [LocalMachine.name] : [])]
        case "newWindow":
            workbenchUIRequest = "newWindow"; return ["ok": true]
        case "newTerminal":
            // Start page ▸ New Terminal, or a server's New Terminal there.
            let profile = (body["server"] as? String).flatMap { name in profiles.first { $0.name == name } }
            if body["server"] != nil, profile == nil { return ["error": "unknown server"] }
            if let value = body["page"] as? String, let next = AppPage.allCases.first(where: { String(describing: $0) == value }) { page = next }
            openHomeTerminal(profile)
            if let text = body["send"] as? String { homeTerminal?.terminal.send(txt: text) }
            try? await Task.sleep(nanoseconds: UInt64((body["wait"] as? Double ?? 0.6) * 1_000_000_000))
            let session = homeTerminal
            return ["page": page.rawValue, "title": windowTitle, "sessions": sessions.count, "recents": recents.count, "started": session?.started ?? false, "ended": session?.ended ?? true,
                    "focused": session.map { $0.terminal.window?.firstResponder === $0.terminal } ?? false,
                    "text": session.map { String($0.recoveryOutput().suffix(160)) } ?? ""]
        case "terminals":
            // The terminal page as it is arranged: its tabs, the panes of the one on screen, and where the keyboard is.
            let scope = currentTerminalScope, layout = arrangement(in: scope)
            func name(_ id: UUID) -> String { sessions.first { $0.id == id }.map { ($0.effectiveDirectory as NSString?)?.lastPathComponent ?? $0.tabTitle } ?? "?" }
            let focused = sessions.first { $0.terminal.window?.firstResponder === $0.terminal }
            return ["page": page.rawValue, "tabs": layout.groups.map { $0.sessionIDs.count }, "tab": layout.groups.firstIndex { $0.id == layout.selectedGroup?.id } ?? -1,
                    "panes": (layout.visible?.sessionIDs ?? []).map(name), "selected": (layout.visible?.sessionIDs ?? []).firstIndex { $0 == layout.selectedID } ?? -1,
                    "focused": focused.flatMap { f in layout.visible?.sessionIDs.firstIndex(of: f.id) } ?? -1, "sessions": sessions.count,
                    "layout": String(describing: layout.visible.map(Self.shape) ?? "-")]
        case "js":
            guard let web = editor?.web, let script = body["script"] as? String else { return ["error": "no editor web view"] }
            do {
                let value = try await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
                return ["result": value.map { JSONSerialization.isValidJSONObject([$0]) ? $0 : String(describing: $0) } ?? NSNull()]
            } catch { return ["error": String(describing: error)] }
        case "snapshot":
            var files: [String] = []
            for (index, window) in NSApp.windows.filter({ $0.isVisible && $0.contentView != nil }).enumerated() {
                guard let view = window.contentView?.superview ?? window.contentView, let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: image)
                let name = id + "-window-\(index).png"
                try? image.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name)); files.append(name)
            }
            // What the window server shows for this application's own windows, system materials included
            // (cacheDisplay draws the views themselves and leaves those out).
            typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
            if body["real"] as? Bool == true, let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
                let capture = unsafeBitCast(symbol, to: Capture.self)
                for (index, window) in NSApp.windows.filter({ $0.isVisible && $0.isOnActiveSpace && $0.frame.width > 300 }).enumerated() {
                    guard let image = capture(.null, 1 << 3, UInt32(window.windowNumber), 1)?.takeRetainedValue() else { continue }
                    let name = id + "-real-\(index).png"
                    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name)); files.append(name)
                }
            }
            if let web = editor?.web, let image = try? await web.takeSnapshot(configuration: nil),
               let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) {
                let name = id + "-web.png"
                try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name)); files.append(name)
            }
            return ["files": files]
        case "dock":
            // The Dock menu as AppKit asks for it, and its first item chosen.
            let menu = NSApp.delegate?.applicationDockMenu?(NSApp)
            if body["perform"] as? Bool == true, let item = menu?.items.first, let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
            try? await Task.sleep(for: .seconds(body["wait"] as? Double ?? 1))
            return ["items": menu?.items.map(\.title) ?? [], "stores": AppStore.all.count, "windows": NSApp.windows.filter { $0.isVisible && $0.frame.width > 300 }.count]
        case "outside":
            // Folders handed to Harbor, as a drop on the Dock icon delivers them.
            let urls = (body["paths"] as? [String] ?? []).map { URL(fileURLWithPath: $0) }
            if body["direct"] as? Bool == true { AppStore.openFromOutside(urls) } else { NSApp.delegate?.application?(NSApp, open: urls) }
            try? await Task.sleep(for: .seconds(body["wait"] as? Double ?? 1))
            return ["stores": AppStore.all.count, "windows": NSApp.windows.filter { $0.isVisible && $0.frame.width > 300 }.count,
                    "pages": AppStore.all.map { ($0.isPrimary ? "primary " : "window ") + $0.page.rawValue + " " + $0.currentFiles.root + ($0.arriving != nil ? " (arriving)" : "") }]
        case "webDrop":
            // Folders let go over the editor, at a point given as fractions of its size.
            guard let web = editor?.web as? WorkbenchWebView else { return ["error": "no editor"] }
            let board = NSPasteboard(name: NSPasteboard.Name("harbor-qa-" + id)); board.clearContents()
            board.writeObjects((body["paths"] as? [String] ?? []).map { NSURL(fileURLWithPath: $0) })
            let at = body["at"] as? [Double] ?? [0.5, 0.3]
            let local = CGPoint(x: web.bounds.width * at[0], y: web.isFlipped ? web.bounds.height * at[1] : web.bounds.height * (1 - at[1]))
            let info = QADrag(pasteboard: board, location: web.convert(local, to: nil), window: web.window)
            let entered = web.draggingEntered(info), done = entered != [] && web.performDragOperation(info)
            try? await Task.sleep(for: .seconds(body["wait"] as? Double ?? 1.5))
            return ["entered": entered.rawValue, "performed": done, "page": page.rawValue, "root": currentFiles.root]
        case "hit":
            // The view a click would reach, at a point given as fractions of the window's content (from the top left).
            guard let content = window?.contentView else { return ["error": "no window"] }
            let at = body["at"] as? [Double] ?? [0.5, 0.5]
            let point = CGPoint(x: content.bounds.width * at[0], y: content.isFlipped ? content.bounds.height * at[1] : content.bounds.height * (1 - at[1]))
            var chain: [String] = []
            var view = content.hitTest(content.superview?.convert(point, from: content) ?? point)
            while let current = view, chain.count < 6 { chain.append(String(describing: type(of: current))); view = current.superview }
            return ["chain": chain]
        case "stopOpening":
            stopOpening(currentFiles)
            try? await Task.sleep(for: .seconds(0.4))
            return ["page": page.rawValue, "root": currentFiles.root, "kept": keptFolders.map(\.title)]
        case "organizer":
            // Folders in Windows: show it, move a folder by its title, and say what is where.
            // A planned window ("draft": its name), a folder put in one ("place": title, "in": index),
            // a folder added to the library ("add": path, "server": name).
            if let name = body["draft"] as? String { let id = withAnimation(WindowOrganizer.motion) { addDraft() }; if let index = windowDrafts.firstIndex(where: { $0.id == id }) { windowDrafts[index].name = name } }
            if let title = body["place"] as? String, let folder = knownFolders().first(where: { $0.title == title }),
               let index = body["in"] as? Int, windowDrafts.indices.contains(index) { place(folder.id, inDraft: windowDrafts[index].id) }
            if let path = body["add"] as? String { addToLibrary(path, profile: (body["server"] as? String).flatMap { name in profiles.first { $0.name == name } }) }
            if let name = body["browse"] as? String { chooseLibraryFolder(on: profiles.first { $0.name == name }, systemPanel: false) }
            if let path = body["path"] as? String { directoryBrowser?.editPath(path) }
            if let index = body["reopen"] as? Int, closedWindows().indices.contains(index) { let window = closedWindows()[index]; withAnimation(WindowOrganizer.motion) { _ = reopen(window) } }
            if let index = body["reopenNow"] as? Int, closedWindows().indices.contains(index) { reopenNow(closedWindows()[index]) }
            if let index = body["discard"] as? Int, windowDrafts.indices.contains(index) { let id = windowDrafts[index].id; withAnimation(WindowOrganizer.motion) { discardDraft(id) } }
            if let visible = body["visible"] as? Bool { organizerVisible = visible }
            if let title = body["move"] as? String, let folder = AppStore.all.lazy.compactMap({ $0.keptFolders.first { $0.title == title } }).first ?? knownFolders().first(where: { $0.title == title }) {
                switch body["to"] as? String {
                case "new": moveToNewWindow(folder.id)
                case "none": _ = AppStore.move(folder.id, to: nil)
                case let name?: _ = AppStore.move(folder.id, to: windowStores.first { $0.windowTitle == name } ?? (name == "this" ? self : nil))
                default: break
                }
            }
            try? await Task.sleep(for: .seconds(body["wait"] as? Double ?? 0.5))
            let placed = Set(windowStores.flatMap { $0.keptFolders.map(\.match) })
            return ["windows": windowStores.map { $0.windowTitle + " [" + $0.page.rawValue + "]: " + $0.keptFolders.map(\.title).joined(separator: ", ") },
                    "free": knownFolders().filter { !placed.contains($0.match) }.map { $0.server + "/" + $0.title }, "visible": organizerVisible, "error": errorMessage ?? "",
                    "drafts": windowDrafts.map { draft in draft.title + ": " + draft.folders.compactMap { AppStore.folder($0)?.title }.joined(separator: ", ") },
                    "library": library().map { $0.name + ": " + $0.folders.map(\.title).joined(separator: ", ") }, "plans": AppStore.pendingPlans.count,
                    "browser": directoryBrowser.map { ($0.adding ? "adding " : "opening ") + $0.path + " [" + $0.folders.prefix(6).map(\.name).joined(separator: ", ") + "] " + ($0.candidatePath ?? "-") } ?? "",
                    "recent": recentWindows().map { $0.name + ": " + $0.folders.compactMap { AppStore.folder($0)?.title }.joined(separator: ", ") },
                    "closed": closedWindows().map(\.name), "columns": windowStores.filter { !$0.isBlank }.map(\.windowTitle), "name": windowName ?? ""]
        case "tabbar":
            // The tab bar as the window holds it: its accessory controller, and what hiding it does.
            guard let window else { return ["error": "no window"] }
            func describe(_ controller: NSTitlebarAccessoryViewController) -> String {
                String(describing: type(of: controller)) + " attr=\(controller.layoutAttribute.rawValue) hidden=\(controller.isHidden) min=\(controller.fullScreenMinHeight) view=" + String(describing: type(of: controller.view)) + " " + NSStringFromRect(controller.view.frame)
            }
            var bar: NSView?
            func find(_ view: NSView) { if String(describing: type(of: view)) == "NSTabBar" { bar = view }; view.subviews.forEach(find) }
            for host in NSApp.windows where host.isVisible { if bar == nil, let root = host.contentView?.superview { find(root) } }
            var chain: [String] = []
            var responder: NSResponder? = bar
            var owner: NSTitlebarAccessoryViewController?
            while let current = responder, chain.count < 12 {
                chain.append(String(describing: type(of: current)))
                if owner == nil, let controller = current as? NSTitlebarAccessoryViewController { owner = controller }
                responder = current.nextResponder
            }
            let target = owner ?? window.titlebarAccessoryViewControllers.first { String(describing: type(of: $0)).contains("Tab") }
            if let hidden = body["hidden"] as? Bool { target?.isHidden = hidden }
            if let height = body["minHeight"] as? Double { target?.fullScreenMinHeight = height }
            if let peek = body["peek"] as? Bool {
                // The pointer arriving at, or leaving, the top of the window.
                var anchor: WindowChrome.ChromeAnchor?
                func search(_ view: NSView) { if let found = view as? WindowChrome.ChromeAnchor { anchor = found }; view.subviews.forEach(search) }
                if let root = window.contentView { search(root) }
                if let anchor, let event = NSEvent.enterExitEvent(with: peek ? .mouseEntered : .mouseExited, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil) {
                    if peek { anchor.mouseEntered(with: event) } else { anchor.mouseExited(with: event) }
                }
            }
            if let always = body["always"] as? Bool {
                UserDefaults.standard.set(always, forKey: WindowChrome.ChromeAnchor.alwaysShowKey)
                NotificationCenter.default.post(name: .harborTabBarPolicyChanged, object: nil)
            }
            try? await Task.sleep(for: .seconds(body["wait"] as? Double ?? 0.6))
            return ["accessories": window.titlebarAccessoryViewControllers.map(describe), "chain": chain, "owner": owner.map(describe) ?? "",
                    "layout": NSStringFromRect(window.contentLayoutRect), "frame": NSStringFromRect(window.frame), "tabBarVisible": window.tabGroup?.isTabBarVisible ?? false,
                    "top": ["tabBar": windowTop.tabBar, "peek": windowTop.peek, "contentTop": windowTop.contentTop, "leading": windowTop.barLeading],
                    "full": window.styleMask.contains(.fullScreen)]
        case "film":
            // Frames of this window as the window server draws it, taken at a fixed interval while an optional
            // step runs, laid out on one sheet: how a transition looks between its two ends.
            typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
            for _ in 0..<150 where self.window == nil { try? await Task.sleep(for: .milliseconds(20)) }
            guard let window, let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return ["error": "no window"] }
            let capture = unsafeBitCast(symbol, to: Capture.self)
            let count = body["frames"] as? Int ?? 12, interval = body["interval"] as? Double ?? 0.08
            if let step = body["then"] as? [String: Any] { Task { _ = await self.answerQAProbe(step, id: id + "-then", directory: directory) } }
            var frames: [(Double, CGImage)] = []
            let began = Date(), wasActive = NSApp.isActive
            // "around": "ready" keeps a few frames from before the editor is ready and `frames` after it.
            let around = body["around"] as? String == "ready", before = body["before"] as? Int ?? 3
            var after = around ? -1 : 0
            while after < count, Date().timeIntervalSince(began) < 40 {
                if let image = capture(.null, 1 << 3, UInt32(window.windowNumber), 1)?.takeRetainedValue() { frames.append((Date().timeIntervalSince(began), image)) }
                if after >= 0 { after += 1 }
                else if codeWorkbench.existing(for: currentFiles)?.ready == true, Date().timeIntervalSince(began) > 0.5 { after = 0 }
                else if frames.count > before { frames.removeFirst(frames.count - before) }
                try? await Task.sleep(for: .seconds(interval))
            }
            guard let first = frames.first?.1 else { return ["error": "no frames"] }
            let unit = body["crop"] as? [Double] ?? [0, 0, 1, 1]
            let crop = CGRect(x: Double(first.width) * unit[0], y: Double(first.height) * unit[1], width: Double(first.width) * unit[2], height: Double(first.height) * unit[3]).integral
            let scale = body["scale"] as? Double ?? 0.5, columns = body["columns"] as? Int ?? 3
            let cell = CGSize(width: (crop.width * scale).rounded(), height: (crop.height * scale).rounded())
            let rows = (frames.count + columns - 1) / columns
            guard let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(cell.width) * columns, pixelsHigh: Int(cell.height) * rows, bitsPerSample: 8, samplesPerPixel: 4,
                                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: sheet) else { return ["error": "no sheet"] }
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            for (index, frame) in frames.enumerated() {
                guard let part = frame.1.cropping(to: crop) else { continue }
                let origin = CGPoint(x: Double(index % columns) * cell.width, y: Double(rows - 1 - index / columns) * cell.height)
                context.cgContext.draw(part, in: CGRect(origin: origin, size: cell))
                (String(format: "%.2fs", frame.0) as NSString).draw(at: CGPoint(x: origin.x + 6, y: origin.y + 4),
                    withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.systemRed])
            }
            NSGraphicsContext.restoreGraphicsState()
            let name = id + "-film.png"
            try? sheet.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name))
            return ["file": name, "seconds": frames.last?.0 ?? 0, "active": NSApp.isActive, "key": window.isKeyWindow, "wasActive": wasActive]
        case "render":
            // Canvas content is not captured by cacheDisplay; render it directly.
            let dark = body["dark"] as? Bool ?? false, selection = body["selection"] as? String ?? HarborTheme.selection
            let palette = HarborTheme.palette(dark: dark, selection: selection)
            var files: [String] = []
            if body["dolls"] as? Bool == true {
                let background = Color(nsColor: HarborTheme.hex(palette.colors["editor.background"] ?? "#FFFFFF"))
                for (index, pose) in [(0.0, 0.0, 0.0), (0.0, 0.8, 0.8), (1.0, 0.0, -0.8)].enumerated() {
                    let sheet = AgentHarborAnimation.dollSheet(dark: dark, scale: body["scale"] as? Double ?? 6, blink: pose.0, wave: pose.1, look: pose.2, time: Double(index) * 0.7).background(background)
                    let renderer = ImageRenderer(content: sheet); renderer.scale = 2
                    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { continue }
                    let name = id + "-dolls-\(index).png"
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name)); files.append(name)
                }
                return ["files": files]
            }
            for time in body["times"] as? [Double] ?? [AgentHarborAnimation.settled] {
                // "drag": [doll, across, up] carries one of the dolls.
                var interaction = AgentHarborAnimation.Interaction()
                if let drag = body["drag"] as? [Double], drag.count == 3 { interaction.dragging = Int(drag[0]); interaction.hovered = Int(drag[0]); interaction.dragOffset = CGSize(width: drag[1], height: -drag[2]) }
                let view = Canvas { context, size in AgentHarborAnimation.draw(&context, size: size, time: time, palette: palette, interaction: interaction, repeats: false) }
                    .frame(width: body["width"] as? Double ?? 892, height: body["height"] as? Double ?? 188)
                    .background(Color(nsColor: HarborTheme.hex(palette.colors["editor.background"] ?? "#FFFFFF")))
                let renderer = ImageRenderer(content: view); renderer.scale = 2
                guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { continue }
                let name = id + "-t" + String(format: "%.1f", time) + ".png"
                try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name)); files.append(name)
            }
            return ["files": files]
        case "slim":
            // Builds (or finds) the trimmed editor package for a platform, as a server would be sent it.
            do {
                let script = try String(contentsOf: AppResources.directory("CodeWorkbench").appendingPathComponent("bootstrap.py"), encoding: .utf8)
                let manifest = try CodeRuntimePackage.manifest(script: script), started = Date()
                let slim = try await CodeRuntimePackage.slim(target: body["target"] as? String ?? "linux-amd64", manifest: manifest, xz: body["xz"] as? Bool ?? true) { _, _, _ in }
                return ["path": slim.url.path, "digest": slim.digest, "megabytes": Double(slim.size) / 1_048_576, "seconds": Date().timeIntervalSince(started), "pruned": manifest.pruned]
            } catch { return ["error": error.localizedDescription] }
        case "quit":
            Task { try? await Task.sleep(nanoseconds: 200_000_000); shutdown(); exit(0) }
            return ["ok": true]
        default: return ["error": "unknown action"]
        }
    }
    static func residentMemory() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
        return result == KERN_SUCCESS ? Int(info.resident_size) : 0
    }
}
/// A drag as a view is told about it, for the probe.
final class QADrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint
    let draggingDestinationWindow: NSWindow?
    init(pasteboard: NSPasteboard, location: NSPoint, window: NSWindow?) { draggingPasteboard = pasteboard; draggingLocation = location; draggingDestinationWindow = window }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
#endif
