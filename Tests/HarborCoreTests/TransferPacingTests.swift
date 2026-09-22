import XCTest
import Darwin
@testable import HarborCore

/// The gateway's token service (serve_tokens in gateway-shaper.py), reduced to what the client sees.
private final class TokenServer: @unchecked Sendable {
    let port: Int
    private let listener: Int32, slice: Int, interval: TimeInterval, silent: Bool
    private let lock = NSLock()
    private var total = 0, hello = false
    var granted: Int { lock.lock(); defer { lock.unlock() }; return total }
    var greeted: Bool { lock.lock(); defer { lock.unlock() }; return hello }

    /// Grants at most `slice` bytes every `interval`; `silent` accepts and reads but never answers.
    init(slice: Int = 8192, interval: TimeInterval = 0.02, silent: Bool = false) throws {
        self.slice = slice; self.interval = interval; self.silent = silent
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
        }
        guard bound, listen(fd, 8) == 0 else { Darwin.close(fd); throw POSIXError(.EADDRINUSE) }
        listener = fd; port = Int(UInt16(bigEndian: address.sin_port))
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                Thread.detachNewThread { self.serve(client) }
            }
        }
    }
    func stop() { Darwin.close(listener) }

    private func line(_ fd: Int32) -> String? {
        var bytes = [UInt8](), byte: UInt8 = 0
        while recv(fd, &byte, 1, 0) == 1 { if byte == 10 { return String(decoding: bytes, as: UTF8.self) }; bytes.append(byte) }
        return nil
    }
    private func serve(_ fd: Int32) {
        defer { Darwin.close(fd) }
        var on: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        guard line(fd) == "RP-TAKE" else { return }
        lock.lock(); hello = true; lock.unlock()
        while let text = line(fd), let want = Int(text) {
            if silent { continue }
            Thread.sleep(forTimeInterval: interval)
            let give = min(want, slice), reply = Array("\(give)\n".utf8)
            lock.lock(); total += give; lock.unlock()
            guard send(fd, reply, reply.count, 0) == reply.count else { return }
        }
    }
}

