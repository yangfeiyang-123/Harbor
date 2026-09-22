import AppKit
import Darwin
import HarborCore

extension TerminalSession {
    var effectiveDirectory: String? {
        if profile == nil, !ended, terminal.process.shellPid > 0 {
            var info = proc_vnodepathinfo()
            let size = MemoryLayout<proc_vnodepathinfo>.size
            if proc_pidinfo(terminal.process.shellPid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(size)) == size {
                let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { bytes in String(cString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self)) }
                if !path.isEmpty {
                    if let workingDirectory, let resolved = realpath(workingDirectory, nil) {
                        defer { free(resolved) }
                        currentDirectory = String(cString: resolved) == path ? workingDirectory : path
                    } else { currentDirectory = path }
                }
            }
        }
        return currentDirectory ?? workingDirectory
    }
    func acceptDirectory(_ value: String?) {
        guard let value else { return }
        let path: String
        if value.hasPrefix("file://"), let url = URL(string: value) { path = url.path }
        else { path = value }
        guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return }
        currentDirectory = path
        if initialDirectoryTitle == nil { initialDirectoryTitle = Self.directoryTitle(path) }
    }
}

extension AppStore {
    func refreshTerminalDirectories(_ candidates: [TerminalSession]) async {
        for session in candidates where session.profile == nil { _ = session.effectiveDirectory }
        let ids = Set(candidates.compactMap { $0.profile?.id })
        for id in ids {
            let members = candidates.filter { $0.profile?.id == id && !$0.ended && $0.ready }
            guard let first = members.first else { continue }
            let files = files(for: first.profile, directoryID: first.directoryWorkspaceID)
            await files.prepare(store: self)
            guard let service = files.service else { continue }
            let plain = members.filter { $0.tmuxName == nil && $0.remoteShellPID != nil }
            if !plain.isEmpty, let paths = try? await service.terminalDirectories(plain.map { ($0.remoteShellPID!, $0.directoryToken) }) {
                for session in plain { session.acceptDirectory(paths[session.directoryToken]) }
            }
            for session in members where session.tmuxName != nil {
                guard let profile = session.profile, let socket = session.socket, let name = session.tmuxName else { continue }
                let command = "tmux display-message -p -t " + SSHArguments.quote(name + ":") + " '#{pane_current_path}'"
                let result = await ProcessRunner.run("/usr/bin/ssh", SSHArguments.probe(profile, socket: socket, command: command), timeout: 5)
                if result.succeeded { session.acceptDirectory(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
        }
    }
    func startDirectoryTracking() {
        guard directoryTrackingTask == nil else { return }
        directoryTrackingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, let self else { break }
                let candidates = self.sessions.filter { !$0.ended && $0.ready && $0.directoryCheckNeeded }
                candidates.forEach { $0.directoryCheckNeeded = false }
                await self.refreshTerminalDirectories(candidates)
            }
        }
    }
}
