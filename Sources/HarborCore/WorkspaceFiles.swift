import Foundation
import CryptoKit
import Darwin

public struct WorkspaceEntry: Codable, Identifiable, Equatable, Sendable {
    public var path: String
    public var name: String
    public var directory: Bool
    public var size: Int64
    public var modified: Double
    public var id: String { path }
    public init(path: String, name: String, directory: Bool, size: Int64, modified: Double) {
        self.path = path; self.name = name; self.directory = directory; self.size = size; self.modified = modified
    }
}
public struct WorkspaceListing: Codable, Sendable {
    public var path: String
    public var entries: [WorkspaceEntry]
    public var truncated: Bool
    public var stamp: String? = nil
    public init(path: String, entries: [WorkspaceEntry], truncated: Bool = false, stamp: String? = nil) {
        self.path = path; self.entries = entries; self.truncated = truncated; self.stamp = stamp
    }
}
public enum WorkspaceError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
public enum WorkspacePath {
    public static func local(_ path: String) -> URL {
        URL(fileURLWithPath: NSString(string: path.isEmpty ? "~" : path).expandingTildeInPath).standardizedFileURL
    }
    public static func child(_ name: String, in parent: String) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"), !name.contains("\n") else {
            throw WorkspaceError.message("Names cannot be empty or contain slashes or line breaks.")
        }
        return (parent as NSString).appendingPathComponent(name)
    }
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// Binary stdout is written directly to a private file: never mixed with SSH diagnostics or truncated.
private final class FileProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func start(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try process.run(); self.process = process
    }
    func finish() { lock.lock(); process = nil; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
    func cancel() {
        lock.lock(); cancelled = true
        let running = process
        if let running, running.isRunning { running.terminate() }
        lock.unlock()
        if let running {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                self.lock.lock(); defer { self.lock.unlock() }
                if self.process === running, running.isRunning { kill(running.processIdentifier, SIGKILL) }
            }
        }
    }
}
public enum FileProcess {
    /// With `pacer`, stdin is fed one granted slice at a time instead of handing the file to the
    /// process. With `stallTimeout`, a transfer ends when neither stdin nor the output file moved
    /// for that long; `timeout` stays the absolute limit. A paced transfer can take hours, so a
    /// short absolute limit would kill it while it is making progress.
    public static func run(_ executable: String, arguments: [String], input: Data, output: URL, timeout: TimeInterval = 120, inputFile: URL? = nil, inputOffset: UInt64 = 0,
                           pacer: TransferPacer? = nil, stallTimeout: TimeInterval? = nil,
                           progress: (@Sendable (FileProcessProgress) -> Void)? = nil) async throws {
        let cancellation = FileProcessCancellation()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await Task.detached(priority: .utility) {
                try runSync(executable, arguments: arguments, input: input, output: output, timeout: timeout, cancellation: cancellation, inputFile: inputFile, inputOffset: inputOffset, pacer: pacer, stallTimeout: stallTimeout, report: progress)
            }.value
            try Task.checkCancellation()
        } onCancel: { cancellation.cancel(); pacer?.cancel() }
    }
    private final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private var moved: Int64 = 0, halted = false
        func add(_ count: Int) { lock.lock(); moved += Int64(count); lock.unlock() }
        func stop() { lock.lock(); halted = true; lock.unlock() }
        var total: Int64 { lock.lock(); defer { lock.unlock() }; return moved }
        var stopped: Bool { lock.lock(); defer { lock.unlock() }; return halted }
    }
    /// Writes all of `data` to a non-blocking pipe, giving up when `progress` is stopped or the reader is gone.
    /// A blocking write could not be reached by cancellation while another holder of the read end kept the pipe full.
    private static func push(_ data: Data, to fd: Int32, progress: Progress) -> Bool {
        var offset = 0
        while offset < data.count {
            if progress.stopped { return false }
            let sent = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, data.count - offset) }
            if sent > 0 { offset += sent; continue }
            if sent < 0, errno == EINTR { continue }
            guard sent < 0, errno == EAGAIN else { return false }
            var waiting = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            _ = poll(&waiting, 1, 500)
        }
        return true
    }
    private static func runSync(_ executable: String, arguments: [String], input: Data, output: URL, timeout: TimeInterval, cancellation: FileProcessCancellation, inputFile: URL?, inputOffset: UInt64 = 0,
                                pacer: TransferPacer?, stallTimeout: TimeInterval?, report: (@Sendable (FileProcessProgress) -> Void)?) throws {
            try cancellation.check()
            let fm = FileManager.default, scratch = fm.temporaryDirectory.appendingPathComponent("harbor-io-" + UUID().uuidString)
            try fm.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: scratch) }
            let request = scratch.appendingPathComponent("request"), errors = scratch.appendingPathComponent("stderr")
            try input.write(to: request, options: .atomic)
            fm.createFile(atPath: errors.path, contents: nil, attributes: [.posixPermissions: 0o600])
            fm.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let source = try FileHandle(forReadingFrom: inputFile ?? request), sink = try FileHandle(forWritingTo: output), errorSink = try FileHandle(forWritingTo: errors)
            defer { try? source.close(); try? sink.close(); try? errorSink.close() }
            // Continue an interrupted upload: the child inherits this position.
            if inputOffset > 0 { try source.seek(toOffset: inputOffset) }
            let process = Process(), done = DispatchSemaphore(value: 0)
            let feed = pacer == nil ? nil : Pipe(), fed = Progress(), feeding = DispatchGroup()
            // A terminal opened during the upload is forked without descriptor hygiene (SwiftTerm, forkpty). With
            // the write end inherited there, closing ours would never reach the child as end of input.
            if let feed { for handle in [feed.fileHandleForReading, feed.fileHandleForWriting] { _ = fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC) } }
            process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            process.standardInput = feed ?? source; process.standardOutput = sink; process.standardError = errorSink
            process.terminationHandler = { _ in done.signal() }
            try cancellation.start(process)
            defer { cancellation.finish() }
            if let pacer, let feed {
                // The child has its own copy; with ours open a dead child would leave the writer blocked, not failed.
                try? feed.fileHandleForReading.close()
                let writer = feed.fileHandleForWriting, descriptor = writer.fileDescriptor
                _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
                _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
                feeding.enter()
                Thread.detachNewThread {
                    defer { try? writer.close(); feeding.leave() }
                    while let block = try? source.read(upToCount: 65_536), !block.isEmpty {
                        var offset = 0
                        while offset < block.count {
                            let granted = pacer.take(block.count - offset)
                            guard granted > 0, push(block.subdata(in: offset..<offset + granted), to: descriptor, progress: fed) else { return }
                            offset += granted; fed.add(granted)
                        }
                    }
                }
            }
            // The writer reads `source`, which the defer above closes: it must be gone before this returns.
            defer { fed.stop(); pacer?.cancel(); feeding.wait() }
            var finished = false
            let deadline = Date().addingTimeInterval(timeout)
            var lastMoved = Date(), lastFed: Int64 = -1, lastSize: Int64 = -1
            func sample() {
                // stdin is a duplicate of this open file description, so its
                // offset also tracks SSH reads when no pacing pipe is needed.
                let sent = feed == nil ? max(0, Int64(lseek(source.fileDescriptor, 0, SEEK_CUR))) : fed.total
                let size = ((try? fm.attributesOfItem(atPath: output.path))?[.size] as? NSNumber)?.int64Value ?? 0
                if sent != lastFed || size != lastSize {
                    lastFed = sent; lastSize = size; lastMoved = Date()
                    report?(FileProcessProgress(inputBytes: sent, outputBytes: size))
                }
            }
            sample()
            if stallTimeout != nil || report != nil {
                while true {
                    if done.wait(timeout: .now() + 0.2) == .success { finished = true; break }
                    sample()
                    if let stallTimeout, Date().timeIntervalSince(lastMoved) > stallTimeout { break }
                    if Date() > deadline { break }
                }
                sample()
            } else { finished = done.wait(timeout: .now() + timeout) == .success }
            if !finished {
                process.terminate()
                if done.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL); _ = done.wait(timeout: .now() + 2) }
                throw WorkspaceError.message("The file operation timed out. Check the server connection and try again.")
            }
            try cancellation.check()
            try sink.synchronize()
            guard process.terminationStatus == 0 else {
                let errorData = (try? Data(contentsOf: errors)) ?? Data()
                let message = String(decoding: errorData.suffix(8_000), as: UTF8.self)
                throw WorkspaceError.message(message.isEmpty ? "The file operation failed (\(process.terminationStatus))." : message)
            }
    }
}

