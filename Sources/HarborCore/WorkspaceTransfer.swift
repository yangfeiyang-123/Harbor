import Foundation
import Darwin

/// A bounded, streamed file tree. Only regular files, directories and safe
/// relative symlinks are supported; no archive member can escape its staging root.
public enum WorkspaceTransfer {
    public struct Record: Codable {
        var path: String
        var kind: String
        var size: Int64 = 0
        var mode: Int = 0o644
        var link: String? = nil
    }
    static func exact(_ handle: FileHandle, _ count: Int) throws -> Data {
        var result = Data()
        while result.count < count {
            guard let next = try handle.read(upToCount: count - result.count), !next.isEmpty else { throw WorkspaceError.message("The transfer did not complete. Try again.") }
            result.append(next)
        }
        return result
    }
    static func writeRecord(_ record: Record, to handle: FileHandle) throws {
        let data = try JSONEncoder().encode(record)
        guard data.count <= 65_536 else { throw WorkspaceError.message("The file path is too long.") }
        var length = UInt32(data.count).bigEndian
        try withUnsafeBytes(of: &length) { try handle.write(contentsOf: Data($0)) }
        try handle.write(contentsOf: data)
    }
    public static func export(_ source: URL, to archive: URL) throws {
        let fm = FileManager.default
        fm.createFile(atPath: archive.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: archive); defer { try? output.close() }
        func append(_ url: URL, relative: String, depth: Int) throws {
            guard depth < 128 else { throw WorkspaceError.message("The folder nesting is too deep.") }
            try Task.checkCancellation()
            let attributes = try fm.attributesOfItem(atPath: url.path)
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
            switch attributes[.type] as? FileAttributeType {
            case .typeDirectory:
                try writeRecord(Record(path: relative, kind: "directory", mode: mode), to: output)
                for name in try fm.contentsOfDirectory(atPath: url.path).sorted() {
                    try append(url.appendingPathComponent(name), relative: relative + "/" + name, depth: depth + 1)
                }
            case .typeRegular:
                let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                guard fd >= 0 else { throw POSIXError(.EIO) }
                let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? input.close() }
                var info = stat(); guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw WorkspaceError.message("The file type has changed.") }
                let size = Int64(info.st_size)
                try writeRecord(Record(path: relative, kind: "file", size: size, mode: mode), to: output)
                var left = size
                while left > 0 { let data = try exact(input, Int(min(left, 1_048_576))); try output.write(contentsOf: data); left -= Int64(data.count) }
            case .typeSymbolicLink:
                try writeRecord(Record(path: relative, kind: "symlink", mode: mode, link: fm.destinationOfSymbolicLink(atPath: url.path)), to: output)
            default: throw WorkspaceError.message("Sockets, devices, and other special files cannot be transferred.")
            }
        }
        try append(source, relative: "item", depth: 0)
        try output.write(contentsOf: Data(repeating: 0, count: 4))
    }
    public static func extract(_ archive: URL, into staging: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let input = try FileHandle(forReadingFrom: archive); defer { try? input.close() }
        var seen = Set<String>(), directories = [String: Int](), records = 0
        while true {
            try Task.checkCancellation()
            let prefix = try exact(input, 4)
            let count = prefix.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            if count == 0 { break }
            guard count <= 65_536 else { throw WorkspaceError.message("The transfer format is invalid.") }
            let record = try JSONDecoder().decode(Record.self, from: exact(input, Int(count)))
            let parts = record.path.components(separatedBy: "/")
            records += 1
            guard records <= 1_000_000, parts.first == "item", !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("\0") }), seen.insert(record.path).inserted,
                  parts.count == 1 || directories[(record.path as NSString).deletingLastPathComponent] != nil else { throw WorkspaceError.message("The transfer contains an invalid path.") }
            let url = staging.appendingPathComponent(record.path)
            switch record.kind {
            case "directory":
                try fm.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); directories[record.path] = record.mode & 0o777
            case "file":
                guard record.size >= 0 else { throw WorkspaceError.message("The file size is invalid.") }
                let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                guard fd >= 0 else { throw POSIXError(.EIO) }
                let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                do {
                    var left = record.size
                    while left > 0 { let data = try exact(input, Int(min(left, 1_048_576))); try output.write(contentsOf: data); left -= Int64(data.count) }
                    try output.close(); try fm.setAttributes([.posixPermissions: record.mode & 0o777], ofItemAtPath: url.path)
                } catch { try? output.close(); throw error }
            case "symlink":
                guard let link = record.link, !link.hasPrefix("/"), !link.contains("\0") else { throw WorkspaceError.message("Symbolic links outside the directory cannot be transferred.") }
                let resolved = url.deletingLastPathComponent().appendingPathComponent(link).standardizedFileURL.path
                let root = staging.appendingPathComponent("item").path
                guard resolved == root || resolved.hasPrefix(root + "/") else { throw WorkspaceError.message("Symbolic links outside the directory cannot be transferred.") }
                try fm.createSymbolicLink(atPath: url.path, withDestinationPath: link)
            default: throw WorkspaceError.message("The transfer type is invalid.")
            }
        }
        guard seen.contains("item"), (try input.read(upToCount: 1) ?? Data()).isEmpty else { throw WorkspaceError.message("The transfer data is incomplete.") }
        for (path, mode) in directories.sorted(by: { $0.key.count > $1.key.count }) { try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: staging.appendingPathComponent(path).path) }
        return staging.appendingPathComponent("item")
    }
    public static func destination(name: String, parent: String, copy: Bool) throws -> URL {
        var path = try WorkspacePath.child(name, in: parent)
        if copy {
            let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
            var index = 1
            while exists(path) { let label = stem + " copy" + (index == 1 ? "" : " \(index)") + (ext.isEmpty ? "" : "." + ext); path = try WorkspacePath.child(label, in: parent); index += 1 }
        } else if exists(path) { throw WorkspaceError.message("An item with this name already exists at the destination. It was not overwritten.") }
        return URL(fileURLWithPath: path)
    }
    static func exists(_ path: String) -> Bool { var info = stat(); return lstat(path, &info) == 0 }
    public static func moveWithoutReplacing(_ source: URL, to destination: URL) throws {
        if renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return }
        let code = errno
        guard code == EXDEV else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".harbor-move-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let candidate = staging.appendingPathComponent("item")
        try fm.copyItem(at: source, to: candidate)
        try moveWithoutReplacing(candidate, to: destination)
        try fm.removeItem(at: source)
    }
}
