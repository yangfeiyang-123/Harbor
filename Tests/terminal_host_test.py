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

    def client(self, mode, rows=24, cols=80, framed=False, sanitize=False, env=None):
        proc = subprocess.Popen([sys.executable, str(HOST), mode, self.sid,
            '--directory', '/tmp', '--rows', str(rows), '--cols', str(cols)] + (['--framed'] if framed else [])
            + (['--sanitize-replay'] if sanitize else []),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            env=None if env is None else dict(os.environ, **env))
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

    def test_shell_gets_the_account_umask_and_default_sigpipe(self):
        # The connection's first process records the umask it was started with (here 027).
        first = self.client('create', env={'HARBOR_UMASK': '27'})
        self.until(first, b'7777;' + self.sid.encode())
        self.send(first, 'echo "mask=$(umask)" "left=${HARBOR_UMASK:-none}"\n')
        self.assertRegex(self.until(first, b'left=none'), rb'mask=0*27 ')
        # A writer whose reader has left ends by SIGPIPE (status 141), without a "Broken pipe" report.
        self.send(first, '( yes; echo "writer=$?" >&2 ) | head -n 1 >/dev/null\n')
        self.until(first, b'writer=141')

    def test_a_client_that_is_behind_slows_the_shell_and_loses_nothing(self):
        first = self.client('create')
        self.until(first, b'7777;' + self.sid.encode())
        # Six megabytes, more than the host ever queues, while this client reads nothing.
        self.send(first, 'head -c 6000000 /dev/zero | tr "\\0" x; echo; echo TAIL-$((40+2))\n')
        time.sleep(2.5)
        data = self.until(first, b'TAIL-42', timeout=30)
        self.assertGreaterEqual(data.count(b'x'), 6000000)
        self.assertIsNone(first.poll())
        self.send(first, 'echo STILL-$((1+1))\n')
        self.until(first, b'STILL-2')

    def test_a_client_that_takes_nothing_is_released_and_the_shell_goes_on(self):
        first = self.client('create', env={'HARBOR_PTY_STALL': '2'})
        self.until(first, b'7777;' + self.sid.encode())
        marker = '/tmp/harbor-stall-' + self.sid
        self.addCleanup(lambda: Path(marker).unlink(missing_ok=True))
        self.send(first, 'head -c 6000000 /dev/zero | tr "\\0" x; echo done > ' + marker + '\n')
        # Nothing is read here: the host lets go of this client, and the command completes.
        for _ in range(150):
            if os.path.exists(marker):
                break
            time.sleep(.1)
        self.assertTrue(os.path.exists(marker))
        second = self.client('attach')
        self.until(second, b'7777;' + self.sid.encode())
        self.send(second, 'echo BACK-$((1+1))\n')
        self.until(second, b'BACK-2')
        # The first connection was dropped, not ended: its status is not that of a shell that is gone.
        while os.read(first.stdout.fileno(), 65536):
            pass
        self.assertEqual(first.wait(timeout=6), 0)

    def test_what_a_shell_printed_last_arrives_however_slowly_it_is_read(self):
        first = self.client('create')
        self.until(first, b'7777;' + self.sid.encode())
        # Less than the host holds back for, more than the connection takes unread: the shell is
        # over while most of it still waits here.
        self.send(first, 'head -c 800000 /dev/zero | tr "\\0" x; echo; echo TAIL-$((40+2)); exit\n')
        time.sleep(2.5)
        data = self.until(first, b'remote terminal ended', timeout=30)
        self.assertGreaterEqual(data.count(b'x'), 800000)
        self.assertIn(b'TAIL-42', data)
        # And the connection says that its shell has ended: there is nothing to reconnect to.
        self.assertEqual(first.wait(timeout=6), host.ENDED)

    def test_closing_a_terminal_whose_shell_has_ended_succeeds(self):
        first = self.client('create')
        self.until(first, b'7777;' + self.sid.encode())
        self.send(first, 'exit\n')
        self.assertEqual(first.wait(timeout=6), host.ENDED)
        closing = self.client('close')
        closing.wait(timeout=6)
        self.assertEqual(closing.returncode, 0)
        self.assertEqual(closing.stdout.read(), b'')

    def test_missing_session_never_silently_starts_shell(self):
        proc = self.client('attach')
        output = proc.communicate(timeout=5)[0]
        # Its own exit status: the app tells "that shell is gone" from a connection that failed.
        self.assertEqual(proc.returncode, 3)
        self.assertIn(b'Previous remote process is no longer available', output)
        self.assertFalse(Path(self.base + '.state').exists())

    def test_sanitized_raw_attachment_preserves_process_and_user_input(self):
        first = self.client('create')
        self.until(first, b'7777;')
        program = ("import os,tty;tty.setraw(0);"
                   "os.write(1,b'\\x1b[6n'+b'HIST_'+b'QUERY_'+str(os.getpid()).encode()+b'\\n');"
                   "data=os.read(0,4096);"
                   "os.write(1,b'\\x1b[6n'+b'INPUT_'+b'RECORD_'+data.hex().encode()+b'\\n')")
        self.send(first, 'exec python3 -c ' + shlex.quote(program) + '\n')
        data = self.until(first, b'HIST_QUERY_')
        self.assertIn(b'\x1b[6n', data)
        pid = json.loads(Path(self.base + '.state').read_text())['pid']
        first.kill(); first.wait()
        second = self.client('attach', sanitize=True)
        history = self.until(second, b'HIST_QUERY_')
        self.assertNotIn(b'\x1b[6n', history)
        self.assertEqual(pid, json.loads(Path(self.base + '.state').read_text())['pid'])
        self.send(second, 'hello')
        live = self.until(second, b'INPUT_RECORD_68656c6c6f')
        self.assertIn(b'\x1b[6n', live, 'live terminal queries still reach the real renderer')

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
        self.assertNotIn(b'View Saved Output', host.replay([b'partial\nwhole\n'], True))

    def test_old_host_banner_removed_across_transport_chunks_without_touching_live_output(self):
        raw = host.ReplayStartFilter.legacy + b'Previous answer\r\n\x1b]7777;token;123\x07'
        for split in range(1, len(raw)):
            stream = host.ReplayStartFilter()
            restored = stream.feed(raw[:split]) + stream.feed(raw[split:])
            self.assertEqual(restored, host.ReplayStartFilter.reset + raw[len(host.ReplayStartFilter.legacy):])
            self.assertEqual(stream.feed(raw), raw)

    def test_replay_filter_keeps_current_output_byte_exact(self):
        for raw in [b'\x1bc\x1b[3Jnew history\r\n', b'other output', b'\x1bc']:
            stream = host.ReplayStartFilter()
            result = b''.join(stream.feed(bytes([value])) for value in raw)
            self.assertEqual(result + stream.feed(b'', final=True), raw)


