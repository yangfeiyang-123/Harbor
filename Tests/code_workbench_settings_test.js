'use strict';
const assert = require('node:assert/strict');
const {test} = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = path.resolve(__dirname, '../Sources/HarborSSH/Resources/CodeWorkbench');
const defaults = {
  'harbor.appearance': 'system', 'harbor.interfaceFontSize': 13, 'harbor.liquidGlassEnabled': true,
  'harbor.modeSwitchShortcut': 'alt+z',
  'editor.fontSize': 14, 'editor.wordWrap': 'off', 'terminal.integrated.fontSize': 14,
  'terminal.integrated.scrollback': 1000, 'terminal.integrated.copyOnSelection': false
};
const state = (values = {}, acknowledgements = {}) => ({values: {...defaults, 'editor.fontSize': 13, 'terminal.integrated.fontSize': 13,
  'terminal.integrated.scrollback': 20000, ...values}, acknowledgements});
function fixture(t, stored = {}, migrated = false, builtin = {}) {
  const global = new Map(Object.entries(stored)), folder = new Map(), events = [], warnings = [], writes = [], rejects = new Set();
  const globalState = new Map(migrated ? [['harborPreferencesVersion', 1], ...(migrated === 'unified' ? [['harborUnifiedSettingsVersion', 1]] : [])] : []);
  let listener;
  const config = {
    inspect(key) { return {defaultValue: key in builtin ? builtin[key] : defaults[key], globalValue: global.get(key), workspaceValue: folder.get(key)}; },
    async update(key, value, target) {
      if (rejects.has(key)) throw Error(key + ' is not a registered configuration');
      assert.equal(target, 1); writes.push({key, value}); global.set(key, value);
      listener?.({affectsConfiguration: candidate => candidate === key});
    }
  };
  const vscode = {ConfigurationTarget: {Global: 1},
    workspace: {getConfiguration: () => config, onDidChangeConfiguration(fn) { listener = fn; return {dispose() { listener = undefined; }}; }},
    window: {showWarningMessage(message) { warnings.push(message); }}
  };
  const module = {exports: {}};
  const loaded = vm.runInThisContext('(function(require,module,exports){\n' + fs.readFileSync(path.join(source, 'harbor-settings.js'), 'utf8') + '\n})');
  loaded(name => name === 'vscode' ? vscode : name.startsWith('./') ? require(path.join(source, name)) : require(name), module, module.exports);
  const context = {subscriptions: [], globalState: {get: key => globalState.get(key), async update(key, value) { globalState.set(key, value); }}};
  const update = module.exports.install(context, event => events.push(event));
  t.after(() => context.subscriptions.forEach(s => s.dispose()));
  const change = async (key, value, inFolder = false) => {
    (inFolder ? folder : global).set(key, value);
    listener({affectsConfiguration: candidate => candidate === key});
    await new Promise(resolve => setImmediate(resolve));
  };
  return {global, folder, events, warnings, writes, rejects, update, change, globalState, configuration: module.exports.configuration};
}

test('first migration preserves Harbor values and existing editor customizations without synchronization echoes', async t => {
  const f = fixture(t, {'editor.fontSize': 17, 'editor.wordWrap': 'bounded'});
  await f.update(state({'harbor.appearance': 'anthropic', 'harbor.liquidGlassEnabled': false}));
  assert.equal(f.global.get('harbor.appearance'), 'anthropic'); assert.equal(f.global.get('harbor.liquidGlassEnabled'), false);
  assert.equal(f.global.get('terminal.integrated.scrollback'), 20000);
  assert.equal(f.global.get('editor.fontSize'), 17); assert.equal(f.global.get('editor.wordWrap'), 'bounded');
  assert.deepEqual(f.events.map(e => [e.action, e.key, JSON.parse(e.value)]), [['preference', 'editor.fontSize', 17], ['preference', 'editor.wordWrap', 'bounded']]);
  assert.ok(f.events.every(e => /^[a-f0-9-]{36}$/.test(e.id))); assert.equal(f.globalState.get('harborPreferencesVersion'), 1);
});

test('user edits survive stale snapshots and coalesce only after their matching acknowledgement', async t => {
  const f = fixture(t); await f.update(state()); assert.equal(f.events.length, 0);
  await f.change('editor.fontSize', 18); const first = f.events.at(-1);
  await f.update(state()); assert.equal(f.global.get(first.key), 18);
  await f.change(first.key, 20); const latest = f.events.at(-1);
  await f.update(state({[first.key]: 18}, {[first.key]: first.id})); assert.equal(f.global.get(first.key), 20);
  await f.update(state({[latest.key]: 20}, {[latest.key]: latest.id})); assert.equal(f.global.get(first.key), 20);
  assert.equal(f.events.length, 2); assert.equal(f.warnings.length, 0);
  await f.update(state({[latest.key]: 22}, {[latest.key]: latest.id})); assert.equal(f.global.get(first.key), 22);
  assert.equal(f.events.length, 2, 'native changes must not produce an event loop');
});

