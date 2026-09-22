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
        pid = state.get('pid', 0)
        owned = bool(pid > 1 and state.get('start') and identity(pid) == state['start'])
        def ready():
            try:
                with socket.create_connection(('127.0.0.1', config['port']), timeout=0.5): return True
            except OSError: return False
        listening = ready()
        if config['action'] in ('stop', 'force-stop'):
            # PID reuse and process-group checks prevent affecting unrelated jobs.
            if owned and os.getpgid(pid) == pid:
                os.killpg(pid, signal.SIGKILL if config['action'] == 'force-stop' else signal.SIGTERM)
                for _ in range(30):
                    if identity(pid) != state['start']: break
                    time.sleep(0.1)
                if identity(pid) == state['start']:
                    return dict(ready=ready(), owned=True, message='Process is still shutting down. Force Stop is available for this Harbor job.')
            elif owned:
                raise RuntimeError('Process group changed; refusing to stop it.')
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
