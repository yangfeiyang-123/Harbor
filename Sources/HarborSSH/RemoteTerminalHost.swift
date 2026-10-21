import Foundation
import CryptoKit
import HarborCore

/// Versioned, user-owned stdlib helper. SSH only transports bytes; the remote
/// process owns its PTY independently of the connection and app lifecycle.
enum RemoteTerminalHost {
    static func command(id: UUID, mode: String, directory: String?, rows: Int = 24, columns: Int = 80, framed: Bool = false) throws -> String {
        guard ["create", "attach", "close"].contains(mode) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let url = AppResources.directory("WorkspaceRuntime").appendingPathComponent("terminal_host.py")
        let data = try Data(contentsOf: url)
        let hash = SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
        let bootstrap = """
        import os,sys,stat,base64
        os.environ['HARBOR_UMASK']='%o'%os.umask(0o077)
        root='/tmp/harbor-pty-'+str(os.getuid())
        try: os.mkdir(root,0o700)
        except FileExistsError: pass
        s=os.lstat(root)
        if not stat.S_ISDIR(s.st_mode) or s.st_uid!=os.getuid() or s.st_mode&0o077: raise RuntimeError('Unsafe terminal storage directory')
        path=root+'/host-\(hash).py'
        if not os.path.exists(path):
            tmp=path+'.'+str(os.getpid())
            fd=os.open(tmp,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
            with os.fdopen(fd,'wb') as f: f.write(base64.b64decode('\(data.base64EncodedString())'))
            os.replace(tmp,path)
        os.execv(sys.executable,[sys.executable,path]+sys.argv[2:])
        """
        var args = [Data(bootstrap.utf8).base64EncodedString(), mode, id.uuidString,
                    "--directory", directory ?? "", "--rows", String(rows), "--cols", String(columns)]
        if framed { args.append("--framed") }
        // One line, run by sh whatever the account's login shell is: csh reads neither `2>&1` nor a
        // quoted text of several lines, so the script travels encoded, as the editor's do.
        let inner = "command -v python3 >/dev/null 2>&1 || { printf '\\nHarbor requires Python 3 for reconnectable terminals.\\n'; exit 1; }; exec python3 -c 'import base64,sys;exec(base64.b64decode(sys.argv[1]))' " + args.map(SSHArguments.quote).joined(separator: " ")
        return "sh -c " + SSHArguments.quote(inner)
    }

    @MainActor static func arguments(_ session: TerminalSession, profile: ServerProfile, socket: String, requireMaster: Bool = false) throws -> [String] {
        guard let id = session.remotePTYID else {
            return SSHArguments.terminal(profile, socket: socket, tmuxName: session.tmuxName, requireMaster: requireMaster,
                workingDirectory: session.workingDirectory, directoryToken: session.directoryToken)
        }
        let model = session.terminal.getTerminal()
        var args = requireMaster ? ["-o", "ProxyCommand=false", "-o", "ControlMaster=no"] : []
        args += SSHArguments.common(profile, socket: socket) + ["-T", "--", profile.host]
        args.append(try command(id: id, mode: session.remotePTYReconnect ? "attach" : "create", directory: session.workingDirectory, rows: model.rows, columns: model.cols, framed: true))
        return args
    }
}
