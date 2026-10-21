import Foundation
import CryptoKit
import HarborCore

/// Delivers the editor runtime to a server from this Mac, so the server never
/// has to reach GitHub. The Mac downloads the official release once, checks its
/// SHA-256, leaves out what Harbor prunes anyway (the built-in assistant and
/// its native runtime, about two thirds of the bytes) and sends the rest over
/// the ssh connection that is already open. An interrupted upload continues
/// where it stopped.
enum CodeRuntimePackage {
    struct Slim: Equatable, Sendable {
        let url: URL
        let digest: String
        let size: Int64
    }
    struct Manifest: Sendable {
        let version: String
        let digests: [String: String]
        /// Paths below the package directory that are left out; `*` matches within a name.
        let pruned: [String]
    }

    static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "app.harbor.ssh", isDirectory: true).appendingPathComponent("CodeOSS", isDirectory: true)
    }

    /// The release, checksums and prune lists are read from the service script itself, so the
    /// two can never disagree.
    static func manifest(script: String) throws -> Manifest {
        func strings(in name: String, closing: Character) -> [String] {
            guard let start = script.range(of: "\n" + name + " = "), let end = script[start.upperBound...].firstIndex(of: closing) else { return [] }
            let body = String(script[start.upperBound..<end])
            let pattern = try! NSRegularExpression(pattern: "\"([^\"]+)\"")
            return pattern.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap { Range($0.range(at: 1), in: body).map { String(body[$0]) } }
        }
        let version = strings(in: "VERSION", closing: "\n").first ?? ""
        let pairs = strings(in: "DIGESTS", closing: "}")
        var digests: [String: String] = [:]
        for index in stride(from: 0, to: pairs.count - 1, by: 2) { digests[pairs[index]] = pairs[index + 1] }
        let pruned = strings(in: "PRUNED_BUILTIN_EXTENSIONS", closing: ")").map { "lib/vscode/extensions/" + $0 } + strings(in: "PRUNED_RUNTIME_PATHS", closing: ")")
        guard !version.isEmpty, !digests.isEmpty, !pruned.isEmpty, digests.values.allSatisfy({ $0.count == 64 }) else {
            throw WorkspaceError.message("The editor service script does not describe its release.")
        }
        return Manifest(version: version, digests: digests, pruned: pruned)
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// "12.4 of 81 MB · 310 KB/s · about 4 min left"
    static func describeRate(_ rate: Double) -> String {
        rate >= 1_048_576 ? String(format: "%.1f MB/s", rate / 1_048_576) : String(format: "%.0f KB/s", rate / 1024)
    }
    static func describe(sent: Int64, total: Int64, rate: Double) -> String {
        var text = total > 0 ? String(format: "%.1f of %.0f MB", Double(sent) / 1_048_576, Double(total) / 1_048_576) : String(format: "%.1f MB", Double(sent) / 1_048_576)
        guard rate > 0 else { return text }
        text += rate >= 1_048_576 ? String(format: " · %.1f MB/s", rate / 1_048_576) : String(format: " · %.0f KB/s", rate / 1024)
        if total > sent {
            let minutes = Int(Double(total - sent) / rate / 60) + 1
            text += minutes >= 60 ? " · about \(minutes / 60) h \(minutes % 60) min left" : " · about \(minutes) min left"
        }
        return text
    }

    /// One build at a time for a platform. Two windows that open folders on servers which both
    /// lack the editor ask for the package at the same moment; side by side they wrote the same
    /// files, and one could record the digest of the other's half-written package. That package
    /// then failed every server's check, for good. The second waits for the first and finds its result.
    private actor Queue {
        private var last: [String: Task<Void, Never>] = [:]
        func add(_ key: String, _ work: @escaping @Sendable () async throws -> Slim) -> Task<Slim, Error> {
            let before = last[key]
            let task = Task<Slim, Error> { await before?.value; try Task.checkCancellation(); return try await work() }
            last[key] = Task { _ = await task.result }
            return task
        }
    }
    private static let queue = Queue()

    /// The trimmed package for `target` ("linux-amd64"), built once and kept in the cache.
    static func slim(target: String, manifest: Manifest, xz: Bool, cache: URL = cacheDirectory,
                     report: @escaping @Sendable (String, Double?, String?) -> Void) async throws -> Slim {
        let task = await queue.add(cache.path + "\n" + target) { try await build(target: target, manifest: manifest, xz: xz, cache: cache, report: report) }
        // Stopping the opening stops its own turn (a download under way), not another window's.
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// What the note beside a package says: its digest, and its size since Harbor writes that too.
    static func note(_ url: URL) -> (digest: String, size: Int64?)? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let fields = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let digest = fields.first, digest.count == 64 else { return nil }
        return (digest, fields.count > 1 ? Int64(fields[1]) : nil)
    }

    private static func build(target: String, manifest: Manifest, xz: Bool, cache: URL,
                              report: @escaping @Sendable (String, Double?, String?) -> Void) async throws -> Slim {
        guard let official = manifest.digests[target] else { throw WorkspaceError.message("Code-OSS has no release for \(target).") }
        let name = "code-server-\(manifest.version)-\(target)"
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // The name carries everything the content depends on: release, prune list and compression.
        let recipe = SHA256.hash(data: Data((official + manifest.pruned.joined(separator: "\n") + (xz ? "xz" : "gz")).utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        let slim = cache.appendingPathComponent("\(name).slim-\(recipe).tar.\(xz ? "xz" : "gz")"), note = slim.appendingPathExtension("sha256")
        if let known = Self.note(note), let size = ((try? FileManager.default.attributesOfItem(atPath: slim.path))?[.size] as? NSNumber)?.int64Value, size > 0 {
            // The note has to be about this very file. One written by an earlier Harbor names no
            // size, and is checked against the file once; a package that is not what its note
            // says (see the queue above) is built again instead of being sent, and refused, for ever.
            var matches = known.size == size
            if known.size == nil, (try? await digest(of: slim)) == known.digest {
                try? (known.digest + " " + String(size)).write(to: note, atomically: true, encoding: .utf8); matches = true
            }
            if matches {
                sweep(cache, target: target, keeping: [slim, note])
                return Slim(url: slim, digest: known.digest, size: size)
            }
            try? FileManager.default.removeItem(at: slim); try? FileManager.default.removeItem(at: note)
        }
        let archive = cache.appendingPathComponent(name + ".tar.gz")
        let cached = FileManager.default.fileExists(atPath: archive.path) ? try? await digest(of: archive) : nil
        if cached != official {
            try? FileManager.default.removeItem(at: archive)
            let url = URL(string: "https://github.com/coder/code-server/releases/download/v\(manifest.version)/\(name).tar.gz")!
            try await download(url, to: archive) { received, total, rate in
                report("Downloading Code-OSS to this Mac", total > 0 ? Double(received) / Double(total) : nil, describe(sent: received, total: total, rate: rate))
            }
            guard try await digest(of: archive) == official else {
                try? FileManager.default.removeItem(at: archive)
                throw WorkspaceError.message("The editor download did not pass its SHA-256 check.")
            }
        }
        report("Preparing the editor package", nil, "Leaving out the built-in assistant")
        let building = cache.appendingPathComponent(slim.lastPathComponent + ".building")
        try? FileManager.default.removeItem(at: building)
        // bsdtar copies entries from one archive into another; nothing is unpacked on this Mac.
        var arguments = xz ? ["--options", "xz:compression-level=6,xz:threads=0", "-cJf", building.path] : ["-czf", building.path]
        for path in manifest.pruned { arguments += ["--exclude", name + "/" + path] }
        arguments.append("@" + archive.path)
        let result = await ProcessRunner.run("/usr/bin/tar", arguments, timeout: 900)
        guard result.succeeded else {
            try? FileManager.default.removeItem(at: building)
            throw WorkspaceError.message("The editor package could not be prepared. " + result.output.suffix(400))
        }
        let digest = try await digest(of: building)
        let size = ((try FileManager.default.attributesOfItem(atPath: building.path))[.size] as? NSNumber)?.int64Value ?? 0
        try? FileManager.default.removeItem(at: note)
        try? FileManager.default.removeItem(at: slim)
        try FileManager.default.moveItem(at: building, to: slim)
        try (digest + " " + String(size)).write(to: note, atomically: true, encoding: .utf8)
        // The full release is only the source of the trimmed one.
        try? FileManager.default.removeItem(at: archive)
        sweep(cache, target: target, keeping: [slim, note])
        return Slim(url: slim, digest: digest, size: size)
    }

    /// Packages of earlier releases or prune lists for the same platform are of no further use:
    /// a server is only ever sent the current one. Each is tens of megabytes.
    static func sweep(_ cache: URL, target: String, keeping: [URL]) {
        let kept = Set(keeping.map(\.lastPathComponent))
        for file in (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? [] {
            let name = file.lastPathComponent
            guard name.hasPrefix("code-server-"), name.contains("-" + target + "."), !kept.contains(name) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func digest(of url: URL) async throws -> String {
        try await Task.detached(priority: .utility) { try sha256(of: url) }.value
    }

    private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let report: @Sendable (Int64, Int64, Double) -> Void
        private let started = Date()
        private var last = Date.distantPast
        init(report: @escaping @Sendable (Int64, Int64, Double) -> Void) { self.report = report }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            let now = Date()
            guard now.timeIntervalSince(last) >= 0.5 else { return }
            last = now
            let elapsed = now.timeIntervalSince(started)
            report(totalBytesWritten, max(0, totalBytesExpectedToWrite), elapsed >= 2 ? Double(totalBytesWritten) / elapsed : 0)
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }

    private static func download(_ url: URL, to destination: URL, report: @escaping @Sendable (Int64, Int64, Double) -> Void) async throws {
        var request = URLRequest(url: url); request.setValue("Harbor", forHTTPHeaderField: "User-Agent"); request.timeoutInterval = 60
        let (file, response) = try await URLSession.shared.download(for: request, delegate: DownloadProgress(report: report))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            try? FileManager.default.removeItem(at: file)
            throw WorkspaceError.message("GitHub did not provide the editor release (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: file, to: destination)
    }

    /// SHA-256 of the first `count` bytes of a file: what a server must already hold for an upload to continue.
    static func sha256(of url: URL, upTo count: Int64) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hasher = SHA256(), left = count
        while left > 0, let chunk = try handle.read(upToCount: Int(min(left, 1 << 20))), !chunk.isEmpty { hasher.update(data: chunk); left -= Int64(chunk.count) }
        guard left == 0 else { throw WorkspaceError.message("The editor package is shorter than expected.") }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// What the receiver prints when another upload of the same package holds the file.
    static let uploadBusy = "harbor-upload-busy"
    /// What it prints when the server's copy is not the start of this package.
    static let uploadMismatch = "harbor-upload-mismatch"
    /// How long the receiver waits for more bytes before it lets go of the file. A connection that
    /// died without saying so (a tunnel that dropped while the Mac slept) would otherwise keep the
    /// file, and every other upload waiting, until the server's TCP timeout hours later.
    static let uploadIdle = 180
    /// Runs on the server and appends stdin to its copy of the package. One writer at a time: two
    /// windows once sent the same package into one file, and the mixture had the right size.
    /// A new upload records which package it is; a continued one must find that package's own
    /// first `offset` bytes there (checked by digest, not only by size) or it is refused.
    /// Exit 6: no bytes arrived for `idle` seconds; 7: another upload is writing; 8: cannot write there; 9: mismatch.
    private static let receiver = """
    import fcntl, hashlib, os, select, sys
    directory, name, digest, offset, prefix, idle = sys.argv[2:8]; offset = int(offset); idle = float(idle)
    os.umask(0o077)
    try: os.makedirs(directory, exist_ok=True)
    except OSError: sys.exit(8)
    part = os.path.join(directory, name + ".slim.part"); note = os.path.join(directory, name + ".slim.sha256")
    try:
        lock = open(os.path.join(directory, name + ".slim.lock"), "a")
    except OSError: sys.exit(8)
    try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("\(uploadBusy)", file=sys.stderr); sys.exit(7)
    if offset == 0:
        try:
            with open(note, "w") as f: f.write(digest)
            open(part, "wb").close()
        except OSError: sys.exit(8)
    else:
        known = ""; seen = hashlib.sha256(); size = -1
        try:
            with open(note) as f: known = f.read().strip()
            size = 0
            with open(part, "rb") as f:
                for block in iter(lambda: f.read(1 << 20), b""):
                    seen.update(block); size += len(block)
        except OSError: size = -1
        if known != digest or size != offset or seen.hexdigest() != prefix:
            print("\(uploadMismatch)", file=sys.stderr); sys.exit(9)
    out = os.open(part, os.O_WRONLY | os.O_APPEND)
    while True:
        if not select.select([0], [], [], idle)[0]:
            print("harbor-upload-idle", file=sys.stderr); sys.exit(6)
        block = os.read(0, 65536)
        if not block: break
        view = memoryview(block)
        while view: view = view[os.write(out, view):]
    """

    /// Appends the package to the server's copy from `offset`; `prefix` is the digest of the bytes
    /// before it.
    static func uploadCommand(directory: String, name: String, digest: String, offset: Int64, prefix: String = "", idle: Double = Double(uploadIdle)) -> String {
        // One line with nothing a login shell (fish, csh) could read differently: the script travels encoded.
        let script = Data(receiver.utf8).base64EncodedString()
        let arguments = [script, directory, name, digest, String(offset), prefix.isEmpty ? "-" : prefix, String(idle)].map(SSHArguments.quote).joined(separator: " ")
        return "sh -c " + SSHArguments.quote("exec python3 -c \"import base64,sys;exec(base64.b64decode(sys.argv[1]))\" " + arguments)
    }
}
