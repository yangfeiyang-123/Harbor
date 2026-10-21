import Foundation
import HarborCore

/// Every ssh Harbor runs without a terminal (checks, tunnels, forwards, the editor's own connection)
/// asks nothing. For a server that takes a password, that used to mean it could not connect at all;
/// with a password Harbor keeps for it, it now connects with that one (ServerPasswords.quiet).
extension ServerPasswords {
    /// The arguments and environment for such an ssh to `server`. Reading the keychain takes a
    /// moment, so it is done off the main thread.
    static func quietly(_ arguments: [String], server: UUID) async -> (arguments: [String], environment: [String: String]?) {
        let executable = TerminalTransport.executable
        return await Task.detached(priority: .utility) { ServerPasswords.quiet(arguments, server: server, executable: executable) }.value
    }
    /// `ProcessRunner.run` for such an ssh.
    static func runQuietly(_ arguments: [String], server: UUID, timeout: TimeInterval) async -> CommandResult {
        let quiet = await quietly(arguments, server: server)
        return await ProcessRunner.run("/usr/bin/ssh", quiet.arguments, timeout: timeout, environment: quiet.environment)
    }
}
