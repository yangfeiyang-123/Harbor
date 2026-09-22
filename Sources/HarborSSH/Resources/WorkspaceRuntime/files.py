import os, sys, json, stat, hashlib, base64, tempfile, shutil, time, socket

def search_workspace(root, request):
    # Bounded, read-only traversal. Never follow directory symlinks or read
    # special files. Large generated artifacts must not stall interactive search.
    query = str(request.get('query', ''))[:256]
    content = request.get('content', False)
    sensitive = request.get('caseSensitive', False)
    needle = query if sensitive else query.casefold()
    excluded = {'.git', '.hg', '.svn', '.venv', 'venv', 'node_modules', '__pycache__', '.cache', '.build', 'dist'}
    hits, scanned, skipped, truncated = [], 0, 0, False
    deadline = time.monotonic() + 4
    if content and not needle: return dict(hits=[], scanned=0, skipped=0, truncated=False)
    def matches(value):
        value = value if sensitive else value.casefold()
        if needle in value: return True
        if content: return False
        iterator = iter(value)
        return all(any(char == candidate for candidate in iterator) for char in needle)
    pending = [root]
    while pending:
        parent = pending.pop()
        try:
            with os.scandir(parent) as children:
                for child in children:
                    scanned += 1
                    if scanned > 20000 or time.monotonic() >= deadline or len(hits) >= 200:
                        truncated = True; break
                    if not request.get('hidden', False) and child.name.startswith('.'): continue
                    if child.is_symlink(): continue
                    try:
                        s = child.stat(follow_symlinks=False)
                        if stat.S_ISDIR(s.st_mode):
                            if child.name not in excluded: pending.append(child.path)
                            continue
                        if not stat.S_ISREG(s.st_mode): continue
                        relative = os.path.relpath(child.path, root)
                        entry = dict(path=child.path, name=child.name, directory=False, size=s.st_size, modified=s.st_mtime)
                        if not content:
                            if matches(relative): hits.append(dict(entry=entry, relative=relative))
                            continue
                        if s.st_size > 2 * 1024 * 1024: skipped += 1; continue
                        with os.fdopen(os.open(child.path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW), 'rb') as handle:
                            if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode): continue
                            data = handle.read(2 * 1024 * 1024 + 1)
                        if len(data) > 2 * 1024 * 1024 or b'\0' in data: skipped += 1; continue
                        try: text = data.decode('utf-8')
                        except UnicodeError: skipped += 1; continue
                        for number, line in enumerate(text.splitlines(), 1):
                            if matches(line):
                                index = (line if sensitive else line.casefold()).find(needle)
                                if not sensitive:
                                    folded = 0
                                    for original, char in enumerate(line):
                                        if folded >= index: index = original; break
                                        folded += len(char.casefold())
                                # CodeMirror positions use UTF-16 code units.
                                column = len(line[:index].encode('utf-16-le')) // 2 + 1
                                hits.append(dict(entry=entry, relative=relative, line=number, column=column, preview=line[:260]))
                            if len(hits) >= 200 or time.monotonic() >= deadline: truncated = True; break
                    except OSError: skipped += 1
        except OSError: skipped += 1
        if truncated: break
    hits.sort(key=lambda h: (h['relative'].casefold(), h.get('line', 0)))
    return dict(hits=hits, scanned=scanned, skipped=skipped, truncated=truncated)


def directory_stamp(path):
    s = os.stat(path)
    return str(s.st_ino) + ':' + str(s.st_mtime_ns)

def list_directory(path, hidden=False):
    stamp = directory_stamp(path)
    entries, truncated = [], False
    with os.scandir(path) as iterator:
        for entry in iterator:
            if not hidden and entry.name.startswith('.'): continue
            if len(entries) >= 10000:
                truncated = True
                break
            try:
                s = entry.stat()
                entries.append(dict(path=entry.path, name=entry.name, directory=stat.S_ISDIR(s.st_mode), size=s.st_size, modified=s.st_mtime))
            except OSError:
                entries.append(dict(path=entry.path, name=entry.name, directory=False, size=0, modified=0))
    entries.sort(key=lambda e: (not e['directory'], e['name'].casefold()))
    return dict(path=path, entries=entries, truncated=truncated, stamp=stamp)