public struct WorkspaceFileService: Sendable {
    public let profile: ServerProfile?
    public let socket: String?
    public let script: String
    public let cache: URL
    let sshConnection: WorkspaceSSHConnection?
    /// Set for servers that may sit behind the managed reverse tunnel; see `TransferPacer`.
    public let relay: TransferRelayLookup?
    /// A paced transfer runs at what the VPN path carries, so it is bounded by lack of progress, not by total time.
    static let pacedLimit: TimeInterval = 86_400, pacedStall: TimeInterval = 900
    public init(profile: ServerProfile?, socket: String?, script: String, cache: URL, relay: TransferRelayLookup? = nil) {
        self.profile = profile; self.socket = socket; self.script = script; self.cache = cache; self.relay = relay
        sshConnection = profile.flatMap { p in socket.map { WorkspaceSSHConnection(profile: p, socket: $0) } }
    }
    /// `bulk` marks a reply that can be large: behind the tunnel the server paces it (files.py, PacedOutput).
    /// A large request body is paced here the same way.
    func remote(_ request: [String: Any], destination: URL? = nil, timeout: TimeInterval = 120, bulk: Bool = false,
                progress: (@Sendable (FileProcessProgress) -> Void)? = nil) async throws -> Data {
        guard let sshConnection else { throw WorkspaceError.message("Connect to this server first.") }
        var request = request, input = try JSONSerialization.data(withJSONObject: request)
        let port = bulk || input.count > 65_536 ? await relay?() : nil
        if bulk, port != nil { request["paced"] = true; input = try JSONSerialization.data(withJSONObject: request) }
        let output = destination ?? cache.appendingPathComponent(UUID().uuidString)
        defer { if destination == nil { try? FileManager.default.removeItem(at: output) } }
        let command = "python3 -c " + SSHArguments.quote(script)
        do {
            try await sshConnection.run(command: command) { arguments in
                try await FileProcess.run("/usr/bin/ssh", arguments: arguments, input: input, output: output,
                                          timeout: port == nil ? timeout : max(timeout, Self.pacedLimit),
                                          pacer: port.flatMap { input.count > 65_536 ? TransferPacer(port: $0) : nil }, stallTimeout: port == nil ? nil : Self.pacedStall, progress: progress)
            }
        } catch {
            if destination != nil { try? FileManager.default.removeItem(at: output) }
            throw error
        }
        return destination == nil ? try Data(contentsOf: output) : Data()
    }
    public func list(_ path: String, showHidden: Bool = false) async throws -> WorkspaceListing {
        if profile != nil { return try JSONDecoder().decode(WorkspaceListing.self, from: await remote(["op": "list", "path": path, "hidden": showHidden])) }
        return try await Task.detached { try Self.localListing(path, showHidden: showHidden) }.value
    }
    private static func directoryStamp(_ path: String) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: WorkspacePath.local(path).path)
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(attributes[.systemFileNumber] ?? ""):\(modified)"
    }
    private static func localListing(_ path: String, showHidden: Bool) throws -> WorkspaceListing {
            let stamp = try directoryStamp(path)
            let root = WorkspacePath.local(path), fm = FileManager.default
            let urls = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey], options: showHidden ? [] : [.skipsHiddenFiles])
            let entries = urls.prefix(10_000).compactMap { url -> WorkspaceEntry? in
                // FileManager may canonicalize /var to /private/var in child
                // URLs. Keep the same spelling as the listed root for identity.
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) else { return nil }
                return WorkspaceEntry(path: (root.path as NSString).appendingPathComponent(url.lastPathComponent), name: url.lastPathComponent, directory: values.isDirectory ?? false, size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0)
            }.sorted { $0.directory != $1.directory ? $0.directory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return WorkspaceListing(path: root.path, entries: entries, truncated: urls.count > 10_000, stamp: stamp)
    }
    /// Working directories of remote terminal shells, by session token.
    public func terminalDirectories(_ sessions: [(pid: Int32, token: String)]) async throws -> [String: String] {
        guard profile != nil else { return [:] }
        return try JSONDecoder().decode([String: String].self, from: await remote(["op": "cwd", "sessions": sessions.map { ["pid": $0.pid, "token": $0.token] as [String: Any] }], timeout: 8))
    }
}
