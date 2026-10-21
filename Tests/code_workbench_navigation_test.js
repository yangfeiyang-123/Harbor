'use strict';
// Run with: node --test Tests/code_workbench_navigation_test.js
// The extension runs unchanged against a minimal VS Code API;
// HTTP requests exercise their real authenticated loopback transport.
const assert = require('node:assert/strict');
const {test} = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const http = require('node:http');
const {setTimeout: delay} = require('node:timers/promises');
const source = path.resolve(__dirname, '../Sources/HarborSSH/Resources/CodeWorkbench');

function mockVSCode() {
  const registrations = new Map(), providers = new Map(), executed = [], updates = [];
  class EventEmitter {
    constructor() { this.listeners = []; this.event = fn => { this.listeners.push(fn); return {dispose() {}}; }; }
    fire(value) { this.listeners.forEach(fn => fn(value)); }
    dispose() { this.listeners = []; }
  }
  const configurationChanges = new EventEmitter(), globalValues = new Map();
  const opened = new EventEmitter(), closed = new EventEmitter(), tabs = new EventEmitter(), closedTabs = [];
  const documentChanged = new EventEmitter(), documentSaved = new EventEmitter(), documentClosed = new EventEmitter();
  const vscode = {
    EventEmitter,
    TreeItem: class { constructor(label, collapsibleState) { Object.assign(this, {label, collapsibleState}); } },
    ThemeIcon: class { constructor(id) { this.id = id; } },
    TreeItemCollapsibleState: {None: 0, Collapsed: 1, Expanded: 2},
    ConfigurationTarget: {Global: 1}, TerminalLocation: {Panel: 1},
    commands: {
      registerCommand(name, action) { registrations.set(name, action); return {dispose() { registrations.delete(name); }}; },
      async executeCommand(name, ...args) { executed.push(name); return registrations.get(name)?.(...args); }
    },
    window: {
      terminals: [], onDidOpenTerminal: opened.event, onDidCloseTerminal: closed.event,
      createTerminal(options) {
        const terminal = {name: options.name, creationOptions: options, processId: Promise.resolve(123),
          show() { vscode.window.activeTerminal = terminal; }, sendText(text, addNewLine) { terminal.input = {text, addNewLine}; },
          dispose() { vscode.window.terminals = vscode.window.terminals.filter(item => item !== terminal); closed.fire(terminal); }};
        vscode.window.terminals.push(terminal); opened.fire(terminal); return terminal;
      },
      registerTreeDataProvider(id, provider) { providers.set(id, provider); return {dispose() { providers.delete(id); }}; },
      registerWebviewViewProvider() { return {dispose() {}}; },
      tabGroups: {onDidChangeTabs: tabs.event, async close(tab) { closedTabs.push(tab); return true; }},
      showWarningMessage() {}
    },
    workspace: {isTrusted: true, textDocuments: [], onDidChangeConfiguration: configurationChanges.event,
      onDidChangeTextDocument: documentChanged.event, onDidSaveTextDocument: documentSaved.event, onDidCloseTextDocument: documentClosed.event,
      getConfiguration(section) {
      const full = key => section ? section + '.' + key : key;
      return {inspect(key) { return {globalValue: globalValues.get(full(key))}; }, async update(key, value, target) {
        if (full(key) === 'workbench.experimental.floatingPanels' || full(key) === 'chat.tips.enabled') throw new Error('Retired, unregistered configuration');
        updates.push({section, key, value, target}); globalValues.set(full(key), value);
        configurationChanges.fire({affectsConfiguration: candidate => candidate === full(key)});
      }};
    }},
    extensions: {all: [{id: 'harbor.workbench'}]}
  };
  return {vscode, registrations, providers, executed, updates, globalValues, documentChanged, documentSaved, tabs, closedTabs};
}

