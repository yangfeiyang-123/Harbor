#!/usr/bin/env python3
"""Harbor's private remote PTY host. Python stdlib only; no tmux or TCP ports.

SSH transports attach to a user-owned Unix socket. The daemon owns the PTY;
losing an SSH transport never closes it. Input is never recorded or replayed.
"""
import argparse
import collections
import fcntl
import json
import os
import pty
import re
import select
import signal
import socket
import stat
import struct
import subprocess
import sys
import termios
import time
import tty

class Gone(RuntimeError):
    """The shell that was asked for is no longer there. Told apart by its exit status (3):
    the app then starts a new shell on Reconnect instead of asking for this one again."""


# The exit status of a connection whose shell is no more: it was asked for and is gone, or it
# ended while this connection was attached to it.
ENDED = 3

LIMIT = 4 * 1024 * 1024
GRACE = 24 * 60 * 60
# While this much output waits for the attached client the shell is not read any further, so a
# program that prints faster than the link carries is slowed to the link, as over plain ssh.
PAUSE = 1024 * 1024
# A client that takes nothing for this long is gone; the shell must not wait for it any longer.
STALL = 30
# The umask the shell is started with: the account's own, not this host's private one.
SHELL_UMASK = 0o077


def private_directory(path):
    try:
        os.mkdir(path, 0o700)
    except FileExistsError:
        pass
    info = os.lstat(path)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise RuntimeError('Unsafe terminal storage directory')


def paths(session):
    if not re.fullmatch(r'[a-fA-F0-9-]{36}', session):
        raise ValueError('Invalid terminal identity')
    root = '/tmp/harbor-pty-' + str(os.getuid())
    private_directory(root)
    return root + '/' + session


def packet(kind, data=b''):
    return kind + struct.pack('!I', len(data)) + data


def resize(fd, data):
    rows, cols = json.loads(data)
    rows, cols = min(500, max(2, int(rows))), min(1000, max(2, int(cols)))
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))


def replay(chunks, truncated):
    data = b''.join(chunks)
    if truncated:
        # Start on a complete line instead of half a UTF-8/control sequence.
        pos = data.find(b'\n')
        data = data[pos + 1:] if pos >= 0 else b''
    # Replaying historical clipboard writes must not change the local clipboard.
    data = re.sub(rb'\x1b\]52;.*?(?:\x07|\x1b\\)', b'', data, flags=re.S)
    prefix = b'\x1bc\x1b[3J'
    return prefix + data


class ReplayStartFilter:
    """Older running hosts can still send the retired saved-output banner."""
    reset = b'\x1bc\x1b[3J'
    legacy = reset + b'[Harbor: earlier output is available in View Saved Output.]\r\n'

    def __init__(self):
        self.pending = b''
        self.finished = False

    def feed(self, data, final=False):
        if self.finished:
            return data
        self.pending += data
        if not final and self.legacy.startswith(self.pending) and len(self.pending) < len(self.legacy):
            return b''
        result, self.pending, self.finished = self.pending, b'', True
        if result.startswith(self.legacy):
            result = self.reset + result[len(self.legacy):]
        return result


