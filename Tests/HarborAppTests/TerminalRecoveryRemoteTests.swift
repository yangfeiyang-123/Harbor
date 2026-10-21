import XCTest
import AppKit
import HarborCore
@testable import HarborSSH

final class TerminalRecoveryRemoteTests: XCTestCase {
    @MainActor func testRemotePTYSurvivesTransportLossAndHarborShutdownWithSameProcess() async throws {
        guard let host = ProcessInfo.processInfo.environment["HARBOR_QA_SSH_HOST"] else { throw XCTSkip("Authorized remote recovery check requires HARBOR_QA_SSH_HOST") }
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-remote-recovery-" + UUID().uuidString)
        let suite = "harbor.remote-recovery." + UUID().uuidString, prefs = TestDefaults.suite(suite)!
        let profile = ServerProfile(name:"Recovery QA",host:host,useTmux:false)
        let store = AppStore(historyRoot:root,workspaceDefaults:prefs)
        try store.history.prepare(); store.loading = false; store.profiles = [profile]; store.selectWorkspace(profile.id)
        _ = store.openTerminal(profile,workingDirectory:"/tmp",useWorkspaceDirectory:false)
        let original = try XCTUnwrap(store.activeSession), hostID = try XCTUnwrap(original.remotePTYID)
        var restored: AppStore?
        func wait(line: UInt = #line, _ test: () -> Bool) async throws {
            let end = Date().addingTimeInterval(35)
            while !test() && Date() < end { try await Task.sleep(nanoseconds:100_000_000) }
            XCTAssertTrue(test(), "wait at line \(line): " + store.sessions.map { $0.status + " " + $0.recoveryOutput().suffix(1800) }.joined(separator: " | ")); if !test() { throw NSError(domain:"PTYQA",code:Int(line)) }
        }
        func cleanup() async {
            restored?.shutdown(); store.shutdown()
            if let socket = original.socket {
                let result = await ProcessRunner.run("/usr/bin/ssh",SSHArguments.probe(profile,socket:socket,command:try! RemoteTerminalHost.command(id:hostID,mode:"close",directory:nil)),timeout:10)
                XCTAssertTrue(result.succeeded,"Could not remove isolated QA PTY " + hostID.uuidString)
            }
            prefs.removePersistentDomain(forName:suite); try? FileManager.default.removeItem(at:root)
        }
        do {
            try await wait { original.ready }
            let pidBefore = try XCTUnwrap(original.remoteShellPID)
            XCTAssertNil(original.tmuxName)
            original.terminal.send(txt:"export HARBOR_RECOVERY_QA_VALUE=retained_\(original.id.uuidString); printf 'BEFORE_%s\\n' $HARBOR_RECOVERY_QA_VALUE\n")
            try await wait { original.recoveryOutput().contains("BEFORE_retained_" + original.id.uuidString) }
            // Kill only the transport: the shell must keep its PID, cwd and exports.
            original.terminal.send(txt:"cd /; printf 'DIRECTORY_%s\\n' \"$PWD\"; printf 'NO_TMUX_%s\\n' \"${TMUX-unset}\"\n")
            try await wait { original.recoveryOutput().contains("DIRECTORY_/") && original.recoveryOutput().contains("NO_TMUX_unset") }
            XCTAssertEqual(Darwin.kill(original.terminal.process.shellPid, SIGKILL), 0)
            try await wait { original.ended }
            store.reconnect(original)
            let reconnected = try XCTUnwrap(store.activeSession)
            try await wait { reconnected.ready }
            XCTAssertEqual(reconnected.remoteShellPID, pidBefore)
            XCTAssertEqual(reconnected.remotePTYID, hostID)
            reconnected.terminal.send(txt:"printf 'NETWORK_%s:%s\\n' \"$HARBOR_RECOVERY_QA_VALUE\" \"$PWD\"\n")
            try await wait { reconnected.recoveryOutput().contains("NETWORK_retained_" + original.id.uuidString + ":/") }
            reconnected.terminal.getTerminal().resize(cols: 111, rows: 37)
            reconnected.terminal.sizeChanged(source: reconnected.terminal, newCols: 111, newRows: 37)
            reconnected.terminal.send(txt:"stty size\n")
            try await wait { reconnected.recoveryOutput().contains("37 111") }
            store.shutdown()
            let next = AppStore(historyRoot:root,workspaceDefaults:prefs); restored = next
            next.profiles = [profile]; next.loading = false; await next.restoreTerminals()
            let saved = try XCTUnwrap(next.activeSession)
            XCTAssertTrue(saved.ended); XCTAssertFalse(saved.started)
            XCTAssertTrue(saved.recoveryOutput().contains("BEFORE_retained_" + original.id.uuidString))
            next.reconnect(saved)
            let live = try XCTUnwrap(next.activeSession)
            try await wait { live.ready }
            XCTAssertNil(live.tmuxName)
            XCTAssertEqual(live.remotePTYID,hostID)
            XCTAssertEqual(live.remoteShellPID,pidBefore)
            live.terminal.send(txt:"printf 'AFTER_%s\\n' $HARBOR_RECOVERY_QA_VALUE\n")
            try await wait { live.recoveryOutput().contains("AFTER_retained_" + original.id.uuidString) }
            // A TUI queries its cursor once, then waits without user input.
            // Reattaching must not send a second reply to that historical query.
            let program = """
            import os,select,time,tty
            tty.setraw(0)
            def query():
                os.write(1,b'\\x1b[6n')
                data=b''
                end=time.monotonic()+3
                while not data.endswith(b'R') and time.monotonic()<end:
                    if select.select([0],[],[],.1)[0]: data+=os.read(0,100)
                return data.startswith(b'\\x1b[') and data.endswith(b'R')
            if not query(): raise RuntimeError('initial query failed')
            print('THINKING_'+'READY',flush=True)
            end=time.monotonic()+30
            while time.monotonic()<end:
                if not select.select([0],[],[],.1)[0]: continue
                data=os.read(0,100)
                if data==b'x':
                    print('FRESH_'+'QUERY_OK' if query() else 'FRESH_'+'QUERY_FAILED',flush=True)
                    break
                print('UNEXPECTED_'+'INPUT_'+data.hex(),flush=True)
            time.sleep(1)
            """
            live.terminal.send(txt: "exec python3 -c " + SSHArguments.quote(program) + "\n")
            try await wait { live.terminal.getTerminal().getRecoveryText().contains("THINKING_READY") }
            XCTAssertEqual(Darwin.kill(live.terminal.process.shellPid, SIGKILL), 0)
            try await wait { live.ended }
            next.reconnect(live)
            let thinking = try XCTUnwrap(next.activeSession)
            try await wait { thinking.ready }
            try await Task.sleep(nanoseconds: 500_000_000)
            let visible = thinking.terminal.getTerminal().getRecoveryText()
            XCTAssertTrue(visible.contains("THINKING_READY"), "Restored content must exist in the terminal, not only in savedOutput")
            XCTAssertFalse(visible.contains("UNEXPECTED_INPUT_"))
            thinking.terminal.send(txt: "x")
            try await wait { thinking.terminal.getTerminal().getRecoveryText().contains("FRESH_QUERY_OK") }
            // The program the shell was replaced by is over a second later. The pane says that its
            // shell has ended (the host's own status, through ssh and the transport), after the
            // last of its output: there is nothing to reconnect to, and Reconnect starts a new one.
            try await wait { thinking.ended }
            XCTAssertTrue(thinking.remotePTYGone, thinking.status); XCTAssertFalse(thinking.resumable)
            XCTAssertTrue(thinking.recoveryOutput().contains("remote terminal ended"))
            await cleanup()
        } catch { await cleanup(); throw error }
    }
}
