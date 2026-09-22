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

LIMIT = 4 * 1024 * 1024
GRACE = 24 * 60 * 60


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
    if truncated:
        prefix += b'[Harbor: earlier output is available in View Saved Output.]\r\n'
    return prefix + data


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
            reads = [listener, master] + ([client] if client is not None else [])
            writes = ([client] if client is not None and outgoing else []) + ([master] if pending_input else [])
            readable, writable, _ = select.select(reads, writes, [], 1)
            if listener in readable:
                new, _ = listener.accept()
                detach()
                client = new
                client.setblocking(False)
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
                    if len(outgoing) > LIMIT + 131072:
                        detach()  # A slow transport must never block the shell.
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
                                try:
                                    os.killpg(os.tcgetpgrp(master), signal.SIGWINCH)
                                except ProcessLookupError:
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
                except BlockingIOError:
                    pass
                except OSError:
                    detach()
    finally:
        if client is not None:
            try:
                client.settimeout(1)
                client.sendall(outgoing + b'\r\n[Harbor: remote terminal ended.]\r\n')
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
        with open(base + '.state', 'w') as f:
            json.dump({'ended': True}, f)


def attach(args, base):
    with open(base + '.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        conn = socket.socket(socket.AF_UNIX)
        try:
            conn.connect(base + '.sock')
        except OSError:
            if args.mode != 'create' or os.path.exists(base + '.state'):
                raise RuntimeError('Previous remote process is no longer available. Saved output is kept. Use New Terminal to start a new shell.')
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
                    break
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


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['create', 'attach', 'close', 'serve'])
    parser.add_argument('session')
    parser.add_argument('--directory', default='')
    parser.add_argument('--rows', type=int, default=24)
    parser.add_argument('--cols', type=int, default=80)
    parser.add_argument('--framed', action='store_true')
    args = parser.parse_args()
    base = paths(args.session)
    if args.mode == 'serve':
        serve(args, base)
    else:
        attach(args, base)


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, ValueError) as error:
        print('\r\n[Harbor: %s]\r\n' % error, file=sys.stderr)
        sys.exit(1)
