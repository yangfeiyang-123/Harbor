import Foundation
import Network

/// Stands between the editor's web view and a server's Code-OSS. The editor's
/// own program (about 6 MB compressed, 20 MB of JavaScript) is the same on every
/// machine for one Harbor version, and this Mac already has it, so those files
/// are answered from the local copy; opening a folder on a server then costs the
/// link only the folder's own data. Everything else — pages, requests, the
/// connection to the extension host — passes through untouched.
final class WorkbenchStaticProxy: @unchecked Sendable {
    let port: Int
    private let upstream: NWEndpoint.Port
    private let assets: URL
    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.harbor.static-proxy")
    private static let terminator = Data("\r\n\r\n".utf8)
    /// Only program files: anything that could carry per-server headers (pages) is left to the server.
    private static let types = ["js": "text/javascript; charset=utf-8", "css": "text/css; charset=utf-8", "wasm": "application/wasm", "ttf": "font/ttf",
                                "woff": "font/woff", "woff2": "font/woff2", "svg": "image/svg+xml", "png": "image/png", "json": "application/json; charset=utf-8",
                                "map": "application/json; charset=utf-8"]

    /// `assets` is the local runtime's lib/vscode directory.
    init(port: Int, upstream: Int, assets: URL) throws {
        guard let listen = NWEndpoint.Port(rawValue: UInt16(clamping: port)), let target = NWEndpoint.Port(rawValue: UInt16(clamping: upstream)) else { throw POSIXError(.EINVAL) }
        self.port = port; self.upstream = target; self.assets = assets.resolvingSymlinksInPath()
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: listen)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue); self.readHead(connection, buffer: Data())
        }
        listener.start(queue: queue)
    }
    func stop() { listener.cancel() }
    deinit { listener.cancel() }

    /// The local file for a request path such as `/stable-<commit>/static/out/vs/…/workbench.js`.
    func localFile(for target: String) -> URL? {
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 4, parts[1] == "static", ["out", "node_modules"].contains(parts[2]),
              !parts.contains(where: { $0 == ".." || $0 == "." || $0.contains("\\") || $0.contains("%") }),
              let last = parts.last, let dot = last.lastIndex(of: "."), Self.types[String(last[last.index(after: dot)...]).lowercased()] != nil else { return nil }
        let file = assets.appendingPathComponent(parts[2...].joined(separator: "/")).resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard file.path.hasPrefix(assets.path + "/"), FileManager.default.fileExists(atPath: file.path, isDirectory: &directory), !directory.boolValue else { return nil }
        return file
    }

    private func readHead(_ client: NWConnection, buffer: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { client.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Self.terminator) {
                self.route(client, head: buffer.subdata(in: buffer.startIndex..<end.upperBound), rest: buffer.subdata(in: end.upperBound..<buffer.endIndex))
            } else if buffer.count > 128 * 1024 {
                // Not a request this proxy understands: hand the bytes on as they are.
                self.tunnel(client, first: buffer)
            } else if complete || error != nil { client.cancel() }
            else { self.readHead(client, buffer: buffer) }
        }
    }

    private func route(_ client: NWConnection, head: Data, rest: Data) {
        let text = String(decoding: head, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        let request = lines.first?.split(separator: " ").map(String.init) ?? []
        let names = lines.dropFirst().map { $0.split(separator: ":", maxSplits: 1).first.map { $0.lowercased() } ?? "" }
        if request.count == 3, request[0] == "GET", rest.isEmpty, let file = localFile(for: request[1]), let body = try? Data(contentsOf: file, options: .mappedIfSafe) {
            let type = Self.types[file.pathExtension.lowercased()] ?? "application/octet-stream"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: public, max-age=31536000, immutable\r\nX-Harbor-Source: local\r\nConnection: keep-alive\r\n\r\n"
            client.send(content: Data(response.utf8) + body, completion: .contentProcessed { [weak self] error in
                if error != nil { client.cancel() } else { self?.readHead(client, buffer: Data()) }
            })
            return
        }
        if names.contains("upgrade") { tunnel(client, first: head + rest); return }
        // One request per connection, so the next one is read (and possibly answered locally) again.
        lines.removeAll { line in ["connection:", "keep-alive:"].contains { line.lowercased().hasPrefix($0) } }
        lines.insert("Connection: close", at: min(1, lines.count))
        tunnel(client, first: Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8) + rest)
    }

    private func tunnel(_ client: NWConnection, first: Data) {
        let server = NWConnection(host: .ipv4(.loopback), port: upstream, using: .tcp)
        server.stateUpdateHandler = { state in
            // Nothing listening upstream (the forward is gone with its connection) leaves a loopback
            // connection waiting, not failed. The page is told at once, and nothing is left open:
            // it used to hang on every attempt it made while the connection was down.
            switch state {
            case .failed, .waiting: client.cancel(); server.cancel()
            default: break
            }
        }
        server.start(queue: queue)
        server.send(content: first, completion: .contentProcessed { error in if error != nil { client.cancel(); server.cancel() } })
        pump(from: client, to: server); pump(from: server, to: client)
    }

    private func pump(from source: NWConnection, to sink: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            if let data, !data.isEmpty {
                sink.send(content: data, completion: .contentProcessed { sendError in
                    if sendError != nil { source.cancel(); sink.cancel() }
                    else if complete || error != nil { sink.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in }) }
                    else { self?.pump(from: source, to: sink) }
                })
            } else if complete || error != nil {
                // The sender is done: finish the other direction's stream, then let both go.
                sink.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in sink.cancel(); source.cancel() })
            } else { self?.pump(from: source, to: sink) }
        }
    }
}