test('reopening a migrated runtime respects newer native preferences and workspace overrides stay local', async t => {
  const f = fixture(t, {'editor.fontSize': 17}, true); await f.update(state({'editor.fontSize': 20}));
  assert.equal(f.global.get('editor.fontSize'), 20); assert.equal(f.events.length, 0);
  await f.change('editor.fontSize', 25, true); assert.equal(f.events.length, 0); assert.equal(f.folder.get('editor.fontSize'), 25);
  await f.change('editor.fontSize', 21); assert.equal(f.events.length, 1); assert.equal(JSON.parse(f.events[0].value), 21);
});

test('a setting changed for one folder is not taken for a new preference, whether Harbor holds a value for it or not', async t => {
  // The editor's own defaults for two settings Harbor sends no value for.
  const f = fixture(t, {}, 'unified', {'editor.tabSize': 4, 'editor.cursorStyle': 'line'}); await f.update(state());
  // Their values for the user are untouched by a folder's settings.json.
  await f.change('editor.tabSize', 8, true); await f.change('editor.cursorStyle', 'block', true);
  assert.equal(f.events.length, 0);
  // Changed for the user, they are reported like any other.
  await f.change('editor.cursorStyle', 'underline');
  assert.deepEqual(f.events.map(e => [e.key, JSON.parse(e.value)]), [['editor.cursorStyle', 'underline']]);
});

test('unsupported values and rejected shortcuts restore visible configuration rather than silently doing nothing', async t => {
  const f = fixture(t); await f.update(state());
  await f.change('harbor.interfaceFontSize', 1000000); assert.equal(f.global.get('harbor.interfaceFontSize'), 13);
  assert.equal(f.events.length, 0); assert.equal(f.warnings.length, 1);
  await f.change('harbor.modeSwitchShortcut', 'cmd+d'); const rejected = f.events.at(-1);
  await f.update(state({}, {[rejected.key]: rejected.id}));
  assert.equal(f.global.get('harbor.modeSwitchShortcut'), 'alt+z'); assert.equal(f.warnings.length, 2);
});

test('settings schema contributes only Harbor controls; built-in editor and terminal settings keep a single entry', async t => {
  const f = fixture(t);
  assert.equal(f.configuration.title, 'Harbor');
  assert.ok(Object.keys(f.configuration.properties).every(key => key.startsWith('harbor.')));
  assert.ok(Object.values(f.configuration.properties).every(entry => entry.scope === 'application'));
  await f.update({values: {'terminal.integrated.scrollback': false, 'untrusted.secret': 'no', 'harbor.appearance': ['dark']}});
  assert.equal(f.writes.length, 0); assert.equal(f.events.length, 0);
});


test('the unified settings adopt what an editor already had once, then Harbor and the editor stay in step', async t => {
  const f = fixture(t, {'terminal.integrated.fontSize': 45, 'editor.cursorStyle': 'block', 'editor.tabSize': 99}, true);
  await f.update(state());
  // A terminal size chosen here before wins over Harbor's and is reported to it.
  assert.equal(f.global.get('terminal.integrated.fontSize'), 45);
  assert.equal(f.global.get('terminal.integrated.scrollback'), 20000);
  // An option Harbor holds no value for is adopted when it was customized here and is valid.
  assert.deepEqual(f.events.map(e => [e.key, JSON.parse(e.value)]).sort(), [['editor.cursorStyle', 'block'], ['terminal.integrated.fontSize', 45]]);
  assert.equal(f.globalState.get('harborUnifiedSettingsVersion'), 1);
  const acks = Object.fromEntries(f.events.map(e => [e.key, e.id]));
  await f.update(state({'terminal.integrated.fontSize': 45, 'editor.cursorStyle': 'block'}, acks));
  // From now on a value chosen in Harbor's Settings reaches this editor,
  await f.update(state({'terminal.integrated.fontSize': 45, 'editor.cursorStyle': 'underline', 'terminal.integrated.scrollback': 90000}, acks));
  assert.equal(f.global.get('editor.cursorStyle'), 'underline'); assert.equal(f.global.get('terminal.integrated.scrollback'), 90000);
  assert.equal(f.events.length, 2, 'values from Harbor are not echoed back');
  // and one changed here goes back to Harbor.
  await f.change('terminal.integrated.cursorBlinking', true);
  assert.deepEqual([f.events.at(-1).key, JSON.parse(f.events.at(-1).value)], ['terminal.integrated.cursorBlinking', true]);
  assert.equal(f.warnings.length, 0);
});

test('a later run does not adopt editor values again', async t => {
  const f = fixture(t, {'editor.cursorStyle': 'block'}, 'unified');
  await f.update(state());
  assert.deepEqual(f.events.map(e => e.key), []);
});

test('a setting this editor build does not register cannot hold back the others', async t => {
  const f = fixture(t, {}, 'unified');
  f.rejects.add('editor.formatOnSave');
  await f.update(state({'editor.formatOnSave': true, 'editor.cursorStyle': 'block', 'breadcrumbs.enabled': false}));
  assert.equal(f.global.get('editor.cursorStyle'), 'block'); assert.equal(f.global.get('breadcrumbs.enabled'), false);
  assert.equal(f.global.has('editor.formatOnSave'), false);
  assert.equal(f.globalState.get('harborPreferencesVersion'), 1);
});
