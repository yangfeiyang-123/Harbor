import XCTest
import Network
import HarborCore
@testable import HarborSSH

/// Sending the editor to a server from this Mac, and answering its program files locally.
final class RuntimeDeliveryTests: XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-delivery-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func shell(_ command: String, input: Data, home: URL) throws -> Int32 {
        let process = Process(), stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", command]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        process.standardInput = stdin; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        stdin.fileHandleForWriting.write(input); try stdin.fileHandleForWriting.close()
        process.waitUntilExit(); return process.terminationStatus
    }

    func testManifestIsReadFromTheServiceScript() throws {
        let script = try String(contentsOf: AppResources.directory("CodeWorkbench").appendingPathComponent("bootstrap.py"), encoding: .utf8)
        let manifest = try CodeRuntimePackage.manifest(script: script)
        XCTAssertEqual(manifest.version.split(separator: ".").count, 3)
        XCTAssertEqual(Set(manifest.digests.keys), ["macos-arm64", "macos-amd64", "linux-amd64", "linux-arm64"])
        XCTAssertTrue(manifest.pruned.contains("lib/vscode/extensions/copilot"))
        XCTAssertTrue(manifest.pruned.contains("lib/vscode/node_modules/@github/copilot-sdk-*"))
        XCTAssertThrowsError(try CodeRuntimePackage.manifest(script: "print('no release here')"))
        XCTAssertEqual(CodeRuntimePackage.describe(sent: 13 * 1_048_576, total: 66 * 1_048_576, rate: 310 * 1024), "13.0 of 66 MB · 310 KB/s · about 3 min left")
    }

    func testPackagesOfEarlierReleasesAreSweptFromTheCacheForTheSamePlatformOnly() throws {
        let cache = try temporary()
        func file(_ name: String) -> URL {
            let url = cache.appendingPathComponent(name); FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8)); return url
        }
        let current = file("code-server-4.140.0-linux-amd64.slim-aaaaaaaaaaaa.tar.xz"), note = file(current.lastPathComponent + ".sha256")
        let stale = [file("code-server-4.139.0-linux-amd64.slim-bbbbbbbbbbbb.tar.xz"), file("code-server-4.139.0-linux-amd64.slim-bbbbbbbbbbbb.tar.xz.sha256"),
                     file("code-server-4.140.0-linux-amd64.slim-cccccccccccc.tar.gz"), file("code-server-4.139.0-linux-amd64.tar.gz")]
        let unrelated = [file("code-server-4.140.0-macos-arm64.slim-dddddddddddd.tar.xz"), file("code-server-4.140.0-linux-arm64.slim-eeeeeeeeeeee.tar.xz"), file("notes.txt")]
        CodeRuntimePackage.sweep(cache, target: "linux-amd64", keeping: [current, note])
        for url in [current, note] + unrelated { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.lastPathComponent) }
        for url in stale { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), url.lastPathComponent) }
    }

    func testUploadStartsRecordsItsPackageAndContinuesOnlyThatPackage() throws {
        let home = try temporary(), directory = home.appendingPathComponent("code oss/archives").path, name = "code-server-9.9.9-linux-amd64"
        let package = Data((0..<5000).map { UInt8($0 % 251) }), digest = String(repeating: "a", count: 64)
        let source = home.appendingPathComponent("package"); try package.write(to: source)
        func prefix(_ count: Int64) throws -> String { try CodeRuntimePackage.sha256(of: source, upTo: count) }
        XCTAssertEqual(try prefix(5000), try CodeRuntimePackage.sha256(of: source)); XCTAssertNotEqual(try prefix(2000), try prefix(2001))
        XCTAssertThrowsError(try prefix(5001))
        let part = URL(fileURLWithPath: directory).appendingPathComponent(name + ".slim.part")
        func upload(_ digest: String, from offset: Int64, _ bytes: Data, prefix: String = "") throws -> Int32 {
            try shell(CodeRuntimePackage.uploadCommand(directory: directory, name: name, digest: digest, offset: offset, prefix: prefix), input: bytes, home: home)
        }
        XCTAssertEqual(try upload(digest, from: 0, package.prefix(2000)), 0)
        XCTAssertEqual(try Data(contentsOf: part), package.prefix(2000))
        XCTAssertEqual(try String(contentsOf: part.deletingLastPathComponent().appendingPathComponent(name + ".slim.sha256"), encoding: .utf8), digest)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: part.path)[.posixPermissions] as? Int), 0o600)
        // A different package, or an offset the server's copy does not have, is refused without touching it.
        XCTAssertEqual(try upload(String(repeating: "b", count: 64), from: 2000, package.suffix(3000), prefix: try prefix(2000)), 9)
        XCTAssertEqual(try upload(digest, from: 2500, package.suffix(2500), prefix: try prefix(2500)), 9)
        XCTAssertEqual(try Data(contentsOf: part), package.prefix(2000))
        XCTAssertEqual(try upload(digest, from: 2000, package.suffix(3000), prefix: try prefix(2000)), 0)
        XCTAssertEqual(try Data(contentsOf: part), package)
        // Starting over replaces what was there.
        XCTAssertEqual(try upload(digest, from: 0, package.prefix(10)), 0)
        XCTAssertEqual(try Data(contentsOf: part).count, 10)
    }

    func testUploadContinuesOnlyFromThePackagesOwnBytesAndOneWriterAtATime() throws {
        let home = try temporary(), directory = home.appendingPathComponent("archives").path, name = "code-server-9.9.9-linux-amd64"
        let package = Data((0..<6000).map { UInt8(($0 * 7) % 253) }), digest = String(repeating: "c", count: 64)
        let source = home.appendingPathComponent("package"); try package.write(to: source)
        let part = URL(fileURLWithPath: directory).appendingPathComponent(name + ".slim.part")
        func command(from offset: Int64) throws -> String {
            CodeRuntimePackage.uploadCommand(directory: directory, name: name, digest: digest, offset: offset, prefix: offset > 0 ? try CodeRuntimePackage.sha256(of: source, upTo: offset) : "")
        }
        // Two uploads once wrote into one file: the right size and the right note, the wrong bytes.
        XCTAssertEqual(try shell(try command(from: 0), input: package.prefix(1000) + Data(repeating: 0xEE, count: 2000), home: home), 0)
        XCTAssertEqual(try shell(try command(from: 3000), input: package.suffix(3000), home: home), 9, "size and note match, the content does not")
        XCTAssertEqual(try Data(contentsOf: part).count, 3000, "a refused upload writes nothing")
        // While one upload is writing, a second one is turned away instead of appending beside it.
        let first = Process(), input = Pipe(), errors = Pipe()
        first.executableURL = URL(fileURLWithPath: "/bin/sh"); first.arguments = ["-c", try command(from: 0)]
        first.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]; first.standardInput = input; first.standardOutput = FileHandle.nullDevice; first.standardError = FileHandle.nullDevice
        try first.run()
        input.fileHandleForWriting.write(package.prefix(4000))
        let deadline = Date().addingTimeInterval(10)
        while ((try? Data(contentsOf: part))?.count ?? 0) < 4000, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertEqual(try Data(contentsOf: part), package.prefix(4000))
        let second = Process()
        second.executableURL = URL(fileURLWithPath: "/bin/sh"); second.arguments = ["-c", try command(from: 4000)]
        second.environment = first.environment; second.standardInput = FileHandle.nullDevice; second.standardOutput = FileHandle.nullDevice; second.standardError = errors
        try second.run(); second.waitUntilExit()
        XCTAssertEqual(second.terminationStatus, 7)
        XCTAssertTrue(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).contains(CodeRuntimePackage.uploadBusy))
        input.fileHandleForWriting.write(package.suffix(2000)); try input.fileHandleForWriting.close(); first.waitUntilExit()
        XCTAssertEqual(first.terminationStatus, 0); XCTAssertEqual(try Data(contentsOf: part), package)
        // The file is free again once that writer has gone.
        XCTAssertEqual(try shell(try command(from: 6000), input: Data(), home: home), 0)
        // A writer whose connection died silently lets go by itself, so the next upload is not kept waiting for hours.
        let silent = Process(), open = Pipe()
        silent.executableURL = URL(fileURLWithPath: "/bin/sh")
        silent.arguments = ["-c", CodeRuntimePackage.uploadCommand(directory: directory, name: name, digest: digest, offset: 6000, prefix: try CodeRuntimePackage.sha256(of: source, upTo: 6000), idle: 0.5)]
        silent.environment = first.environment; silent.standardInput = open; silent.standardOutput = FileHandle.nullDevice; silent.standardError = FileHandle.nullDevice
        try silent.run(); silent.waitUntilExit()
        XCTAssertEqual(silent.terminationStatus, 6)
        XCTAssertEqual(try shell(try command(from: 6000), input: Data(), home: home), 0)
        try open.fileHandleForWriting.close()
    }

    func testFileProcessFeedsFromAnOffset() async throws {
        let home = try temporary(), source = home.appendingPathComponent("in"), output = home.appendingPathComponent("out")
        try Data("0123456789".utf8).write(to: source)
        try await FileProcess.run("/bin/cat", arguments: [], input: Data(), output: output, inputFile: source, inputOffset: 6)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "6789")
    }

    @MainActor func testExtensionDigestIsStableAndSensitiveToContent() {
        let bundles = ["harbor.workbench-1.0.0": ["extension.js": "a", "package.json": "{}"], "harbor.themes-1.0.0": ["package.json": "{}"]]
        XCTAssertEqual(CodeWorkbenchSession.digest(of: bundles), CodeWorkbenchSession.digest(of: bundles))
        XCTAssertEqual(CodeWorkbenchSession.digest(of: bundles).count, 64)
        var changed = bundles; changed["harbor.workbench-1.0.0"]?["extension.js"] = "b"
        XCTAssertNotEqual(CodeWorkbenchSession.digest(of: bundles), CodeWorkbenchSession.digest(of: changed))
    }

    func testProxyAnswersProgramFilesLocallyAndPassesEverythingElseThrough() async throws {
        let assets = try temporary()
        try FileManager.default.createDirectory(at: assets.appendingPathComponent("out/vs"), withIntermediateDirectories: true)
        try Data("console.log('local')".utf8).write(to: assets.appendingPathComponent("out/vs/workbench.js"))
        try Data("<html>".utf8).write(to: assets.appendingPathComponent("out/vs/frame.html"))
        try Data("secret".utf8).write(to: assets.deletingLastPathComponent().appendingPathComponent("outside.js"))
        // A server that answers every request with its request line and what it was told about the connection.
        let upstream = try NWListener(using: .tcp, on: .any), queue = DispatchQueue(label: "upstream")
        upstream.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                let head = String(decoding: data ?? Data(), as: UTF8.self)
                let body = (head.components(separatedBy: "\r\n").first ?? "") + "|" + (head.lowercased().contains("connection: close") ? "close" : "keep")
                connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let ready = expectation(description: "upstream")
        upstream.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        upstream.start(queue: queue); await fulfillment(of: [ready], timeout: 5)
        defer { upstream.cancel() }
        let port = try await MainActor.run { try RemoteDisplaySession.unusedPort() }
        let proxy = try WorkbenchStaticProxy(port: port, upstream: Int(try XCTUnwrap(upstream.port).rawValue), assets: assets)
        defer { proxy.stop() }
        XCTAssertNotNil(proxy.localFile(for: "/stable-abc/static/out/vs/workbench.js?v=1"))
        for refused in ["/stable-abc/static/out/vs/frame.html", "/stable-abc/static/out/../outside.js", "/stable-abc/static/out/vs/missing.js", "/stable-abc/other/out/vs/workbench.js",
                        "/stable-abc/static/extensions/x.js", "/stable-abc/static/out/%2e%2e/outside.js", "/out/vs/workbench.js"] {
            XCTAssertNil(proxy.localFile(for: refused), refused)
        }
        let configuration = URLSessionConfiguration.ephemeral; configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration), base = "http://127.0.0.1:\(port)"
        try await Task.sleep(nanoseconds: 200_000_000)
        let (local, localResponse) = try await session.data(from: URL(string: base + "/stable-abc/static/out/vs/workbench.js")!)
        XCTAssertEqual(String(decoding: local, as: UTF8.self), "console.log('local')")
        XCTAssertEqual((localResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Harbor-Source"), "local")
        XCTAssertEqual((localResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Cache-Control"), "public, max-age=31536000, immutable")
        for path in ["/login?to=1", "/stable-abc/static/out/vs/frame.html", "/stable-abc/static/out/vs/workbench.js"] {
            let (data, _) = try await session.data(from: URL(string: base + path)!)
            let text = String(decoding: data, as: UTF8.self)
            if path.hasSuffix("workbench.js") { XCTAssertEqual(text, "console.log('local')", "a connection is read again after a forwarded request") }
            else { XCTAssertEqual(text, "GET \(path) HTTP/1.1|close") }
        }
    }
}
