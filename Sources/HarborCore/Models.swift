import Foundation

public struct ServerProfile: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var user: String
    public var port: Int
    public var identityFile: String
    public var imported: Bool
    public var group: String
    public var useTmux: Bool
    public var recordOutput: Bool
    public var aliases: [String]?
    public var iconSymbol: String?
    public init(id: UUID = UUID(), name: String = "", host: String = "", user: String = "", port: Int = 22,
                identityFile: String = "", imported: Bool = false, group: String = "My Servers", useTmux: Bool = false, recordOutput: Bool = false) {
        self.id = id; self.name = name; self.host = host; self.user = user; self.port = port
        self.identityFile = identityFile; self.imported = imported; self.group = group
        self.useTmux = useTmux; self.recordOutput = recordOutput
    }
    public var destination: String { user.isEmpty ? host : "\(user)@\(host)" }
    public var validationError: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a server name." }
        if !SSHArguments.validHost(host) { return "Enter a valid hostname, IP address, or SSH alias." }
        if !user.isEmpty && !SSHArguments.validUser(user) { return "Usernames cannot contain spaces, control characters, or SSH arguments." }
        if !(1...65535).contains(port) { return "Ports must be between 1 and 65535." }
        if identityFile.contains("\n") || identityFile.contains("\0") { return "The identity file path is invalid." }
        return nil
    }
}

public enum ForwardKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case remote, local, dynamic
    public var id: String { rawValue }
    public var label: String {
        switch self { case .remote: return "Reverse Proxy / Remote Forwarding"; case .local: return "Local Port Forwarding"; case .dynamic: return "SOCKS Proxy" }
    }
}

public struct ForwardRule: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name = "Reverse Proxy"
    public var serverID: UUID
    public var kind: ForwardKind = .remote
    public var listenPort = 11080
    public var targetHost = "127.0.0.1"
    public var targetPort = 10810
    public var checkURL = "https://example.com"
    public init(serverID: UUID) { self.serverID = serverID }
    public var validationError: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a rule name." }
        if !(1...65535).contains(listenPort) || !(1...65535).contains(targetPort) { return "Ports must be between 1 and 65535." }
        if !SSHArguments.validHost(targetHost) { return "The target host is invalid." }
        if let url = URL(string: checkURL), ["http", "https"].contains(url.scheme ?? ""), url.host != nil { return nil }
        return "Enter a complete HTTP or HTTPS check URL."
    }
    public var summary: String {
        switch kind {
        case .remote: return "Server :\(listenPort) → Local \(targetHost):\(targetPort)"
        case .local: return "Local :\(listenPort) → Remote \(targetHost):\(targetPort)"
        case .dynamic: return "Local 127.0.0.1:\(listenPort) · SOCKS5"
        }
    }
}

public struct SessionRecord: Codable, Identifiable, Sendable {
    public var id: UUID
    public var serverID: UUID?
    public var serverName: String
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var exitCode: Int32?
    public var tmuxName: String?
    public var recorded: Bool
    public var workingDirectory: String?
    public init(id: UUID = UUID(), serverID: UUID?, serverName: String, title: String, tmuxName: String? = nil, recorded: Bool = true, workingDirectory: String? = nil) {
        self.id = id; self.serverID = serverID; self.serverName = serverName; self.title = title
        self.startedAt = Date(); self.tmuxName = tmuxName; self.recorded = recorded; self.workingDirectory = workingDirectory
    }
}

