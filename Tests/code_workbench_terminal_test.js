'use strict';
// Exercise terminal ownership, legacy attach safety, and metadata without
// starting shells or altering the user's running terminal sessions.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = path.resolve(__dirname, '../Sources/HarborSSH/Resources/CodeWorkbench');
const sessionID = '12b11579-5d87-4b8e-a537-590b5cec602c';
function fixture(t) {
  const registered = new Map(), executed = [], creates = [];
  const opened = [], closed = [];
  const event = list => callback => { list.push(callback); return {dispose() {}}; };
  const vscode = {
    TerminalLocation: {Panel: 1},
    workspace: {workspaceFolders: [{uri: {fsPath: '/work/project'}}]},
    commands: {
      registerCommand(name, fn) { registered.set(name, fn); return {dispose() { registered.delete(name); }}; },
      async executeCommand(name, ...args) { executed.push({name, args}); return registered.get(name)?.(...args); }
    },
    window: {
      terminals: [], onDidOpenTerminal: event(opened), onDidCloseTerminal: event(closed),
      createTerminal(options) {
        creates.push(options);
        const terminal = {name: options.name, creationOptions: options, processId: Promise.resolve(101 + creates.length),
          show() { vscode.window.activeTerminal = terminal; },
          sendText(text, newLine) { terminal.input = {text, newLine}; },
          dispose() { vscode.window.terminals = vscode.window.terminals.filter(item => item !== terminal); closed.forEach(fn => fn(terminal)); }};
        vscode.window.terminals.push(terminal); opened.forEach(fn => fn(terminal)); return terminal;
      },
      async showQuickPick(items) { return items[0]; }, async showInformationMessage() {}
    }
  };
  const module = {exports: {}};
  const load = vm.runInThisContext('(function(require,module,exports,process){\n' + fs.readFileSync(path.join(source, 'harbor-terminal.js'), 'utf8') + '\n})');
  load(name => name === 'vscode' ? vscode : require(name), module, module.exports, {env: {PATH: ''}});
  const context = {subscriptions: [], extensionPath: source};
  const terminals = module.exports.install(context);
  t.after(() => context.subscriptions.forEach(item => item.dispose()));
  return {vscode, registered, executed, creates, terminals, context};
}

test('new terminals use the configured builtin profile and splits use the builtin inherited-cwd command', async t => {
  const f = fixture(t);
  const first = await f.terminals.run('newTerminal');
  assert.deepEqual(f.creates[0], {name: 'project', cwd: '/work/project', location: 1});
  assert.equal('pty' in f.creates[0], false); assert.equal('shellPath' in f.creates[0], false);
  const active = f.vscode.window.activeTerminal;
  active.shellIntegration = {cwd: {fsPath: '/work/project/subdir'}};
  await f.terminals.run('splitTerminal');
  assert.equal(f.executed.at(-1).name, 'workbench.action.terminal.split');
  assert.equal(f.creates.length, 1, 'splitting must remain under Code-OSS process/profile ownership');
  const second = await f.terminals.run('newTerminal');
  assert.equal(second.name, 'subdir'); assert.equal(second.cwd, '/work/project/subdir');
  await f.terminals.run('focusTerminal', {id: first.id}); assert.equal(f.vscode.window.activeTerminal, active);
  await f.terminals.run('renameTerminal'); assert.equal(f.executed.at(-1).name, 'workbench.action.terminal.rename');
  assert.equal(first.id, f.terminals.status()[0].id);
});

test('status identifies live terminals without exposing shell arguments or environment', async t => {
  const f = fixture(t);
  const terminal = f.vscode.window.createTerminal({name: 'Existing', cwd: '/work', shellArgs: ['private'], env: {TOKEN: 'secret'}});
  terminal.shellIntegration = {cwd: {fsPath: '/work/current'}};
  terminal.show(); await Promise.resolve();
  const status = f.terminals.status();
  assert.equal(status[0].processId, 102); assert.equal(status[0].cwd, '/work/current');
  assert.equal(status[0].cwdSource, 'shellIntegration'); assert.equal(status[0].active, true);
  assert.equal(JSON.stringify(status).includes('secret'), false); assert.equal(JSON.stringify(status).includes('private'), false);
  assert.equal(f.creates.length, 1, 'discovering a restored terminal never starts an additional process');
});