final class TransferPacingTests: XCTestCase {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-pacing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func randomFile(_ count: Int, in root: URL) throws -> (URL, Data) {
        var data = Data(count: count); data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, count) }
        let url = root.appendingPathComponent("input"); try data.write(to: url); return (url, data)
    }

    func testPacedInputArrivesIntactAtTheGrantedRate() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let server = try TokenServer(slice: 8192, interval: 0.02); defer { server.stop() }   // about 400 KB/s
        let (input, data) = try randomFile(300_000, in: root), output = root.appendingPathComponent("output")
        let started = Date()
        try await FileProcess.run("/bin/cat", arguments: [], input: Data(), output: output, timeout: 30, inputFile: input, pacer: TransferPacer(port: server.port), stallTimeout: 10)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(try Data(contentsOf: output), data)
        XCTAssertTrue(server.greeted)
        XCTAssertEqual(server.granted, data.count, "every byte is covered by a grant, and nothing is granted twice")
        XCTAssertGreaterThan(elapsed, 0.6, "37 slices at 20 ms each cannot arrive faster")
    }

    func testPacerFallsBackToAFixedRateWithoutAGateway() throws {
        let closed = try TokenServer(); let port = closed.port; closed.stop()
        let pacer = TransferPacer(port: port, fallbackRate: 200_000)
        let started = Date(); var left = 100_000
        while left > 0 { let granted = pacer.take(left); XCTAssertGreaterThan(granted, 0); left -= granted }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThan(elapsed, 0.35); XCTAssertLessThan(elapsed, 1.5)
    }

    func testASilentGatewayCostsOneTimeoutNotOnePerSlice() throws {
        let server = try TokenServer(silent: true); defer { server.stop() }
        let pacer = TransferPacer(port: server.port, fallbackRate: 200_000, answerTimeout: 1, retryDelay: 0.1, silentDelay: 60)
        let started = Date(); var left = 100_000
        while left > 0 { let granted = pacer.take(left); XCTAssertGreaterThan(granted, 0); left -= granted }
        // One second of silence, then five 20 KB slices at the fallback rate. Reconnecting after every slice took five seconds.
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testAWriterBlockedOnAFullPipeEndsWithTheTransfer() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let server = try TokenServer(slice: 65_536, interval: 0.001); defer { server.stop() }
        let (input, _) = try randomFile(2_000_000, in: root), output = root.appendingPathComponent("output")
        // The shell's child keeps the read end open and never reads: killing the shell alone leaves the pipe full, not broken.
        let task = Task { try await FileProcess.run("/bin/sh", arguments: ["-c", "sleep 12 & wait"], input: Data(), output: output, timeout: 60, inputFile: input, pacer: TransferPacer(port: server.port), stallTimeout: 60) }
        try await Task.sleep(nanoseconds: 600_000_000)
        let started = Date(); task.cancel()
        do { try await task.value; XCTFail("a cancelled transfer must not report success") } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 4, "cancellation must reach a writer that is waiting for pipe space")
    }

    func testCancellingAPacedTransferStopsPromptly() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let server = try TokenServer(silent: true); defer { server.stop() }
        let (input, _) = try randomFile(200_000, in: root), output = root.appendingPathComponent("output")
        let task = Task { try await FileProcess.run("/bin/cat", arguments: [], input: Data(), output: output, timeout: 60, inputFile: input, pacer: TransferPacer(port: server.port), stallTimeout: 60) }
        try await Task.sleep(nanoseconds: 400_000_000)
        let started = Date(); task.cancel()
        do { try await task.value; XCTFail("a cancelled transfer must not report success") } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }

    func testPacedInputSurvivesAProcessThatExitsWithoutReading() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let server = try TokenServer(slice: 65_536, interval: 0.001); defer { server.stop() }
        let (input, _) = try randomFile(1_500_000, in: root), output = root.appendingPathComponent("output")
        let started = Date()
        try await FileProcess.run("/usr/bin/true", arguments: [], input: Data(), output: output, timeout: 30, inputFile: input, pacer: TransferPacer(port: server.port), stallTimeout: 10)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "a closed pipe ends the writer; it must not block or raise SIGPIPE")
    }

    func testAnotherChildStartedMidTransferDoesNotKeepTheInputOpen() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let server = try TokenServer(slice: 8192, interval: 0.02); defer { server.stop() }
        let (input, data) = try randomFile(200_000, in: root), output = root.appendingPathComponent("output")
        let transfer = Task { try await FileProcess.run("/bin/cat", arguments: [], input: Data(), output: output, timeout: 30, inputFile: input, pacer: TransferPacer(port: server.port), stallTimeout: 20) }
        try await Task.sleep(nanoseconds: 150_000_000)
        // Like a terminal tab opened during an upload: a child that inherits every descriptor not marked close-on-exec.
        var pid: pid_t = 0
        let arguments: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("15"), nil]
        defer { arguments.forEach { free($0) } }
        XCTAssertEqual(posix_spawn(&pid, "/bin/sleep", nil, nil, arguments, nil), 0)
        defer { kill(pid, SIGKILL); var status: Int32 = 0; waitpid(pid, &status, 0) }
        let started = Date()
        try await transfer.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 8, "the reader must see end of input when the writer closes, whoever else was forked meanwhile")
        XCTAssertEqual(try Data(contentsOf: output), data)
    }

    func testStallTimeoutEndsATransferThatStopsMoving() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let started = Date()
        do {
            try await FileProcess.run("/bin/sleep", arguments: ["30"], input: Data(), output: root.appendingPathComponent("output"), timeout: 60, stallTimeout: 1)
            XCTFail("a transfer that moves nothing must time out")
        } catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
    }

    func testStallTimeoutDoesNotEndATransferThatKeepsMoving() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("output")
        // Seven seconds of steady output with a two second stall limit.
        try await FileProcess.run("/bin/sh", arguments: ["-c", "for i in 1 2 3 4 5 6 7; do printf x; sleep 1; done"], input: Data(), output: output, timeout: 60, stallTimeout: 2.5)
        XCTAssertEqual(try Data(contentsOf: output).count, 7)
    }
}
