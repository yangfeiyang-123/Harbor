'use strict';
// Run with: node --test Tests/code_workbench_catalog_test.js
// harbor-catalog.js against a small VS Code API: what it reports about installed
// extensions, how it reads and writes values, and the full catalog used at build time.
const assert = require('node:assert/strict');
const {test} = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const zlib = require('node:zlib');
const source = path.resolve(__dirname, '../Sources/HarborSSH/Resources/CodeWorkbench');

function fixture({user = {}, workspace = {}, extensions = [], schemas = {}} = {}) {
  const writes = [], executed = [];
  const nested = flat => {
    const out = {};
    for (const [key, value] of Object.entries(flat)) {
      const parts = key.split('.'); let node = out;
      for (const part of parts.slice(0, -1)) node = node[part] ??= {};
      node[parts.at(-1)] = value;
    }
    return out;
  };
  const vscode = {
    version: '1.140.0', ConfigurationTarget: {Global: 1, Workspace: 2},
    Uri: {parse: text => ({toString: () => text})},
    extensions: {all: extensions},
    commands: {async executeCommand(name, ...args) { executed.push([name, ...args]); }},
    workspace: {isTrusted: false,
      async openTextDocument(uri) {
        const text = schemas[uri.toString()];
        if (text === undefined) throw Error('no such document');
        return {getText: () => JSON.stringify(text)};
      },
      getConfiguration() {
        const merged = nested({'editor.fontSize': 12, 'files.exclude': {}, 'window.zoomLevel': 0, ...user, ...workspace});
        return Object.assign(merged, {
          inspect(section) { return {globalValue: nested(user)[section], workspaceValue: nested(workspace)[section]}; },
          async update(key, value, target) {
            writes.push({key, value, target});
            const store = target === 2 ? workspace : user;
            if (value === undefined) delete store[key]; else store[key] = value;
          }
        });
      }}
  };
  const module = {exports: {}};
  const load = vm.runInThisContext('(function(require,module,exports){\n' + fs.readFileSync(path.join(source, 'harbor-catalog.js'), 'utf8') + '\n})');
  load(name => name === 'vscode' ? vscode : require(name), module, module.exports);
  return {catalog: module.exports.install({}), writes, executed, user, workspace};
}

const extension = (id, manifest) => ({id, packageJSON: manifest});

test('installed extensions are described; built-in ones are left to the catalog Harbor ships', async () => {
  const f = fixture({extensions: [
    extension('vscode.git', {isBuiltin: true, displayName: 'Git', contributes: {configuration: {title: 'Git', properties: {'git.enabled': {type: 'boolean', default: true}}}}}),
    extension('acme.lint', {displayName: 'Acme Lint', contributes: {configuration: [
      {title: 'Rules', order: 2, properties: {
        'acme.level': {type: 'string', enum: ['off', 'warn'], markdownEnumDescriptions: ['Never', 'Report'], default: 'warn', markdownDescription: 'How **loud** to be.', scope: 'resource', order: 1},
        'acme.paths': {type: 'array', items: {type: 'string'}, default: [], description: 'Folders to lint.'},
        'acme.huge': {type: 'object', default: {text: 'x'.repeat(3000)}, deprecationMessage: 'Use acme.paths.'}}},
      {properties: {'acme.max': {type: ['integer', 'null'], minimum: 1, maximum: 9, editPresentation: 'multilineText'}}}]}}),
    extension('acme.theme', {displayName: 'Theme only', contributes: {themes: []}})
  ]});
  const {groups} = await f.catalog.run('settingsCatalog', {});
  assert.deepEqual(groups.map(group => [group.extension, group.name, group.title, group.order]), [['acme.lint', 'Acme Lint', 'Rules', 2], ['acme.lint', 'Acme Lint', 'Acme Lint', 1]]);
  assert.deepEqual(groups[0].settings[0], {key: 'acme.level', type: 'string', default: 'warn', enum: ['off', 'warn'], enumDescriptions: ['Never', 'Report'],
    description: 'How **loud** to be.', order: 1, scope: 'resource'});
  assert.deepEqual(groups[0].settings[1].items, {type: 'string'});
  assert.equal('default' in groups[0].settings[2], false, 'an oversized default is left for settings.json');
  assert.equal(groups[0].settings[2].deprecated, 'Use acme.paths.');
  assert.deepEqual(groups[1].settings[0], {key: 'acme.max', type: ['integer', 'null'], minimum: 1, maximum: 9, multiline: true});
});

test('values are reported per scope and one setting is written at a time', async () => {
  const f = fixture({user: {'editor.fontSize': 15, 'files.exclude': {'**/.git': true}}, workspace: {'editor.tabSize': 2}});
  assert.deepEqual(await f.catalog.run('settingsValues', {}), {user: {editor: {fontSize: 15}, files: {exclude: {'**/.git': true}}},
    workspace: {editor: {tabSize: 2}}, trusted: false});
  const after = await f.catalog.run('settingsUpdate', {key: 'editor.rulers.note', value: ['80', '100'], scope: 'workspace'});
  assert.deepEqual(f.writes.at(-1), {key: 'editor.rulers.note', value: ['80', '100'], target: 2});
  assert.deepEqual(after.workspace.editor, {tabSize: 2, rulers: {note: ['80', '100']}});
  await f.catalog.run('settingsUpdate', {key: 'editor.fontSize', remove: true});
  assert.deepEqual(f.writes.at(-1), {key: 'editor.fontSize', value: undefined, target: 1});
  for (const body of [{key: 'editor', value: 1}, {key: 'a b.c', value: 1}, {key: 'x.y', value: {a: 1}}, {key: 'x.y', value: [1]}, {key: 'x.y', value: 'x'.repeat(4001)}, {key: 'x.y'}]) {
    await assert.rejects(f.catalog.run('settingsUpdate', body));
  }
  await f.catalog.run('settingsJson', {scope: 'workspace', key: 'editor.tabSize'});
  await f.catalog.run('settingsJson', {});
  assert.deepEqual(f.executed, [['workbench.action.openWorkspaceSettingsFile', {revealSetting: {key: 'editor.tabSize', edit: true}}], ['workbench.action.openSettingsJson', undefined]]);
});

test('the full catalog follows references into the per-language schema', async () => {
  const f = fixture({schemas: {
    'vscode://schemas/settings/default': {properties: {
      'editor.fontSize': {$ref: 'vscode://schemas/settings/resourceLanguage#/properties/editor.fontSize'},
      'window.zoomLevel': {type: 'number', default: 0, description: 'Zoom.'},
      '[python]': {type: 'object'}}},
    'vscode://schemas/settings/resourceLanguage': {properties: {'editor.fontSize': {type: 'number', default: 12, minimum: 6, description: 'Size.'}}}
  }, extensions: [extension('vscode.git', {isBuiltin: true, name: 'git', contributes: {configuration: {properties: {'git.enabled': {type: 'boolean'}}}}})]});
  const reply = await f.catalog.run('settingsCatalog', {full: true});
  const full = JSON.parse(zlib.inflateRawSync(Buffer.from(reply.deflated, 'base64')).toString());
  assert.equal(full.version, '1.140.0');
  assert.deepEqual(full.settings, [{key: 'editor.fontSize', type: 'number', default: 12, description: 'Size.', minimum: 6},
    {key: 'window.zoomLevel', type: 'number', default: 0, description: 'Zoom.'}]);
  assert.deepEqual(full.groups.map(group => [group.extension, group.title]), [['vscode.git', 'git']]);
  assert.deepEqual(full.installed, []);
});