function loadModule(filename, vscode, environment, cache = new Map()) {
  if (filename.endsWith('.json')) return JSON.parse(fs.readFileSync(path.join(source, filename), 'utf8'));
  const resolved = path.join(source, filename + '.js');
  if (cache.has(resolved)) return cache.get(resolved).exports;
  const module = {exports: {}}; cache.set(resolved, module);
  const localRequire = name => name === 'vscode' ? vscode : name.startsWith('./')
    ? loadModule(name.slice(2), vscode, environment, cache) : require(name);
  const invoke = vm.runInThisContext('(function(require,module,exports,process){\n' + fs.readFileSync(resolved, 'utf8') + '\n})', {filename: resolved});
  invoke(localRequire, module, module.exports, {env: environment});
  return module.exports;
}

async function fixture(t, initialGlobalState = {}, initialConfiguration = {}, options = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'harbor-navigation-'));
  const folder = path.join(root, 'project'), data = path.join(root, 'data');
  fs.mkdirSync(folder); fs.mkdirSync(path.join(data, 'bridges'), {recursive: true});
  fs.writeFileSync(path.join(data, 'lease'), '');
  const mock = mockVSCode(), token = 'test-only-token';
  for (const [key, value] of Object.entries(initialConfiguration)) mock.globalValues.set(key, value);
  mock.vscode.workspace.workspaceFolders = [{uri: {fsPath: folder}}];
  // Layout tests assert exact writes; the lean-profile migration has its own test.
  const globals = new Map(Object.entries({harborLeanProfileVersion: 2, ...initialGlobalState}));
  const context = {extensionPath: source, subscriptions: [], globalState: {get: key => globals.get(key), async update(key, value) { globals.set(key, value); }}};
  // An editor started by this Harbor finds its token in the service's record, not in its environment.
  if (options.tokenInRecord) fs.writeFileSync(path.join(data, 'runtime.json'), JSON.stringify({port: 1, token}));
  loadModule('bridge', mock.vscode, options.tokenInRecord ? {HARBOR_CODE_DATA: data} : {HARBOR_CODE_DATA: data, HARBOR_CODE_TOKEN: token}).activate(context);
  t.after(() => { for (const resource of context.subscriptions.slice().reverse()) resource.dispose(); fs.rmSync(root, {recursive: true, force: true}); });
  const deadline = Date.now() + 3000;
  let record;
  while (!record && Date.now() < deadline) {
    record = fs.readdirSync(path.join(data, 'bridges'))[0];
    if (!record) await delay(5);
  }
  assert.ok(record, 'extension must advertise its live authenticated bridge');
  const {port} = JSON.parse(fs.readFileSync(path.join(data, 'bridges', record), 'utf8'));
  function post(body, headers = {}, method = 'POST') {
    return new Promise((resolve, reject) => {
      const req = http.request({hostname: '127.0.0.1', port, method, headers: {authorization: 'Bearer ' + token, ...headers}}, res => {
        let text = ''; res.setEncoding('utf8'); res.on('data', chunk => text += chunk);
        res.on('end', () => resolve({status: res.statusCode, body: JSON.parse(text)}));
      });
      req.setTimeout(3500, () => req.destroy(Error('bridge response timed out')));
      req.on('error', reject); req.end(JSON.stringify(body));
    });
  }
  return {...mock, post, globals, root, folder, data, port, token};
}

test('Harbor has no view in the sidebar: its places are commands that send an action\'s name and nothing else', async t => {
  const f = await fixture(t);
  assert.equal(f.providers.size, 0, 'no tree view is registered');
  assert.equal(f.registrations.has('harbor.navigate'), false, 'and nothing takes an action from a caller');
  const state = {servers: [{id: 'local', name: 'Local', connected: true, count: 0, directories: []},
    {id: 'server-a', name: 'Research GPU', connected: true, count: 2, directories: [{id: 'dir-a', name: 'Experiment', active: true}]}]};
  assert.equal((await f.post({command: 'nativeState', state})).status, 200, 'the app still reports its servers (the terminals read their sessions from it)');
  const commands = ['addServer', 'settings', 'openFolder', 'closeFolder', 'switchFolder', 'foldersInWindows', 'startPage', 'reverseProxy', 'remoteDisplay', 'terminalMode'];
  for (const command of commands) await f.vscode.commands.executeCommand('harbor.' + command, {action: 'shell', id: 'ignored'});
  assert.deepEqual((await f.post({command: 'events'})).body.result, ['addServer', 'settings', 'openFolder', 'closeFolder', 'switchFolder',
    'organizer', 'recent', 'proxy', 'display', 'terminalMode'].map(action => ({action})));
});

