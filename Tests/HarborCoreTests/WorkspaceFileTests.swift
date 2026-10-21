import XCTest
@testable import HarborCore

final class WorkspaceFileTests: XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-files-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testLocalListingUnicodePathsHiddenFilesAndDirectories() async throws {
        let root = try temporary(), cache = try temporary()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("实验 目录"), withIntermediateDirectories: false)
        try Data("hello".utf8).write(to: root.appendingPathComponent("a ' $(uname).py"))
        try Data().write(to: root.appendingPathComponent(".hidden"))
        let service = WorkspaceFileService(profile: nil, socket: nil, script: "", cache: cache)
        let listing = try await service.list(root.path)
        XCTAssertEqual(listing.entries.map(\.name), ["实验 目录", "a ' $(uname).py"])
        XCTAssertTrue(listing.entries[0].directory)
        let hidden = try await service.list(root.path, showHidden: true)
        XCTAssertEqual(hidden.entries.count, 3)
    }
    func testChildPathsRejectTraversal() throws {
        let root = try temporary()
        for name in ["../escape", "/absolute", "", ".", "..", "new\nline"] { XCTAssertThrowsError(try WorkspacePath.child(name, in: root.path)) }
    }
    func testTerminalDirectoryIsSafelyQuotedAndLegacyRecordLoads() throws {
        let profile = ServerProfile(name: "test", host: "host")
        let path = "/data/实验 ' $(touch /tmp/nope)"
        let normal = SSHArguments.terminal(profile, socket: "/tmp/socket", workingDirectory: path)
        XCTAssertEqual(normal.last, "cd -- " + SSHArguments.quote(path) + " && exec \"${SHELL:-/bin/sh}\" -l")
        let tmux = SSHArguments.terminal(profile, socket: "/tmp/socket", tmuxName: "session", workingDirectory: path)
        XCTAssertTrue(tmux.last!.contains(" -c " + SSHArguments.quote(path)))
        let original = SessionRecord(serverID: nil, serverName: "本机", title: "本机 · 1")
        let data = try JSONEncoder().encode(original)
        XCTAssertNil(try JSONDecoder().decode(SessionRecord.self, from: data).workingDirectory)
    }
    func testBinaryTransportKeepsStderrSeparateAndDoesNotTruncate() async throws {
        let root = try temporary(), output = root.appendingPathComponent("binary")
        let data = Data((0..<300_000).map { UInt8($0 % 256) })
        try await FileProcess.run("/bin/sh", arguments: ["-c", "cat; printf diagnostic >&2"], input: data, output: output, timeout: 5)
        XCTAssertEqual(try Data(contentsOf: output), data)
    }
    func testCancelledFileProcessStopsPromptly() async throws {
        let root = try temporary()
        let started = Date()
        let task = Task { try await FileProcess.run("/bin/sleep", arguments: ["30"], input: Data(), output: root.appendingPathComponent("output")) }
        try await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()
        do { try await task.value; XCTFail("A cancelled directory request must stop its SSH channel") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }
    func testTmuxFallbackAndArgumentsUseTheSameQuotedDirectory() async throws {
        let root = try temporary(), folder = root.appendingPathComponent("中文 ' project")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
        let shell = root.appendingPathComponent("fake-shell")
        try "#!/bin/sh\nprintf 'FALLBACK_DIRECTORY=%s\\n' \"$PWD\"\n".write(to:shell,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:shell.path)
        let command = try XCTUnwrap(SSHArguments.terminal(ServerProfile(name:"QA",host:"unused"),socket:"unused",tmuxName:"harbor-qa",workingDirectory:folder.path,directoryToken:"qa-token").last)
        let missing = await ProcessRunner.run("/bin/sh",["-c","PATH=/nonexistent; SHELL=" + SSHArguments.quote(shell.path) + "; export PATH SHELL; " + command])
        XCTAssertTrue(missing.succeeded)
        XCTAssertTrue(missing.output.contains("tmux is unavailable"))
        XCTAssertTrue(missing.output.contains("7778;qa-token;0"))
        XCTAssertTrue(missing.output.contains("7777;qa-token;"))
        XCTAssertTrue(missing.output.contains("FALLBACK_DIRECTORY=" + folder.path))
        let stub = root.appendingPathComponent("tmux")
        try "#!/bin/sh\nprintf 'ARG=%s\\n' \"$@\"\n".write(to:stub,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:stub.path)
        let present = await ProcessRunner.run("/bin/sh",["-c","PATH=" + SSHArguments.quote(root.path) + "; export PATH; " + command])
        XCTAssertTrue(present.succeeded)
        XCTAssertTrue(present.output.contains("ARG=-A")); XCTAssertTrue(present.output.contains("ARG=harbor-qa"))
        XCTAssertTrue(present.output.contains("ARG=" + folder.path))
        XCTAssertFalse(present.output.contains("FALLBACK_DIRECTORY="))
        XCTAssertTrue(present.output.contains("ARG=;\nARG=set-option\nARG=-t\nARG=harbor-qa\nARG=status\nARG=off"))
    }

}
