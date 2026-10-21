'use strict';
// Execute the actual hash-verified pinned workbench methods against services.
// The Python fixture test supplies an isolated patched copy, never a live UI.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
if (!process.argv[2]) {
  require('node:test').test('pinned workbench layout fixture', {skip: 'Run through code_workbench_test.py with HARBOR_CODE_WORKBENCH_FIXTURE'}, () => {});
} else {
const source = fs.readFileSync(process.argv[2], 'utf8');
const extractClass = (name, end) => source.slice(source.indexOf(name + '=class') + name.length + 1, source.indexOf(end, source.indexOf(name + '=class')));
const layoutEvents = [];
const context = vm.createContext({
  Event: class { constructor(type) { this.type = type; } },
  dispatchEvent: event => layoutEvents.push(event.type),
  kU: class { onDidOpen(view) { this.opened = view.getId(); } },
  $c: class {}, p3: class { constructor(item) { this.item = item; } },
  j: class {}, U: () => ({dispose() {}}), ui: Symbol('views'),
  Di: class { constructor(width, height) { Object.assign(this, {width, height}); } },
  MA: () => {}, L: {more: 'more', chevronDown: 'chevron-down'},
  Q: {asClassNameArray: value => [value]}, d: () => 'More', d1e: class {},
});
context.Di.None = {width: 0, height: 0};
const Sidebar = vm.runInContext('(' + extractClass('M3', ';M3=I(') + ')', context);
const PartLayout = vm.runInContext('(' + extractClass('V8i', ',rle=class') + ')', context);
const CompositeBar = vm.runInContext('(' + extractClass('bze', ';bze=I(') + ')', context);
context.lvt = vm.runInContext('(' + extractClass('lvt', ',d1e=class') + ')', context);

const sidebar = Object.create(Sidebar.prototype);
Object.assign(sidebar, {options: {hasTitle: true}, titleArea: {style: {}}, relayout() { this.layouts = (this.layouts || 0) + 1; }});
const layout = new PartLayout(sidebar.options, null, {isFloatingPanelsEnabled: () => false});
layout.setHeaderVisibility(true);
context.__harborEmbeddedWorkbench = true;
sidebar.onDidOpen({getId: () => 'workbench.view.explorer'});
assert.equal(sidebar.options.hasTitle, false);
assert.equal(sidebar.titleArea.style.display, 'none');
assert.equal(layout.layout(300, 600).contentSize.height, 565, 'Explorer reclaims the actual title row height');
sidebar.onDidOpen({getId: () => 'workbench.view.extensions'});
assert.equal(sidebar.options.hasTitle, true);
assert.equal(layout.layout(300, 600).contentSize.height, 530, 'other sidebar views keep their controls');
context.__harborEmbeddedWorkbench = false;
sidebar.onDidOpen({getId: () => 'workbench.view.explorer'});
assert.equal(sidebar.options.hasTitle, true, 'ordinary browser layout is unchanged');

function barFixture(centered) {
  const items = Array.from({length: 6}, (_, i) => ({id: String(i), pinned: true, activityAction: {id: String(i)}}));
  const actions = [], overflowIcons = [];
  const bar = Object.create(CompositeBar.prototype);
  Object.assign(bar, {
    options: {harborCentered: centered, orientation: 0, overflowActionSize: 30, icon: true},
    harborCompositeElement: {style: {}},
    model: {visibleItems: items, activeItem: items[5], findItem: id => items.find(i => i.id === id)},
    compositeSizeInBar: new Map(items.map(i => [i.id, 30])), visibleComposites: [],
    compositeOverflowAction: {}, compositeOverflowActionViewItem: {},
    compositeSwitcherBar: {length: () => actions.length, pull: i => actions.splice(i, 1), push(a, o) { actions.splice(o?.index ?? actions.length, 0, a); }},
    _onDidChange: {fire() {}}, instantiationService: {createInstance(kind, ...args) {
      if (kind === context.lvt) { const action = new kind(...args); overflowIcons.push(action.item.classNames[0]); return action; }
      return {showMenu() {}};
    }},
  });
  return {bar, actions, overflowIcons};
}
const centered = barFixture(true);
centered.bar.layout({width: 140, height: 35});
assert.equal(centered.bar.harborCompositeElement.style.justifyContent, 'center');
assert.equal(centered.bar.harborCompositeElement.style.width, '140px');
assert.equal(centered.bar.visibleComposites.length, 3, 'real overflow reserves room for the arrow');
assert.ok(centered.bar.visibleComposites.includes('5'), 'active view remains reachable when narrow');
assert.deepEqual(centered.overflowIcons, ['chevron-down']);
assert.equal(centered.bar.getOverflowingComposites().length, 3);
centered.bar.layout({width: 250, height: 35});
assert.equal(centered.bar.visibleComposites.length, 6);
assert.equal(centered.bar.compositeOverflowAction.value, undefined, 'overflow disappears when all icons fit');
const ordinary = barFixture(false);
ordinary.bar.layout({width: 140, height: 35});
assert.deepEqual(ordinary.bar.harborCompositeElement.style, {});
assert.deepEqual(ordinary.overflowIcons, ['more']);

// Evaluate the actual terminal registration (not a mirror of its conditions).
const start = source.indexOf('var N2r=');
const finish = source.indexOf(';_Rn();', start);
const registrations = [];
Object.assign(context, {
  me: {as: () => ({registerViewContainer(value, location, options) { registrations.push({value, options}); return value; }, registerViews(views) { registrations.push({views}); }})},
  dr: {}, Fd: 'terminal', F: (id, value) => ({value}), ooo: {}, li: class {}, wd: {}, LJe: {},
  _: {greater: (key, value) => ({evaluate: values => values[key] > value})},
});
context.__harborEmbeddedWorkbench = true;
vm.runInContext(source.slice(start, finish), context);
assert.equal(registrations[0].value.title.value, 'Terminal');
assert.equal(registrations[0].options.isDefault, true);
assert.equal(registrations[1].views[0].when, undefined, 'the real Terminal remains available even before creating a shell');
registrations.length = 0;
context.__harborEmbeddedWorkbench = false;
vm.runInContext(source.slice(start, finish), context);
assert.equal(registrations[0].value.title.value, 'Terminal');
assert.equal(registrations[0].options.isDefault, true);
assert.equal(registrations[1].views[0].when, undefined);

// Exercise the real layout routing and sidebar method, including the focus
// side effect that native Terminal must opt out of during Command+B.
function sidebarFocusBehavior() {
  const extractMethod = (start, end) => source.slice(source.indexOf(start), source.indexOf(end, source.indexOf(start)));
  Object.assign(context, {qo: {SIDEBAR_HIDDEN: 'sidebarHidden'}, dt: {}});
  const methods = vm.runInContext('({' + [
    extractMethod('setPartHidden(e,t,i=!1){', 'toggleSecondarySideBar(){'),
    extractMethod('setSideBarHidden(e,t=!1){', 'hasViews(e){'),
    extractMethod('focusPart(e,t=dt){', 'getContainer(e,t){'),
  ].join(',') + '})', context);
  const state = {hidden: false, active: true, focuses: 0, editorFocuses: 0};
  const container = {}, host = {
    ...methods,
    mainContainer: {classList: {add() {}, remove() {}}},
    stateModel: {setRuntimeValue(key, value) { state.hidden = value; }},
    workbenchGrid: {setViewVisible(view, value) { assert.equal(value, !state.hidden); }},
    paneCompositeService: {
      getActivePaneComposite: () => state.active,
      hideActivePaneComposite() { state.active = false; },
      getLastActivePaneCompositeId: () => 'workbench.view.explorer',
    },
    isVisible: () => !state.hidden,
    setAuxiliaryBarMaximized: () => false,
    isAuxiliaryBarMaximized: () => false,
    focusPanelOrEditor() { state.focuses++; },
    openViewContainer(location, id) { assert.equal(location, 0); assert.equal(id, 'workbench.view.explorer'); state.active = true; },
    getContainer: () => container,
    editorGroupService: {getPart(value) { assert.equal(value, container); return {activeGroup: {focus() { state.editorFocuses++; }}}; }},
  };
  context.__harborEmbeddedWorkbench = true;
  host.setPartHidden(true, 'workbench.parts.sidebar', true);
  assert.equal(state.hidden, true); assert.equal(state.active, false);
  assert.equal(state.focuses, 0, 'preserving native focus skips the actual upstream focus side effect');
  host.setPartHidden(false, 'workbench.parts.sidebar', true);
  assert.equal(state.hidden, false); assert.equal(state.active, true);
  assert.equal(state.focuses, 0, 'reopening the sidebar does not request focus');
  host.setPartHidden(true, 'workbench.parts.sidebar');
  assert.equal(state.focuses, 1, 'the omitted option retains default editor focus behavior');
  host.setPartHidden(false, 'workbench.parts.sidebar');
  host.setPartHidden(true, 'workbench.parts.sidebar', false);
  assert.equal(state.focuses, 2, 'explicit false retains default focus behavior');
  host.setPartHidden(false, 'workbench.parts.sidebar');
  context.__harborEmbeddedWorkbench = false;
  host.setPartHidden(true, 'workbench.parts.sidebar', true);
  assert.equal(state.focuses, 3, 'ordinary browser behavior remains unchanged even with the option');
  host.focusPart('workbench.parts.editor');
  assert.equal(state.editorFocuses, 1, 'focusEditor reaches the active editor group');
}
sidebarFocusBehavior();

async function terminalGraceBehavior() {
  const start = source.indexOf('async reduceConnectionGraceTime(){if(globalThis.__harborEmbeddedWorkbench===true)return;');
  assert.ok(start >= 0);
  const end = source.indexOf('async getTerminalLayoutInfo(){', start);
  const backend = vm.runInContext('({' + source.slice(start, end) + '})', context);
  let reductions = 0;
  backend._remoteTerminalChannel = {reduceConnectionGraceTime() { reductions++; }};
  context.__harborEmbeddedWorkbench = true;
  await backend.reduceConnectionGraceTime();
  assert.equal(reductions, 0, 'opening another Harbor workspace cannot expire detached PTYs after five minutes');
  context.__harborEmbeddedWorkbench = false;
  await backend.reduceConnectionGraceTime();
  assert.equal(reductions, 1, 'ordinary browser behavior remains upstream');
}

async function terminalMenuActions() {
  const events = [], created = [];
  let taskViewVisible = false;
  Object.assign(context, {
    CustomEvent: class { constructor(type, options) { Object.assign(this, {type, detail: options.detail}); } },
    dispatchEvent: event => events.push(event),
    He: Symbol('workspace'), ve: Symbol('commands'), Ft: Symbol('editors'),
    bi: value => typeof value === 'object' && value !== null, Mu: () => false,
    jM: () => false, mo: () => ({}), dMe: async () => {}, TRn: value => value,
    obo: async () => '/task-cwd',
  });
  function runCommand(id) {
    const start = source.indexOf('Ms({id:"workbench.action.terminal.' + id + '"');
    const begin = source.indexOf('run:async', start) + 4;
    return vm.runInContext('(' + source.slice(begin, source.indexOf(id === 'new' ? '}});async function s(' : '}}),Ms({id:"workbench.action.terminal.splitActiveTab"', begin) + 1) + ')', context);
  }
  const service = {isProcessSupportRegistered: true, async createTerminal(options) { created.push(options); return {id: created.length}; }, setActiveInstance() {},
    async getInstanceHost() { return {activeInstance: {id: 'task-parent'}}; }};
  const accessor = {get: token => token === context.ui ? {isViewVisible: () => taskViewVisible} : token === context.He ? {getWorkspace: () => ({folders: []})} : {}};
  context.__harborEmbeddedWorkbench = true;
  const newTerminal = runCommand('new'), splitTerminal = runCommand('split');
  await newTerminal({service}, accessor); await splitTerminal({service}, accessor);
  assert.deepEqual(events, [], 'built-in terminal commands are never intercepted by Harbor');
  assert.equal(created.length, 2, 'ordinary user actions create and split real Code-OSS shells');
  await newTerminal({service}, accessor, {cwd: '/plugin'});
  await splitTerminal({service}, accessor, {config: {name: 'Extension task'}});
  assert.equal(created.length, 4, 'explicit extension command parameters still use Code-OSS terminals');
  assert.equal(created[2].cwd, '/plugin'); assert.equal(created[3].cwd, '/task-cwd');
  taskViewVisible = true;
  await newTerminal({service}, accessor); await splitTerminal({service}, accessor);
  assert.equal(created.length, 6, 'all commands share the same genuine terminal service');
  context.__harborEmbeddedWorkbench = false; taskViewVisible = false;
  await newTerminal({service}, accessor);
  assert.equal(created.length, 7, 'ordinary browser behavior remains upstream');
  context.dispatchEvent = event => layoutEvents.push(event.type);
}

async function localActions() {
  const calls = [], visible = {sidebar: true, panel: false, auxiliarybar: false};
  let maximized = false, position = 2, alignment = 'center', nativeVisible = false;
  const host = {
    _register() {},
    layoutService: {
      isVisible: id => visible[id.split('.').at(-1)], isPanelMaximized: () => maximized,
      setPartHidden(hidden, id, preserveFocus) { visible[id.split('.').at(-1)] = !hidden; if (hidden && id.endsWith('panel')) nativeVisible = false; calls.push(['hidden', id, hidden, preserveFocus]); },
      focusPart(id) { calls.push(['focus', id]); },
      getPanelPosition: () => position, setPanelPosition(value) { position = value; calls.push(['position', value]); },
      getPanelAlignment: () => alignment, setPanelAlignment(value) { alignment = value; calls.push(['align', value]); },
      toggleMaximizedPanel() { maximized = !maximized; calls.push(['maximize', maximized]); },
    },
    instantiationService: {invokeFunction: fn => fn({get: token => token === context.ve ? {
      async executeCommand(id) { calls.push(['command', id]); }
    } : {
      isViewVisible(id) { assert.equal(id, 'terminal'); return nativeVisible; },
      async openView(id, focus) { assert.equal(id, 'terminal'); calls.push(['open', id, focus]); nativeVisible = visible.panel = true; return {}; }
    }})},
  };
  Sidebar.prototype.registerActions.call(host);
  assert.equal(context.__harborWorkbenchCommand, undefined, 'browser client never receives a native UI API');
  context.__harborEmbeddedWorkbench = true;
  Sidebar.prototype.registerActions.call(host);
  const action = context.__harborWorkbenchCommand;
  const descriptor = Object.getOwnPropertyDescriptor(context, '__harborWorkbenchCommand');
  assert.equal(descriptor.writable, false); assert.equal(descriptor.configurable, false);
  assert.equal((await action('workbench.action.terminal.sendSequence')).ok, false);
  assert.equal(calls.length, 0, 'unknown commands cannot reach services');
  await action('openTerminal');
  assert.deepEqual(calls, [['open', 'terminal', false]], 'default geometry does not trigger redundant layouts');
  calls.length = 0;
  await action('toggleMaximizedPanel');
  assert.deepEqual(calls, [['maximize', true]], 'maximization is local and does not reopen a visible view');
  await action('toggleMaximizedPanel');
  await action('enterTerminalMode');
  assert.equal(visible.sidebar, false); assert.equal(maximized, true);
  assert.equal(context.__harborTerminalMode, true);
  await action('enterTerminalMode'); // must not replace the saved sidebar state
  await action('leaveTerminalMode');
  assert.equal(visible.sidebar, true); assert.equal(maximized, true, 'native host owns panel restore state');
  assert.equal(context.__harborTerminalMode, false);
  assert.ok(layoutEvents.length > 0); assert.ok(layoutEvents.every(type => type === 'harbor-layout'));
  await action('setTerminalPanel', {visible: true, maximized: false});
  assert.equal(maximized, false);
  calls.length = 0;
  await action('setTerminalPanel', {visible: true, maximized: false});
  assert.equal(calls.length, 0, 'idempotent desired state must not trigger layout');
  assert.equal((await action('setTerminalPanel', {visible: true})).ok, false);
  await Promise.all([action('setTerminalPanel', {visible: true, maximized: true}), action('setTerminalPanel', {visible: true, maximized: false})]);
  assert.equal(maximized, false, 'queued desired states converge in call order');
  await action('toggleSidebar');
  await action('enterTerminalMode'); await action('leaveTerminalMode');
  assert.equal(visible.sidebar, false, 'mode return preserves an originally hidden sidebar');
  await action('hidePanel');
  assert.equal(visible.panel, false);
  assert.equal((await action({action: 'openTerminal'})).ok, false);
  calls.length = 0;
  assert.equal((await action('toggleSidebar', {preserveFocus: 'true'})).ok, false);
  assert.equal(calls.length, 0, 'invalid focus options never reach the layout service');
  const mutable = {preserveFocus: true};
  const preserving = action('toggleSidebar', mutable);
  mutable.preserveFocus = false;
  await preserving;
  assert.deepEqual(calls, [['hidden', 'workbench.parts.sidebar', false, true]], 'the queued focus option is snapshotted');
  calls.length = 0;
  await action('toggleSidebar');
  assert.deepEqual(calls, [['hidden', 'workbench.parts.sidebar', true, false]], 'the local API defaults to upstream focus behavior');
  calls.length = 0;
  const oldMaximized = maximized;
  assert.equal((await action('focusEditor')).ok, true);
  assert.deepEqual(calls, [['focus', 'workbench.parts.editor']], 'focusEditor never opens a terminal or changes panel geometry');
  assert.equal(visible.panel, false); assert.equal(maximized, oldMaximized);
  calls.length = 0;
  for (const name of ['newTerminal', 'splitTerminal', 'toggleTerminal', 'focusTerminal']) assert.equal((await action(name)).ok, true);
  assert.deepEqual(calls, ['new', 'split', 'toggleTerminal', 'focus'].map(name => ['command', 'workbench.action.terminal.' + name]), 'fixed local actions call the actual built-in commands without SSH or a custom panel');
}
terminalGraceBehavior().then(terminalMenuActions).then(localActions).then(() => console.log('Pinned Code-OSS layout and fixed local-action behavior passed.'), error => { console.error(error); process.exitCode = 1; });

}