test('navigation wakes a pending request and is delivered exactly once across poll replacement', async t => {
  const f = await fixture(t);
  const first = f.post({command: 'events'});
  await delay(20);
  const replacement = f.post({command: 'events'});
  assert.deepEqual((await first).body.result, []);
  await f.vscode.commands.executeCommand('harbor.reverseProxy');
  assert.deepEqual((await replacement).body.result, [{action: 'proxy'}]);
  const next = f.post({command: 'events'});
  await delay(20);
  await f.vscode.commands.executeCommand('harbor.startPage');
  assert.deepEqual((await next).body.result, [{action: 'recent'}], 'a handled action must not replay');
});

test('bridge rejects unauthenticated/browser-origin requests and arbitrary command execution', async t => {
  const f = await fixture(t);
  for (const [headers, method] of [[{authorization: 'Bearer wrong'}, 'POST'], [{origin: 'https://example.invalid'}, 'POST'], [{}, 'GET']]) {
    assert.equal((await f.post({command: 'nativeState', state: {servers: []}}, headers, method)).status, 403);
  }
  assert.equal((await f.post({command: 'workbench.action.terminal.sendSequence', args: {text: 'unsafe'}})).status, 400);
  assert.equal((await f.post({command: 'nativeState', state: {servers: 'invalid'}})).status, 400);
  const before = f.executed.length;
  await f.vscode.commands.executeCommand('harbor.navigate', {action: 'shell', command: 'unsafe'});
  await f.vscode.commands.executeCommand('harbor.reverseProxy', {action: 'shell', command: 'unsafe'});
  assert.deepEqual((await f.post({command: 'events'})).body.result, [{action: 'proxy'}], 'a command sends its own action whatever it is called with');
  await f.vscode.commands.executeCommand('harbor.settings');
  assert.deepEqual((await f.post({command: 'events'})).body.result, [{action: 'settings'}]);
  assert.equal(f.executed.slice(before).includes('workbench.action.terminal.sendSequence'), false);
  assert.equal((await f.post({command: 'workbench.action.openSettings'})).status, 200);
  assert.equal(f.executed.at(-1), 'workbench.action.openSettings');
});

test('layout migration runs once and panel activation preserves the right editor column', async t => {
  const f = await fixture(t);
  assert.equal(f.globals.get('harborLayoutVersion'), 5);
  assert.deepEqual(f.updates, [
    {section: 'window', key: 'customTitleBarVisibility', value: undefined, target: 1},
    {section: 'workbench', key: 'activityBar.location', value: 'top', target: 1},
    {section: 'workbench', key: 'statusBar.visible', value: true, target: 1},
    ...['experimental.modernUI', 'shadows']
      .map(key => ({section: 'workbench', key, value: false, target: 1})),
    ...Object.entries({'tabs.title': '${cwdFolder}', enablePersistentSessions: true, persistentSessionReviveProcess: 'onExitAndWindowClose', splitCwd: 'inherited', enableBell: false, smoothScrolling: false})
      .map(([key, value]) => ({section: 'terminal.integrated', key, value, target: 1}))
  ]);
  f.executed.length = 0;
  await f.post({command: 'terminalPanel', visible: true, toggleMaximized: true});
  assert.deepEqual(f.executed, ['workbench.action.terminal.focus', 'workbench.action.positionPanelBottom', 'workbench.action.alignPanelCenter', 'workbench.action.toggleMaximizedPanel']);
  await f.post({command: 'terminalPanel', visible: false});
  assert.equal(f.executed.at(-1), 'workbench.action.closePanel');
  const customized = await fixture(t, {initialized: true, harborLayoutVersion: 5, harborBuiltinTerminalDefaultsVersion: 1});
  assert.deepEqual(customized.updates, [], 'subsequent activation must preserve user layout customizations');
  assert.deepEqual(customized.executed, []);
});

