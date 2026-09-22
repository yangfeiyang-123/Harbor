import Foundation

/// Byte-oriented filtering preserves UTF-8 split across arbitrary PTY reads and strips terminal control payloads.
public struct TranscriptFilter {
    private enum State { case text, escape, csi, string, stringEscape, charset }
    private var state = State.text
    private var lastWasCR = false
    public init() {}
    public mutating func consume(_ data: Data) -> Data {
        var result = Data()
        for byte in data {
            switch state {
            case .text:
                if byte == 0x1b { state = .escape }
                else if byte == 13 { result.append(10); lastWasCR = true }
                else if byte == 10 { if !lastWasCR { result.append(10) }; lastWasCR = false }
                else { lastWasCR = false; if byte >= 32 || byte == 9 { if byte != 127 { result.append(byte) } } }
            case .escape:
                if byte == 91 { state = .csi }
                else if [93, 80, 94, 95, 88].contains(byte) { state = .string }
                else if [40, 41, 42, 43, 35, 37].contains(byte) { state = .charset }
                else { state = .text }
            case .csi: if (0x40...0x7e).contains(byte) { state = .text }
            case .string: if byte == 7 { state = .text } else if byte == 27 { state = .stringEscape }
            case .stringEscape: state = byte == 92 ? .text : .string
            case .charset: state = .text
            }
        }
        return result
    }
}

public final class TranscriptWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.harbor.transcript", qos: .utility)
    private var filter = TranscriptFilter()
    private var commandFilter = CommandTranscriptFilter()
    private var commandHandle: FileHandle?
    private var commandSize = 0
    private var handle: FileHandle?
    private var size = 0
    private let limit: Int
    private var capped = false
    public init(url: URL, limit: Int = 25_000_000) throws {
        self.limit = limit
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        handle = try FileHandle(forWritingTo: url)
        size = Int(try handle!.seekToEnd())
        let commandURL = url.deletingPathExtension().appendingPathExtension("commands.log")
        if !FileManager.default.fileExists(atPath: commandURL.path) {
            _ = FileManager.default.createFile(atPath: commandURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        commandHandle = try FileHandle(forWritingTo: commandURL)
        commandSize = Int(try commandHandle!.seekToEnd())
    }
    public func append(_ data: Data) {
        queue.async { [self] in
            guard let handle, !capped else { return }
            let clean = filter.consume(data)
            let commands = commandFilter.consume(data)
            let available = max(0, limit - size)
            let content = clean.prefix(available)
            do {
                try handle.write(contentsOf: content); size += content.count
                if let commandHandle {
                    try commandHandle.seek(toOffset: UInt64(commandSize))
                    let committed = commands.prefix(max(0, limit - commandSize))
                    try commandHandle.write(contentsOf: committed); commandSize += committed.count
                    let pending = commandFilter.pending.prefix(max(0, limit - commandSize))
                    try commandHandle.write(contentsOf: pending)
                    try commandHandle.truncate(atOffset: UInt64(commandSize + pending.count))
                }
                if clean.count > available {
                    try handle.write(contentsOf: Data("\n[Harbor: This session reached the 25 MB recording limit. Further output was not saved.]\n".utf8)); capped = true
                }
            } catch { capped = true }
        }
    }
    public func flush() { queue.sync { try? handle?.synchronize(); try? commandHandle?.synchronize() } }
    public func close() { queue.sync { try? handle?.close(); handle = nil; try? commandHandle?.close(); commandHandle = nil } }
    deinit { try? handle?.close(); try? commandHandle?.close() }
}

public final class HistoryStore: @unchecked Sendable {
    public let root: URL
    public let logs: URL
    public init(location: URL) {
        self.root = location; logs = location.appendingPathComponent("Transcripts", isDirectory: true)
    }
    public convenience init(root: URL) throws {
        self.init(location: root)
        try prepare()
    }
    public func prepare() throws {
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }
    public func logURL(_ id: UUID) -> URL { logs.appendingPathComponent(id.uuidString).appendingPathExtension("log") }
    public func commandLogURL(_ id: UUID) -> URL { logs.appendingPathComponent(id.uuidString).appendingPathExtension("commands.log") }
    public func commandTranscript(_ id: UUID) -> String {
        let url = commandLogURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return transcript(id) }
        return readTranscript(url, limit: 2_000_000)
    }
    public func read<T: Decodable>(_ name: String, as type: T.Type) throws -> T? {
        let url = root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    public func write<T: Encodable>(_ value: T, name: String) throws {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = root.appendingPathComponent(name)
        try e.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func transcript(_ id: UUID, limit: Int = 2_000_000) -> String {
        readTranscript(logURL(id), limit: limit)
    }
    private func readTranscript(_ url: URL, limit: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "Terminal output was not recorded for this session." }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > limit ? size - UInt64(limit) : 0
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        return (offset > 0 ? "[Showing the latest 2 MB. Export to read the full record.]\n\n" : "") + String(decoding: data, as: UTF8.self)
    }
    public func search(_ records: [SessionRecord], query: String) -> [UUID] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return records.filter { record in
            if q.isEmpty || record.serverName.localizedCaseInsensitiveContains(q) || record.title.localizedCaseInsensitiveContains(q) { return true }
            return [commandLogURL(record.id), logURL(record.id)].contains { url in
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
                return String(decoding: data, as: UTF8.self).localizedCaseInsensitiveContains(q)
            }
        }.map(\.id)
    }
    public func delete(_ record: SessionRecord) throws {
        let url = logURL(record.id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let commandURL = commandLogURL(record.id)
        if FileManager.default.fileExists(atPath: commandURL.path) { try FileManager.default.removeItem(at: commandURL) }
    }
}