class ReplayQueryTests(unittest.TestCase):
    session = '12b11579-5d87-4b8e-a537-590b5cec602c'

    @property
    def boundary(self):
        return ('\x1b]7777;' + self.session + ';4321\x07').encode()

    def test_fragmented_queries_removed_but_live_queries_survive_every_split(self):
        queries = [b'\x1b[6n', b'\x1b[?6n', b'\x1b[c', b'\x1b[>0c', b'\x1b[=0c',
                   b'\x1b[?2026$p', b'\x1b[>q', b'\x1b[?u', b'\x1b[?1;1;0S', b'\x1b[18t', b'\x1b[1x', b'\x1bZ',
                   b'\x1b]10;?\x07', b'\x1b]11;?\x1b\\', b'\x1b]4;7;?\x07',
                   b'\x1bP$qm\x1b\\', b'\x1bP+q544e\x1b\\']
        drawing = 'saved 中文'.encode() + b'\x1b[31mred\x1b[0m\x1b[2J\x1b[3;5H\x1b[8;24;80t'
        for query in queries:
            raw = drawing + query + self.boundary + query + b'LIVE'
            expected = drawing + query + b'LIVE'
            for split in range(len(raw) + 1):
                stream = host.ReplayQueryFilter(self.session)
                self.assertEqual(stream.feed(raw[:split]) + stream.feed(raw[split:]), expected, (query, split))
            stream = host.ReplayQueryFilter(self.session)
            self.assertEqual(b''.join(stream.feed(bytes([byte])) for byte in raw), expected)

    def test_color_assignments_and_non_query_controls_are_preserved(self):
        raw = (b'\x1bc\x1b[3J\x1b]4;0;?;1;#ff0000\x07'
               b'\x1b]10;?;#abcdef\x1b\\\x1b]0;Window title\x07\x1bP0qimage\x1b\\')
        expected = (b'\x1bc\x1b[3J\x1b]4;1;#ff0000\x07'
                    b'\x1b]11;#abcdef\x1b\\\x1b]0;Window title\x07\x1bP0qimage\x1b\\')
        stream = host.ReplayQueryFilter(self.session)
        self.assertEqual(b''.join(stream.feed(bytes([byte])) for byte in raw) + stream.feed(self.boundary), expected)

    def test_other_session_markers_do_not_end_filter_and_old_clipboard_is_removed(self):
        wrong = b'\x1b]7777;other-session;4321\x07'
        stream = host.ReplayQueryFilter(self.session)
        self.assertEqual(stream.feed(wrong + b'\x1b[6n\x1b]52;c;c2VjcmV0\x07'), wrong)
        self.assertFalse(stream.finished)
        self.assertEqual(stream.feed(self.boundary + b'\x1b[6n'), b'\x1b[6n')
        self.assertTrue(stream.finished)

    def test_incomplete_replay_control_does_not_escape_at_eof(self):
        for suffix in (b'\x1b', b'\x1b[?', b'\x1b]10;?', b'\x1bP$qm'):
            stream = host.ReplayQueryFilter(self.session)
            self.assertEqual(stream.feed(b'Saved answer\n' + suffix) + stream.feed(b'', final=True), b'Saved answer\n')

    def test_daemon_boundary_ends_a_truncated_control_without_buffering_live_output(self):
        for suffix in (b'\x1bP$qunfinished', b'\x1b]10;unfinished'):
            raw = b'Saved answer\n' + suffix + self.boundary + b'LIVE\x1b[6n'
            for split in range(len(raw) + 1):
                stream = host.ReplayQueryFilter(self.session)
                self.assertEqual(stream.feed(raw[:split]) + stream.feed(raw[split:]), b'Saved answer\nLIVE\x1b[6n')


if __name__ == '__main__':
    unittest.main()
