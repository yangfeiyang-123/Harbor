import XCTest
import AppKit
import WebKit
import SwiftUI
import Combine
import HarborCore
@testable import HarborSSH

final class CodeWorkbenchIntegrationTests: XCTestCase {
    @MainActor private var rendererFixtureViews = Set<ObjectIdentifier>()
    // Bare XCTest has no application run loop and WebKit can report hidden even
    // for an ordered-front test window. Keep the production observer unchanged;
    // only schedule its real RAF callbacks while that test document is hidden.
    private static let hiddenRendererScheduler = """
        (() => {
          if (window.__harborQARAFAdapter) return;
          const request = window.requestAnimationFrame.bind(window);
          const cancel = window.cancelAnimationFrame.bind(window);
          const timers = new Map(); let next = -1;
          const state = window.__harborQARAFAdapter = {scheduled:0};
          window.requestAnimationFrame = callback => {
            if (!document.hidden) return request(callback);
            const id = next--; state.scheduled++;
            timers.set(id, setTimeout(() => { timers.delete(id); callback(performance.now()); }, 16));
            return id;
          };
          window.cancelAnimationFrame = id => {
            if (timers.has(id)) { clearTimeout(timers.get(id)); timers.delete(id); }
            else cancel(id);
          };
        })();
        """

    /// XCTest does not run SwiftUI's window lifecycle. Attach and activate the
    /// real WK view, then inspect page readiness while waiting for the remote
    /// extension. An otherwise idle/occluded bare test window can have its page
    /// work deferred until the first JavaScript inspection, after our timeout.
    /// This observes normal browser state; it never activates Harbor commands.
    @MainActor private func inspectPage(_ session: CodeWorkbenchSession, in window: NSWindow) async -> String {
        guard let web = session.web else { return "not-mounted" }
        if window.contentView !== web {
            window.contentViewController = nil
            window.contentView = web
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(web)
            NSApp.activate(ignoringOtherApps: true)
        }
        let identity = ObjectIdentifier(web)
        if !rendererFixtureViews.contains(identity) {
            XCTAssertTrue(web.configuration.userContentController.userScripts.contains(where: { $0.source == Self.hiddenRendererScheduler }),
                "The XCTest scheduler must precede the first navigation; reloading creates a second extension-host connection")
            rendererFixtureViews.insert(identity)
            print("CODE_QA: XCTest hidden-document RAF adapter installed before first navigation; no test reload")
        }
        do {
            let state = try await web.evaluateJavaScript("JSON.stringify({ready:document.readyState,visibility:document.visibilityState,focused:document.hasFocus()})")
            return state as? String ?? "no-page-state"
        } catch { return "Page readiness: " + error.localizedDescription }
    }

    /// Keep a renderer-progress probe independent of Harbor's layout message.
    /// It is bounded and observational: it never fabricates a terminal frame or
    /// calls receiveLayout, so a broken product observer still fails this test.
    @MainActor private func probeRenderer(_ web: WKWebView) async throws {
        _ = try await web.evaluateJavaScript("""
            (() => {
              window.__harborQARenderFrames = 0;
              const tick = () => { if (++window.__harborQARenderFrames < 4) requestAnimationFrame(tick); };
              requestAnimationFrame(tick);
              if (!window.__harborQAErrors) {
                window.__harborQAErrors = [];
                addEventListener('error', event => window.__harborQAErrors.push(String(event.message)));
              }
            })()
            """)
    }