test('the bridge creates real terminals and only accepts input addressed to an existing terminal', async t => {
  const f = await fixture(t);
  const created = await f.post({command: 'newTerminal', name: 'QA terminal', cwd: f.folder});
  assert.equal(created.status, 200); assert.equal(created.body.result.name, 'QA terminal');
  const id = created.body.result.id;
  assert.ok(id); assert.equal(f.vscode.window.terminals.length, 1);
  let status = (await f.post({command: 'status'})).body.result;
  assert.equal(status.workspaceTrusted, true); assert.equal(status.terminals[0].id, id);
  assert.equal(status.terminals[0].processId, 123);
  assert.equal((await f.post({command: 'terminalInput', id: 'unknown', text: 'bad'})).status, 400);
  assert.equal((await f.post({command: 'terminalInput', id, text: 'echo fixture\n'})).status, 200);
  assert.deepEqual(f.vscode.window.terminals[0].input, {text: 'echo fixture\n', addNewLine: false});
  assert.equal((await f.post({command: 'splitTerminal'})).status, 200);
  assert.equal(f.executed.at(-1), 'workbench.action.terminal.split');
  assert.equal((await f.post({command: 'workbench.action.terminal.focusFind'})).status, 200);
  assert.equal(f.executed.at(-1), 'workbench.action.terminal.focusFind');
  assert.equal((await f.post({command: 'closeTerminal', id})).status, 200);
  assert.equal((await f.post({command: 'terminalInput', id, text: 'bad'})).status, 400);
});


test('the command token is read from the service record, and a request that arrives in pieces keeps its text whole', async t => {
  const f = await fixture(t, {}, {}, {tokenInRecord: true});
  const created = await f.post({command: 'newTerminal', name: 'QA terminal', cwd: f.folder});
  assert.equal(created.status, 200);
  assert.equal((await f.post({command: 'status'}, {authorization: 'Bearer wrong'})).status, 403);
  // Cut in the middle of a three-byte character: both halves travel separately.
  const body = Buffer.from(JSON.stringify({command: 'terminalInput', id: created.body.result.id, text: "cd '/data/项目/文档' "}));
  const cut = body.indexOf(Buffer.from('项')) + 1;
  const status = await new Promise((resolve, reject) => {
    const req = http.request({hostname: '127.0.0.1', port: f.port, method: 'POST', headers: {authorization: 'Bearer ' + f.token}}, res => { res.resume(); res.on('end', () => resolve(res.statusCode)); });
    req.on('error', reject); req.setNoDelay(true); req.write(body.subarray(0, cut));
    setTimeout(() => req.end(body.subarray(cut)), 60);
  });
  assert.equal(status, 200);
  assert.deepEqual(f.vscode.window.terminals[0].input, {text: "cd '/data/项目/文档' ", addNewLine: false});
});

