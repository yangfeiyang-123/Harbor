'use strict';
// Execute the actual WK layout reporter against a small DOM contract. These are
// geometry/event regression tests; the macOS integration suite owns rendering.
const assert = require('node:assert/strict');
const {test} = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const swift = fs.readFileSync(path.resolve(__dirname, '../Sources/HarborSSH/CodeWorkbench.swift'), 'utf8');
const source = swift.match(/private static let chromeStyle = """\n([\s\S]*?)\n\s*"""/)?.[1];
assert.ok(source, 'the actual embedded reporter must be extracted, not a test-only copy');
function fixture() {
  const messages = [], raf = [], mutations = [], resizes = [], handlers = new Map(), overlays = [], timers = [], workbench = {};
  const box = (left, top, width, height) => ({x: left, y: top, left, top, right: left + width, bottom: top + height, width, height});
  const element = (rect, visible = true) => ({rect, visible, cssVisible: true,
    getBoundingClientRect() { return this.rect; },
    checkVisibility(options) { return this.visible && (!options?.visibilityProperty || this.cssVisible); }
  });
  const panel = element(box(300, 40, 700, 860)), body = element(box(300, 610, 700, 290)), editor = element(box(300, 40, 700, 535));
  const container = element(panel.rect); container.querySelector = selector => selector === '.pane-body' ? body : undefined;
  const document = {
    head: {appendChild() {}}, body: {}, documentElement: {}, createElement: () => ({}),
    addEventListener: (name, handler) => handlers.set(name, handler), activeElement: null,
    querySelector: selector => ({'.part.panel': panel, '.part.editor': editor, '.monaco-workbench': workbench})[selector],
    getElementById: id => id === 'workbench.view.extension.harborTerminals' ? container : undefined,
    querySelectorAll(selector) {
      const matching = overlays.filter(e => selector.split(',').includes(e.selector));
      return selector.startsWith('.part.panel,') ? [panel, body, editor, ...matching] : matching;
    }
  };
  class Observer {
    constructor(callback, store) { this.callback = callback; this.targets = new Set(); store.push(this); }
    observe(target) { this.targets.add(target); }
  }
  const context = {document, window: {webkit: {messageHandlers: {harborLayout: {postMessage: value => messages.push({...value})}}},
    addEventListener: (name, handler) => handlers.set(name, handler), removeEventListener() {}, dispatchEvent() {}},
    // Timers belong to motion, activity-row sizing and divider dragging, not to the geometry under test.
    // They are collected, and run only by a test that asks for them.
    setTimeout: (fn, ms) => timers.push({fn, ms}), clearTimeout(id) { if (timers[id - 1]) timers[id - 1].cancelled = true; }, Event: class { constructor(type) { this.type = type; } },
    requestAnimationFrame: fn => raf.push(fn),
    MutationObserver: class extends Observer { constructor(fn) { super(fn, mutations); } },
    ResizeObserver: class extends Observer { constructor(fn) { super(fn, resizes); } }
  };
  vm.runInNewContext(source, context);
  const flush = () => { while (raf.length) raf.shift()(); return messages.at(-1); };
  const mutate = target => mutations.filter(o => o.targets.has(target)).forEach(o => o.callback());
  const add = (selector, rect) => { const result = element(rect); result.selector = selector; overlays.push(result); mutate(document.body); return result; };
  const elapse = ms => timers.filter(timer => timer.ms === ms && !timer.cancelled && !timer.ran).forEach(timer => { timer.ran = true; timer.fn(); });
  return {messages, context, box, panel, body, editor, container, add, flush, mutate, handlers, mutations, document, workbench, elapse};
}

test('builtin panel geometry is reported once and no native terminal command layer remains', () => {
  const f = fixture(), initial = f.flush();
  assert.equal(initial.visible, true);
  assert.deepEqual([initial.x, initial.y, initial.width, initial.height], [300, 40, 700, 860]);
  assert.equal(f.handlers.has('harbor-terminal-action'), false);
  f.handlers.get('harbor-layout')(); f.flush();
  assert.equal(f.messages.length, 1);
});
test('Markdown DOM churn is not observed after workbench parts mount', () => {
  const f = fixture(); f.flush();
  assert.ok(f.mutations.every(observer => !observer.targets.has(f.document.body)));
  for (let i = 0; i < 1000; i++) f.mutate(f.document.body);
  assert.equal(f.messages.length, 1);
});
test('maximize and panel close publish actual builtin grid state', () => {
  const f = fixture(); f.flush();
  f.editor.rect = f.box(0, 0, 0, 0); f.handlers.get('harbor-layout')();
  assert.equal(f.flush().maximized, true);
  f.panel.visible = false; f.mutate(f.panel);
  assert.equal(f.flush().visible, false);
});
test('keyboard routing follows native workbench terminal focus and avoids duplicate reports', () => {
  const f = fixture(); f.flush();
  f.document.activeElement = {closest: () => ({})};
  f.handlers.get('focusin')();
  assert.equal(f.messages.at(-1).terminalFocused, true);
  const count = f.messages.length; f.handlers.get('focusin')(); assert.equal(f.messages.length, count);
  f.document.activeElement = {closest: () => null}; f.handlers.get('focusin')();
  assert.equal(f.messages.at(-1).terminalFocused, false);
});
test('the editor\'s own Settings editor is never drawn: held back, reported to Harbor and closed where it opened', () => {
  const f = fixture(); f.flush(); f.messages.length = 0;
  const watcher = f.mutations.find(observer => observer.targets.has(f.workbench));
  assert.ok(watcher, 'modal blocks are noticed on the workbench element, not by watching the whole page');
  const modal = () => {
    const block = {style: {}, isConnected: true, content: null, settings: null, closes: 0,
      classList: {names: new Set(['monaco-modal-editor-block']), contains(name) { return this.names.has(name); }, add(name) { this.names.add(name); }},
      querySelector(selector) {
        if (selector === '.settings-editor') return block.settings;
        if (selector === '.editor-instance > *') return block.content || block.settings;
        return selector.includes('codicon-close') ? {click() { block.closes++; }} : null;
      }};
    watcher.callback([{addedNodes: [{}, block]}]);
    return {block, changed: () => f.mutations.find(observer => observer.targets.has(block)).callback()};
  };
  // settings.json or Keyboard Shortcuts: shown as soon as its editor is in place.
  const file = modal();
  assert.equal(file.block.style.visibility, 'hidden', 'nothing is drawn until the block is known to hold something else');
  file.block.content = {}; file.changed();
  assert.equal(file.block.style.visibility, ''); assert.deepEqual(f.messages, []);
  // The Settings editor: Harbor hears at once, then gets the filter it was opened with, and the block is closed here.
  const settings = modal();
  settings.block.settings = {querySelector: () => ({textContent: '@ext:acme.lint\u00a0'})}; settings.changed(); settings.changed();
  assert.deepEqual(f.messages, [{settingsEditor: true}]);
  assert.equal(settings.block.style.visibility, 'hidden');
  f.elapse(80);
  assert.deepEqual(f.messages, [{settingsEditor: true}, {settingsEditor: true, query: '@ext:acme.lint'}]);
  assert.equal(settings.block.closes, 1);
  // Left open by both this and the extension, it is shown after all rather than blocking the workbench unseen.
  f.elapse(5000);
  assert.equal(settings.block.classList.contains('harbor-shown'), true);
});