class ReplayQueryFilter:
    """Remove historical terminal queries before the daemon's replay boundary.

    The native renderer suppresses replies while replaying. A stock xterm cannot
    distinguish them from live requests, so raw legacy attachment filters queries
    in its output stream instead. This class never processes keyboard input.
    """
    def __init__(self, session):
        self.marker = b'7777;' + session.encode('ascii') + b';'
        self.boundary = re.compile(rb'\x1b\]' + re.escape(self.marker) + rb'\d+(?:\x07|\x1b\\)')
        self.pending = b''
        self.finished = False

    def _osc(self, payload, terminator):
        if payload.startswith(self.marker) and payload[len(self.marker):].isdigit():
            self.finished = True
            return b''
        fields = payload.split(b';')
        if fields[0] == b'52':
            return b''  # Old daemon versions may not strip clipboard writes.
        if fields[0] == b'4' and len(fields) % 2 == 1:
            colors = [fields[index:index + 2] for index in range(1, len(fields), 2) if fields[index + 1] != b'?']
            return (b'\x1b]4;' + b';'.join(value for pair in colors for value in pair) + terminator) if colors else b''
        if fields[0].isdigit() and 10 <= int(fields[0]) <= 19:
            # A dynamic-color OSC can contain both queries and assignments.
            return b''.join(b'\x1b]' + str(int(fields[0]) + index).encode() + b';' + value + terminator
                            for index, value in enumerate(fields[1:]) if value != b'?')
        return b'\x1b]' + payload + terminator

    def feed(self, data, final=False):
        if self.finished:
            return data
        data = self.pending + data
        self.pending = b''
        boundary = self.boundary.search(data)
        if boundary:
            # The history ring may end inside an unfinished escape string. Its
            # malformed tail must not swallow the daemon marker and buffer live
            # output forever. The session-specific boundary is authoritative.
            history = self.feed(data[:boundary.start()], final=True)
            self.finished = True
            return history + data[boundary.end():]
        output = bytearray()
        index = 0
        while index < len(data):
            start = data.find(b'\x1b', index)
            if start < 0:
                output.extend(data[index:])
                break
            output.extend(data[index:start])
            if start + 1 == len(data):
                self.pending = data[start:]
                break
            kind = data[start + 1:start + 2]
            if kind == b'[':
                end = start + 2
                while end < len(data) and not 0x40 <= data[end] <= 0x7e:
                    end += 1
                if end == len(data):
                    self.pending = data[start:]
                    break
                body, command = data[start + 2:end], data[end:end + 1]
                query = (command in (b'n', b'c') or command == b'p' and body.endswith(b'$')
                         or command == b'q' and body.startswith(b'>')
                         or command == b'u' and body == b'?'
                         or command == b'S' and body.startswith(b'?')
                         or command == b'x' and body in (b'', b'0', b'1')
                         or command == b't' and body.split(b';')[0] in [str(n).encode() for n in range(13, 22)])
                if not query:
                    output.extend(data[start:end + 1])
                index = end + 1
            elif kind in (b']', b'P'):
                st = data.find(b'\x1b\\', start + 2)
                bell = data.find(b'\x07', start + 2) if kind == b']' else -1
                ends = [pos for pos in (st, bell) if pos >= 0]
                if not ends:
                    self.pending = data[start:]
                    break
                end = min(ends)
                terminator = b'\x07' if end == bell else b'\x1b\\'
                payload = data[start + 2:end]
                if kind == b']':
                    output.extend(self._osc(payload, terminator))
                elif not payload.startswith((b'$q', b'+q')):
                    output.extend(data[start:end] + terminator)
                index = end + len(terminator)
                if self.finished:
                    output.extend(data[index:])
                    break
            else:
                if kind != b'Z':  # DECID, the older device-attributes query.
                    output.extend(data[start:start + 2])
                index = start + 2
        # An incomplete historical control must not escape later as an active
        # query. Text and complete drawing controls have already been emitted.
        if final:
            self.pending = b''
        return bytes(output)


