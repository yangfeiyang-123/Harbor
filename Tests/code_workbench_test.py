"""Exercise installer boundaries without downloads or live server processes."""
import hashlib
import importlib.util
import io
import json
import os
import shutil
import sqlite3
import sys
import select
import subprocess
import tarfile
import tempfile
import time
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

source = Path(__file__).resolve().parents[1] / 'Sources/HarborSSH/Resources/CodeWorkbench/bootstrap.py'
# The scripts under test are app resources: a __pycache__ beside them would be bundled into the app.
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('code_bootstrap', source)
boot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(boot)


def layout_original():
    revisions = boot.HOST_LAYOUT_PREVIOUS_PATCH_SETS + (boot.HOST_LAYOUT_PATCHES,)
    return '\n'.join(dict.fromkeys(old for revision in revisions for old, _ in revision))


class BootstrapTests(unittest.TestCase):
    def layout_fixture(self, root, content):
        runtime = Path(root) / 'runtime'
        script = runtime / boot.HOST_LAYOUT_PATH
        script.parent.mkdir(parents=True)
        script.write_bytes(content)
        script.chmod(0o644)
        return runtime / 'bin/code-server', script

    def test_host_layout_patch_preserves_original_and_is_idempotent(self):
        # Use upstream decision prefixes with independent surrounding content
        # so a partial patch cannot pass the hash gate.
        content = ('/* upstream license */\n' + layout_original() + '\n/* end */').encode()
        with tempfile.TemporaryDirectory() as temp:
            binary, script = self.layout_fixture(temp, content)
            with patch.dict(boot.HOST_LAYOUT_HASHES, {boot.VERSION: {hashlib.sha256(content).hexdigest()}}):
                boot.patch_host_layout(binary)
                updated = script.read_text()
                for old, new in boot.HOST_LAYOUT_PATCHES:
                    self.assertEqual(updated.count(new), 1)
                    updated = updated.replace(new, old)
                self.assertEqual(updated.encode(), content)
                before = script.stat().st_mtime_ns
                boot.patch_host_layout(binary)
                self.assertEqual(script.stat().st_mtime_ns, before)
                self.assertEqual(script.stat().st_mode & 0o777, 0o644)

    def test_host_layout_upgrades_complete_previous_revisions(self):
        original = layout_original()
        for revision in boot.HOST_LAYOUT_PREVIOUS_PATCH_SETS:
            with self.subTest(patches=len(revision)), tempfile.TemporaryDirectory() as temp:
                previous = original
                for old, new in revision:
                    previous = previous.replace(old, new)
                binary, script = self.layout_fixture(temp, previous.encode())
                with patch.dict(boot.HOST_LAYOUT_HASHES, {boot.VERSION: {hashlib.sha256(original.encode()).hexdigest()}}):
                    boot.patch_host_layout(binary)
                    for _, new in boot.HOST_LAYOUT_PATCHES:
                        self.assertEqual(script.read_text().count(new), 1)
                    before = script.stat().st_mtime_ns
                    boot.patch_host_layout(binary)
                    self.assertEqual(script.stat().st_mtime_ns, before)

    def test_host_layout_rejects_mixed_revision_without_write(self):
        original = layout_original()
        for revision in boot.HOST_LAYOUT_PREVIOUS_PATCH_SETS:
            previous = original
            for old, new in revision:
                previous = previous.replace(old, new)
            # An incomplete upgrade cannot be mistaken for any released set.
            previous = previous.replace(*boot.HOST_LAYOUT_PATCHES[-2])
            previous += '\n// incomplete upgrade'
            with self.subTest(patches=len(revision)), tempfile.TemporaryDirectory() as temp:
                binary, script = self.layout_fixture(temp, previous.encode())
                with patch.dict(boot.HOST_LAYOUT_HASHES, {boot.VERSION: {hashlib.sha256(original.encode()).hexdigest()}}):
                    with self.assertRaisesRegex(RuntimeError, 'Unsupported Code-OSS workbench layout'):
                        boot.patch_host_layout(binary)
                self.assertEqual(script.read_text(), previous)

    def test_host_layout_rejects_unknown_hash_version_or_ambiguous_anchor_without_write(self):
        valid = layout_original().encode()
        for kind in ['unknown-hash', 'unknown-version', 'duplicate-anchor', 'missing-anchor', 'partial-patch']:
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temp:
                content = valid
                if kind == 'duplicate-anchor': content += boot.HOST_LAYOUT_PATCHES[0][0].encode()
                if kind == 'missing-anchor': content = b'known but incompatible workbench'
                if kind == 'partial-patch': content = content.replace(*[p.encode() for p in boot.HOST_LAYOUT_PATCHES[0]])
                binary, script = self.layout_fixture(temp, content)
                hashes = {hashlib.sha256(content if kind in ['duplicate-anchor', 'missing-anchor'] else valid).hexdigest()}
                if kind == 'unknown-hash': hashes = {'0' * 64}
                with patch.dict(boot.HOST_LAYOUT_HASHES, {boot.VERSION: hashes}), patch.object(boot, 'VERSION', 'future' if kind == 'unknown-version' else boot.VERSION):
                    with self.assertRaisesRegex(RuntimeError, 'Unsupported Code-OSS workbench layout'):
                        boot.patch_host_layout(binary)
                self.assertEqual(script.read_bytes(), content)

    def test_host_layout_real_pinned_workbench(self):
        # Point at an unpacked official archive for release QA. Never mutate the
        # fixture/runtime itself; exercise the full 19 MB file in an isolated copy.
        fixture = os.environ.get('HARBOR_CODE_WORKBENCH_FIXTURE')
        if not fixture: self.skipTest('Opt-in: set HARBOR_CODE_WORKBENCH_FIXTURE to official workbench.js')
        original = Path(fixture).read_bytes()
        with tempfile.TemporaryDirectory() as temp:
            binary, script = self.layout_fixture(temp, original)
            boot.patch_host_layout(binary)
            self.assertNotEqual(script.read_bytes(), original)
            first = script.read_bytes()
            node = shutil.which('node')
            self.assertIsNotNone(node, 'Real-runtime QA requires Node.js to verify patched JavaScript')
            subprocess.run([node, '--check', str(script)], check=True, capture_output=True, text=True)
            source = first.decode()
            visibility = source[source.index('function vq('):source.index('var K8t=', source.index('function vq('))]
            listener_start = source.index(boot.HOST_LAYOUT_PATCHES[1][1])
            listener_end = source.index('this.doUpdateLayoutConfiguration()', listener_start) + len('this.doUpdateLayoutConfiguration()')
            listener = source[listener_start:listener_end]
            # Execute the actual patched decision code with small service stubs.
            # The browser layout remains upstream, while embedded layout omits
            # the duplicate title bar and never writes the unknown desktop key.
            check = '''
const assert = require('node:assert/strict');
const FF=()=>true, LD=()=>false, Lz=()=>false, Wt=true, Ct=false, Fs=false,
      O$=()=>false, ave=()=>false, jM=()=>false,
      PA=s=>s.getValue('window.menuBarVisibility');
const values={'window.commandCenter':false,'workbench.activityBar.location':'top',
              'window.menuBarVisibility':'hidden','window.customTitleBarVisibility':'never'};
const config={getValue:key=>values[key]};
''' + visibility + '''
globalThis.__harborEmbeddedWorkbench=true; assert.equal(vq(config,{},false),false);
globalThis.__harborEmbeddedWorkbench=false; assert.equal(vq(config,{},false),true);
const n={affectsConfiguration:key=>key==='workbench.activityBar.location'}, a=false,c=false,l=false;
let writes=0, layouts=0;
const target={configurationService:{...config,updateValue:()=>writes++},doUpdateLayoutConfiguration:()=>layouts++};
function onChange(){''' + listener + '''}
globalThis.__harborEmbeddedWorkbench=true; onChange.call(target); assert.equal(writes,0); assert.equal(layouts,1);
globalThis.__harborEmbeddedWorkbench=false; onChange.call(target); assert.equal(writes,1); assert.equal(layouts,1);
'''
            subprocess.run([node, '-e', check], check=True, capture_output=True, text=True)
            behavior = subprocess.run([node, str(Path(__file__).with_name('code_workbench_layout_test.js')), str(script)], capture_output=True, text=True)
            self.assertEqual(behavior.returncode, 0, behavior.stderr[:4000])
            boot.patch_host_layout(binary)
            self.assertEqual(script.read_bytes(), first)
            # Also upgrade each complete released patch revision on the real
            # official bundle, including the old API implementation.
            for revision in boot.HOST_LAYOUT_PREVIOUS_PATCH_SETS:
                previous = original.decode()
                for old, new in revision:
                    self.assertEqual(previous.count(old), 1)
                    previous = previous.replace(old, new)
                script.write_text(previous)
                boot.patch_host_layout(binary)
                self.assertEqual(script.read_bytes(), first)
            # Unknown edits to a previously patched runtime must still fail.
            script.write_bytes(first + b'\n// unrelated modification')
            with self.assertRaisesRegex(RuntimeError, 'Unsupported Code-OSS workbench layout'):
                boot.patch_host_layout(binary)

    def test_what_a_program_copies_in_the_terminal_reaches_harbors_clipboard(self):
        fixture = os.environ.get('HARBOR_CODE_WORKBENCH_FIXTURE')
        if not fixture: self.skipTest('Opt-in: set HARBOR_CODE_WORKBENCH_FIXTURE to official workbench.js')
        with tempfile.TemporaryDirectory() as temp:
            binary, script = self.layout_fixture(temp, Path(fixture).read_bytes())
            boot.patch_host_layout(binary)
            source = script.read_text()
        # The terminal's OSC 52 provider, as patched, run with stubs for the workbench's clipboard
        # service (g) and for the page's clipboard, which in Harbor is its bridge to the pasteboard.
        start = source.index('async writeText(R,M){if(globalThis.__harborEmbeddedWorkbench')
        end = source.index('"selection":"clipboard")}', start) + len('"selection":"clipboard")}')
        check = '''
const assert = require('node:assert/strict');
(async () => {
  const kept = [], sent = [];
  const g = {writeText: async (text, type) => { kept.push([text, type]); }};
  Object.defineProperty(globalThis, 'navigator', {configurable: true, value: {clipboard: {writeText: async text => { sent.push(text); }}}});
  const provider = {%s};
  // An ordinary browser page: as upstream, the text stays in the workbench's own table.
  await provider.writeText('c', 'browser');
  assert.deepEqual(sent, []); assert.deepEqual(kept, [['browser', 'clipboard']]);
  // In Harbor it goes to the pasteboard as well: "c", and no target at all (tmux).
  globalThis.__harborEmbeddedWorkbench = true;
  await provider.writeText('c', 'from codex'); await provider.writeText('', 'from tmux');
  assert.deepEqual(sent, ['from codex', 'from tmux']);
  assert.deepEqual(kept.slice(1), [['from codex', 'clipboard'], ['from tmux', 'clipboard']]);
  // The primary selection is not the clipboard.
  await provider.writeText('p', 'selected'); assert.equal(sent.length, 2); assert.deepEqual(kept.at(-1), ['selected', 'selection']);
  // A bridge that refuses does not lose the workbench's own copy.
  globalThis.navigator.clipboard.writeText = async () => { throw new Error('refused'); };
  const error = console.error; console.error = () => {};
  await provider.writeText('c', 'kept anyway'); console.error = error;
  assert.deepEqual(kept.at(-1), ['kept anyway', 'clipboard']);
})().catch(error => { console.error(error); process.exit(1); });
''' % source[start:end]
        node = shutil.which('node')
        self.assertIsNotNone(node, 'Real-runtime QA requires Node.js to verify patched JavaScript')
        result = subprocess.run([node, '-e', check], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr[:4000])
        # With the bridge in the page, the workbench does not begin a write of its own at every
        # key press and click; without it (a browser, Safari) it does as upstream.
        guard = '!(globalThis.__harborEmbeddedWorkbench===true&&globalThis.webkit?.messageHandlers?.harborClipboard)&&this.installWebKitWriteTextWorkaround()'
        self.assertEqual(source.count(guard), 1)

    def test_markdown_scroll_real_pinned_preview(self):
        fixture = os.environ.get('HARBOR_CODE_WORKBENCH_FIXTURE')
        if not fixture: self.skipTest('Opt-in: set HARBOR_CODE_WORKBENCH_FIXTURE to official workbench.js')
        runtime = next(parent for parent in Path(fixture).parents if (parent / boot.MARKDOWN_SCROLL_PATH).is_file())
        original = (runtime / boot.MARKDOWN_SCROLL_PATH).read_bytes()
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / boot.MARKDOWN_SCROLL_PATH
            target.parent.mkdir(parents=True); target.write_bytes(original)
            binary = Path(temp) / 'bin/code-server'
            boot.patch_markdown_scroll(binary)
            current = target.read_bytes()
            self.assertNotEqual(current, original)
            node = shutil.which('node')
            self.assertIsNotNone(node)
            subprocess.run([node, '--check', str(target)], check=True, capture_output=True, text=True)
            behavior = subprocess.run([node, str(Path(__file__).with_name('code_workbench_markdown_test.js')), str(target)], capture_output=True, text=True)
            self.assertEqual(behavior.returncode, 0, behavior.stderr[:4000])
            before = target.stat().st_mtime_ns
            boot.patch_markdown_scroll(binary)
            self.assertEqual(target.stat().st_mtime_ns, before)
            for contents in [current + b'\n// unrelated modification', original.replace(*[value.encode() for value in boot.MARKDOWN_SCROLL_PATCHES[0]])]:
                target.write_bytes(contents)
                with self.assertRaisesRegex(RuntimeError, 'Unsupported Code-OSS Markdown preview'):
                    boot.patch_markdown_scroll(binary)
                self.assertEqual(target.read_bytes(), contents)

    def test_revision_runtime_clones_verified_legacy_without_modifying_it(self):
        original = layout_original()
        previous = original
        for old, new in boot.HOST_LAYOUT_PATCHES_V3:
            previous = previous.replace(old, new)
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            legacy = root / ('code-server-%s-linux-amd64' % boot.VERSION)
            script = legacy / boot.HOST_LAYOUT_PATH
            script.parent.mkdir(parents=True)
            script.write_text(previous)
            binary = legacy / 'bin/code-server'
            binary.parent.mkdir(); binary.write_text('immutable launcher'); binary.chmod(0o755)
            markdown = legacy / boot.MARKDOWN_SCROLL_PATH
            markdown.parent.mkdir(parents=True)
            markdown_original = '\n'.join(old for old, _ in boot.MARKDOWN_SCROLL_PATCHES)
            markdown.write_text(markdown_original)
            before = script.stat().st_ino
            with patch.object(boot.platform, 'system', return_value='Linux'), patch.object(boot.platform, 'machine', return_value='x86_64'), patch.dict(boot.HOST_LAYOUT_HASHES, {boot.VERSION: {hashlib.sha256(original.encode()).hexdigest()}}), patch.dict(boot.MARKDOWN_SCROLL_HASHES, {boot.VERSION: {hashlib.sha256(markdown_original.encode()).hexdigest()}}):
                installed = boot.install(root)
                self.assertNotEqual(installed, binary)
                self.assertIn(boot.HOST_LAYOUT_REVISION, str(installed))
                self.assertEqual(script.stat().st_ino, before)
                self.assertEqual(script.read_text(), previous)
                current = installed.parent.parent / boot.HOST_LAYOUT_PATH
                self.assertNotEqual(current.stat().st_ino, before)
                self.assertNotIn('harbor.nativeTerminal', current.read_text())
                self.assertEqual(installed.stat().st_ino, binary.stat().st_ino, 'immutable package files are shared without extra copies')
                self.assertEqual(boot.install(root), installed)
                with patch.object(boot, 'HOST_LAYOUT_REVISION', 'builtin-terminal-future'):
                    future = boot.install(root)
                    self.assertNotEqual(future, installed)
                    self.assertEqual(current.read_text(), (future.parent.parent / boot.HOST_LAYOUT_PATH).read_text())

    def test_unknown_legacy_runtime_is_not_mutated_or_reused(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            legacy = root / ('code-server-%s-linux-amd64' % boot.VERSION)
            script = legacy / boot.HOST_LAYOUT_PATH
            script.parent.mkdir(parents=True); script.write_text('unknown patch')
            binary = legacy / 'bin/code-server'; binary.parent.mkdir(); binary.touch()
            bad_archive = root / 'archive'; bad_archive.write_bytes(b'not an official release')
            with patch.object(boot.platform, 'system', return_value='Linux'), patch.object(boot.platform, 'machine', return_value='x86_64'):
                with self.assertRaisesRegex(RuntimeError, 'SHA-256'):
                    boot.install(root, str(bad_archive))
            self.assertEqual(script.read_text(), 'unknown patch')

    def test_profile_migration_snapshots_live_state_and_preserves_old_service(self):
        with tempfile.TemporaryDirectory() as temp:
            base = boot.private(Path(temp) / 'owner')
            user = base / 'user-data/User'; user.mkdir(parents=True)
            settings = '// User JSONC\n{"editor.fontSize":17}\n'
            (user / 'settings.json').write_text(settings)
            backups = base / 'user-data/Backups'; backups.mkdir(); (backups / 'dirty.txt').write_text('unsaved')
            cache = base / 'user-data/Cache'; cache.mkdir(); (cache / 'large').write_text('excluded')
            old_runtime = {'version': boot.VERSION, 'port': 12345, 'token': 'old-service'}
            boot.save(base / 'runtime.json', old_runtime)
            (base / 'lease').touch()
            extension = base / 'extensions/example.language-1.0'; extension.mkdir(parents=True)
            (extension / 'package.json').write_text('{}')
            old_harbor = base / 'extensions/harbor.workbench-1.0'; old_harbor.mkdir()
            with sqlite3.connect(user / 'state.vscdb') as database:
                database.execute('PRAGMA journal_mode=WAL')
                database.execute('CREATE TABLE ItemTable (key TEXT, value TEXT)')
                database.execute('INSERT INTO ItemTable VALUES (?, ?)', ('currentFolder', '/workspace')); database.commit()
                profile = boot.service_profile(base)
                with sqlite3.connect(profile / 'user-data/User/state.vscdb') as migrated:
                    self.assertEqual(migrated.execute('SELECT value FROM ItemTable').fetchone(), ('/workspace',))
            self.assertEqual((profile / 'user-data/User/settings.json').read_text(), settings)
            self.assertEqual((profile / 'user-data/Backups/dirty.txt').read_text(), 'unsaved')
            self.assertFalse((profile / 'user-data/Cache').exists())
            self.assertFalse((profile / 'runtime.json').exists())
            self.assertFalse((base / 'stop').exists())
            self.assertEqual(boot.load(base / 'runtime.json'), old_runtime)
            self.assertFalse((profile / 'extensions/example.language-1.0').is_symlink())
            self.assertEqual((profile / 'extensions/example.language-1.0/package.json').stat().st_ino, (extension / 'package.json').stat().st_ino)
            self.assertFalse((profile / 'extensions/harbor.workbench-1.0').exists())
            (profile / 'user-data/User/settings.json').write_text('new personal setting')
            self.assertEqual(boot.service_profile(base), profile)
            self.assertEqual((profile / 'user-data/User/settings.json').read_text(), 'new personal setting')
            self.assertEqual((user / 'settings.json').read_text(), settings)
            # A future revision inherits the most recent durable profile and
            # reuses package bytes while keeping independent directory entries.
            with patch.object(boot, 'HOST_LAYOUT_REVISION', 'builtin-terminal-next'):
                future = boot.service_profile(base)
                self.assertNotEqual(future, profile)
                self.assertEqual((future / 'user-data/User/settings.json').read_text(), 'new personal setting')
                self.assertFalse((future / 'extensions/example.language-1.0').is_symlink())
                self.assertEqual((future / 'extensions/example.language-1.0/package.json').stat().st_ino, (extension / 'package.json').stat().st_ino)
            shutil.rmtree(extension)
            self.assertEqual((profile / 'extensions/example.language-1.0/package.json').read_text(), '{}')
            self.assertEqual((future / 'extensions/example.language-1.0/package.json').read_text(), '{}')

    def test_immutable_package_copy_falls_back_across_filesystems(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / 'original'; source.write_text('package'); target = Path(temp) / 'copy'
            with patch.object(boot.os, 'link', side_effect=OSError('cross-device link')):
                boot.clone_immutable_file(source, target)
            source.unlink()
            self.assertEqual(target.read_text(), 'package')

    def test_supervisor_keeps_disconnected_tty_and_reclaims_only_idle_service(self):
        scope = {'__name__': 'supervisor_test'}
        exec(boot.SUPERVISOR_SOURCE, scope)
        table = '100 1 ?\n101 100 ?\n102 101 pts/7\n200 1 pts/9\n'
        result = subprocess.CompletedProcess([], 0, stdout=table)
        with tempfile.TemporaryDirectory() as temp:
            data = Path(temp); lease = data / 'lease'; lease.touch()
            os.utime(lease, (1, 1))
            with patch.object(scope['subprocess'], 'run', return_value=result) as inspect:
                self.assertFalse(scope['should_stop'](data, 100, 1810), 'a disconnected shell survives idle cleanup')
                self.assertEqual(inspect.call_args.args[0], ['ps', '-A', '-o', 'pid=,ppid=,tty='])
            no_shell = subprocess.CompletedProcess([], 0, stdout='100 1 ??\n101 100 ??\n200 1 ttys006\n')
            with patch.object(scope['subprocess'], 'run', return_value=no_shell):
                self.assertTrue(scope['should_stop'](data, 100, 1810), 'unrelated terminals do not pin an idle service')
            with patch.object(scope['subprocess'], 'run') as inspect:
                self.assertFalse(scope['should_stop'](data, 100, 1700))
                inspect.assert_not_called()
            for problem in (OSError('cannot inspect'), subprocess.TimeoutExpired('ps', 3)):
                with patch.object(scope['subprocess'], 'run', side_effect=problem):
                    self.assertFalse(scope['should_stop'](data, 100, 1810), 'process inspection failure must never kill user shells')
            (data / 'stop').touch()
            with patch.object(scope['subprocess'], 'run') as inspect:
                self.assertTrue(scope['should_stop'](data, 100, 1810), 'explicit shutdown remains available')
                inspect.assert_not_called()

    @unittest.skipUnless(hasattr(os, 'forkpty'), 'PTY test needs POSIX')
    def test_supervisor_recognizes_its_own_live_pty_process(self):
        scope = {'__name__': 'supervisor_test'}
        exec(boot.SUPERVISOR_SOURCE, scope)
        child = """import os,sys,time,signal
pid,fd=os.forkpty()
if pid==0:
 time.sleep(10);os._exit(0)
print(pid,flush=True)
try: sys.stdin.read()
finally:
 try: os.kill(pid,signal.SIGTERM)
 except ProcessLookupError: pass
 os.waitpid(pid,0);os.close(fd)
"""
        process = subprocess.Popen([sys.executable, '-c', child], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.assertTrue(select.select([process.stdout], [], [], 5)[0], 'isolated test PTY started')
            self.assertGreater(int(process.stdout.readline()), 0)
            self.assertTrue(scope['has_live_terminal'](process.pid))
        finally:
            process.communicate('', timeout=5)
        self.assertEqual(process.returncode, 0)

    def test_session_socket_fits_macos_limit_and_is_isolated(self):
        with tempfile.TemporaryDirectory() as temp:
            data = Path(temp) / ('long-private-data-path-' * 8)
            with patch.object(boot, 'private', side_effect=lambda p: p):
                first = boot.session_socket(data)
                second = boot.session_socket(data / 'another-owner')
            self.assertLess(len(str(first).encode()), 104)
            self.assertNotEqual(first, second)
            self.assertEqual(first.parent.parent, Path('/tmp'))

    def test_archive_traversal_and_external_links_are_rejected(self):
        for name, link in [('../escape', None), ('runtime/link', '/tmp/outside')]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temp:
                root = Path(temp); archive = root / 'fixture.tar.gz'
                with tarfile.open(archive, 'w:gz') as tar:
                    item = tarfile.TarInfo(name)
                    if link:
                        item.type = tarfile.SYMTYPE; item.linkname = link
                    tar.addfile(item)
                checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
                with patch.object(boot.platform, 'system', return_value='Linux'), patch.object(boot.platform, 'machine', return_value='x86_64'), patch.dict(boot.DIGESTS, {'linux-amd64': checksum}), redirect_stdout(io.StringIO()):
                    with self.assertRaisesRegex(RuntimeError, 'Unsafe'):
                        boot.install(root, str(archive))

    def test_checksum_mismatch_rejects_before_extracting(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); archive = root / 'fixture'; archive.write_bytes(b'not an official archive')
            with self.assertRaisesRegex(RuntimeError, 'SHA-256'):
                boot.install(root, str(archive))

    def test_reuse_keeps_personal_settings_and_returns_new_folder(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); data = boot.service_profile(boot.private(root / 'test-owner')); user = data / 'user-data/User'; user.mkdir(parents=True)
            settings = user / 'settings.json'; personal = '// personal JSONC\n{"editor.fontSize": 17}\n'; settings.write_text(personal)
            boot.save(data / 'runtime.json', {'version': boot.VERSION, 'layoutRevision': boot.HOST_LAYOUT_REVISION, 'port': 12345, 'token': 'fixture', 'password': 'fixture'})
            folder = root / 'another-project'; folder.mkdir(); output = io.StringIO()
            with patch.object(boot, 'install', return_value=Path('/unused')), patch.object(boot, 'available', return_value=True), redirect_stdout(output):
                boot.main({'owner': 'test-owner', 'storage': str(root), 'folder': str(folder), 'settings': {'editor.fontSize': 9}})
            reply = json.loads(output.getvalue())['result']
            self.assertTrue(reply['reused']); self.assertEqual(reply['folder'], str(folder.resolve()))
            self.assertEqual(settings.read_text(), personal)
            self.assertEqual(data.stat().st_mode & 0o777, 0o700)

    def test_extension_cannot_write_outside_its_directory(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with patch.object(boot, 'install', return_value=Path('/unused')):
                with self.assertRaisesRegex(RuntimeError, 'Invalid extension file'):
                    boot.main({'owner': 'qa', 'storage': temp, 'folder': temp,
                               'extensions': {'valid': {'../../escape': 'bad'}}})
            self.assertFalse((root / 'qa/escape').exists())

    def test_bundled_upgrade_preserves_user_installed_extensions(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            personal = {"identifier": {"id": "ms-pyright.pyright"}, "version": "1.1.402", "metadata": {"installedTimestamp": 42}}
            old = {"identifier": {"id": "harbor.workbench"}, "version": "1.0.0"}
            boot.save(root / "extensions.json", [personal, old])
            bundles = {"harbor.workbench-1.1.0": {"package.json": json.dumps({"publisher": "harbor", "name": "workbench", "version": "1.1.0"})}}
            boot.register_bundled_extensions(root, bundles)
            installed = json.loads((root / "extensions.json").read_text())
            self.assertEqual(installed[0], personal)
            self.assertEqual(installed[1]["version"], "1.1.0")
            self.assertEqual(installed[1]["relativeLocation"], "harbor.workbench-1.1.0")
            before = (root / "extensions.json").stat().st_mtime_ns
            boot.register_bundled_extensions(root, bundles)
            self.assertEqual((root / "extensions.json").stat().st_mtime_ns, before)

    def cleanup_fixture(self, temp):
        """A server after two updates: this Mac's client, another Mac's, and what earlier versions left."""
        root = Path(temp); current = boot.HOST_LAYOUT_REVISION; name = 'code-server-%s-linux-amd64' % boot.VERSION
        for revision in (current, 'builtin-terminal-old1', 'builtin-terminal-old2'):
            binary = root / 'runtimes' / revision / name / 'bin/code-server'; binary.parent.mkdir(parents=True); binary.write_text('#!/bin/sh\n')
        legacy = root / name / 'bin/code-server'; legacy.parent.mkdir(parents=True); legacy.write_text('#!/bin/sh\n')
        (root / 'runtimes' / current / 'clone-stale').mkdir(); (root / 'install-stale').mkdir(); (root / 'archives').mkdir()
        (root / 'archives' / (name + '.slim.part')).write_text('partial upload')
        base = root / 'this-mac'; data = base / 'revisions' / current
        for directory in (data, base / 'revisions/builtin-terminal-old1', base / 'revisions/profile-interrupted', base):
            (directory / 'user-data/User').mkdir(parents=True); (directory / 'user-data/User/settings.json').write_text('{}')
            (directory / 'extensions').mkdir(exist_ok=True)
        boot.save(data / 'migration.json', {'revision': current}); boot.save(base / 'latest-profile.json', {'revision': current})
        boot.save(base / 'revisions/builtin-terminal-old1/runtime.json', {'port': 41001})
        boot.save(base / 'runtime.json', {'port': 41000}); (base / 'config.yaml').write_text('legacy')
        os.utime(base / 'revisions/profile-interrupted', (0, 0))
        other = root / 'other-mac'; (other / 'revisions/builtin-terminal-old2').mkdir(parents=True)
        boot.save(other / 'latest-profile.json', {'revision': 'builtin-terminal-old2'}); (other / 'revisions/builtin-terminal-old2/lease').touch()
        return root, base, data, name

    def test_update_leftovers_are_removed_once_the_new_version_has_settled(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(boot, 'available', return_value=False):
            root, base, data, name = self.cleanup_fixture(Path(temp).resolve())
            names = lambda removed: sorted(str(Path(path).relative_to(root)) for path in removed)
            # Just updated: runtimes nobody will start again go at once, profiles wait a day.
            self.assertEqual(names(boot.prune(root, base, data, dry=True)),
                             ['code-server-%s-linux-amd64' % boot.VERSION, 'install-stale', 'runtimes/%s/clone-stale' % data.name, 'runtimes/builtin-terminal-old1'])
            self.assertTrue((root / 'runtimes/builtin-terminal-old1').is_dir(), 'a dry run removes nothing')
            boot.prune(root, base, data)
            self.assertFalse((root / 'runtimes/builtin-terminal-old1').exists()); self.assertFalse((root / name).exists()); self.assertFalse((root / 'install-stale').exists())
            self.assertTrue((root / 'runtimes' / data.name / name / 'bin/code-server').is_file())
            self.assertTrue((root / 'runtimes/builtin-terminal-old2').is_dir(), "another Mac's Harbor still starts this one")
            self.assertTrue((base / 'revisions/builtin-terminal-old1/user-data/User/settings.json').is_file()); self.assertTrue((base / 'user-data').is_dir())
            self.assertTrue((root / 'archives' / (name + '.slim.part')).is_file(), 'an upload in progress is kept')
            # A day later the previous profile, the pre-revision one and an interrupted migration go too.
            old = data / 'migration.json'; os.utime(old, (old.stat().st_atime, old.stat().st_mtime - boot.PROFILE_SETTLE_SECONDS - 60))
            self.assertEqual(names(boot.prune(root, base, data)), ['this-mac/config.yaml', 'this-mac/extensions', 'this-mac/revisions/builtin-terminal-old1',
                                                              'this-mac/revisions/profile-interrupted', 'this-mac/runtime.json', 'this-mac/user-data'])
            self.assertEqual(sorted(entry.name for entry in base.iterdir()), ['latest-profile.json', 'revisions'])
            self.assertEqual([entry.name for entry in (base / 'revisions').iterdir()], [data.name])
            self.assertTrue((data / 'user-data/User/settings.json').is_file())
            self.assertTrue((root / 'other-mac/revisions/builtin-terminal-old2').is_dir(), "another Mac's profile is never touched")
            self.assertEqual(boot.prune(root, base, data), [], 'nothing is left to remove')
            # Once the other Mac has not connected for a month, its runtime goes; its profile stays.
            lease = root / 'other-mac/revisions/builtin-terminal-old2/lease'; os.utime(lease, (0, 0))
            self.assertEqual(names(boot.prune(root, base, data)), ['runtimes/builtin-terminal-old2'])
            self.assertTrue((root / 'other-mac/revisions/builtin-terminal-old2').is_dir())

    def test_a_running_older_editor_keeps_its_profile_and_runtime(self):
        with tempfile.TemporaryDirectory() as temp:
            root, base, data, name = self.cleanup_fixture(Path(temp).resolve())
            # Terminals can outlive an update for days inside the previous revision's editor.
            with patch.object(boot, 'available', side_effect=lambda port: port == 41001):
                removed = boot.prune(root, base, data, force=True)
            self.assertTrue((base / 'revisions/builtin-terminal-old1/user-data').is_dir()); self.assertTrue((root / 'runtimes/builtin-terminal-old1').is_dir())
            self.assertIn(str(base / 'user-data'), removed, 'with force the day of waiting is skipped for what is not running')
            # A supervisor that is alive counts even when the editor is too busy to answer.
            boot.save(base / 'revisions/builtin-terminal-old1/runtime.json', {'port': 41001, 'supervisor': os.getpid()})
            with patch.object(boot, 'available', return_value=False), patch.object(boot, 'process_arguments') as arguments:
                arguments.return_value = os.fsencode('python3 -c ... %s [...]' % (base / 'revisions/builtin-terminal-old1'))
                self.assertTrue(boot.service_alive(base / 'revisions/builtin-terminal-old1'))
                arguments.return_value = b'some other process that now has this number'
                self.assertFalse(boot.service_alive(base / 'revisions/builtin-terminal-old1'))
                # Where nothing can be asked, what is being cleaned up is left alone.
                arguments.return_value = None
                self.assertTrue(boot.service_alive(base / 'revisions/builtin-terminal-old1'))
            # An older Harbor on another Mac that has not moved to revisions keeps the old layout's runtime.
            legacy = root / name / 'bin/code-server'; legacy.parent.mkdir(parents=True); legacy.write_text('#!/bin/sh\n')
            (root / 'old-mac/user-data').mkdir(parents=True); (root / 'old-mac/lease').touch()
            with patch.object(boot, 'available', return_value=False):
                boot.prune(root, base, data, force=True)
            self.assertTrue(legacy.is_file()); self.assertTrue((root / 'old-mac/user-data').is_dir())

    def test_earlier_versions_of_harbors_extensions_go_when_no_editor_uses_them(self):
        with tempfile.TemporaryDirectory() as temp:
            extensions = Path(temp)
            for name in ('harbor.workbench-1.5.0', 'harbor.workbench-1.6.1', 'harbor.themes-1.1.0', 'harbor.themes-1.2.0', 'anthropic.claude-code-2.1.288', 'harbor.workbenchmark-1.0.0'):
                (extensions / name).mkdir(); (extensions / name / 'package.json').write_text('{}')
            self.assertEqual(boot.prune_bundled_extensions(extensions), [], 'without the record of what is current nothing is guessed')
            boot.save(extensions / '.harbor-bundles.json', {'digest': 'd', 'names': ['harbor.themes-1.2.0', 'harbor.workbench-1.6.1']})
            self.assertEqual(sorted(Path(path).name for path in boot.prune_bundled_extensions(extensions)), ['harbor.themes-1.1.0', 'harbor.workbench-1.5.0'])
            self.assertEqual(sorted(entry.name for entry in extensions.iterdir() if entry.is_dir()),
                             ['anthropic.claude-code-2.1.288', 'harbor.themes-1.2.0', 'harbor.workbench-1.6.1', 'harbor.workbenchmark-1.0.0'])
            (extensions / 'harbor.workbench-1.6.1/package.json').unlink()
            (extensions / 'harbor.workbench-1.6.0').mkdir()
            self.assertEqual(boot.prune_bundled_extensions(extensions), [], 'an incomplete current version is no reason to remove another')

    def test_cleanup_can_be_asked_for_and_leaves_a_client_that_has_not_updated_alone(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(boot, 'available', return_value=False):
            root, base, data, name = self.cleanup_fixture(Path(temp).resolve())
            def ask(**request):
                output = io.StringIO()
                with redirect_stdout(output):
                    boot.main(dict(owner='this-mac', storage=str(root), op='prune', **request))
                return json.loads(output.getvalue())['result']
            reply = ask(dryRun=True, force=True)
            self.assertTrue(reply['current']); self.assertIn(str(base / 'revisions/builtin-terminal-old1'), reply['removed'])
            self.assertTrue((base / 'revisions/builtin-terminal-old1').is_dir())
            self.assertIn(str(root / 'runtimes/builtin-terminal-old1'), ask(force=True)['removed'])
            self.assertFalse((base / 'revisions/builtin-terminal-old1').exists()); self.assertFalse((base / 'user-data').exists())
            output = io.StringIO()
            with redirect_stdout(output):
                boot.main(dict(owner='other-mac', storage=str(root), op='prune', force=True))
            self.assertEqual(json.loads(output.getvalue())['result'], {'removed': [], 'current': False})
            self.assertFalse((root / 'other-mac/revisions' / boot.HOST_LAYOUT_REVISION).exists(), 'asking creates nothing')

    def test_owner_and_symlink_storage_are_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'Invalid editor identity'):
            boot.main({'owner': '../escape'})
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); target = root / 'real'; target.mkdir(); link = root / 'link'; link.symlink_to(target)
            with self.assertRaisesRegex(RuntimeError, 'must belong'):
                boot.private(link)


class RangeServer:
    """Serves one payload with Range support; can cut the first response short."""
    def __init__(self, payload, cut_first_at=None):
        import http.server, threading
        owner = self; self.payload = payload; self.cut = cut_first_at; self.requests = []
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_GET(self):
                header = self.headers.get('Range'); owner.requests.append(header)
                start = int(header[6:-1]) if header else 0
                if start >= len(owner.payload):
                    self.send_response(416); self.end_headers(); return
                body = owner.payload[start:]
                self.send_response(206 if header else 200)
                self.send_header('Content-Length', str(len(body))); self.end_headers()
                if owner.cut is not None:
                    body = body[:owner.cut]; owner.cut = None
                self.wfile.write(body)
        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.url = 'http://127.0.0.1:%d/archive' % self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
    def close(self):
        self.server.shutdown(); self.server.server_close()


class DownloadTests(unittest.TestCase):
    payload = bytes(range(256)) * 4000

    def fetch(self, server, partial, **options):
        with patch.dict(os.environ, {'no_proxy': '*', 'NO_PROXY': '*'}), patch.object(boot.time, 'sleep'), redirect_stdout(io.StringIO()) as output:
            boot.download_archive(server.url, partial, **options)
        return [json.loads(line) for line in output.getvalue().splitlines()]

    def test_download_continues_from_the_saved_part(self):
        with tempfile.TemporaryDirectory() as temp:
            partial = Path(temp) / 'runtime.tar.gz.part'; partial.write_bytes(self.payload[:300_000])
            server = RangeServer(self.payload)
            try:
                events = self.fetch(server, partial)
            finally:
                server.close()
            self.assertEqual(server.requests, ['bytes=300000-'])
            self.assertEqual(partial.read_bytes(), self.payload)
            self.assertIn('Resuming', events[0]['detail'])

    def test_interrupted_download_keeps_bytes_and_resumes_in_the_same_call(self):
        with tempfile.TemporaryDirectory() as temp:
            partial = Path(temp) / 'runtime.tar.gz.part'
            server = RangeServer(self.payload, cut_first_at=200_000)
            try:
                self.fetch(server, partial)
            finally:
                server.close()
            self.assertEqual(server.requests[0], None)
            self.assertTrue(all(r and r.startswith('bytes=') for r in server.requests[1:]))
            self.assertGreaterEqual(len(server.requests), 2)
            self.assertEqual(partial.read_bytes(), self.payload)

    def test_failed_download_keeps_what_arrived(self):
        with tempfile.TemporaryDirectory() as temp:
            partial = Path(temp) / 'runtime.tar.gz.part'
            server = RangeServer(self.payload, cut_first_at=200_000)
            try:
                with self.assertRaisesRegex(RuntimeError, 'continues from there'):
                    self.fetch(server, partial, attempts=1)
            finally:
                server.close()
            self.assertEqual(partial.read_bytes(), self.payload[:200_000])

    def test_a_complete_part_is_not_fetched_again(self):
        with tempfile.TemporaryDirectory() as temp:
            partial = Path(temp) / 'runtime.tar.gz.part'; partial.write_bytes(self.payload)
            server = RangeServer(self.payload)
            try:
                self.fetch(server, partial)
            finally:
                server.close()
            self.assertEqual(partial.read_bytes(), self.payload)

    def test_interrupted_downloads_of_earlier_versions_are_adopted(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); partial = root / 'archives' / 'runtime.tar.gz.part'; partial.parent.mkdir()
            for name, size in [('install-a', 10), ('install-b', 500), ('install-c', 0)]:
                (root / name).mkdir()
                if size:
                    (root / name / 'runtime.tar.gz').write_bytes(b'x' * size)
            boot.adopt_interrupted_download(root, partial)
            self.assertEqual(partial.stat().st_size, 500)
            self.assertEqual(sorted(p.name for p in root.iterdir()), ['archives'])

    def test_staged_archive_is_installed_without_a_download(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve(); name = 'code-server-%s-linux-amd64' % boot.VERSION
            staged = root / 'archives' / (name + '.tar.gz'); staged.parent.mkdir()
            with tarfile.open(staged, 'w:gz') as tar:
                item = tarfile.TarInfo(name + '/bin/code-server'); item.size = 2
                tar.addfile(item, io.BytesIO(b'ok'))
            checksum = hashlib.sha256(staged.read_bytes()).hexdigest()
            with patch.object(boot.platform, 'system', return_value='Linux'), patch.object(boot.platform, 'machine', return_value='x86_64'), \
                 patch.dict(boot.DIGESTS, {'linux-amd64': checksum}), patch.object(boot, 'patch_runtime'), \
                 patch.object(boot, 'download_archive', side_effect=AssertionError('no download expected')), redirect_stdout(io.StringIO()):
                binary = boot.install(root)
            self.assertEqual(binary.read_text(), 'ok')
            self.assertFalse(staged.exists())

    def test_archive_installs_where_the_home_directory_is_a_link(self):
        # /home/me -> /data/me/home is common on shared servers. The archive's members are checked
        # after resolving links, so the directory they are checked against must be resolved too;
        # otherwise every member of a good archive is refused as "unsafe".
        with tempfile.TemporaryDirectory() as temp:
            real = Path(temp).resolve() / 'data/me/home'; real.mkdir(parents=True)
            home = Path(temp).resolve() / 'home-me'; home.symlink_to(real, target_is_directory=True)
            root = home / '.local/share/harbor/code-oss'; root.mkdir(parents=True)
            self.assertNotEqual(str(root), str(root.resolve()))
            name = 'code-server-%s-linux-amd64' % boot.VERSION
            def stage(extra=()):
                staged = root / 'archives' / (name + '.tar.gz'); staged.parent.mkdir(exist_ok=True)
                with tarfile.open(staged, 'w:gz') as tar:
                    item = tarfile.TarInfo(name + '/bin/code-server'); item.size = 2
                    tar.addfile(item, io.BytesIO(b'ok'))
                    link = tarfile.TarInfo(name + '/bin/code'); link.type = tarfile.SYMTYPE; link.linkname = 'code-server'
                    tar.addfile(link)
                    for member in extra:
                        item = tarfile.TarInfo(member); item.size = 2
                        tar.addfile(item, io.BytesIO(b'no'))
                return hashlib.sha256(staged.read_bytes()).hexdigest()
            def install(checksum):
                with patch.object(boot.platform, 'system', return_value='Linux'), patch.object(boot.platform, 'machine', return_value='x86_64'), \
                     patch.dict(boot.DIGESTS, {'linux-amd64': checksum}), patch.object(boot, 'patch_runtime'), \
                     patch.object(boot, 'download_archive', side_effect=AssertionError('no download expected')), redirect_stdout(io.StringIO()):
                    return boot.install(root)
            # Leaving the directory is still refused through the link,
            with self.assertRaisesRegex(RuntimeError, 'Unsafe path'):
                install(stage(extra=['../escaped']))
            self.assertFalse((root.parent / 'escaped').exists())
            # and a good archive installs.
            binary = install(stage())
            self.assertEqual(binary.read_text(), 'ok'); self.assertEqual((binary.parent / 'code').read_text(), 'ok')
            self.assertEqual([entry.name for entry in root.iterdir() if entry.name.startswith('install-')], [])

    def package(self, root, name):
        """A tiny release with one pruned native payload, and the trimmed package a Mac would send."""
        full = root / 'full.tar.gz'; slim = root / 'slim.tar.xz'
        for path, members in [(full, ['bin/code-server', 'lib/vscode/node_modules/@github/copilot-sdk-linux-x64/runtime.node']), (slim, ['bin/code-server'])]:
            with tarfile.open(path, 'w:gz' if path == full else 'w:xz') as tar:
                for member in members:
                    item = tarfile.TarInfo(name + '/' + member); item.size = 2
                    tar.addfile(item, io.BytesIO(b'ok'))
        return full, slim

    def test_a_server_asks_for_the_package_instead_of_downloading_and_installs_what_the_mac_sends(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve(); name = 'code-server-%s-linux-amd64' % boot.VERSION
            full, slim = self.package(root, name); digest = hashlib.sha256(slim.read_bytes()).hexdigest()
            with patch.object(boot.platform, 'system', return_value='Linux'), patch.object(boot.platform, 'machine', return_value='x86_64'), \
                 patch.dict(boot.DIGESTS, {'linux-amd64': hashlib.sha256(full.read_bytes()).hexdigest()}), patch.object(boot, 'patch_host_layout'), patch.object(boot, 'patch_markdown_scroll'), \
                 patch.object(boot, 'download_archive', side_effect=AssertionError('a server must not download')), redirect_stdout(io.StringIO()):
                with self.assertRaises(boot.ArchiveNeeded) as needed:
                    boot.install(root, download=False)
                self.assertEqual(needed.exception.value['name'], name); self.assertEqual(needed.exception.value['target'], 'linux-amd64')
                self.assertEqual(needed.exception.value['slimHave'], 0); self.assertTrue(needed.exception.value['directory'].endswith('/archives'))
                archives = Path(needed.exception.value['directory'])
                # Half an upload: the server reports how far it got and for which package.
                (archives / (name + '.slim.sha256')).write_text(digest); (archives / (name + '.slim.part')).write_bytes(slim.read_bytes()[:40])
                with self.assertRaises(boot.ArchiveNeeded) as needed:
                    boot.install(root, download=False, slim_digest=digest)
                self.assertEqual((needed.exception.value['slimHave'], needed.exception.value['slimDigest']), (40, digest))
                # A complete upload with the wrong digest is not installed.
                (archives / (name + '.slim.part')).write_bytes(slim.read_bytes())
                with self.assertRaises(boot.ArchiveNeeded):
                    boot.install(root, download=False, slim_digest='0' * 64)
                binary = boot.install(root, download=False, slim_digest=digest)
            self.assertEqual(binary.read_text(), 'ok')
            self.assertEqual(list(archives.iterdir()), [], 'the delivered package is removed once installed')

    def test_a_server_downloads_from_the_relay_chosen_for_it_and_from_github_when_the_relay_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve(); name = 'code-server-%s-linux-amd64' % boot.VERSION
            full, _ = self.package(root, name); fetched = []
            def download(url, partial, attempts=4):
                fetched.append(url)
                if url.startswith('https://ghfast.top/'):
                    partial.write_bytes(full.read_bytes()[:10]); raise RuntimeError('the relay stopped')
                partial.write_bytes(full.read_bytes())
            with patch.object(boot.platform, 'system', return_value='Linux'), patch.object(boot.platform, 'machine', return_value='x86_64'), \
                 patch.dict(boot.DIGESTS, {'linux-amd64': hashlib.sha256(full.read_bytes()).hexdigest()}), patch.object(boot, 'patch_runtime'), \
                 patch.object(boot, 'download_archive', side_effect=download), redirect_stdout(io.StringIO()):
                binary = boot.install(root, download=True, mirror='https://ghfast.top/')
            release = 'https://github.com/coder/code-server/releases/download/v%s/%s.tar.gz' % (boot.VERSION, name)
            self.assertEqual(fetched, ['https://ghfast.top/' + release, release])
            self.assertEqual(binary.read_text(), 'ok')
            # Only relays Harbor knows are used: anything else the request names fetches from GitHub.
            self.assertEqual(boot.release_url(name, 'https://example.com/'), release)

    def test_a_server_times_its_downloads_from_github_and_each_relay(self):
        import http.server, threading
        class Release(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_GET(self):
                pace = {'/fast': 0.002, '/slow': 0.2}.get(self.path)
                if pace is None:
                    time.sleep(10); return
                self.send_response(200); self.send_header('Content-Length', '230000000'); self.end_headers()
                try:
                    while True:
                        self.wfile.write(b'x' * 16384); time.sleep(pace)
                except OSError: pass
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Release)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        base = 'http://127.0.0.1:%d' % server.server_port
        paths = {'': '/silent', 'https://ghfast.top/': '/fast', 'https://gh-proxy.com/': '/slow', 'https://ghproxy.net/': '/silent'}
        try:
            with patch.object(boot, 'release_url', lambda name, mirror='': base + paths[mirror]), patch.dict(os.environ, {'no_proxy': '*', 'NO_PROXY': '*'}):
                started = time.monotonic(); found = boot.probe_downloads('x', seconds=2); took = time.monotonic() - started
        finally:
            server.shutdown()
        self.assertEqual(found['size'], 230000000)
        self.assertEqual(found['rates'][''], 0); self.assertEqual(found['rates']['https://ghproxy.net/'], 0, 'one that sends nothing is not chosen')
        self.assertGreater(found['rates']['https://gh-proxy.com/'], 0)
        self.assertGreater(found['rates']['https://ghfast.top/'], 10 * found['rates']['https://gh-proxy.com/'])
        self.assertLess(took, 8, 'all are timed at once, each for a few seconds')

    def test_a_package_that_arrived_whole_but_spoiled_is_discarded_and_a_complete_release_already_here_is_used(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve(); name = 'code-server-%s-linux-amd64' % boot.VERSION; archives = root / 'archives'; archives.mkdir()
            full, slim = self.package(root, name)
            digest = hashlib.sha256(slim.read_bytes()).hexdigest(); total = slim.stat().st_size
            part = archives / (name + '.slim.part'); note = archives / (name + '.slim.sha256')
            def install(**options):
                with patch.object(boot.platform, 'system', return_value='Linux'), patch.object(boot.platform, 'machine', return_value='x86_64'), \
                     patch.dict(boot.DIGESTS, {'linux-amd64': hashlib.sha256(full.read_bytes()).hexdigest()}), patch.object(boot, 'patch_runtime'), \
                     patch.object(boot, 'download_archive', side_effect=AssertionError('no download expected')), redirect_stdout(io.StringIO()):
                    return boot.install(root, download=False, slim_digest=digest, **options)
            # Two uploads once wrote into one file: every byte counted, the content wrong.
            part.write_bytes(slim.read_bytes()[:40] + b'x' * (total - 40)); note.write_text(digest)
            with self.assertRaises(boot.ArchiveNeeded) as asked:
                install()
            self.assertEqual(asked.exception.value['slimHave'], total, 'without the size the server cannot tell spoiled from unfinished')
            with self.assertRaises(boot.ArchiveNeeded) as asked:
                install(slim_total=total)
            self.assertEqual((asked.exception.value['slimHave'], asked.exception.value['slimDigest']), (0, ''))
            self.assertFalse(part.exists()); self.assertFalse(note.exists())
            # An upload still under way is left to continue.
            part.write_bytes(slim.read_bytes()[:40]); note.write_text(digest)
            with self.assertRaises(boot.ArchiveNeeded) as asked:
                install(slim_total=total)
            self.assertEqual(asked.exception.value['slimHave'], 40); self.assertTrue(part.exists())
            # The whole official release, left by an earlier attempt and passing its checksum, is installed as it is.
            shutil.copyfile(full, archives / (name + '.tar.gz.part')); (archives / (name + '.slim.lock')).touch()
            binary = install(slim_total=total)
            self.assertEqual(binary.read_text(), 'ok')
            self.assertEqual(list(archives.iterdir()), [], 'nothing of either package is left behind')

    def test_native_assistant_payloads_are_pruned_in_place_without_a_new_revision(self):
        with tempfile.TemporaryDirectory() as temp:
            package = Path(temp) / 'runtime'
            for path in ['bin/code-server', 'lib/vscode/node_modules/@github/copilot-sdk-linux-x64/prebuilds/runtime.node', 'lib/vscode/node_modules/@github/copilot-sdk/index.js',
                         'lib/vscode/node_modules/@microsoft/mxc-sdk/bin/x64/lxc-exec', 'lib/vscode/node_modules/@microsoft/mxc-sdk/dist/index.js', 'lib/vscode/extensions/copilot/package.json',
                         'lib/vscode/extensions/git/package.json']:
                (package / path).parent.mkdir(parents=True, exist_ok=True); (package / path).write_text('x')
            boot.prune_builtin_extensions(package / 'bin/code-server')
            left = sorted(str(p.relative_to(package)) for p in package.rglob('*') if p.is_file())
            self.assertEqual(left, ['bin/code-server', 'lib/vscode/extensions/git/package.json', 'lib/vscode/node_modules/@github/copilot-sdk/index.js',
                                    'lib/vscode/node_modules/@microsoft/mxc-sdk/dist/index.js'])
            source = Path(boot.__file__).read_text()
            self.assertNotIn('PRUNED_RUNTIME_PATHS', source.split('HOST_LAYOUT_REVISION = ')[1].split('\n')[0], 'pruning more must not move every machine to a new revision')

    # A stand-in for the editor: it listens where its config says, and writes down what it was started with.
    STUB = """#!%s
import http.server, json, os, re, sys, time
args = sys.argv[1:]
port = int(re.search(r'127[.]0[.]0[.]1:([0-9]+)', open(args[args.index('--config') + 1]).read()).group(1))
mask = os.umask(0); os.umask(mask)
with open(os.environ['STUB_RECORD'], 'a') as record:
    record.write(json.dumps({'pid': os.getpid(), 'port': port, 'umask': mask, 'token': os.environ.get('HARBOR_CODE_TOKEN'), 'maskVariable': os.environ.get('HARBOR_UMASK')}) + chr(10))
if os.path.exists(os.environ['STUB_RECORD'] + '.never'):
    time.sleep(1000)
if os.path.exists(os.environ['STUB_RECORD'] + '.late'):
    time.sleep(3)
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if os.path.exists(os.environ['STUB_RECORD'] + '.slow'):
            time.sleep(2.5)
        self.send_response(200); self.end_headers()
    def log_message(self, *args): pass
http.server.ThreadingHTTPServer(('127.0.0.1', port), Handler).serve_forever()
""" % sys.executable

    def service_fixture(self):
        temp = tempfile.mkdtemp(); self.addCleanup(shutil.rmtree, temp, True)
        root = Path(temp).resolve(); binary = root / 'stub-editor'
        binary.write_text(self.STUB); binary.chmod(0o755)
        record = root / 'record'; folder = root / 'project'; folder.mkdir()
        def start(folder=folder):
            output = io.StringIO()
            with patch.object(boot, 'install', return_value=binary), patch.dict(os.environ, {'STUB_RECORD': str(record)}), redirect_stdout(output):
                boot.main({'owner': 'test-owner', 'storage': str(root), 'folder': str(folder)})
            return json.loads(output.getvalue().splitlines()[-1])['result']
        def started():
            return [json.loads(line) for line in record.read_text().splitlines()] if record.exists() else []
        data = boot.service_profile(boot.private(root / 'test-owner'))
        def stop():
            (data / 'stop').touch()
            for _ in range(160):
                if not boot.supervisor_running(data, boot.load(data / 'runtime.json')):
                    break
                time.sleep(.1)
            for entry in started():
                try: os.kill(entry['pid'], 9)
                except OSError: pass
        self.addCleanup(stop)
        return root, data, record, start, started

    def test_the_editor_is_asked_directly_whatever_proxy_the_environment_names(self):
        import http.server, threading
        class Health(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200 if self.path == '/healthz' else 502); self.end_headers()
            def log_message(self, *args): pass
        editor = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Health); proxy = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Health)
        for server in (editor, proxy):
            threading.Thread(target=server.serve_forever, daemon=True).start()
            self.addCleanup(server.server_close); self.addCleanup(server.shutdown)
        # A proxy that answers 502 to an absolute URL, as one that cannot reach this machine's loopback does.
        address = 'http://127.0.0.1:%d' % proxy.server_address[1]
        with patch.dict(os.environ, {'http_proxy': address, 'HTTP_PROXY': address}):
            for name in ('no_proxy', 'NO_PROXY'):
                os.environ.pop(name, None)
            self.assertTrue(boot.available(editor.server_address[1]))

    def test_an_editor_that_is_slow_to_answer_is_waited_for_not_replaced(self):
        root, data, record, start, started = self.service_fixture()
        first = start()
        self.assertNotIn('reused', first)
        # The server is busy: every answer takes longer than the one-second look.
        Path(str(record) + '.slow').touch()
        other = root / 'other'; other.mkdir()
        second = start(other)
        self.assertTrue(second.get('reused')); self.assertEqual(second['folder'], str(other))
        self.assertEqual((second['port'], second['password'], second['supervisor']), (first['port'], first['password'], first['supervisor']))
        self.assertEqual(len(started()), 1, 'no second editor was started beside the first')

    def test_a_start_that_times_out_leaves_nothing_behind_to_take_the_next_ones_place(self):
        root, data, record, start, started = self.service_fixture()
        never = Path(str(record) + '.never'); never.touch()
        with patch.object(boot, 'START_WAIT_SECONDS', 1.5), self.assertRaisesRegex(RuntimeError, 'timed out'):
            start()
        never.unlink()
        # The next start waits for what the first one left, ends it when it still does not answer,
        # and starts one editor that it can sign in to.
        with patch.object(boot, 'BUSY_WAIT_SECONDS', 1.5):
            reply = start()
        entries = started()
        self.assertEqual(len(entries), 2)
        self.assertNotIn('reused', reply)
        self.assertIn(reply['password'], (data / 'config.yaml').read_text())
        with self.assertRaises(OSError):
            os.kill(entries[0]['pid'], 0)
        self.assertTrue(boot.available(reply['port']))

    def test_the_editor_runs_with_the_accounts_umask_and_without_the_token_in_its_environment(self):
        root, data, record, start, started = self.service_fixture()
        previous = os.umask(0o077)
        try:
            with patch.object(boot, 'ACCOUNT_UMASK', 0o027):
                reply = start()
        finally:
            os.umask(previous)
        entry = started()[0]
        self.assertEqual(entry['umask'], 0o027)
        self.assertIsNone(entry['token']); self.assertIsNone(entry['maskVariable'])
        # The bridge finds the token here instead, in a file only this account reads.
        self.assertEqual(boot.load(data / 'runtime.json')['token'], reply['token'])
        self.assertEqual((data / 'runtime.json').stat().st_mode & 0o777, 0o600)
        self.assertEqual(data.stat().st_mode & 0o777, 0o700)

    def test_waiting_for_another_start_is_said_while_it_lasts(self):
        import errno, fcntl, threading
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'lock'
            with path.open('a') as holder, path.open('a') as waiter:
                fcntl.flock(holder, fcntl.LOCK_EX)
                threading.Timer(.6, lambda: fcntl.flock(holder, fcntl.LOCK_UN)).start()
                output = io.StringIO()
                with redirect_stdout(output):
                    boot.wait_for_lock(waiter, 'Waiting for another start')
                self.assertEqual(json.loads(output.getvalue().splitlines()[0]), {'phase': 'Waiting for another start', 'progress': None})
            with path.open('a') as free:
                output = io.StringIO()
                with redirect_stdout(output):
                    boot.wait_for_lock(free, 'Waiting for another start')
                self.assertEqual(output.getvalue(), '')
            # A lock that cannot be taken at all (a home directory whose lock service is down) is
            # an error to report, not something to wait for.
            with path.open('a') as broken, patch.object(boot.fcntl, 'flock', side_effect=OSError(errno.ENOLCK, 'No locks available')):
                with self.assertRaises(OSError):
                    boot.wait_for_lock(broken, 'Waiting for another start')

    def test_an_editor_that_needs_longer_than_a_start_waits_is_used_by_the_next_start(self):
        root, data, record, start, started = self.service_fixture()
        Path(str(record) + '.late').touch()
        with patch.object(boot, 'START_WAIT_SECONDS', 1), self.assertRaisesRegex(RuntimeError, 'timed out'):
            start()
        reply = start()
        self.assertTrue(reply.get('reused'))
        self.assertEqual(len(started()), 1, 'the editor that was coming up is the one that is used')
        # It goes on running afterwards: nothing had marked it to stop.
        time.sleep(3)
        self.assertTrue(boot.available(reply['port']))

    def test_an_editor_that_was_told_to_stop_is_not_handed_out(self):
        root, data, record, start, started = self.service_fixture()
        first = start()
        (data / 'stop').touch()
        second = start()
        self.assertNotIn('reused', second)
        self.assertEqual(len(started()), 2)
        self.assertNotEqual(second['supervisor'], first['supervisor'])
        time.sleep(3)
        self.assertTrue(boot.available(second['port']))

    def test_an_editor_that_has_died_is_started_again_where_ps_is_missing(self):
        root, data, record, start, started = self.service_fixture()
        first = start()
        for pid in (first['supervisor'], started()[0]['pid']):
            os.kill(pid, 9)
        for _ in range(100):
            if not boot.available(first['port']):
                break
            time.sleep(.05)
        # Its record is still there. Nothing can be asked of `ps` here; the start goes ahead.
        began = time.monotonic()
        with patch.dict(os.environ, {'PATH': str(root / 'nothing-here')}):
            second = start()
        self.assertNotIn('reused', second)
        self.assertLess(time.monotonic() - began, 20)
        self.assertEqual(len(started()), 2)
        self.assertFalse(boot.supervisor_running(data, {'supervisor': first['supervisor']}, unknown=False))

    def test_transfer_description(self):
        self.assertEqual(boot.describe_transfer(13 * 1048576, 218 * 1048576, 31 * 1024), '13.0 of 218 MB · 31 KB/s · about 1 h 53 min left')
        self.assertEqual(boot.describe_transfer(1048576, 0, 0), '1.0 MB')
        self.assertIn('MB/s · about 1 min left', boot.describe_transfer(0, 50 * 1048576, 2 * 1048576))


if __name__ == '__main__':
    unittest.main()