public enum SSHArguments {
    public static func validHost(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("-") && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:[]%").contains($0)
        }
    }
    public static func validUser(_ value: String) -> Bool {
        !value.hasPrefix("-") && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@").contains($0)
        }
    }
    public static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public static func connection(_ p: ServerProfile) -> [String] {
        guard !p.imported else { return [] }
        var a = ["-p", String(p.port)]
        if !p.user.isEmpty { a += ["-l", p.user] }
        if !p.identityFile.isEmpty { a += ["-i", NSString(string: p.identityFile).expandingTildeInPath, "-o", "IdentitiesOnly=yes"] }
        return a
    }
    public static func common(_ p: ServerProfile, socket: String) -> [String] {
        connection(p) + ["-S", socket, "-o", "ControlMaster=auto", "-o", "ControlPersist=8h",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=5", "-o", "TCPKeepAlive=no",
            "-o", "ConnectTimeout=30", "-o", "ClearAllForwardings=yes", "-o", "RemoteCommand=none"]
    }
    public static func terminal(_ p: ServerProfile, socket: String, tmuxName: String? = nil, requireMaster: Bool = false, workingDirectory: String? = nil, directoryToken: String? = nil) -> [String] {
        var a = requireMaster ? ["-o", "ProxyCommand=false", "-o", "ControlMaster=no"] : []
        a += common(p, socket: socket) + ["-tt", "--", p.host]
        if let name = tmuxName {
            let marker = directoryToken.map { "export HARBOR_SESSION_ID=" + quote($0) + "; printf '\\033]7778;%s;0\\007\\033]7777;%s;%s\\007' " + quote($0) + " " + quote($0) + " \"$$\"; " } ?? ""
            let cd = workingDirectory.map { "cd -- " + quote($0) + " || exit; " } ?? ""
            a.append("if command -v tmux >/dev/null 2>&1; then exec tmux new-session -A -s \(quote(name))\(workingDirectory.map { " -c " + quote($0) } ?? "") \\; set-option -t \(quote(name)) status off; else " + marker + "printf '\\n[Harbor: tmux is unavailable. Displayed output is saved locally; remote processes cannot survive disconnect.]\\n'; " + cd + "exec \"${SHELL:-/bin/sh}\" -l; fi")
        } else if let token = directoryToken {
            let marker = "export HARBOR_SESSION_ID=" + quote(token) + "; printf '\\033]7777;%s;%s\\007' " + quote(token) + " \"$$\"; "
            let cd = workingDirectory.map { "cd -- " + quote($0) + " || exit; " } ?? ""
            a.append(cd + marker + "exec \"${SHELL:-/bin/sh}\" -l")
        } else if let path = workingDirectory {
            a.append("cd -- " + quote(path) + " && exec \"${SHELL:-/bin/sh}\" -l")
        }
        return a
    }
    public static func probe(_ p: ServerProfile, socket: String, command: String = "printf HARBOR_SSH_READY") -> [String] {
        // ProxyCommand=false prevents an unhealthy socket from silently opening another TCP connection.
        ["-o", "ControlMaster=no", "-o", "ProxyCommand=false", "-o", "BatchMode=yes"] + common(p, socket: socket) + ["-T", "--", p.host, command]
    }
    public static func forward(_ r: ForwardRule, profile: ServerProfile) -> [String] {
        let host = r.targetHost.contains(":") && !r.targetHost.hasPrefix("[") ? "[\(r.targetHost)]" : r.targetHost
        var a = connection(profile) + ["-N", "-T", "-v", "-S", "none", "-o", "ControlMaster=no", "-o", "ControlPersist=no",
            "-o", "ClearAllForwardings=yes", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=5", "-o", "ConnectTimeout=30", "-o", "RemoteCommand=none"]
        // ClearAllForwardings would also clear our command-line forwards. The controller
        // rejects aliases that already contain forwarding directives before launching.
        a.removeSubrange((a.firstIndex(of: "ClearAllForwardings=yes")! - 1)...a.firstIndex(of: "ClearAllForwardings=yes")!)
        switch r.kind {
        case .remote: a += ["-R", "127.0.0.1:\(r.listenPort):\(host):\(r.targetPort)"]
        case .local: a += ["-L", "127.0.0.1:\(r.listenPort):\(host):\(r.targetPort)"]
        case .dynamic: a += ["-D", "127.0.0.1:\(r.listenPort)"]
        }
        return a + ["--", profile.host]
    }
}