def serve(args, base):
    listener = socket.socket(socket.AF_UNIX)
    listener.bind(base + '.sock')
    os.chmod(base + '.sock', 0o600)
    listener.listen(4)
    listener.setblocking(False)
    pid, master = pty.fork()
    if pid == 0:
        os.environ['TERM'] = 'xterm-256color'
        os.environ['COLORTERM'] = 'truecolor'
        os.environ['TERM_PROGRAM'] = 'HarborSSH'
        os.environ['HARBOR_SESSION_ID'] = args.session
        os.environ.pop('TMUX', None)
        os.environ.pop('HARBOR_UMASK', None)
        # This host keeps its own files private; what the user creates in the shell gets the
        # permissions it would get in any other login.
        os.umask(SHELL_UMASK)
        # Python ignores SIGPIPE, and an ignored signal stays ignored across exec: `yes | head`
        # would report "Broken pipe" instead of ending quietly.
        for name in ('SIGPIPE', 'SIGXFSZ'):
            if hasattr(signal, name):
                signal.signal(getattr(signal, name), signal.SIG_DFL)
        # Same scope as `mesg n`: private terminal permissions, no global log changes.
        os.fchmod(0, 0o600)
        resize(0, json.dumps([args.rows, args.cols]))
        try:
            os.chdir(os.path.expanduser(args.directory or '~'))
            shell = os.environ.get('SHELL', '/bin/sh')
            os.execv(shell, [shell, '-l'])
        except Exception as error:
            print('Harbor: cannot start shell: ' + str(error), flush=True)
            os._exit(1)
    os.set_blocking(master, False)
    with open(base + '.state', 'w') as f:
        json.dump({'pid': pid, 'hostPID': os.getpid()}, f)
    chunks = collections.deque()
    total, truncated = 0, False
    client, incoming, outgoing, pending_input = None, bytearray(), bytearray(), bytearray()
    detached_at = time.monotonic()
    progress = time.monotonic()
    stall = float(os.environ.get('HARBOR_PTY_STALL') or STALL)
    stopping = False

    def detach():
        nonlocal client, incoming, outgoing, detached_at
        if client is not None:
            client.close()
        client = None
        incoming, outgoing = bytearray(), bytearray()
        detached_at = time.monotonic()

    try:
        while not stopping:
            if client is None and time.monotonic() - detached_at > GRACE:
                break
            if client is None or not outgoing:
                progress = time.monotonic()
            elif time.monotonic() - progress > stall:
                detach()  # A dead transport must never block the shell.
            # A client that is behind holds the shell back; without one, output goes to the history.
            paused = client is not None and len(outgoing) >= PAUSE
            reads = [listener] + ([] if paused else [master]) + ([client] if client is not None else [])
            writes = ([client] if client is not None and outgoing else []) + ([master] if pending_input else [])
            readable, writable, _ = select.select(reads, writes, [], 1)
            if listener in readable:
                new, _ = listener.accept()
                detach()
                client = new
                client.setblocking(False)
                progress = time.monotonic()
                outgoing.extend(replay(chunks, truncated))
                outgoing.extend(('\x1b]7777;%s;%s\x07' % (args.session, pid)).encode())
            if master in readable:
                try:
                    data = os.read(master, 65536)
                except OSError:
                    data = b''
                if not data:
                    break
                # Coalesce small writes to bound Python object overhead as well as bytes.
                if chunks and len(chunks[-1]) + len(data) <= 65536:
                    chunks[-1] += data
                else:
                    chunks.append(data)
                total += len(data)
                while total > LIMIT:
                    total -= len(chunks.popleft())
                    truncated = True
                if client is not None:
                    outgoing.extend(data)
            if client is not None and client in readable:
                try:
                    data = client.recv(65536)
                    if not data:
                        detach()
                    else:
                        incoming.extend(data)
                        while len(incoming) >= 5:
                            size = struct.unpack('!I', incoming[1:5])[0]
                            if size > 65536:
                                raise ValueError('Invalid frame')
                            if len(incoming) < size + 5:
                                break
                            kind, body = incoming[:1], bytes(incoming[5:5 + size])
                            del incoming[:5 + size]
                            if kind == b'I':
                                pending_input.extend(body)
                                if len(pending_input) > LIMIT:
                                    raise ValueError('Input queue full')
                            elif kind == b'R':
                                resize(master, body)
                                # Full-screen clients redraw even if the size is unchanged.
                                # A foreground job of another user (sudo, su) cannot be signalled;
                                # the size change above already told it.
                                try:
                                    os.killpg(os.tcgetpgrp(master), signal.SIGWINCH)
                                except (ProcessLookupError, PermissionError):
                                    pass
                            elif kind == b'X':
                                stopping = True
                except (OSError, ValueError):
                    detach()
            if master in writable and pending_input:
                try:
                    count = os.write(master, pending_input[:65536])
                    del pending_input[:count]
                except BlockingIOError:
                    pass
            if client is not None and client in writable and outgoing:
                try:
                    count = client.send(outgoing[:65536])
                    del outgoing[:count]
                    if count:
                        progress = time.monotonic()
                except BlockingIOError:
                    pass
                except OSError:
                    detach()
    finally:
        if client is not None and not stopping:
            # What the shell printed last goes out under the same rule as everything before it:
            # at the connection's pace, given up only when nothing has been taken for `stall` seconds.
            outgoing.extend(b'\r\n[Harbor: remote terminal ended.]\r\n')
            progress = time.monotonic()
            try:
                while outgoing and time.monotonic() - progress <= stall:
                    if not select.select([], [client], [], 1)[1]:
                        continue
                    try:
                        count = client.send(outgoing[:65536])
                    except BlockingIOError:
                        continue
                    del outgoing[:count]
                    if count:
                        progress = time.monotonic()
            except (OSError, ValueError):
                pass
        # Written before the connection is let go of: by it the other end tells a shell that has
        # ended from a connection that was only dropped.
        try:
            with open(base + '.state', 'w') as f:
                json.dump({'ended': True}, f)
        except OSError:
            pass
        detach()
        # Closing the controlling PTY hangs up this terminal, never unrelated jobs.
        os.close(master)
        listener.close()
        try:
            os.unlink(base + '.sock')
        except FileNotFoundError:
            pass