def no_replace(source, target):
    import ctypes, errno
    libc = ctypes.CDLL(None, use_errno=True)
    if hasattr(libc, 'renameat2'):
        result = libc.renameat2(-100, os.fsencode(source), -100, os.fsencode(target), 1)
        if result == 0: return
        code = ctypes.get_errno()
        if code != errno.EXDEV: raise OSError(code, os.strerror(code), target)
    elif hasattr(libc, 'renamex_np'):
        if libc.renamex_np(os.fsencode(source), os.fsencode(target), 4) == 0: return
        code = ctypes.get_errno()
        if code != errno.EXDEV: raise OSError(code, os.strerror(code), target)
    else: raise ValueError('This system does not support safe moves.')
    if os.path.lexists(target): raise ValueError('An item with this name already exists at the destination. It was not overwritten.')
    # Cross-device moves copy to a private sibling first; publish without replacing.
    staging = tempfile.mkdtemp(prefix='.harbor-move-', dir=os.path.dirname(target))
    try:
        candidate = os.path.join(staging, 'item')
        copy_item(source, candidate)
        no_replace(candidate, target)
        if os.path.isdir(source) and not os.path.islink(source): shutil.rmtree(source)
        else: os.unlink(source)
    finally: shutil.rmtree(staging, ignore_errors=True)

def copy_item(source, target):
    if os.path.islink(source): os.symlink(os.readlink(source), target)
    elif os.path.isdir(source): shutil.copytree(source, target, symlinks=True)
    elif stat.S_ISREG(os.stat(source).st_mode): shutil.copy2(source, target)
    else: raise ValueError('Special files cannot be copied.')

def destination(parent, name, duplicate=False):
    if not name or name in ('.', '..') or '/' in name or '\0' in name: raise ValueError('The name is invalid.')
    if not os.path.isdir(parent): raise ValueError('Select a destination folder.')
    target = os.path.join(parent, name)
    if duplicate:
        stem, extension = os.path.splitext(name)
        index = 1
        while os.path.lexists(target):
            target = os.path.join(parent, stem + ' copy' + ('' if index == 1 else ' ' + str(index)) + extension)
            index += 1
    elif os.path.lexists(target): raise ValueError('An item with this name already exists at the destination. It was not overwritten.')
    return target

def stream_exact(source, count):
    chunks = bytearray()
    while len(chunks) < count:
        part = source.read(count - len(chunks))
        if not part: raise ValueError('The transfer did not complete. Try again.')
        chunks.extend(part)
    return bytes(chunks)

