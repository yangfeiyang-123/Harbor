import Foundation
import Network
import HarborCore

/// Serves bundled, read-only viewer assets on loopback. It exposes no commands or filesystem API.
@MainActor final class IsaacViewerServer {
    /// NVIDIA's separately licensed viewer can be installed by the user.
    /// The default public bundle contains a setup page, not NVIDIA binaries.
    private let optionalViewerDirectory: URL
    init(optionalViewerDirectory: URL? = nil) {
        self.optionalViewerDirectory = optionalViewerDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/HarborSSH/IsaacViewer", isDirectory: true)
    }
    var assetDirectory: URL {
        let index = optionalViewerDirectory.appendingPathComponent("index.html")
        if FileManager.default.isReadableFile(atPath: index.path) { return optionalViewerDirectory }
        return AppResources.directory("Simulation").appendingPathComponent("viewer")
    }
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private let token = UUID().uuidString
    private(set) var port: UInt16?
    func start() async throws {
        if port != nil { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var finished = false
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                switch state {
                case .ready:
                    guard !finished else { return }; finished = true
                    self?.port = listener.port?.rawValue; continuation.resume()
                case .failed(let error):
                    guard !finished else { return }; finished = true; continuation.resume(throwing: error)
                case .cancelled:
                    guard !finished else { return }; finished = true; continuation.resume(throwing: CancellationError())
                default: break
                }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                guard let self, self.connections.count < 24 else { connection.cancel(); return }
                let id = UUID(); self.connections[id] = connection
                connection.start(queue: .main); self.receive(connection, id: id, buffer: Data())
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.connections.removeValue(forKey: id)?.cancel() }
                }
            }
            listener.start(queue: .main)
        }
    }
    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor in
            guard let self else { connection.cancel(); return }
            var request = buffer; request.append(data ?? Data())
            if request.count > 8192 || error != nil { self.connections.removeValue(forKey: id)?.cancel(); return }
            guard request.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if complete { self.connections.removeValue(forKey: id)?.cancel() }
                else { self.receive(connection, id: id, buffer: request) }; return
            }
            let fields = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")[0].split(separator: " ")
            var body = Data("Not found".utf8), code = "404 Not Found", mime = "text/plain"
            if fields.count == 3, fields[0] == "GET" {
                let path = String(fields[1]).components(separatedBy: "?")[0]
                let prefix = "/\(self.token)/"
                if path.hasPrefix(prefix) {
                    let relative = String(path.dropFirst(prefix.count))
                    if relative == "health" {
                        body = Data("ok".utf8); code = "200 OK"
                    } else if !relative.contains(".."), !relative.contains("%"), !relative.contains("\\") {
                        let root = self.assetDirectory.resolvingSymlinksInPath()
                        let file = root.appendingPathComponent(relative.isEmpty ? "index.html" : relative).resolvingSymlinksInPath()
                        if file.path.hasPrefix(root.path + "/"), let bytes = try? Data(contentsOf: file), bytes.count < 20_000_000 {
                            body = bytes; code = "200 OK"
                            mime = ["html":"text/html", "js":"text/javascript", "css":"text/css", "svg":"image/svg+xml", "txt":"text/plain"][file.pathExtension] ?? "application/octet-stream"
                        }
                    }
                }
            }
            var response = Data("HTTP/1.1 \(code)\r\nContent-Type: \(mime)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n".utf8)
            response.append(body)
            connection.send(content: response, completion: .contentProcessed { [weak self] _ in
                Task { @MainActor in connection.cancel(); self?.connections.removeValue(forKey: id) }
            })
            }
        }
    }
    func url(profile: RemoteDisplayProfile) -> URL? {
        guard let port else { return nil }
        var query = URLComponents()
        query.queryItems = [URLQueryItem(name: "host", value: profile.url?.host), URLQueryItem(name: "port", value: String(profile.port)), URLQueryItem(name: "name", value: profile.name)]
        var url = URLComponents(string: "http://127.0.0.1:\(port)/\(token)/")!
        url.percentEncodedFragment = query.percentEncodedQuery
        return url.url
    }
    func stop() {
        listener?.cancel(); listener = nil; port = nil
        for connection in connections.values { connection.cancel() }; connections.removeAll()
    }
}