    @MainActor private func mountingDiagnostic(_ session: CodeWorkbenchSession, hosting: NSView, window: NSWindow) async -> String {
        func hierarchy(_ view: NSView?) -> String {
            guard let view else { return "nil" }
            var names: [String] = [], current: NSView? = view
            while let node = current, names.count < 10 {
                names.append("\(type(of: node))(frame=\(node.frame),window=\(node.window?.windowNumber ?? -1),hidden=\(node.isHidden))")
                current = node.superview
            }
            return names.joined(separator: " > ")
        }
        let native = "window=\(window.windowNumber) visible=\(window.isVisible) occlusion=\(window.occlusionState.rawValue) key=\(window.isKeyWindow) appActive=\(NSApp.isActive) appRunning=\(NSApp.isRunning) foreground=\(session.foreground) frame=\(session.terminalFrame) overlayOccluded=\(session.terminalOccluded) responder=\(String(describing: window.firstResponder)) workspaceEnabled=\(session.workspace.enabled) panelVisible=\(session.workspace.terminalVisible) hosting=\(hierarchy(hosting)) web=\(hierarchy(session.web)) nativeTerminals=\(nativeTerminalCount(hosting))"
        guard let web = session.web else { return native }
        let page = try? await web.evaluateJavaScript("""
            JSON.stringify((() => {
              const rect = element => {
                if (!element) return null;
                const box = element.getBoundingClientRect();
                return {visible:element.checkVisibility(),x:box.x,y:box.y,width:box.width,height:box.height};
              };
              const container = document.getElementById('workbench.view.extension.harborTerminals');
              return {ready:document.readyState,visibility:document.visibilityState,focus:document.hasFocus(),
                viewport:[innerWidth,innerHeight],frames:window.__harborQARenderFrames ?? -1,hiddenRAFs:window.__harborQARAFAdapter?.scheduled ?? 0,
                handler:!!window.webkit?.messageHandlers?.harborLayout,embedded:window.__harborEmbeddedWorkbench,
                terminalMode:window.__harborTerminalMode,errors:window.__harborQAErrors || [],
                panel:rect(document.querySelector('.part.panel')),xterm:rect(document.querySelector('.part.panel .xterm-screen')),container:rect(container),body:rect(container?.querySelector('.pane-body')),
                editor:rect(document.querySelector('.part.editor')),sidebar:rect(document.querySelector('.part.sidebar'))};
            })())
            """)
        return native + " scripts=\(web.configuration.userContentController.userScripts.count) page=" + String(describing: page)
    }