def attach(args, base):
    with open(base + '.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        conn = socket.socket(socket.AF_UNIX)
        try:
            conn.connect(base + '.sock')
        except OSError:
            if args.mode == 'close':
                return  # Its shell has ended already: there is nothing left to close.
            if args.mode != 'create' or os.path.exists(base + '.state'):
                raise Gone('Previous remote process is no longer available. Reconnect starts a new shell.')
            try:
                os.unlink(base + '.sock')
            except FileNotFoundError:
                pass
            proc = subprocess.Popen([sys.executable, os.path.abspath(__file__), 'serve', args.session,
                '--directory', args.directory, '--rows', str(args.rows), '--cols', str(args.cols)],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                start_new_session=True, close_fds=True)
            for _ in range(100):
                try:
                    conn.connect(base + '.sock')
                    break
                except OSError:
                    if proc.poll() is not None:
                        raise RuntimeError('Remote terminal host failed to start')
                    time.sleep(.05)
            else:
                raise RuntimeError('Remote terminal host did not become ready')
    if args.mode == 'close':
        conn.sendall(packet(b'X'))
        conn.close()
        return
    old = termios.tcgetattr(0) if os.isatty(0) else None
    changed = True
    released = False
    replay_start = ReplayStartFilter()
    replay_queries = ReplayQueryFilter(args.session) if args.sanitize_replay else None

    def window_changed(*_):
        nonlocal changed
        changed = True

    signal.signal(signal.SIGWINCH, window_changed)
    try:
        if old:
            tty.setraw(0)
        while True:
            if changed:
                changed = False
                size = os.get_terminal_size(0) if old else os.terminal_size((args.cols, args.rows))
                conn.sendall(packet(b'R', json.dumps([size.lines, size.columns]).encode()))
            ready, _, _ = select.select([0, conn], [], [], .2)
            if conn in ready:
                data = conn.recv(65536)
                if not data:
                    remaining = replay_start.feed(b'', final=True)
                    if replay_queries:
                        remaining = replay_queries.feed(remaining, final=True)
                    while remaining:
                        remaining = remaining[os.write(1, remaining):]
                    released = True
                    break
                data = replay_start.feed(data)
                if replay_queries:
                    data = replay_queries.feed(data)
                # os.write may be short on a PTY.
                while data:
                    data = data[os.write(1, data):]
            if 0 in ready:
                data = os.read(0, 65536)
                if not data:
                    break
                # The signed macOS relay frames input and resize messages over
                # SSH pipes. Legacy clients retain their raw-tty transport.
                conn.sendall(data if args.framed else packet(b'I', data))
    finally:
        conn.close()
        if old:
            termios.tcsetattr(0, termios.TCSADRAIN, old)
    # The host let go of this connection. When that is because its shell has ended (`exit`, or
    # the program it was started for is over), there is nothing to return to, and the status says
    # so. A connection the host dropped for being too slow, or for another one, ends as before.
    if released:
        for _ in range(20):
            try:
                with open(base + '.state') as f:
                    if json.load(f).get('ended') is True:
                        return ENDED
            except (OSError, ValueError, AttributeError):
                pass
            time.sleep(.05)  # a host of an earlier version writes it a moment later
    return 0


def main():
    global SHELL_UMASK
    # The first process of a connection records the umask it was started with, before making
    # this host's own files private; the host it starts and the shell after that inherit the record.
    previous = os.umask(0o077)
    recorded = os.environ.get('HARBOR_UMASK', '')
    SHELL_UMASK = int(recorded, 8) if re.fullmatch(r'[0-7]{1,4}', recorded) else previous
    os.environ['HARBOR_UMASK'] = '%o' % SHELL_UMASK
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['create', 'attach', 'close', 'serve'])
    parser.add_argument('session')
    parser.add_argument('--directory', default='')
    parser.add_argument('--rows', type=int, default=24)
    parser.add_argument('--cols', type=int, default=80)
    parser.add_argument('--framed', action='store_true')
    parser.add_argument('--sanitize-replay', action='store_true')
    args = parser.parse_args()
    base = paths(args.session)
    if args.mode == 'serve':
        serve(args, base)
        return 0
    return attach(args, base) or 0


if __name__ == '__main__':
    try:
        status = main()
    except (OSError, RuntimeError, ValueError) as error:
        print('\r\n[Harbor: %s]\r\n' % error, file=sys.stderr)
        sys.exit(ENDED if isinstance(error, Gone) else 1)
    sys.exit(status)
