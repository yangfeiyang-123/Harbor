# Remote terminal reconnection

Harbor 0.19 uses a remote PTY host, not tmux, for newly created remote terminals.
The design follows the process-reconnection model described by [VS Code](https://code.visualstudio.com/docs/terminal/advanced): keep the remote process independent of its connection, then reconnect to that process. Harbor does not use VS Code's server implementation.

## What is retained

- A dropped SSH connection or normal Harbor quit detaches the transport. The remote shell and foreground program continue running, with the same PID, environment and working directory.
- Reconnect attaches to the original PTY. Disconnected terminals on the same server reconnect together; healthy terminals are left alone.
- Harbor restores names, tabs, split layouts, selected terminals and saved text on launch. Click Reconnect when ready to resume.
- Input is never recorded for execution or rerun. Reconnect cannot repeat your last shell command.
- Explicitly closing a terminal ends its remote PTY. If offline, remote termination can fail and the retained process expires after the disconnect grace period.
- A server's terminal page (Start ▸ the server ▸ New Terminal) is kept across a quit like a terminal window: New Terminal for that server returns to its panes and tabs and reconnects them. A plain terminal on this Mac ends with Harbor. What a further window holds comes back as a terminal window; closing only that window ends its shells on servers, after asking.
- The shell runs with the account's own umask and default signal handling. (Until 0.34 it inherited the host's private umask, so new files were 600, and an ignored SIGPIPE, so `yes | head` reported "Broken pipe".)

## Requirements and limits

The server needs Python 3 with its standard Unix PTY support. No administrator access, third-party Python packages, tmux, TCP listeners or system services are needed. A versioned helper and private Unix sockets live in `/tmp/harbor-pty-<uid>` (directory mode 0700, files 0600). Each shell has an independent host; a disconnected host expires after **24 hours**. CPU use is idle while no output is arriving.

Each host keeps up to **4 MB** of recent output in memory. While more than 1 MB waits for the attached client the shell is not read further, so a program that prints faster than the connection carries is slowed to the connection, as over plain ssh; a client that takes nothing for 30 seconds is let go of, so a dead connection never holds the shell. Reconnect clears the live view and replays that stream, then asks full-screen programs to redraw. Old clipboard control sequences are excluded from replay. Very long sessions can exceed the replay buffer; use **View Saved Output…** for the local rendered-text archive (up to 8 MB per terminal). This is not a byte-perfect persistent screen snapshot; text archived across app restarts does not retain color or images.

A server reboot, exited process, terminated host or expired grace period means the original process is gone. The host says so with its own exit status, Harbor shows that message in the pane and retains the saved text, and it does **not** silently replace the shell. **Reconnect** in that pane then starts a new one (it used to fail the same way each time), and New Terminal for a server's terminal page does the same. A shell that ends while a terminal is attached to it (`exit`) is reported the same way, after everything it printed has been delivered at the connection's pace.

## Existing terminals

Existing tmux terminals stay attached to their original tmux sessions, including after reconnect. They cannot be converted into independent PTYs without restarting the program. Close those when their work is finished and create a new terminal to use the new host. Imported and existing server settings no longer enable tmux for new terminals. Local terminals retain their existing behavior: archived output restores after quitting, but the local process is not hosted remotely.

## Display and server broadcasts (0.23)

The signed Harbor executable has a small transport-only child mode. It runs OpenSSH with `-T`, pipes the existing PTY stream, and frames keyboard input and resize messages separately. It waits for the remote session handshake before consuming keyboard input so SSH authentication still works. The remote foreground application keeps a real PTY and receives `SIGWINCH`, including an unchanged-size redraw when its surface returns to view.

No outer SSH login terminal is registered for system broadcasts to write into. This removes unsolicited syslog/wall output from current PTY-host sessions without disabling server logging, changing the kernel watchdog, or restarting remote workloads. A real soft-lockup fault still needs server-side diagnosis. `mesg n` alone is insufficient for root rsyslog broadcasts: [rsyslog's omusrmsg implementation](https://github.com/rsyslog/rsyslog/blob/master/tools/omusrmsg.c) checks owner-write permission. Existing PTY hosts accept the same framed input/resize protocol and survive a reconnect through the new transport.

AppKit surfaces coalesce complete-buffer repaints after output and layout/visibility changes. Collapsing a surface does not resize its remote terminal to zero or one cell. Repainting preserves the font, scrollback, selection, bracketed-paste mode, and alternate screen. This uses event-driven work only; hidden surfaces have no recurring repaint timer.

## Verification

`Tests/terminal_host_test.py` exercises independent host/transport lifecycle, offline output, shell state (umask and SIGPIPE included), resize, explicit close, missing-session errors and their exit status, a client that is behind or takes nothing, and safe replay. `RemoteTerminalHostTests` runs the command that starts the host under sh, bash, zsh, csh and tcsh. `TerminalRecoveryRemoteTests` is opt-in with `HARBOR_QA_SSH_HOST`; it creates an isolated test shell, kills only that SSH client, verifies the same remote PID and shell variables, then repeats after a Harbor store shutdown/restore. It closes its own remote PTY afterwards.