test('native settings and folder/terminal actions share the authenticated event channel', async t => {
  const f = await fixture(t);
  f.vscode.window.terminals.push({name: 'Task'});
  assert.equal((await f.post({command: 'status'})).body.result.terminalCount, 1);
  await f.post({command: 'nativeState', state: {servers: [], preferences: {values: {'harbor.appearance': 'dark'}, acknowledgements: {}}}});
  const config = f.vscode.workspace.getConfiguration();
  assert.equal(config.inspect('harbor.appearance').globalValue, 'dark');
  await config.update('harbor.appearance', 'anthropic', 1);
  const events = (await f.post({command: 'events'})).body.result;
  assert.equal(events.length, 1);
  assert.equal(events[0].action, 'preference'); assert.equal(events[0].key, 'harbor.appearance');
  assert.equal(JSON.parse(events[0].value), 'anthropic');
  await f.post({command: 'nativeState', state: {servers: [], preferences: {values: {'harbor.appearance': 'dark'}, acknowledgements: {}}}});
  assert.equal(config.inspect('harbor.appearance').globalValue, 'anthropic', 'stale native state must not undo a Settings editor change');
  for (const command of ['openFolder', 'closeFolder', 'newTerminal', 'splitTerminal', 'toggleTerminal']) {
    await f.vscode.commands.executeCommand('harbor.' + command);
  }
  assert.deepEqual((await f.post({command: 'events'})).body.result, ['openFolder', 'closeFolder'].map(action => ({action})));
});


test('upgrading the old native overlay restores the real status bar exactly once', async t => {
  const f = await fixture(t, {initialized: true, harborLayoutVersion: 3, harborBuiltinTerminalDefaultsVersion: 1});
  assert.equal(f.globals.get('harborLayoutVersion'), 5);
  assert.deepEqual(f.updates, [
    {section: 'workbench', key: 'statusBar.visible', value: true, target: 1},
    ...['experimental.modernUI', 'shadows']
      .map(key => ({section: 'workbench', key, value: false, target: 1}))
  ]);
});

test('existing profiles remove floating panel gaps once without resetting their theme or later choices', async t => {
  const flags = ['experimental.modernUI', 'shadows'];
  const configuration = {'workbench.colorTheme': 'My custom theme', 'workbench.statusBar.visible': false,
    ...Object.fromEntries(flags.map(key => ['workbench.' + key, true]))};
  const f = await fixture(t, {initialized: true, harborLayoutVersion: 4, harborBuiltinTerminalDefaultsVersion: 1}, configuration);
  assert.equal(f.globals.get('harborLayoutVersion'), 5);
  assert.deepEqual(f.updates, flags.map(key => ({section: 'workbench', key, value: false, target: 1})));
  for (const key of flags) assert.equal(f.globalValues.get('workbench.' + key), false);
  assert.equal(f.globalValues.get('workbench.colorTheme'), 'My custom theme');
  assert.equal(f.globalValues.get('workbench.statusBar.visible'), false, 'the completed status-bar migration must not run again');

  const customized = await fixture(t, {initialized: true, harborLayoutVersion: 5, harborBuiltinTerminalDefaultsVersion: 1}, configuration);
  assert.deepEqual(customized.updates, [], 'customizing layout after the upgrade remains allowed');
  for (const key of flags) assert.equal(customized.globalValues.get('workbench.' + key), true);
});

test('a previous session is attached only when its command is run for it', async t => {
  const f = await fixture(t), id = '12b11579-5d87-4b8e-a537-590b5cec602c';
  await f.post({command: 'nativeState', state: {servers: [], legacyTerminals: [{id, name: 'Previous run', directory: f.folder}]}});
  assert.equal(f.vscode.window.terminals.length, 0, 'knowing about a session attaches nothing');
  await f.vscode.commands.executeCommand('harbor.resumePreviousSession', {id});
  assert.equal(f.vscode.window.terminals.length, 1);
  assert.deepEqual(f.vscode.window.terminals[0].creationOptions.shellArgs.slice(1), ['attach', id, '--sanitize-replay']);
});

