import Foundation
import HarborCore

/// Finds the reverse-tunnel gateway relay that paces traffic to a server, so Harbor's own file
/// transfers can take tokens from it (`TransferPacer`). The gateway (gateway-shaper.py, started by
/// an optional user-managed service) lists relay addresses and ports in `/status`.
enum ManagedRelay {
    /// Optional local pacing service; absent on a standard installation.
    private static let status = URL(string: "http://127.0.0.1:10809/status")!
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2; configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }()
    private static let lock = NSLock()
    nonisolated(unsafe) private static var addresses: [String: String] = [:]

    /// nil when the gateway is not running or the server is not one of its tunnels.
    static func port(for profile: ServerProfile) async -> Int? {
        guard let (data, _) = try? await session.data(from: status),
              let relays = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return nil }
        let servers = relays.values.compactMap { relay -> (String, Int)? in
            guard let host = relay["host"] as? String, let port = relay["port"] as? Int else { return nil }
            return (host, port)
        }
        guard !servers.isEmpty else { return nil }
        let address = await address(of: profile.host)
        if let match = servers.first(where: { $0.0 == address || $0.0 == profile.host }) { return match.1 }
        // A HostName that is a DNS name for the server: compare what it resolves to.
        let resolved = await Task.detached(priority: .utility) { Self.addresses(named: address) }.value
        return servers.first { resolved.contains($0.0) }?.1
    }

    private static func addresses(named host: String) -> Set<String> {
        var hints = addrinfo(), list: UnsafeMutablePointer<addrinfo>?
        hints.ai_family = AF_INET; hints.ai_socktype = SOCK_STREAM
        guard getaddrinfo(host, nil, &hints, &list) == 0 else { return [] }
        defer { freeaddrinfo(list) }
        var found = Set<String>(), entry = list
        while let current = entry {
            var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(current.pointee.ai_addr, current.pointee.ai_addrlen, &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST) == 0 { found.insert(String(cString: text)) }
            entry = current.pointee.ai_next
        }
        return found
    }

    /// The HostName ssh would connect to: profiles usually name an alias from ~/.ssh/config.
    private static func address(of host: String) async -> String {
        if let known = lock.withLock({ addresses[host] }) { return known }
        let result = await ProcessRunner.run("/usr/bin/ssh", ["-G", "--", host], timeout: 5)
        let resolved = result.succeeded ? result.output.split(separator: "\n").first { $0.hasPrefix("hostname ") }.map { String($0.dropFirst(9)) } : nil
        guard let resolved else { return host }
        lock.withLock { addresses[host] = resolved }
        return resolved
    }
}