test('legacy sessions resume only after explicit selection and attach without creating or killing their daemon', async t => {
  const f = fixture(t);
  f.terminals.updateNativeState({legacyTerminals: [{id: sessionID, name: 'Old research', directory: '/work/project'}]});
  assert.equal(f.creates.length, 0, 'state synchronization must not steal a running legacy session');
  const resumed = await f.terminals.run('resumePreviousSession', {id: sessionID});
  assert.equal(f.creates.length, 1);
  assert.deepEqual(f.creates[0].shellArgs, [path.join(source, 'legacy-terminal-host.py'), 'attach', sessionID, '--sanitize-replay']);
  assert.equal(f.creates[0].shellPath, '/usr/bin/python3');
  assert.deepEqual(f.creates[0].env, {HARBOR_LEGACY_SESSION_ID: sessionID});
  assert.equal(resumed.legacySessionID, sessionID);
  assert.equal((await f.terminals.run('resumePreviousSession', {id: sessionID})).id, resumed.id);
  assert.equal(f.creates.length, 1, 'repeat selection focuses the already attached terminal');
  f.terminals.updateNativeState({legacyTerminals: []});
  await assert.rejects(f.terminals.run('resumePreviousSession', {id: sessionID}), /not available/);
  assert.equal(f.vscode.window.terminals.length, 1, 'removing a tree item must never terminate a session');
});

test('restored legacy terminals are deduplicated using their creation environment', async t => {
  const f = fixture(t);
  const old = f.vscode.window.createTerminal({name: 'Restored', env: {HARBOR_LEGACY_SESSION_ID: sessionID}});
  f.terminals.updateNativeState({legacyTerminals: [{id: sessionID, name: 'Old', directory: '/work'}]});
  await f.terminals.run('resumePreviousSession');
  assert.equal(f.creates.length, 1); assert.equal(f.vscode.window.activeTerminal, old);
  f.terminals.updateNativeState({legacyTerminals: [{id: '../bad', name: 'Bad', directory: '/work'}, {id: sessionID, name: 'Bad', directory: 'relative'}]});
  await assert.rejects(f.terminals.run('resumePreviousSession', {id: sessionID}), /not available/);
});

test('legacy login-directory sessions expand home on the actual extension host', async t => {
  const f = fixture(t);
  f.terminals.updateNativeState({legacyTerminals: [{id: sessionID, name: 'Login shell', directory: '~'}]});
  await f.terminals.run('resumePreviousSession', {id: sessionID});
  assert.equal(f.creates[0].cwd, require('os').homedir());
});

test('input and close are confined to live opaque terminal IDs', async t => {
  const f = fixture(t); const terminal = await f.terminals.run('newTerminal');
  await assert.rejects(f.terminals.run('terminalInput', {id: 'stale', text: 'hello'}), /Unknown terminal/);
  await assert.rejects(f.terminals.run('terminalInput', {id: terminal.id, text: 'x'.repeat(8193)}), /Invalid terminal input/);
  await assert.rejects(f.terminals.run('terminalInput', {id: terminal.id, text: 'x\0y'}), /Invalid terminal input/);
  await f.terminals.run('terminalInput', {id: terminal.id, text: 'fixture\n'});
  assert.deepEqual(f.vscode.window.terminals[0].input, {text: 'fixture\n', newLine: false});
  await f.terminals.run('closeTerminal', {id: terminal.id});
  await assert.rejects(f.terminals.run('terminalInput', {id: terminal.id, text: 'late'}), /Unknown terminal/);
  await assert.rejects(f.terminals.run('newTerminal', {cwd: 'relative'}), /absolute/);
});