test('builtin terminal defaults migrate existing profiles without replacing explicit user settings', async t => {
  const f = await fixture(t, {initialized: true, harborLayoutVersion: 5}, {
    'terminal.integrated.tabs.title': 'My custom title', 'terminal.integrated.enableBell': true,
    'terminal.integrated.enablePersistentSessions': false
  });
  assert.equal(f.globals.get('harborBuiltinTerminalDefaultsVersion'), 1);
  assert.equal(f.globalValues.get('terminal.integrated.tabs.title'), 'My custom title');
  assert.equal(f.globalValues.get('terminal.integrated.enableBell'), true);
  assert.equal(f.globalValues.get('terminal.integrated.enablePersistentSessions'), false);
  assert.deepEqual(f.updates, Object.entries({persistentSessionReviveProcess: 'onExitAndWindowClose', splitCwd: 'inherited', smoothScrolling: false})
    .map(([key, value]) => ({section: 'terminal.integrated', key, value, target: 1})));
});

test('the lean profile turns built-in assistant surfaces off once and keeps the user\'s own watcher and search choices', async t => {
  const f = await fixture(t, {initialized: true, harborLayoutVersion: 5, harborBuiltinTerminalDefaultsVersion: 1, harborLeanProfileVersion: 0},
    {'search.followSymlinks': true});
  const deadline = Date.now() + 2000;
  while (f.globals.get('harborLeanProfileVersion') !== 2 && Date.now() < deadline) await delay(5);
  assert.equal(f.globals.get('harborLeanProfileVersion'), 2);
  assert.equal(f.globalValues.get('chat.disableAIFeatures'), true);
  assert.equal(f.globalValues.get('editor.inlineSuggest.enabled'), false, 'AI inline suggestions are off');
  assert.equal(f.globalValues.get('editor.quickSuggestions'), undefined, 'typed completion settings are never touched');
  assert.equal(f.globalValues.get('editor.suggest.preview'), undefined);
  assert.equal(f.globalValues.has('chat.tips.enabled'), false, 'an unregistered key is skipped without stopping the migration');
  assert.equal(f.globalValues.get('search.followSymlinks'), true, 'an explicit user choice wins');
  assert.equal(f.globalValues.get('files.watcherExclude')['**/.venv/**'], true);
  const again = await fixture(t, {initialized: true, harborLayoutVersion: 5, harborBuiltinTerminalDefaultsVersion: 1, harborLeanProfileVersion: 2});
  await delay(30);
  assert.deepEqual(again.updates, [], 'the migration never runs twice');
});

test('a profile from before gets the folders of tools left out of file watching, and keeps what the user set there', async t => {
  // What 0.32 wrote, with a folder the user added and one of Harbor's the user switched back on.
  const before = {'**/.venv/**': true, '**/venv/**': true, '**/__pycache__/**': true, '**/.mypy_cache/**': true, '**/.pytest_cache/**': true,
    '**/.ruff_cache/**': true, '**/wandb/**': false, '**/datasets/**': true};
  const f = await fixture(t, {initialized: true, harborLayoutVersion: 5, harborBuiltinTerminalDefaultsVersion: 1, harborLeanProfileVersion: 1},
    {'files.watcherExclude': before, 'chat.disableAIFeatures': false});
  const deadline = Date.now() + 2000;
  while (f.globals.get('harborLeanProfileVersion') !== 2 && Date.now() < deadline) await delay(5);
  const after = f.globalValues.get('files.watcherExclude');
  for (const name of ['.venvs', '.cache', 'node_modules', 'site-packages', '.conda', '.tox', '.ipynb_checkpoints', '.omc']) {
    assert.equal(after['**/' + name + '/**'], true, name + ' is left out now');
  }
  assert.equal(after['**/wandb/**'], false, 'a folder the user switched back on stays watched');
  assert.equal(after['**/datasets/**'], true, 'a folder the user added stays');
  assert.deepEqual(f.updates.map(update => update.key), ['files.watcherExclude'], 'nothing else is written: the first step already ran');
  assert.equal(f.globalValues.get('chat.disableAIFeatures'), false);
  // With nothing to add, nothing is written.
  const full = await fixture(t, {initialized: true, harborLayoutVersion: 5, harborBuiltinTerminalDefaultsVersion: 1, harborLeanProfileVersion: 1},
    {'files.watcherExclude': after});
  while (full.globals.get('harborLeanProfileVersion') !== 2 && Date.now() < deadline + 2000) await delay(5);
  assert.deepEqual(full.updates, []);
});

