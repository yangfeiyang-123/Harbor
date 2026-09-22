import XCTest
@testable import HarborCore

final class HarborCoreTests: XCTestCase {
    func testCommandTranscriptReplaysRedrawsBackspaceAndSplitUTF8() {
        let raw = Data("%                 \r \r(base) demo@Mac ~ % p\u{8}printf '中文\\n'\r(base) demo@Mac ~ % printf '中文\\n'\u{1b}[K\r\n中文\r\n(base) demo@Mac ~ % ".utf8)
        let expected = "(base) demo@Mac ~ % printf '中文\\n'\n中文\n(base) demo@Mac ~ %"
        for width in 1...raw.count {
            var filter = CommandTranscriptFilter(), output = Data()
            for offset in stride(from: 0, to: raw.count, by: width) { output.append(filter.consume(raw.subdata(in: offset..<min(offset + width, raw.count)))) }
            output.append(filter.pending)
            XCTAssertEqual(String(decoding: output, as: UTF8.self), expected)
        }
    }
    func testCommandTranscriptCollapsesProgressAndSeparatesFullScreenPrograms() {
        var filter = CommandTranscriptFilter()
        let result = filter.consume(Data("user@host:~$ train\r\n10%\r20%\r100%\u{1b}[K\r\nuser@host:~$ vim\r\n\u{1b}[?1049hSECRET_TUI\u{1b}[?1049luser@host:~$ \u{1b}]52;c;SECRET\u{7}".utf8)) + filter.pending
        let text = String(decoding: result, as: UTF8.self)
        XCTAssertTrue(text.contains("100%"))
        XCTAssertFalse(text.contains("10%"))
        XCTAssertFalse(text.contains("SECRET"))
        XCTAssertEqual(CommandHistory.parse(text).compactMap(\.command), ["train", "vim"])
    }
    func testCommandTranscriptBoundsOversizedCursorAndTabSequences() {
        var filter = CommandTranscriptFilter()
        let output = filter.consume(Data("\u{1b}[100000C\tignored\rOK\r\n".utf8))
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "OK\n")
    }
    func testCommandLogUpdatesPendingLineAndSearchesCorrectedCommand() throws {
        let history = try HistoryStore(root: temporaryDirectory())
        let record = SessionRecord(serverID: nil, serverName: "本机", title: "本机 · 1")
        let writer = try TranscriptWriter(url: history.logURL(record.id))
        writer.append(Data("demo@Mac ~ % p\u{8}pwd".utf8)); writer.flush()
        XCTAssertEqual(history.commandTranscript(record.id), "demo@Mac ~ % pwd")
        writer.append(Data("\r\n/home/felix\r\n".utf8)); writer.close()
        XCTAssertEqual(CommandHistory.parse(history.commandTranscript(record.id)).first?.command, "pwd")
        XCTAssertEqual(history.search([record], query: "pwd"), [record.id])
        try history.delete(record)
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.commandLogURL(record.id).path))
    }
    func testServerWorkspacesRememberTheirOwnTabsAndClosingDoesNotSwitchServers() {
        let titan = UUID(), gpu = UUID(), t1 = UUID(), t2 = UUID(), g1 = UUID(), local = UUID()
        var selection = WorkspaceSelection()
        selection.selectSession(t1, profileID: titan)
        selection.selectSession(t2, profileID: titan)
        selection.selectSession(g1, profileID: gpu)
        selection.selectWorkspace(titan, available: [t1, t2])
        XCTAssertEqual(selection.sessionID, t2)
        selection.selectSession(local, profileID: nil)
        selection.removeSession(t2, profileID: titan, remaining: [t1])
        XCTAssertNil(selection.profileID)
        XCTAssertEqual(selection.sessionID, local)
        selection.selectWorkspace(titan, available: [t1])
        XCTAssertEqual(selection.sessionID, t1)
        selection.removeSession(t1, profileID: titan, remaining: [])
        XCTAssertEqual(selection.profileID, titan)
        XCTAssertNil(selection.sessionID)
        selection.selectWorkspace(gpu, available: [g1])
        XCTAssertEqual(selection.sessionID, g1)
    }
    func testEmptyWorkspaceNeverBorrowsAnotherServerTerminal() {
        var selection = WorkspaceSelection()
        selection.selectSession(UUID(), profileID: UUID())
        selection.selectWorkspace(UUID(), available: [])
        XCTAssertNil(selection.sessionID)
        selection.selectWorkspace(nil, available: [])
        XCTAssertNil(selection.sessionID)
    }
    func testServerIdentityMergesAliasesButPreservesAccountsRoutesAndPorts() {
        let base = ["hostname": "GPU.Example", "user": "alice", "port": "22", "identityfile": "/key"]
        var alias = base; alias["hostname"] = "gpu.example"
        XCTAssertEqual(ServerIdentity.key(effective: base), ServerIdentity.key(effective: alias))
        for (key, value) in [("user", "bob"), ("port", "2222"), ("proxyjump", "bastion"), ("identityfile", "/other")] {
            var other = base; other[key] = value
            XCTAssertNotEqual(ServerIdentity.key(effective: base), ServerIdentity.key(effective: other))
        }
        XCTAssertNil(ServerIdentity.key(effective: ["hostname": "gpu"]))
    }
    func testCommandHistoryGroupsBashZshAndChineseWithoutChangingOutput() {
        let text = "Last login: yesterday\ndemo@gpu:~$ pwd\n/home/demo\n(base) demo@gpu:~/work$ printf '中文'\n中文\ndemo@Mac ~ % ls\na.txt\nb.txt\ndemo@Mac ~ % "
        let blocks = CommandHistory.parse(text)
        XCTAssertEqual(blocks.compactMap(\.command), ["pwd", "printf '中文'", "ls"])
        XCTAssertEqual(blocks.map(\.output), ["Last login: yesterday", "/home/demo", "中文", "a.txt\nb.txt"])
        XCTAssertEqual(Set(blocks.map(\.id)).count, blocks.count)
    }
    func testCommandHistoryPreservesUnrecognizedOutputAndBlankCommands() {
        let text = "cost $ 30\n# heading\n$ not a qualified prompt\njust output\n"
        XCTAssertEqual(CommandHistory.parse(text).count, 1)
        XCTAssertNil(CommandHistory.parse(text).first?.command)
        XCTAssertEqual(CommandHistory.parse(text).first?.output, String(text.dropLast()))
        let redraw = "demo@Mac ~ % pwd\ndemo@Mac ~ % pwd\n/Users/demo\ndemo@Mac ~ % \n"
        XCTAssertEqual(CommandHistory.parse(redraw).compactMap(\.command), ["pwd"])
    }
    func testManagedProxyNeedsActualHTTPProofNotJustRunningJobs() {
        let status = ManagedProxyStatus(output: "MODE=usa\nA100_JOB=up\nA100_TUNNEL=up\nRTX_JOB=up\nRTX_TUNNEL=up\n")
        XCTAssertEqual(status.modeLabel, "US Direct")
        XCTAssertFalse(status.verified("A100"))
        let checked = ManagedProxyStatus(output: "MODE=china\nA100_TUNNEL=up\nA100_HTTP=204\nRTX_TUNNEL=stale\nRTX_HTTP=204\n")
        XCTAssertTrue(checked.verified("A100"))
        XCTAssertFalse(checked.verified("RTX"))
    }
    func testManagedCheckCannotUseAStaleMasterOrStartInheritedForwards() {
        let arguments = ManagedProxyProbe.arguments(alias: "test.invalid", key: "A100", fallbackPort: 11088)
        let result = ProcessRunner.sync("/usr/bin/ssh", ["-F", "/dev/null", "-G"] + arguments)
        XCTAssertTrue(result.succeeded)
        let config = SSHConfig.effective(result.output)
        XCTAssertNil(config["controlpath"])
        XCTAssertEqual(config["controlmaster"], "false")
        XCTAssertEqual(config["clearallforwardings"], "yes")
        XCTAssertTrue(arguments.last!.contains("--max-time 30"))
        XCTAssertTrue(arguments.last!.contains("test \"$code\" = 204"))
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HarborTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testTranscriptPreservesSplitChineseAndRemovesControlPayloads() {
        let source = Data("\u{1b}[32m中文🙂\u{1b}[0m\r\nhello\u{1b}]52;c;SECRET\u{7}!\u{1b}]0;TITLE\u{1b}\\\rnext\tline\n".utf8)
        for width in 1...source.count {
            var filter = TranscriptFilter(), result = Data()
            for offset in stride(from: 0, to: source.count, by: width) {
                result.append(filter.consume(source.subdata(in: offset..<min(offset + width, source.count))))
            }
            XCTAssertEqual(String(decoding: result, as: UTF8.self), "中文🙂\nhello!\nnext\tline\n")
        }
    }
    func testHistoryPersistsSearchesAndDeletesOneSession() throws {
        let root = try temporaryDirectory(), history = try HistoryStore(root: root)
        let first = SessionRecord(serverID: nil, serverName: "GPU", title: "training")
        let second = SessionRecord(serverID: nil, serverName: "CPU", title: "monitor")
        let writer = try TranscriptWriter(url: history.logURL(first.id))
        writer.append(Data("准确率 98%\nRun COMPLETE\n".utf8)); writer.close()
        try history.write([first, second], name: "history.json")
        let reopened = try HistoryStore(root: root)
        let records = try XCTUnwrap(reopened.read("history.json", as: [SessionRecord].self))
        XCTAssertEqual(records.map(\.id), [first.id, second.id])
        XCTAssertEqual(reopened.search(records, query: "准确率"), [first.id])
        XCTAssertEqual(reopened.search(records, query: "complete"), [first.id])
        XCTAssertEqual(reopened.search(records, query: "CPU"), [second.id])
        XCTAssertEqual(reopened.search(records, query: "missing"), [])
        let permissions = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("history.json").path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        try reopened.delete(first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.logURL(first.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("history.json").path))
    }
    func testTranscriptCapDoesNotGrowWithFurtherOutput() throws {
        let url = try temporaryDirectory().appendingPathComponent("capped.log")
        let writer = try TranscriptWriter(url: url, limit: 10)
        writer.append(Data("123456789012345".utf8)); writer.flush()
        let capped = try Data(contentsOf: url)
        writer.append(Data(repeating: 65, count: 100_000)); writer.close()
        XCTAssertEqual(try Data(contentsOf: url), capped)
        XCTAssertTrue(String(decoding: capped, as: UTF8.self).hasPrefix("1234567890\n[Harbor"))
    }
    func testIncludesAndAliasesAvoidCyclesAndWildcards() throws {
        let root = try temporaryDirectory(), ssh = root.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        try "Host alpha beta # same target\nInclude \"more.conf\"\nHost * !bad test?\n".write(to: ssh.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try "Host gamma\nInclude config\nHost alpha\n".write(to: ssh.appendingPathComponent("more.conf"), atomically: true, encoding: .utf8)
        XCTAssertEqual(SSHConfig.entries(at: ssh.appendingPathComponent("config"), home: root).map(\.aliases), [["alpha", "beta"], ["gamma"]])
        XCTAssertEqual(SSHConfig.tokens("IdentityFile = \"/a path/key\" # comment"), ["IdentityFile", "/a path/key"])
    }
    func testProbeCannotSilentlyMakeANewNetworkConnection() {
        let p = ServerProfile(name: "offline", host: "127.0.0.1", port: 9)
        let result = ProcessRunner.sync("/usr/bin/ssh", ["-F", "/dev/null"] + SSHArguments.probe(p, socket: "/tmp/harbor-no-such-socket-\(UUID())"), timeout: 3)
        XCTAssertFalse(result.succeeded)
        XCTAssertFalse(result.timedOut)
        XCTAssertFalse(result.output.contains("Connection refused"))
    }
    func testOpenSSHEffectiveForwardAndTerminalConfiguration() {
        let p = ServerProfile(name: "example", host: "example.invalid", user: "user", port: 2222)
        var rule = ForwardRule(serverID: p.id)
        rule.kind = .remote; rule.listenPort = 12001; rule.targetPort = 10810
        let result = ProcessRunner.sync("/usr/bin/ssh", ["-F", "/dev/null", "-G"] + SSHArguments.forward(rule, profile: p))
        XCTAssertTrue(result.succeeded, result.output)
        let config = SSHConfig.effective(result.output)
        XCTAssertEqual(config["remoteforward"], "[127.0.0.1]:12001 [127.0.0.1]:10810")
        XCTAssertEqual(config["exitonforwardfailure"], "yes")
        XCTAssertEqual(config["controlmaster"], "false")
        let terminal = ProcessRunner.sync("/usr/bin/ssh", ["-F", "/dev/null", "-G"] + SSHArguments.terminal(p, socket: "/tmp/harbor-test-socket"))
        XCTAssertTrue(terminal.succeeded)
        let tc = SSHConfig.effective(terminal.output)
        XCTAssertEqual(tc["controlpersist"], "28800")
        XCTAssertEqual(tc["clearallforwardings"], "yes")
    }
    func testShellQuotingTreatsMetacharactersAsLiteral() {
        let value = "a'b $(printf BAD) `printf BAD` ; 中文"
        let result = ProcessRunner.sync("/bin/sh", ["-c", "printf '%s' " + SSHArguments.quote(value)])
        XCTAssertEqual(result.output, value)
        XCTAssertTrue(result.succeeded)
        XCTAssertNotNil(ServerProfile(name: "bad", host: "-oProxyCommand=bad").validationError)
    }
    func testProcessRunnerHandlesLargeOutputExitAndTimeout() {
        let result = ProcessRunner.sync("/bin/sh", ["-c", "i=0; while [ $i -lt 10000 ]; do printf abcdefghij; i=$((i+1)); done; printf END >&2; exit 7"], timeout: 10)
        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(result.output.utf8.count, 100003)
        XCTAssertTrue(result.output.hasSuffix("END"))
        let start = Date()
        let timeout = ProcessRunner.sync("/bin/sh", ["-c", "trap '' TERM; exec /bin/sleep 10"], timeout: 0.15)
        XCTAssertTrue(timeout.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        let missing = ProcessRunner.sync("/no/such/executable", [])
        XCTAssertFalse(missing.succeeded)
    }
}