class PacedOutput:
    # Bulk stdout on a server behind the reverse tunnel. The tunnel's bridge
    # paces what the server sends to the Mac, but this output travels over
    # Harbor's own ssh connection and bypassed it: one large download filled
    # the VPN's queue and stalled every terminal and proxied request. With
    # `paced` set and the bridge's port file present, each slice first takes
    # tokens from the bridge (serve_tokens in loopback-bridge.py), so the
    # download is one more connection in its scheduler. While the bridge does
    # not answer the path is already in trouble, so output falls back to a
    # conservative fixed rate, never to full speed. Other servers are not paced.
    # A paused bridge still grants a slice every eight seconds, so ANSWER
    # seconds of silence mean it is wedged; it is then left alone for SILENT
    # seconds, because reconnecting at once would wait out another timeout per
    # slice and turn the fallback rate into a few bytes per second.
    FALLBACK, ANSWER, RETRY, SILENT = 32 * 1024, 45, 30, 300
    def __init__(self, paced):
        self.out, self.sock, self.port, self.ready, self.retry = sys.stdout.buffer, None, None, 0.0, 0.0
        if paced: self.connect()
    def connect(self):
        # The bridge can come back on another port, so the file is read each time.
        try:
            with open(os.path.expanduser('~/.reverse-proxy-port')) as source: self.port = int(source.read().strip())
        except (OSError, ValueError):
            if self.port is None: return
        try:
            self.sock = socket.create_connection(('127.0.0.1', self.port), timeout=5)
            self.sock.settimeout(self.ANSWER)
            self.sock.sendall(b'RP-TAKE\n')
        except OSError: self.drop(self.RETRY)
    def drop(self, delay):
        try:
            if self.sock is not None: self.sock.close()
        except OSError: pass
        self.sock, self.retry = None, time.monotonic() + delay
    def take(self, count):
        if self.sock is None and time.monotonic() >= self.retry: self.connect()
        if self.sock is not None:
            try:
                self.sock.sendall(b'%d\n' % count)
                line = b''
                while not line.endswith(b'\n'):
                    part = self.sock.recv(64)
                    if not part or len(line) > 64: raise OSError('The pacing connection closed.')
                    line += part
                granted = int(line)
                if 0 < granted <= count: return granted
                self.drop(self.RETRY)
            except socket.timeout: self.drop(self.SILENT)
            except (OSError, ValueError): self.drop(self.RETRY)
        granted = min(count, self.FALLBACK // 10)
        now = time.monotonic()
        if self.ready > now: time.sleep(self.ready - now)
        self.ready = max(now, self.ready) + granted / float(self.FALLBACK)
        return granted
    def write(self, data):
        if self.port is None: self.out.write(data); return
        view = memoryview(data)
        while view:
            granted = self.take(min(len(view), 65536))
            self.out.write(view[:granted]); self.out.flush()
            view = view[granted:]
    def flush(self): self.out.flush()

def export_tree(path, output):
    import struct
    def append(source, relative, depth):
        if depth >= 128: raise ValueError('The folder nesting is too deep.')
        s = os.lstat(source)
        record = dict(path=relative, mode=stat.S_IMODE(s.st_mode), size=0)
        if stat.S_ISDIR(s.st_mode): record['kind'] = 'directory'
        elif stat.S_ISREG(s.st_mode): record.update(kind='file', size=s.st_size)
        elif stat.S_ISLNK(s.st_mode): record.update(kind='symlink', link=os.readlink(source))
        else: raise ValueError('Special files cannot be transferred.')
        data = json.dumps(record).encode()
        if len(data) > 65536: raise ValueError('The path is too long.')
        output.write(struct.pack('!I', len(data))); output.write(data)
        if record['kind'] == 'directory':
            for name in sorted(os.listdir(source)): append(os.path.join(source, name), relative + '/' + name, depth + 1)
        elif record['kind'] == 'file':
            with os.fdopen(os.open(source, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW), 'rb') as handle:
                before = os.fstat(handle.fileno())
                if not stat.S_ISREG(before.st_mode) or (before.st_ino, before.st_size) != (s.st_ino, s.st_size): raise ValueError('The file changed. Try again.')
                left = s.st_size
                while left:
                    data = stream_exact(handle, min(left, 1048576)); output.write(data); left -= len(data)
    append(path, 'item', 0)
    output.write(b'\0\0\0\0'); output.flush()

def import_tree(parent, name):
    import struct
    staging = tempfile.mkdtemp(prefix='.harbor-transfer-', dir=parent)
    seen, directories = set(), {}
    try:
        source = sys.stdin.buffer
        while True:
            size, = struct.unpack('!I', stream_exact(source, 4))
            if size == 0: break
            if size > 65536: raise ValueError('The transfer format is invalid.')
            record = json.loads(stream_exact(source, size))
            relative = record['path']; parts = relative.split('/')
            if len(seen) >= 1000000 or parts[0] != 'item' or any(p in ('', '.', '..') or '\0' in p for p in parts) or relative in seen or (len(parts) > 1 and os.path.dirname(relative) not in directories): raise ValueError('The transfer path is invalid.')
            seen.add(relative); target = os.path.join(staging, relative); kind = record['kind']; mode = int(record['mode']) & 0o777
            if kind == 'directory': os.mkdir(target, 0o700); directories[relative] = mode
            elif kind == 'file':
                left = int(record['size'])
                if left < 0: raise ValueError('The file size is invalid.')
                with open(target, 'xb') as output:
                    while left:
                        data = stream_exact(source, min(left, 1048576)); output.write(data); left -= len(data)
                os.chmod(target, mode)
            elif kind == 'symlink':
                link = record['link']; resolved = os.path.abspath(os.path.join(os.path.dirname(target), link)); root = os.path.join(staging, 'item')
                if os.path.isabs(link) or '\0' in link or not (resolved == root or resolved.startswith(root + '/')): raise ValueError('Symbolic links outside the directory cannot be transferred.')
                os.symlink(link, target)
            else: raise ValueError('The transfer type is invalid.')
        if 'item' not in seen or source.read(1): raise ValueError('The transfer data is incomplete.')
        for relative, mode in sorted(directories.items(), key=lambda pair: len(pair[0]), reverse=True): os.chmod(os.path.join(staging, relative), mode)
        target = destination(parent, name, True)
        no_replace(os.path.join(staging, 'item'), target)
        return target
    finally: shutil.rmtree(staging, ignore_errors=True)

# One request per SSH channel. Paths and file contents arrive as JSON on stdin.
# Nothing is installed or run persistently on the server.
try:
    request = json.loads(base64.b64decode(sys.argv[1])) if len(sys.argv) > 1 else json.loads(sys.stdin.buffer.read(3 * 1024 * 1024))
    path = os.path.abspath(os.path.expanduser(request.get('path') or '~'))
    op = request['op']
    if op == 'search':
        print(json.dumps(search_workspace(path, request)))
    elif op == 'list':
        print(json.dumps(list_directory(path, request.get('hidden'))))
    elif op == 'refresh':
        directories, files = request.get('directories', []), request.get('files', [])
        if len(directories) > 32 or len(files) > 16: raise ValueError('The refresh request exceeds the limit.')
        result = dict(directories=[], files=[])
        for item in directories:
            target = os.path.abspath(os.path.expanduser(item['path']))
            update = dict(path=item['path'], listing=None, error=None)
            try:
                stamp = directory_stamp(target)
                if item.get('stamp') != stamp:
                    update['listing'] = list_directory(target, request.get('hidden'))
            except OSError as error: update['error'] = str(error)
            result['directories'].append(update)
        for target in files:
            update = dict(path=target, entry=None, error=None)
            try:
                s = os.stat(target)
                update['entry'] = dict(path=target, name=os.path.basename(target), directory=stat.S_ISDIR(s.st_mode), size=s.st_size, modified=s.st_mtime)
            except OSError as error: update['error'] = str(error)
            result['files'].append(update)
        print(json.dumps(result))
    elif op == 'read':
        limit = min(int(request['limit']), 512 * 1024 * 1024)
        with os.fdopen(os.open(path, os.O_RDONLY | os.O_NONBLOCK), 'rb', buffering=0) as source:
            s = os.fstat(source.fileno())
            if not stat.S_ISREG(s.st_mode) or s.st_size > limit: raise ValueError('This is not a regular file, or it exceeds the preview size limit.')
            remaining, output = limit, PacedOutput(request.get('paced'))
            while remaining:
                chunk = source.read(min(1024 * 1024, remaining))
                if not chunk: break
                output.write(chunk)
                remaining -= len(chunk)
            output.flush()
            if source.read(1): raise ValueError('The file grew while reading. Try again.')
    elif op == 'write':
        path = os.path.realpath(path)
        data = base64.b64decode(request['data'], validate=True)
        if len(data) > 2 * 1024 * 1024: raise ValueError('The code editor supports files up to 2 MB.')
        with os.fdopen(os.open(path, os.O_RDONLY | os.O_NONBLOCK), 'rb') as source:
            before = os.fstat(source.fileno())
            if not stat.S_ISREG(before.st_mode) or before.st_size > 2 * 1024 * 1024: raise ValueError('The file type or size changed.')
            current = source.read(2 * 1024 * 1024 + 1)
        if hashlib.sha256(current).hexdigest() != request['digest']: raise ValueError('Another application changed this file. It was not overwritten. Copy your changes before reloading.')
        fd, temporary = tempfile.mkstemp(prefix='.harbor-save-', dir=os.path.dirname(path))
        try:
            with os.fdopen(fd, 'wb') as output:
                output.write(data)
                output.flush()
                os.fsync(output.fileno())
                os.fchmod(output.fileno(), stat.S_IMODE(before.st_mode))
            now = os.stat(path)
            if (now.st_ino, now.st_size, now.st_mtime_ns) != (before.st_ino, before.st_size, before.st_mtime_ns): raise ValueError('The file changed while saving and was not overwritten.')
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary): os.unlink(temporary)
        print('{}')
    elif op in ('copy', 'move', 'rename'):
        parent = os.path.abspath(os.path.expanduser(request['parent']))
        if path in ('/', os.path.expanduser('~')): raise ValueError('The entire login directory cannot be moved or copied.')
        if os.path.isdir(path) and not os.path.islink(path):
            source_real, parent_real = os.path.realpath(path), os.path.realpath(parent)
            if parent_real == source_real or parent_real.startswith(source_real + '/'): raise ValueError('A folder cannot be moved into itself or one of its subfolders.')
        target = destination(parent, request.get('name') or os.path.basename(path), op == 'copy')
        if op == 'copy':
            staging = tempfile.mkdtemp(prefix='.harbor-copy-', dir=parent)
            try:
                copy_item(path, os.path.join(staging, 'item')); no_replace(os.path.join(staging, 'item'), target)
            finally: shutil.rmtree(staging, ignore_errors=True)
        else: no_replace(path, target)
        print(json.dumps(dict(path=target)))
    elif op == 'trash':
        home = os.path.expanduser('~')
        if path in ('/', home): raise ValueError('The entire login directory cannot be deleted.')
        trash = os.path.join(home, '.local', 'share', 'Harbor', 'Trash')
        os.makedirs(trash, mode=0o700, exist_ok=True)
        if os.path.realpath(path) == os.path.realpath(trash) or os.path.realpath(trash).startswith(os.path.realpath(path) + '/'): raise ValueError('The trash directory cannot be deleted.')
        slot = tempfile.mkdtemp(prefix='deleted-', dir=trash)
        target = os.path.join(slot, os.path.basename(path))
        with open(os.path.join(slot, 'restore.json'), 'x') as record: json.dump(dict(original=path, stored=target), record)
        try: no_replace(path, target)
        except Exception:
            shutil.rmtree(slot, ignore_errors=True); raise
        print(json.dumps(dict(path=target)))
    elif op == 'export': export_tree(path, PacedOutput(request.get('paced')))
    elif op == 'import':
        print(json.dumps(dict(path=import_tree(path, request['name']))))
    elif op == 'cwd':
        result = {}
        for item in request.get('sessions', [])[:128]:
            try:
                pid = int(item['pid']); token = item['token']
                base = '/proc/' + str(pid)
                if os.stat(base).st_uid != os.getuid(): continue
                with open(base + '/environ', 'rb') as source: environment = source.read(1048576).split(b'\0')
                if ('HARBOR_SESSION_ID=' + token).encode() not in environment: continue
                result[token] = os.readlink(base + '/cwd')
            except (ValueError, OSError): pass
        print(json.dumps(result))
    elif op == 'mkdir':
        os.mkdir(path)
        print('{}')
    elif op == 'create':
        with open(path, 'xb'): pass
        print('{}')
    else: raise ValueError('Unknown file operation.')
except Exception as error:
    print(str(error), file=sys.stderr)
    sys.exit(1)
