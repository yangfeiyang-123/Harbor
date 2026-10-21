"""Manage only Harbor-created viewer jobs. No shell input is read from network ports."""
import fcntl, json, os, pathlib, signal, socket, subprocess, sys, time


def execute(config):
    root = pathlib.Path.home() / '.local/state/harbor/displays' / config['id']
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(root, 0o700)
    with (root / 'lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        statefile = root / 'process.json'
        try: state = json.loads(statefile.read_text())
        except (OSError, ValueError): state = {}
        def identity(pid):
            try:
                fields = pathlib.Path('/proc/%d/stat' % pid).read_text().rsplit(')', 1)[1].split()
                return fields[19] if fields[0] != 'Z' else None
            except (OSError, ValueError): return None
        def ticks():
            # Now, in the clock /proc counts process start times in: the start time of a process
            # made for the purpose. (/proc/uptime is another clock inside some containers.)
            try:
                child = os.fork()
                if child == 0: os._exit(0)
                try: return int(pathlib.Path('/proc/%d/stat' % child).read_text().rsplit(')', 1)[1].split()[19])
                finally: os.waitpid(child, 0)
            except (OSError, ValueError, IndexError): return None
        def boot():
            # Start times begin again when the server restarts; what was written down before is void then.
            try: return pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip()
            except OSError: return None
        def rest(group, before):
            # What is left of a job after its first process has gone: the processes still in its
            # group that were started before it was told to stop. The launch command is usually a
            # script, which ends at once while the simulator it started is still shutting down
            # (or not at all). A later process that was given the same number started after that.
            found = []
            if before is None: return found
            for name in os.listdir('/proc'):
                if not name.isdigit(): continue
                try:
                    fields = pathlib.Path('/proc/%s/stat' % name).read_text().rsplit(')', 1)[1].split()
                    if fields[0] != 'Z' and int(fields[2]) == group and int(fields[19]) <= before: found.append(int(name))
                except (OSError, ValueError, IndexError): continue
            return found
        pid = state.get('pid', 0)
        leader = bool(pid > 1 and state.get('start') and identity(pid) == state['start'])
        asked = state.get('stopAsked') if state.get('boot') == boot() else None
        owned = leader or bool(pid > 1 and asked is not None and rest(pid, asked))
        def ready():
            try:
                with socket.create_connection(('127.0.0.1', config['port']), timeout=0.5): return True
            except OSError: return False
        listening = ready()
        if config['action'] in ('stop', 'force-stop'):
            # PID reuse and process-group checks prevent affecting unrelated jobs.
            if leader and os.getpgid(pid) != pid:
                raise RuntimeError('Process group changed; refusing to stop it.')
            if owned:
                if asked is None:
                    # Recorded before the signal: what is left afterwards is told apart by it.
                    asked = state['stopAsked'] = ticks(); state['boot'] = boot()
                    temp = root / 'process.tmp'; temp.write_text(json.dumps(state)); temp.replace(statefile)
                try: os.killpg(pid, signal.SIGKILL if config['action'] == 'force-stop' else signal.SIGTERM)
                except ProcessLookupError: pass
                def running(): return identity(pid) == state['start'] or bool(rest(pid, asked))
                for _ in range(30):
                    if not running(): break
                    time.sleep(0.1)
                if running():
                    return dict(ready=ready(), owned=True, message='Process is still shutting down. Force Stop is available for this Harbor job.')
                # Over: nothing is kept that a later process with the same number could be taken for.
                try: statefile.unlink()
                except OSError: pass
            return dict(ready=ready(), owned=False, message='Viewer job stopped.' if owned else 'This stream was started outside Harbor; it was left running.')
        if config['action'] == 'start' and not owned and not listening:
            directory = pathlib.Path(config['directory']).expanduser()
            if not directory.is_dir(): raise RuntimeError('Project directory does not exist.')
            log = root / 'output.log'
            with log.open('wb') as output:
                process = subprocess.Popen(['/bin/bash', '-lc', config['command']], cwd=directory,
                    stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT,
                    start_new_session=True, close_fds=True)
            pid = process.pid
            state = dict(pid=pid, start=identity(pid))
            temp = root / 'process.tmp'; temp.write_text(json.dumps(state)); temp.replace(statefile)
            owned = bool(state['start'])
        log = root / 'output.log'
        tail = ''
        if log.exists():
            with log.open('rb') as f:
                f.seek(max(0, log.stat().st_size - 12000)); tail = f.read(12000).decode(errors='replace')
        return dict(ready=listening, owned=owned, log=tail,
            message='Stream ready' if listening else 'Starting simulation' if owned else 'No running stream')

if __name__ == '__main__':
    try: result = execute(json.loads(sys.argv[1]))
    except Exception as exc: result = dict(error=str(exc))
    print('HARBOR_DISPLAY=' + json.dumps(result))
