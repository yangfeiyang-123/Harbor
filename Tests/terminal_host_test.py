"""Transport-independent PTY checks; creates and closes only unique QA shells."""
import importlib.util
import json
import os
from pathlib import Path
import re
import select
import shlex
import socket
import subprocess
import sys
import time
import unittest
import uuid

sys.dont_write_bytecode = True
HOST = Path(__file__).resolve().parents[1] / 'Sources/HarborSSH/Resources/WorkspaceRuntime/terminal_host.py'
spec = importlib.util.spec_from_file_location('host', HOST)
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)


class HostTests(unittest.TestCase):
    def setUp(self):
        self.sid = str(uuid.uuid4())
        self.base = host.paths(self.sid)
        self.clients = []

    def tearDown(self):
        try:
            with socket.socket(socket.AF_UNIX) as conn:
                conn.connect(self.base + '.sock')
                conn.sendall(host.packet(b'X'))
        except OSError:
            pass
        for proc in self.clients:
            if proc.poll() is None:
                proc.kill()
            proc.wait(timeout=5)
            proc.stdin.close()
            proc.stdout.close()
        for _ in range(100):
            if not os.path.exists(self.base + '.sock'):
                break
            time.sleep(.02)
        for suffix in ['.lock', '.state']:
            Path(self.base + suffix).unlink(missing_ok=True)

    def client(self, mode, rows=24, cols=80, framed=False):
        proc = subprocess.Popen([sys.executable, str(HOST), mode, self.sid,
            '--directory', '/tmp', '--rows', str(rows), '--cols', str(cols)] + (['--framed'] if framed else []),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.clients.append(proc)
        return proc

    def until(self, proc, expected, timeout=6, initial=b''):
        data, end = initial, time.monotonic() + timeout
        if expected in data:
            return data
        while time.monotonic() < end:
            if select.select([proc.stdout], [], [], .1)[0]:
                block = os.read(proc.stdout.fileno(), 65536)
                if not block:
                    break
                data += block
                if expected in data:
                    return data
        self.fail('Missing %r in %r' % (expected, data[-3000:]))

    def send(self, proc, text):
        proc.stdin.write(text.encode())
        proc.stdin.flush()

    def test_disconnect_same_pid_environment_cwd_and_offline_output(self):
        first = self.client('create')
        self.until(first, b'7777;')
        pid = json.loads(Path(self.base + '.state').read_text())['pid']
        self.send(first, "export HARBOR_QA_VALUE=retained; cd /; printf 'READY_%s\\n' \"$HARBOR_QA_VALUE\"; (sleep .3; printf 'OFFLINE_%s\\n' preserved) &\n")
        self.until(first, b'READY_retained')
        first.kill()
        first.wait()
        time.sleep(.6)
        second = self.client('attach', rows=37, cols=111)
        self.until(second, b'OFFLINE_preserved')
        self.assertEqual(pid, json.loads(Path(self.base + '.state').read_text())['pid'])
        self.send(second, "printf 'BACK_%s:%s:%s\\n' \"$HARBOR_QA_VALUE\" \"$PWD\" \"${TMUX-unset}\"; stty size\n")
        self.until(second, b'BACK_retained:/:unset')
        self.send(second, "printf 'SIZE_'; stty size\n")
        self.until(second, b'SIZE_37 111')

    def test_pipe_transport_frames_input_and_unchanged_resize_redraws_without_restarting(self):
        proc = self.client('create', framed=True)
        self.until(proc, b'7777;')
        program = "import os,signal,time; signal.signal(signal.SIGWINCH,lambda *_:print(('RED'+'RAW_%s_%s') % (os.getpid(),os.get_terminal_size(0)),flush=True));print(('STA'+'RTED_%s') % os.getpid(),flush=True);time.sleep(10)"
        command = 'exec python3 -c ' + shlex.quote(program) + '\n'
        # Deliver fragmented frames, just as an SSH pipe can split packets.
        message = host.packet(b'I', command.encode())
        proc.stdin.write(message[:3]); proc.stdin.flush()
        proc.stdin.write(message[3:]); proc.stdin.flush()
        data = self.until(proc, b'STARTED_')
        for _ in range(2):
            proc.stdin.write(host.packet(b'R', b'[37,111]')); proc.stdin.flush()
            data = self.until(proc, b'REDRAW_')
            self.assertIn(b'columns=111, lines=37', data)

    def test_missing_session_never_silently_starts_shell(self):
        proc = self.client('attach')
        output = proc.communicate(timeout=5)[0]
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn(b'Previous remote process is no longer available', output)
        self.assertFalse(Path(self.base + '.state').exists())

    def test_full_screen_foreground_program_keeps_running_and_accepts_input(self):
        first = self.client('create')
        self.until(first, b'7777;')
        # Escape sequences belong to the program's output, not to the shell's
        # line editor while it receives this command (notably Bash/readline).
        program = r"""
import os,select,time,tty
tty.setraw(0)
print('\x1b[?1049h',end='',flush=True)
n=0
while True:
    n+=1
    print('\x1b[HFRAME_%d_PID_%d' % (n,os.getpid()),flush=True)
    if select.select([0],[],[],.1)[0] and os.read(0,1)==b'q': break
print('\x1b[?1049lTUI_FINISHED',flush=True)
"""
        self.send(first, 'exec python3 -c ' + shlex.quote(program) + '\n')
        data = self.until(first, b'FRAME_1_PID_')
        pid = re.search(rb'FRAME_1_PID_(\d+)', data).group(1)
        first.kill()
        first.wait()
        time.sleep(.6)
        second = self.client('attach')
        data = self.until(second, b'7777;')
        # A busy runner may render fewer than five frames in the disconnect
        # interval. Wait for output from the same process, retaining partial
        # transport packets, rather than asserting a wall-clock frame rate.
        data = self.until(second, b'FRAME_5_PID_' + pid, initial=data)
        frames = re.findall(rb'FRAME_(\d+)_PID_(\d+)', data)
        self.assertTrue(any(int(n) >= 5 and p == pid for n, p in frames), data)
        self.send(second, 'q')
        self.until(second, b'TUI_FINISHED')

    def test_explicit_close_ends_host_and_cannot_revive_closed_identity(self):
        proc = self.client('create')
        self.until(proc, b'7777;')
        conn = socket.socket(socket.AF_UNIX)
        conn.connect(self.base + '.sock')
        conn.sendall(host.packet(b'X'))
        conn.close()
        for _ in range(100):
            if not Path(self.base + '.sock').exists():
                break
            time.sleep(.02)
        self.assertFalse(Path(self.base + '.sock').exists())
        retry = self.client('create')
        output = retry.communicate(timeout=5)[0]
        self.assertIn(b'Previous remote process is no longer available', output)

    def test_replay_strips_clipboard_and_bounds_truncated_prefix(self):
        data = host.replay([b'hello\x1b]52;c;c2VjcmV0\x07world\n'], False)
        self.assertNotIn(b'52;', data)
        self.assertIn(b'helloworld', data)
        self.assertNotIn(b'partial', host.replay([b'partial\nwhole\n'], True))


if __name__ == '__main__':
    unittest.main()