test('a new profile and one from before leave the same folders out of file watching', () => {
  const swift = fs.readFileSync(path.resolve(source, '../../CodeWorkbench.swift'), 'utf8');
  const list = /static let watcherExclude[^\n]*\[((?:"[^"]+",?\s*)+)\]\.map/.exec(swift);
  assert.ok(list, 'the list the app seeds a new profile with');
  const seeded = list[1].match(/"[^"]+"/g).map(name => '**/' + name.slice(1, -1) + '/**').sort();
  const bridge = loadModule('bridge', mockVSCode().vscode, {});
  assert.deepEqual(Object.keys(bridge.watcherExclude).sort(), seeded);
});

test('unsaved files and terminal counts are pushed as one coalesced status event', async t => {
  const f = await fixture(t, {initialized: true, harborLayoutVersion: 5, harborBuiltinTerminalDefaultsVersion: 1});
  f.vscode.workspace.textDocuments = [{isDirty: true, uri: {fsPath: '/project/draft.py'}}, {isDirty: false, uri: {fsPath: '/project/clean.py'}}];
  for (let index = 0; index < 5; index++) f.documentChanged.fire({});
  const events = (await f.post({command: 'events'})).body.result;
  assert.equal(events.length, 1, 'rapid edits produce one event');
  assert.equal(events[0].action, 'status');
  assert.deepEqual(JSON.parse(events[0].value), {dirty: ['/project/draft.py'], terminalCount: 0});
  f.documentChanged.fire({});
  await delay(250);
  f.vscode.workspace.textDocuments[0].isDirty = false; f.documentSaved.fire({});
  const saved = (await f.post({command: 'events'})).body.result;
  assert.deepEqual(saved.map(event => JSON.parse(event.value)), [{dirty: [], terminalCount: 0}], 'an unchanged status is not repeated');
});

test('the editor\'s own Settings editor gives way to Harbor\'s panel, and settings commands cross the bridge', async t => {
  const f = await fixture(t);
  // A file tab and settings.json are left alone.
  f.tabs.fire({opened: [{label: 'main.py', input: {uri: {}}}, {label: 'settings.json', input: {uri: {}}}], closed: [], changed: []});
  await delay(5);
  assert.deepEqual(f.closedTabs, []);
  const settings = {label: 'Settings', input: undefined};
  f.tabs.fire({opened: [settings], closed: [], changed: []});
  await delay(5);
  assert.deepEqual(f.closedTabs, [settings]);
  // Harbor is told where the request came from: the page usually reported it first.
  assert.deepEqual((await f.post({command: 'events'})).body.result, [{action: 'settings', from: 'editor'}]);
  // Only extensions the user installed are described at run time; built-in ones ship with Harbor.
  assert.deepEqual((await f.post({command: 'settingsCatalog'})).body.result, {groups: []});
  const values = (await f.post({command: 'settingsValues'})).body.result;
  assert.deepEqual(values, {user: {}, workspace: {}, trusted: true});
  assert.equal((await f.post({command: 'settingsUpdate', key: 'editor.rulers', value: {a: 1}})).status, 400, 'objects are edited in settings.json');
  assert.equal((await f.post({command: 'settingsUpdate', key: '../etc', value: 1})).status, 400);
  assert.equal((await f.post({command: 'settingsUpdate', key: 'editor.tabSize', value: 2})).status, 200);
  assert.deepEqual(f.updates.at(-1), {section: undefined, key: 'editor.tabSize', value: 2, target: 1});
  assert.equal((await f.post({command: 'settingsJson', key: 'editor.tabSize'})).status, 200);
  assert.equal(f.executed.at(-1), 'workbench.action.openSettingsJson');
});