    @MainActor func testRealWorkbenchCommandsAndPersistentWorkspace() async throws {
        guard ProcessInfo.processInfo.environment["HARBOR_CODE_INTEGRATION"] == "1" else { throw XCTSkip("Opt-in: downloads and starts the pinned Code-OSS runtime") }
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/private/tmp/harbor-codeoss-integration")
        let remoteHost = ProcessInfo.processInfo.environment["HARBOR_CODE_REMOTE"]
        let project = remoteHost == nil ? root.appendingPathComponent("Project-" + UUID().uuidString) : URL(fileURLWithPath: "/tmp/harbor-codeoss-integration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if remoteHost == nil { try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true) }
        let file = project.appendingPathComponent("main.py")
        let content = "target_velocity = 3\nprint(target_velocity)\n"
        if let remoteHost {
            let result = await ProcessRunner.run("/usr/bin/ssh", ["-o", "BatchMode=yes", remoteHost, "mkdir -p " + SSHArguments.quote(project.path) + " && printf %s " + SSHArguments.quote(content) + " > " + SSHArguments.quote(file.path)])
            XCTAssertTrue(result.succeeded)
        } else { try content.write(to: file, atomically: true, encoding: .utf8) }
        let suite = "app.harbor.code-test." + UUID().uuidString, prefs = TestDefaults.suite(suite)!
        prefs.set("codeoss", forKey: "fileEditorEngine")
        let originalArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain(originalArguments.merging(["fileEditorEngine": "codeoss"]) { _, new in new }, forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain) }
        let store = AppStore(historyRoot: root.appendingPathComponent("state"), workspaceDefaults: prefs)
        try store.history.prepare(); store.loading = false; store.selectWorkspace(nil)
        let profile = remoteHost.map { ServerProfile(name: "Editor Remote QA", host: $0, imported: true) }
        if let profile { store.profiles = [profile]; store.selectWorkspace(profile.id) }
        let workspace = store.files(for: profile); workspace.root = project.path; workspace.enabled = true
        let session = store.codeWorkbench.session(for: workspace)
        // Published delivers synchronously before CodeWorkbenchSession calls
        // view.load. Installing here avoids a QA-only second browser connection.
        let rendererScheduler = session.$web.sink { web in
            guard let web else { return }
            web.configuration.userContentController.addUserScript(WKUserScript(source: Self.hiddenRendererScheduler,
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        defer { rendererScheduler.cancel() }
        let window = NSWindow(contentRect: .init(x: 50, y: 50, width: 1160, height: 740), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; NSApp.setActivationPolicy(.regular); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { session.disconnect(); window.contentViewController = nil; window.contentView = nil; window.close(); store.shutdown(); prefs.removePersistentDomain(forName: suite) }
        CodeWorkbenchSession.launchesService = true
        session.start(store: store)
        let deadline = Date().addingTimeInterval(600)
        var pageState = "not-mounted"
        while !session.ready && session.error == nil && Date() < deadline {
            let observed = await inspectPage(session, in: window)
            if observed != pageState { pageState = observed; print("CODE_QA startup page: ", pageState) }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertNil(session.error, pageState)
        XCTAssertTrue(session.commandsReady, session.phase + " · " + pageState)
        guard session.commandsReady else {
            if let web = session.web { print("CODE_QA page: ", try await web.evaluateJavaScript("document.body.innerText") as? String ?? "empty") }
            _ = try? await session.invoke(["op": "stop"])
            return
        }
        if let web = session.web { window.makeFirstResponder(web) }
        print("CODE_QA: authenticated editor ready")
        let status = try await session.request("status") as? [String: Any]
        print("CODE_QA: status received")
        XCTAssertEqual(status?["folder"] as? String, project.path)
        let extensions = try XCTUnwrap(status?["extensions"] as? [String])
        XCTAssertTrue(extensions.contains("harbor.workbench")); XCTAssertTrue(extensions.contains("harbor.themes"))
        // Language extensions that run project code wait for Workspace Trust.
        // This isolated fixture deliberately starts in Restricted Mode.
        do { _ = try await session.request("openFile", extra: ["path": file.path]) }
        catch {
            print("CODE_QA open error", String(reflecting: type(of: error)), error.localizedDescription)
            if let status = try? await session.request("status") as? [String: Any] { print("CODE_QA stage:", status["lastCommand"] ?? "unknown") }
            if let web = session.web { print("CODE_QA page: ", try await web.evaluateJavaScript("document.body.innerText") as? String ?? "empty") }
            _ = try? await session.invoke(["op": "stop"])
            throw error
        }
        print("CODE_QA: file opened")
        if let web = session.web {
            // showTextDocument acknowledges its extension-host request before
            // the local renderer necessarily mounts Monaco. Find requires the
            // actual editor, so observe it rather than racing a fixed delay.
            try await waitForPage(web, "document.querySelector('.part.editor')?.innerText.includes('target_velocity') === true")
        }
        _ = try await session.request("actions.find")
        print("CODE_QA: open file and Find completed")
        let fixture: TerminalFixture
        // Keep the first-phase reference scoped so only the deliberate retained
        // browser below exercises the reconnect lifecycle.
        do {
            let web = try XCTUnwrap(session.web)
            try await waitForPage(web, "[...document.querySelectorAll('.find-widget')].some(element => element.checkVisibility())")
            let find = try await web.evaluateJavaScript("({count:document.querySelectorAll('.find-widget').length,width:document.querySelector('.find-widget')?.getBoundingClientRect().width})") as? [String: Any]
            XCTAssertGreaterThan(find?["count"] as? Int ?? 0, 0)
            XCTAssertGreaterThanOrEqual(find?["width"] as? Double ?? 0, 460)
            print("CODE_QA: Find layout verified")
            _ = try await session.request("workbench.action.files.save")
            _ = try await session.request("workbench.view.extensions")
            try await Task.sleep(nanoseconds: 300_000_000)
            let text = try await web.evaluateJavaScript("document.body.innerText") as? String ?? ""
            XCTAssertTrue(text.lowercased().contains("extensions"))
            print("CODE_QA: extensions view verified")
            fixture = try await verifyMinimalShell(store: store, workspace: workspace, session: session,
                window: window, preferences: prefs, project: project, remoteHost: remoteHost)
        }
        if let remoteHost {
            let result = await ProcessRunner.run("/usr/bin/ssh", ["-o", "BatchMode=yes", remoteHost, "cat " + SSHArguments.quote(file.path)])
            XCTAssertTrue(result.succeeded); XCTAssertEqual(result.output, content)
        } else { XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), content) }
        // A second client startup must attach to the same server, not spawn more.
        let runtime = try await session.invoke(["op": "start", "folder": project.path])
        XCTAssertEqual(runtime["reused"] as? Bool, true)
        print("CODE_QA: persistent runtime reused")
        let originalURL = session.web?.url
        try await session.web?.evaluateJavaScript("localStorage.setItem('harbor.persistence.qa', 'retained')")
        // SwiftUI or an outstanding callback can retain a detached browser.
        // Reconnect must unload its document instead of relying on deallocation
        // to close the old extension-host websocket.
        let disconnectedWeb = try XCTUnwrap(session.web)
        session.disconnect()
        CodeWorkbenchSession.launchesService = true
        session.start(store: store)
        let reconnectDeadline = Date().addingTimeInterval(90)
        pageState = "not-mounted"
        while !session.ready && session.error == nil && Date() < reconnectDeadline {
            let observed = await inspectPage(session, in: window)
            if observed != pageState { pageState = observed; print("CODE_QA reconnect page: ", pageState) }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertNil(session.error, pageState); XCTAssertTrue(session.commandsReady, pageState)
        try await waitForPage(disconnectedWeb, "document.readyState === 'complete' && document.body.innerText === '' && !document.querySelector('.monaco-workbench')")
        XCTAssertFalse(session.web === disconnectedWeb)
        XCTAssertNil(disconnectedWeb.superview)
        print("CODE_QA: retained old browser unloaded while new editor reconnected")
        if let reopened = session.web {
            XCTAssertEqual(reopened.url, originalURL)
            let persisted = try await reopened.evaluateJavaScript("localStorage.getItem('harbor.persistence.qa')") as? String
            XCTAssertEqual(persisted, "retained")
            try await trustFixtureWorkspace(session, web: reopened)
            _ = try await session.request("openFile", extra: ["path": file.path])
            try await waitForPage(reopened, "document.querySelector('.part.editor')?.innerText.includes('target_velocity') === true")
            print("CODE_QA: reconnected with same origin and persistent workspace")
        }
        let restored = try await waitForTerminal(session) { $0.processID == fixture.primary.processID }
        XCTAssertEqual(restored.processID, fixture.primary.processID, "Reconnect must attach to the existing shell")
        let restoredSplit = try await waitForTerminal(session) { $0.processID == fixture.split.processID }
        XCTAssertEqual(restoredSplit.processID, fixture.split.processID)
        _ = try await session.request("focusTerminal", extra: ["id": restored.id])
        if let reopened = session.web { try await waitForPage(reopened, "[...document.querySelectorAll('.part.panel .xterm-screen')].some(element => element.checkVisibility())") }
        let reconnectFile = project.appendingPathComponent("reconnected-shell.txt")
        _ = try await session.request("terminalInput", extra: ["id": restored.id,
            "text": "printf '%s\\n' \"$$\" \"$PWD\" \"$HARBOR_QA_SENTINEL\" > " + SSHArguments.quote(reconnectFile.path) + "\r"])
        let resumedLines = try await waitForFixtureLines(reconnectFile, remoteHost: remoteHost, count: 3)
        XCTAssertEqual(resumedLines, [String(fixture.primary.processID), fixture.directory, fixture.sentinel],
            "The reconnected shell must retain both its live cwd and exported session state")
        print("CODE_QA: builtin shells reattached with the same PIDs, cwd and sentinel")
        _ = try await session.request("closeTerminal", extra: ["id": restoredSplit.id])
        _ = try await session.request("closeTerminal", extra: ["id": restored.id])
        _ = try await session.invoke(["op": "stop"])
    }

    @MainActor private func panelDiagnostic(_ session: CodeWorkbenchSession) -> [String: String] {
        let fields: Set<String> = ["appliedTerminalMode", "changingPanel", "panelTask", "panelInitialized", "reportedPanelVisible", "reportedPanelMaximized"]
        var result = Dictionary(uniqueKeysWithValues: Mirror(reflecting: session).children.compactMap { child -> (String, String)? in
            guard let name = child.label, fields.contains(name) else { return nil }
            return (name, String(describing: child.value))
        })
        result["enabled"] = String(session.workspace.enabled)
        result["error"] = session.error ?? "none"
        return result
    }

    @MainActor private func waitForPage(_ web: WKWebView, _ condition: String, timeout: TimeInterval = 8) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await web.evaluateJavaScript(condition) as? Bool == true { return }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        let diagnostic = try? await web.evaluateJavaScript("""
            JSON.stringify((() => { const rect = e => { const r=e.getBoundingClientRect(); const css=getComputedStyle(e); return {class:e.className,visible:e.checkVisibility(),display:css.display,visibility:css.visibility,rect:[r.x,r.y,r.width,r.height],parent:e.parentElement?.className}; };
              return {hidden:document.hidden,focused:document.hasFocus(),active:document.activeElement?.outerHTML?.slice(0,500),mode:window.__harborTerminalMode,
                terminals:[...document.querySelectorAll('.terminal-wrapper,.terminal-outer-container,.xterm,.xterm-screen,.xterm-helper-textarea')].map(rect),
                panel:[...document.querySelectorAll('.part.panel')].map(rect)}; })())
            """)
        print("CODE_QA wait timeout:", condition, diagnostic ?? "no DOM")
        XCTFail("Workbench condition timed out: " + condition)
    }

    /// Warm layout changes stay in the browser, without an SSH round trip.
    @MainActor private func localLayout(_ web: WKWebView, action: String, options: [String: Any] = [:]) async throws {
        let result = try await web.callAsyncJavaScript("""
            const start = performance.now();
            const result = await window.__harborWorkbenchCommand(action, options);
            // Bare XCTest windows can remain WebKit-occluded. Their animation
            // callbacks are suspended; measure the actual command completion
            // here and inspect computed layout in waitForPage below instead.
            return {ok:result.ok, error:result.error || '', elapsed:performance.now()-start};
            """, arguments: ["action": action, "options": options], in: nil, contentWorld: .page) as? [String: Any]
        XCTAssertEqual(result?["ok"] as? Bool, true, result?["error"] as? String ?? action)
        XCTAssertLessThan(result?["elapsed"] as? Double ?? .infinity, 1000, action + " should not wait for the remote extension host")
    }

    private struct BuiltinTerminal {
        let id: String
        let processID: Int
        let name: String
        let cwd: String?
        init?(_ value: [String: Any]) {
            guard let id = value["id"] as? String, let pid = value["processId"] as? Int, pid > 0 else { return nil }
            self.id = id; processID = pid; name = value["name"] as? String ?? ""; cwd = value["cwd"] as? String
        }
    }
    private struct TerminalFixture {
        let primary: BuiltinTerminal
        let split: BuiltinTerminal
        let directory: String
        let sentinel: String
    }
    @MainActor private func terminals(_ session: CodeWorkbenchSession) async throws -> [BuiltinTerminal] {
        let status = try await session.request("status") as? [String: Any]
        return (status?["terminals"] as? [[String: Any]] ?? []).compactMap(BuiltinTerminal.init)
    }
    @MainActor private func waitForTerminal(_ session: CodeWorkbenchSession, timeout: TimeInterval = 30,
                                            matching: (BuiltinTerminal) -> Bool) async throws -> BuiltinTerminal {
        let deadline = Date().addingTimeInterval(timeout)
        var last: [BuiltinTerminal] = []
        while Date() < deadline {
            last = try await terminals(session)
            if let found = last.first(where: matching) { return found }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTFail("Expected builtin shell did not become available: \(last.map { "\($0.id):\($0.processID):\($0.name):\($0.cwd ?? "unknown")" })")
        throw CocoaError(.fileReadUnknown)
    }
    @MainActor private func waitForFixtureLines(_ file: URL, remoteHost: String?, count: Int) async throws -> [String] {
        let deadline = Date().addingTimeInterval(25)
        var output = ""
        while Date() < deadline {
            if let remoteHost {
                let result = await ProcessRunner.run("/usr/bin/ssh", ["-o", "BatchMode=yes", remoteHost, "cat " + SSHArguments.quote(file.path)])
                if result.succeeded { output = result.output }
            } else { output = (try? String(contentsOf: file, encoding: .utf8)) ?? "" }
            let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
            if output.hasSuffix("\n"), lines.count == count + 1 { return lines.dropLast().map(String.init) }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTFail("The fixture shell did not write \(file.lastPathComponent): \(output)")
        throw CocoaError(.fileReadUnknown)
    }
    @MainActor private func nativeTerminalCount(_ view: NSView) -> Int {
        (view is CapturingTerminal ? 1 : 0) + view.subviews.reduce(0) { $0 + nativeTerminalCount($1) }
    }
    @MainActor private func acceptFixtureTrustDialog(_ web: WKWebView) async throws -> Bool {
        // Code-OSS may ask for trust when restoring/opening its first terminal.
        // Complete the real current-folder confirmation; never trust a parent
        // or turn off Workspace Trust. Unknown dialogs remain visible and fail.
        let result = try await web.evaluateJavaScript("""
            (() => {
              const dialog = [...document.querySelectorAll('.monaco-dialog-box')].find(element => element.checkVisibility());
              const button = [...(dialog?.querySelectorAll('.monaco-button') || [])].find(element => element.checkVisibility() && element.textContent.trim() === 'Trust Folder & Continue');
              if (!button) return false;
              button.click(); return true;
            })()
            """) as? Bool == true
        if result { print("CODE_QA: accepted the disposable current-folder Trust & Continue dialog") }
        return result
    }
    @MainActor private func trustFixtureWorkspace(_ session: CodeWorkbenchSession, web: WKWebView) async throws {
        let accepted = try await acceptFixtureTrustDialog(web)
        let status = try await session.request("status") as? [String: Any]
        if !accepted && status?["workspaceTrusted"] as? Bool != true {
            _ = try await session.request("workbench.trust.manage")
            // The editor container mounts before its asynchronous trust render.
            // Wait for its actual button, not just the outer editor element.
            try await waitForPage(web, "!!document.querySelector('.workspace-trust-editor.untrusted .workspace-trust-limitations.trusted .monaco-button')?.checkVisibility()", timeout: 15)
            let clicked = try await web.evaluateJavaScript("""
                (() => {
                  const button = document.querySelector('.workspace-trust-editor.untrusted .workspace-trust-limitations.trusted .monaco-button');
                  if (!button?.checkVisibility()) return false;
                  button.click(); return true;
                })()
                """) as? Bool
            XCTAssertEqual(clicked, true)
        }
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            _ = try await acceptFixtureTrustDialog(web)
            let current = try await session.request("status") as? [String: Any]
            if current?["workspaceTrusted"] as? Bool == true {
                try await waitForPage(web, "![...document.querySelectorAll('.monaco-dialog-box')].some(element => element.checkVisibility())")
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTFail("The disposable fixture folder did not become trusted")
        throw CocoaError(.userCancelled)
    }

    @MainActor private func verifyMinimalShell(store: AppStore, workspace: FileWorkspace, session: CodeWorkbenchSession,
        window: NSWindow, preferences: UserDefaults, project: URL, remoteHost: String?) async throws -> TerminalFixture {
        let web = try XCTUnwrap(session.web)
        try await waitForPage(web, "typeof window.__harborWorkbenchCommand === 'function'")
        web.removeFromSuperview(); window.contentView = nil
        let controller = NSHostingController(rootView: ContentView().environmentObject(store).defaultAppStorage(preferences))
        window.contentViewController = controller
        let hosting = controller.view
        window.makeKeyAndOrderFront(nil); window.makeMain(); window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        hosting.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        try await probeRenderer(web)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(web.window === window)
        XCTAssertTrue(web.isDescendant(of: hosting))
        XCTAssertEqual(nativeTerminalCount(hosting), 0, "Code-OSS must own the terminal; no native PTY view may cover its UI")
        try await trustFixtureWorkspace(session, web: web)

        // Only the new opaque ID returned here is permitted to receive QA input.
        let created = try await session.request("newTerminal", extra: ["name": "Harbor QA " + UUID().uuidString, "cwd": project.path]) as? [String: Any]
        let createdID = try XCTUnwrap(created?["id"] as? String)
        let terminal = try await waitForTerminal(session) { $0.id == createdID }
        _ = try await session.request("focusTerminal", extra: ["id": terminal.id])
        try await trustFixtureWorkspace(session, web: web)
        try await waitForPage(web, "[...document.querySelectorAll('.part.panel .xterm-screen')].some(element => element.checkVisibility())")
        let sentinel = UUID().uuidString
        let child = project.appendingPathComponent("shell cwd '中文'", isDirectory: true)
        let originalFile = project.appendingPathComponent("original-shell.txt")
        let input = "mkdir -p " + SSHArguments.quote(child.path) + " && cd " + SSHArguments.quote(child.path)
            + " && export HARBOR_QA_SENTINEL=" + SSHArguments.quote(sentinel)
            + " && printf '%s\\n' \"$$\" \"$PWD\" \"$HARBOR_QA_SENTINEL\" > " + SSHArguments.quote(originalFile.path) + "\r"
        _ = try await session.request("terminalInput", extra: ["id": terminal.id, "text": input])
        let originalLines = try await waitForFixtureLines(originalFile, remoteHost: remoteHost, count: 3)
        XCTAssertEqual(originalLines, [String(terminal.processID), child.path, sentinel])
        // Wait for shell integration's live cwd, not the creation directory.
        _ = try await waitForTerminal(session) { $0.id == terminal.id && $0.cwd == child.path }
        let originalIDs = Set((try await terminals(session)).map(\.id))
        _ = try await session.request("focusTerminal", extra: ["id": terminal.id])
        _ = try await session.request("splitTerminal")
        let split = try await waitForTerminal(session) { !originalIDs.contains($0.id) }
        XCTAssertNotEqual(split.processID, terminal.processID)
        let splitFile = project.appendingPathComponent("split-shell.txt")
        _ = try await session.request("terminalInput", extra: ["id": split.id,
            "text": "printf '%s\\n' \"$$\" \"$PWD\" > " + SSHArguments.quote(splitFile.path) + "\r"])
        let splitLines = try await waitForFixtureLines(splitFile, remoteHost: remoteHost, count: 2)
        XCTAssertEqual(splitLines, [String(split.processID), child.path], "Split must inherit the shell's live directory after cd")
        print("CODE_QA: builtin xterm input, independent shell PIDs and live split cwd verified")

        let before = try await session.request("status") as? [String: Any]
        try await localLayout(web, action: "setTerminalPanel", options: ["visible": true, "maximized": true])
        try await waitForPage(web, "(document.querySelector('.part.editor')?.getBoundingClientRect().height || 0) < 5")
        try await localLayout(web, action: "setTerminalPanel", options: ["visible": true, "maximized": false])
        try await waitForPage(web, "(document.querySelector('.part.editor')?.getBoundingClientRect().height || 0) > 100")
        try await localLayout(web, action: "enterTerminalMode")
        try await waitForPage(web, "window.__harborTerminalMode === true && !document.querySelector('.part.sidebar')?.checkVisibility()")
        try await localLayout(web, action: "leaveTerminalMode")
        let after = try await session.request("status") as? [String: Any]
        XCTAssertEqual(after?["lastCommand"] as? String, before?["lastCommand"] as? String, "Local layout must not invoke the HTTP bridge")
        XCTAssertTrue(session.web === web)
        _ = try await session.request("workbench.view.explorer")
        try await waitForPage(web, "!!document.getElementById('workbench.view.explorer')?.checkVisibility()")
        let chrome = try await web.evaluateJavaScript("""
            (() => {
              const rect = selector => { const e = document.querySelector(selector); return e?.checkVisibility() ? e.getBoundingClientRect() : null; };
              const sidebar = document.querySelector('.part.sidebar'), title = sidebar?.querySelector(':scope > .title');
              const row = sidebar?.querySelector('.composite-bar');
              const overflow = [...(row?.querySelectorAll('.action-item') || [])].find(e => e.querySelector('.codicon-more,.codicon-chevron-down'));
              const panel = rect('.part.panel'), side = rect('.part.sidebar');
              return {titleFound:!!title,titleHeight:title?.getBoundingClientRect().height ?? -1,
                activityHeight:row?.getBoundingClientRect().height ?? 0,overflowVisible:!!overflow?.checkVisibility(),
                overflowChevron:!!overflow?.querySelector('.codicon-chevron-down'),webTitleHeight:rect('.part.titlebar')?.height || 0,
                statusHeight:rect('.part.statusbar')?.height || 0,panelLeft:panel?.left ?? -1,sidebarRight:side?.right ?? -1,
                sidebarBottom:side?.bottom ?? -1,panelTop:panel?.top ?? -1,
                customPanel:!!document.getElementById('workbench.view.extension.harborTerminals'),
                tabs:[...document.querySelectorAll('.part.panel .composite-bar .action-item')].filter(e => e.checkVisibility()).map(e => e.innerText.trim())};
            })()
            """) as? [String: Any]
        XCTAssertEqual(chrome?["titleFound"] as? Bool, true)
        XCTAssertEqual(chrome?["titleHeight"] as? Double, 0)
        XCTAssertEqual(chrome?["webTitleHeight"] as? Double, 0)
        XCTAssertGreaterThan(chrome?["activityHeight"] as? Double ?? 0, 0)
        XCTAssertGreaterThan(chrome?["statusHeight"] as? Double ?? 0, 0, "Use the real Code-OSS status bar")
        if chrome?["overflowVisible"] as? Bool == true { XCTAssertEqual(chrome?["overflowChevron"] as? Bool, true) }
        XCTAssertEqual(chrome?["customPanel"] as? Bool, false, "There must be no second custom Harbor Terminal")
        let tabs = chrome?["tabs"] as? [String] ?? []
        XCTAssertEqual(tabs.filter { $0.caseInsensitiveCompare("Terminal") == .orderedSame }.count, 1, tabs.description)
        XCTAssertFalse(tabs.contains { $0.caseInsensitiveCompare("Tasks") == .orderedSame }, "Task terminals share the builtin Terminal panel")
        XCTAssertGreaterThanOrEqual(chrome?["panelLeft"] as? Double ?? -1, (chrome?["sidebarRight"] as? Double ?? 0) - 1)
        XCTAssertGreaterThan(chrome?["sidebarBottom"] as? Double ?? 0, chrome?["panelTop"] as? Double ?? 0)

        _ = try await session.request("workbench.action.openSettings")
        try await waitForPage(web, "!!document.querySelector('.settings-editor')?.checkVisibility()")
        let point = try await web.evaluateJavaScript("""
            (() => { const r = document.querySelector('.settings-editor').getBoundingClientRect(); return {x:r.left+r.width/2,y:r.top+r.height/2}; })()
            """) as? [String: Double]
        let pointInWeb = NSPoint(x: try XCTUnwrap(point?["x"]), y: try XCTUnwrap(point?["y"]))
        let pointInWindowContent = web.convert(pointInWeb, to: hosting)
        let hit = hosting.hitTest(pointInWindowContent)
        XCTAssertTrue(hit === web || hit?.isDescendant(of: web) == true, "Settings must receive actual native mouse hits, with no native overlay")
        XCTAssertEqual(nativeTerminalCount(hosting), 0)
        _ = try await session.request("focusTerminal", extra: ["id": terminal.id])
        try await waitForPage(web, "!!document.activeElement?.closest('.xterm,.terminal-wrapper,.terminal-outer-container')")
        window.makeFirstResponder(web)
        func key(_ code: UInt16, _ character: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code))
        }
        NSApp.sendEvent(try key(11, "b", .command))
        try await waitForPage(web, "!document.querySelector('.part.sidebar')?.checkVisibility() && !!document.activeElement?.closest('.xterm,.terminal-wrapper,.terminal-outer-container')")
        NSApp.sendEvent(try key(11, "b", .command))
        try await waitForPage(web, "!!document.querySelector('.part.sidebar')?.checkVisibility() && !!document.activeElement?.closest('.xterm,.terminal-wrapper,.terminal-outer-container')")
        print("CODE_QA panel before OptionZ:", panelDiagnostic(session))
        NSApp.sendEvent(try key(6, "z", .option))
        try await waitForPage(web, "window.__harborTerminalMode === true && (document.querySelector('.part.editor')?.getBoundingClientRect().height || 0) < 5")
        XCTAssertFalse(workspace.enabled)
        XCTAssertTrue(session.web === web)
        XCTAssertTrue(session.foreground)
        let maximized = try await web.evaluateJavaScript("""
            (() => { const h = selector => { const e = document.querySelector(selector); return e?.checkVisibility() ? e.getBoundingClientRect().height : 0; };
              return {panel:h('.part.panel'),available:innerHeight-h('.part.titlebar')-h('.part.banner')-h('.part.statusbar')}; })()
            """) as? [String: Any]
        XCTAssertEqual(try XCTUnwrap(maximized?["panel"] as? Double), try XCTUnwrap(maximized?["available"] as? Double), accuracy: 2)
        print("CODE_QA panel before OptionZ:", panelDiagnostic(session))
        NSApp.sendEvent(try key(6, "z", .option))
        try await waitForPage(web, "window.__harborTerminalMode === false && !!document.querySelector('.part.sidebar')?.checkVisibility()")
        print("CODE_QA panel after OptionZ:", panelDiagnostic(session))
        XCTAssertTrue(workspace.enabled)
        XCTAssertTrue(session.web === web)
        let remainingPIDs = Set((try await terminals(session)).map(\.processID))
        XCTAssertTrue(remainingPIDs.contains(terminal.processID)); XCTAssertTrue(remainingPIDs.contains(split.processID))
        print("CODE_QA builtin shell:", await mountingDiagnostic(session, hosting: hosting, window: window))
        return TerminalFixture(primary: terminal, split: split, directory: child.path, sentinel: sentinel)
    }
}
