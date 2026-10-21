'use strict';
// Exercise real pinned preview functions using a deterministic browser clock.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
if (!process.argv[2]) {
  require('node:test').test('pinned Markdown scroll fixture', {skip: 'Run through code_workbench_test.py with HARBOR_CODE_WORKBENCH_FIXTURE'}, () => {});
} else {
const source = fs.readFileSync(process.argv[2], 'utf8');
let now = 0, sequence = 0, userLine = 0;
const timers = new Map(), frames = new Map(), events = new Map(), writes = [], messages = [];
const image = {complete: false, listeners: {}, addEventListener(type, callback) { (this.listeners[type] ||= []).push(callback); }};
const setTimeout = (callback, delay = 0) => { const id = ++sequence; timers.set(id, {at: now + delay, callback}); return id; };
const clearTimeout = id => timers.delete(id);
const window = {scrollY: 0, setTimeout, clearTimeout, addEventListener(type, callback) { events.set(type, callback); }};
const context = vm.createContext({
  Date: class extends Date { static now() { return now; } },
  Number, Promise, setTimeout, clearTimeout, window,
  requestAnimationFrame: callback => { const id = ++sequence; frames.set(id, callback); return id; },
  document: {getElementsByTagName: () => [image]},
  h: {}, A: {}, T: 0, Xe: null, et() {}, me: () => userLine,
  Y: {setState() {}}, X: {postMessage(type, value) { messages.push({type, ...value}); }},
  G(line) { writes.push(line); window.scrollY = line; events.get('scroll')?.(); },
});
function section(start, end) { const i = source.indexOf(start); assert.ok(i >= 0, start); const j = source.indexOf(end, i); assert.ok(j > i, end); return source.slice(i, j); }
vm.runInContext(source.slice(0, source.indexOf('var Ee=')), context); // Actual upstream bounded throttle.
vm.runInContext(section('var harborScrollRevision=', 'var Ge=') + 'var Ge=We(),S=0,w;', context);
vm.runInContext(section('function le(', 'xe(()=>'), context);
vm.runInContext(section('function harborSyncScroll(', 'window.addEventListener("resize"'), context);
vm.runInContext(section('window.addEventListener("scroll",', 'function et(){'), context);
vm.runInContext('var Vt=' + section('Vt=e=>', ',Xe=').slice(3) + ';', context);
function advance(milliseconds) {
  const end = now + milliseconds;
  for (;;) {
    const ready = [...timers.entries()].filter(([, timer]) => timer.at <= end).sort((a, b) => a[1].at - b[1].at)[0];
    if (!ready) break;
    timers.delete(ready[0]); now = ready[1].at; ready[1].callback();
  }
  now = end;
}
function frame() { now += 16; const callbacks = [...frames.values()]; frames.clear(); callbacks.forEach(callback => callback(now)); }
async function loadImage() {
  image.complete = true; (image.listeners.load || []).splice(0).forEach(callback => callback());
  await Promise.resolve(); await Promise.resolve(); advance(0);
}
async function check() {
  let staleInitial = 0;
  context.le(() => staleInitial++);
  assert.equal(timers.size, 0, 'initial positioning still waits for image readiness');
  for (let line = 1; line <= 300; line++) context.Wt(line);
  assert.equal(frames.size, 1, 'continuous editor scroll schedules one frame, not an unbounded callback queue');
  assert.deepEqual(writes, []);
  frame();
  assert.deepEqual(writes, [300], 'latest position is applied next frame while the image is still loading');
  assert.equal(now, 16);
  advance(100);
  assert.equal(messages.length, 0, 'programmatic preview scroll does not feed back to the editor');
  await loadImage();
  assert.equal(staleInitial, 0, 'an old image-wait callback cannot override the latest editor position');
  context.Vt(400); context.Wt(450); frame();
  assert.equal(writes.at(-1), 450, 'diff-preview and editor requests share the same latest-wins scheduler');
  advance(150);
  userLine = 500; events.get('scroll')();
  for (let line = 501; line <= 550; line++) { userLine = line; events.get('scroll')(); }
  advance(50);
  assert.equal(messages.at(-1).line, 550, 'preview-to-editor direction preserves its latest line');
  assert.ok(messages.length <= 2, 'upstream reverse scroll remains bounded to a leading and trailing update');
  assert.ok(messages.every(message => message.type === 'revealLine'));
  let initialPosition = 0;
  image.complete = false;
  context.le(() => initialPosition++);
  advance(1000);
  assert.equal(initialPosition, 0, 'fresh initial positioning still waits for unloaded images');
  await loadImage();
  assert.equal(initialPosition, 1, 'initial positioning runs after images load when not superseded');
  context.Wt(NaN); context.Wt(Infinity); context.Wt('unexpected');
  assert.equal(frames.size, 0, 'invalid positions do not schedule scrolling');
}
check().then(() => console.log('Pinned Markdown latest-wins scroll and feedback-guard behavior passed.'), error => { console.error(error); process.exitCode = 1; });
}
