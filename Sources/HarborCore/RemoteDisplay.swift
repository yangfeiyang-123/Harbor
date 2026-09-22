import Foundation

public enum SimulationPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case isaac, mujoco, gazebo, webots, desktop, web
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .isaac: return "Isaac Sim / Isaac Lab"
        case .mujoco: return "MuJoCo / PyBullet / Genesis"
        case .gazebo: return "Gazebo / ROS"
        case .webots: return "Webots"
        case .desktop: return "Remote Desktop / VNC"
        case .web: return "Custom Web Viewer"
        }
    }
    public var guidance: String {
        switch self {
        case .isaac: return "Start Isaac Sim with livestreaming enabled and use the web viewer URL supplied by your installation. Opens in Chrome or Edge. The media connection also needs VPN access to the streaming UDP port; an SSH web tunnel alone cannot carry it. A100 GPUs do not support Isaac Sim NVENC streaming."
        case .mujoco: return "Run the simulator in a GPU-capable remote desktop, then connect to its noVNC page or VNC port. A headless training process does not automatically create a viewer. GPU rendering must be configured on that desktop."
        case .gazebo: return "Connect to your deployed Gzweb frontend, with its WebSocket bridge reachable by the viewer. For the full Gazebo or RViz desktop, choose noVNC or VNC instead. A bridge port alone is not a viewer page."
        case .webots: return "Enable Webots web streaming and enter the viewer page URL. Any separate WebSocket endpoint must also be reachable through your VPN or server-side web proxy."
        case .desktop: return "Connect to an existing noVNC web desktop, or choose VNC to open macOS Screen Sharing through an SSH tunnel. Starting a display connection does not start or stop the remote simulator."
        case .web: return "Connect to a browser-based simulator, Viser viewer, or another interactive web app. Use the complete viewer URL. Separate WebSocket or media endpoints must be reachable as well."
        }
    }
    public var docs: URL {
        let value: String
        switch self {
        case .isaac: value = "https://docs.isaacsim.omniverse.nvidia.com/latest/installation/manual_livestream_clients.html"
        case .mujoco: value = "https://mujoco.readthedocs.io/en/stable/python.html#interactive-viewer"
        case .gazebo: value = "https://github.com/gazebo-web/gzweb"
        case .webots: value = "https://www.cyberbotics.com/doc/guide/web-streaming"
        case .desktop: value = "https://github.com/novnc/noVNC#quick-start"
        case .web: value = "https://viser.studio/"
        }
        return URL(string: value)!
    }
}

public enum DisplayClient: String, Codable, CaseIterable, Identifiable, Sendable {
    case embedded, chromium, vnc, isaac
    public var id: String { rawValue }
    public var title: String {
        switch self { case .embedded: return "In Harbor (Web / noVNC)"; case .chromium: return "Chrome / Edge (WebRTC)"; case .vnc: return "Screen Sharing (VNC)"; case .isaac: return "Harbor Isaac Viewer" }
    }
}

public struct RemoteDisplayProfile: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var serverID: UUID?
    public var name = "Remote Display"
    public var preset = SimulationPreset.desktop
    public var client = DisplayClient.embedded
    public var address = "http://127.0.0.1:6080/vnc.html?resize=remote"
    public var useSSHTunnel = true
    public var launch: SimulationLaunch?
    public init(serverID: UUID? = nil) { self.serverID = serverID }
    public var url: URL? { URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) }
    public var port: Int { url?.port ?? (client == .isaac ? 49100 : client == .vnc ? 5900 : url?.scheme == "https" ? 443 : 80) }
    public var validationError: String? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Enter a display name." }
        guard let url, let host = url.host, !host.isEmpty, SSHArguments.validHost(host.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")) else { return "Enter a complete viewer URL with a valid host." }
        guard url.user == nil, url.password == nil else { return "Enter credentials in the viewer, not in its saved URL." }
        guard (1...65535).contains(port) else { return "The display port must be between 1 and 65535." }
        if client == .isaac {
            guard url.scheme == "isaac", !useSSHTunnel else { return "Use isaac://host:49100 over your VPN, without an SSH media tunnel." }
            if let launch {
                guard serverID != nil, launch.directory.hasPrefix("/"), !launch.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Choose an SSH server, absolute project directory and launch command." }
            }
            return nil
        }
        guard client == .vnc ? url.scheme == "vnc" : ["http", "https"].contains(url.scheme ?? "") else { return client == .vnc ? "Use vnc://host:port for Screen Sharing." : "Use an http:// or https:// viewer URL." }
        if preset == .isaac && client == .embedded { return "Choose Chrome / Edge for the Isaac Sim WebRTC viewer." }
        if useSSHTunnel && serverID == nil { return "Choose an SSH server or turn off the SSH tunnel." }
        if useSSHTunnel && url.scheme == "https" { return "For HTTPS use the original URL over your VPN to preserve certificate verification, or tunnel a server-local HTTP endpoint." }
        return nil
    }
    public func localURL(port: Int) -> URL? {
        guard var parts = url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else { return nil }
        parts.host = "127.0.0.1"; parts.port = port
        return parts.url
    }
    public func tunnelArguments(server: ServerProfile, localPort: Int) -> [String] {
        var host = url?.host ?? "127.0.0.1"
        if host.contains(":"), !host.hasPrefix("[") { host = "[\(host)]" }
        return SSHArguments.connection(server) + ["-N", "-T", "-S", "none", "-o", "ControlMaster=no", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes", "-o", "ClearAllForwardings=no", "-o", "RemoteCommand=none", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "-L", "127.0.0.1:\(localPort):\(host):\(port)", "--", server.host]
    }
}

/// Optional to keep existing display catalogs compatible. Commands run only on Start & View.
public struct SimulationLaunch: Codable, Equatable, Sendable {
    public var directory: String
    public var command: String
    public init(directory: String, command: String = "./scripts/replay_remote.sh") {
        self.directory = directory; self.command = command
    }
}

public enum RemoteDisplayPersistence {
    public static func load(_ file: URL) throws -> [RemoteDisplayProfile] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([RemoteDisplayProfile].self, from: Data(contentsOf: file))
    }
    public static func save(_ profiles: [RemoteDisplayProfile], to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(profiles).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
