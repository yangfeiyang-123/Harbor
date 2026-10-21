'use strict';
// Runs in Code-OSS's real extension host. Only Harbor's loopback, authenticated
// command channel can invoke this small allowlist; no arbitrary eval/shell API.
const vscode = require('vscode');
const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const commands = new Set([
  'actions.find', 'editor.action.startFindReplaceAction', 'workbench.action.files.save',
  'workbench.action.quickOpen', 'workbench.action.showCommands', 'workbench.action.findInFiles',
  'workbench.action.gotoSymbol', 'workbench.action.gotoLine', 'workbench.action.toggleSidebarVisibility',
  'workbench.action.closeActiveEditor', 'workbench.view.extensions', 'workbench.view.explorer', 'workbench.action.focusActiveEditorGroup',
  'editor.action.fontZoomIn', 'editor.action.fontZoomOut', 'editor.action.fontZoomReset',
  'editor.action.addSelectionToNextFindMatch', 'workbench.action.files.newUntitledFile', 'workbench.action.showAllSymbols',
  'editor.action.selectHighlights', 'workbench.action.closeAllEditors',
  'workbench.action.closeAuxiliaryBar', 'workbench.action.openSettings', 'workbench.action.openGlobalKeybindings',
  'workbench.action.toggleAuxiliaryBar', 'workbench.action.splitEditor', 'workbench.trust.manage',
  'workbench.action.terminal.new', 'workbench.action.terminal.split', 'workbench.action.terminal.focus',
  'workbench.action.terminal.rename', 'workbench.action.terminal.kill', 'workbench.action.terminal.focusFind',
  'workbench.action.terminal.fontZoomIn', 'workbench.action.terminal.fontZoomOut', 'workbench.action.terminal.fontZoomReset',
  'workbench.action.terminal.focusNext', 'workbench.action.terminal.focusPrevious',
  'workbench.action.toggleMaximizedPanel', 'workbench.action.files.openFile',
]);
// Folders that tools fill and nobody edits: environments, caches, installed packages.
const watcherExclude = Object.fromEntries(['.venv', 'venv', '.venvs', '.conda', '.tox', 'site-packages', 'node_modules',
  '__pycache__', '.cache', '.mypy_cache', '.pytest_cache', '.ruff_cache', '.ipynb_checkpoints', '.eggs', '.omc', 'wandb']
  .map(name => ['**/' + name + '/**', true]));
exports.watcherExclude = watcherExclude;
exports.activate = function(context) {
  const data = process.env.HARBOR_CODE_DATA;
  // The command token is in the service's own record, which only this account can read. (An
  // editor started by an earlier Harbor still has it in its environment, where every terminal
  // inherited it.)
  let token = process.env.HARBOR_CODE_TOKEN;
  if (!token && data) {
    try { token = JSON.parse(fs.readFileSync(path.join(data, 'runtime.json'), 'utf8')).token; } catch {}
  }
  const folder = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
  if (!data || !token || !folder) return;
  if (!context.globalState.get('initialized')) {
    vscode.commands.executeCommand('workbench.action.closeAuxiliaryBar');
    context.globalState.update('initialized', true);
  }
  // Migrate the embedded layout once; subsequent user customizations survive.
  // A separate terminal marker also handles a partially completed v4 upgrade.
  if ((context.globalState.get('harborLayoutVersion') || 0) < 5 || !context.globalState.get('harborBuiltinTerminalDefaultsVersion')) {
    (async () => {
      if ((context.globalState.get('harborLayoutVersion') || 0) < 4) {
        if ((context.globalState.get('harborLayoutVersion') || 0) < 3) {
          await vscode.workspace.getConfiguration('window').update('customTitleBarVisibility', undefined, vscode.ConfigurationTarget.Global);
          await vscode.workspace.getConfiguration('workbench').update('activityBar.location', 'top', vscode.ConfigurationTarget.Global);
        }
        // Earlier builds hid Code-OSS's status bar behind Harbor's duplicate.
        // Seed-only settings leave those installed profiles permanently hidden.
        await vscode.workspace.getConfiguration('workbench').update('statusBar.visible', true, vscode.ConfigurationTarget.Global);
        await context.globalState.update('harborLayoutVersion', 4);
      }
      if ((context.globalState.get('harborLayoutVersion') || 0) < 5) {
        // Older Harbor profiles enabled floating surfaces. Updating only the
        // bootstrap defaults leaves their four-pixel panel gaps in place.
        // Reset these layout flags once; themes and later customizations stay.
        const config = vscode.workspace.getConfiguration('workbench');
        for (const key of ['experimental.modernUI', 'shadows']) {
          await config.update(key, false, vscode.ConfigurationTarget.Global);
        }
        await context.globalState.update('harborLayoutVersion', 5);
      }
      if (!context.globalState.get('harborBuiltinTerminalDefaultsVersion')) {
        const config = vscode.workspace.getConfiguration('terminal.integrated');
        const defaults = {'tabs.title': '${cwdFolder}', enablePersistentSessions: true,
          persistentSessionReviveProcess: 'onExitAndWindowClose', splitCwd: 'inherited', enableBell: false, smoothScrolling: false};
        for (const [key, value] of Object.entries(defaults)) {
          if (config.inspect(key)?.globalValue === undefined) await config.update(key, value, vscode.ConfigurationTarget.Global);
        }
        await context.globalState.update('harborBuiltinTerminalDefaultsVersion', 1);
      }
    })().catch(error => vscode.window.showWarningMessage('Harbor could not migrate its workbench layout: ' + String(error.message || error)));
  }
  // Harbor is used with extensions and command-line agents. Turn the built-in
  // assistant surfaces off once, and apply lean watcher/search defaults only
  // where the user has not chosen a value. Later edits in Settings are kept.
  const leanVersion = context.globalState.get('harborLeanProfileVersion') || 0;
  if (leanVersion < 2) {
    (async () => {
      const config = vscode.workspace.getConfiguration();
      if (leanVersion < 1) {
        const assistant = {'chat.disableAIFeatures': true, 'chat.agent.enabled': false, 'editor.inlineSuggest.enabled': false,
          'workbench.editor.empty.hint': 'hidden', 'terminal.integrated.initialHint': false, 'chat.tips.enabled': false,
          'workbench.settings.showAISearchToggle': false, 'chat.agentsControl.enabled': 'hidden', 'editor.aiStats.enabled': false};
        // A key this Code-OSS build does not register rejects; skip it.
        for (const [key, value] of Object.entries(assistant)) {
          try { await config.update(key, value, vscode.ConfigurationTarget.Global); } catch {}
        }
        try {
          if (config.inspect('search.followSymlinks')?.globalValue === undefined) await config.update('search.followSymlinks', false, vscode.ConfigurationTarget.Global);
        } catch {}
      }
      // The file watcher needs one inotify watch for every folder it watches, and
      // a server allows an account a fixed number of them (often 65,536, shared by
      // everyone on a shared account). A project with a few environments and
      // caches in it has more folders than that, and the editor then says "Unable
      // to watch for file changes". The folders that tools fill are left out;
      // whatever the user set, including a folder switched back on, is kept.
      try {
        const current = config.inspect('files.watcherExclude')?.globalValue;
        const own = current && typeof current === 'object' && !Array.isArray(current) ? current : {};
        const merged = {...watcherExclude, ...own};
        if (Object.keys(merged).length !== Object.keys(own).length) await config.update('files.watcherExclude', merged, vscode.ConfigurationTarget.Global);
      } catch {}
      await context.globalState.update('harborLeanProfileVersion', 2);
    })().catch(() => {});
  }
  const events = []; let eventWaiter;
  const deliver = () => {
    if (!eventWaiter || !events.length) return;
    const reply = eventWaiter; eventWaiter = undefined; reply(events.splice(0));
  };
  const dispatch = event => {
    if (events.length < 32) events.push(event);
    deliver();
  };
  // Unsaved files and terminal counts are pushed when they change, so the
  // native app does not need to poll this process every two seconds.
  let statusTimer, lastStatus = '';
  const publishStatus = () => {
    clearTimeout(statusTimer);
    statusTimer = setTimeout(() => {
      const value = JSON.stringify({dirty: vscode.workspace.textDocuments.filter(d => d.isDirty).map(d => d.uri.fsPath),
        terminalCount: vscode.window.terminals.length});
      if (value === lastStatus) return;
      lastStatus = value; dispatch({action: 'status', value});
    }, 150);
  };
  context.subscriptions.push({dispose() { clearTimeout(statusTimer); }},
    vscode.workspace.onDidChangeTextDocument(publishStatus), vscode.workspace.onDidSaveTextDocument(publishStatus),
    vscode.workspace.onDidCloseTextDocument(publishStatus), vscode.window.onDidOpenTerminal(publishStatus),
    vscode.window.onDidCloseTerminal(publishStatus));
  const terminals = require('./harbor-terminal').install(context);
  require('./harbor-commands').install(context, dispatch);
  const updatePreferences = require('./harbor-settings').install(context, dispatch);
  const catalog = require('./harbor-catalog').install(context);
  // Harbor's Settings panel is the one place for settings. When the editor's own
  // Settings editor opens (its menus, the Command Palette, an extension's gear),
  // close it and show the panel instead. settings.json opens as usual.
  const settingsEditor = tab => tab.input === undefined && tab.label === 'Settings';
  context.subscriptions.push(vscode.window.tabGroups.onDidChangeTabs(event => {
    const opened = event.opened.find(settingsEditor);
    if (!opened) return;
    Promise.resolve(vscode.window.tabGroups.close(opened)).catch(() => {}).then(() => dispatch({action: 'settings', from: 'editor'}));
  }));
  const lease = () => { const now = new Date(); try { fs.utimesSync(path.join(data, 'lease'), now, now); } catch {} };
  const key = crypto.createHash('sha256').update(fs.realpathSync(folder)).digest('hex');
  const record = path.join(data, 'bridges', key + '.json');
  let lastCommand = '';
  const server = http.createServer(async (req, res) => {
    res.setHeader('Connection', 'close'); res.setHeader('Content-Type', 'application/json'); res.setHeader('Cache-Control', 'no-store');
    if (req.headers.authorization !== 'Bearer ' + token || req.method !== 'POST' || req.headers.origin) {
      res.writeHead(403); res.end('{}'); return;
    }
    try {
      // Decoded as one stream: a character split between two reads must not turn into two broken ones.
      req.setEncoding('utf8');
      let text = '';
      for await (const chunk of req) { text += chunk; if (text.length > 32768) { req.destroy(); return; } }
      const body = JSON.parse(text); lease(); if (!['status','events','nativeState'].includes(body.command)) lastCommand = body.command;
      let result = null;
      if (body.command === 'events') {
        if (eventWaiter) eventWaiter([]);
        const result = await new Promise(resolve => {
          const finish = value => { clearTimeout(timer); if (eventWaiter === finish) eventWaiter = undefined; resolve(value); };
          const timer = setTimeout(() => finish([]), 20000);
          eventWaiter = finish; res.once('close', () => finish([])); deliver();
        });
        if (!res.destroyed) res.end(JSON.stringify({result}));
        return;
      } else if (body.command === 'nativeState') {
        if (!Array.isArray(body.state?.servers)) throw Error('Invalid Harbor state');
        terminals.updateNativeState(body.state);
        await updatePreferences(body.state.preferences);
      } else if (body.command === 'status') {
        const editor = vscode.window.activeTextEditor;
        result = {folder, lastCommand, terminalCount: vscode.window.terminals.length, terminals: terminals.status(),
          workspaceTrusted: vscode.workspace.isTrusted,
          dirty: vscode.workspace.textDocuments.filter(d => d.isDirty).map(d => d.uri.fsPath),
          active: editor?.document.uri.fsPath,
          label: editor ? `Ln ${editor.selection.active.line + 1}, Col ${editor.selection.active.character + 1} · ${editor.document.languageId}` : 'Code-OSS · Open VSX',
          extensions: vscode.extensions.all.map(e => e.id)};
      } else if (body.command === 'theme') {
        // Harbor's own themes only: the neutral pair, and "Harbor <Family> Light" or "… Dark".
        if (typeof body.value !== 'string' || !/^Harbor(?: [A-Z][a-z]{1,20})? (?:Light|Dark)$/.test(body.value)) throw Error('Invalid theme');
        await vscode.workspace.getConfiguration('workbench').update('colorTheme', body.value, vscode.ConfigurationTarget.Global);
      } else if (body.command === 'editorSettings') {
        const config = vscode.workspace.getConfiguration('editor');
        if (Number.isFinite(body.font) && body.font >= 9 && body.font <= 32) await config.update('fontSize', body.font, vscode.ConfigurationTarget.Global);
        if (typeof body.wrap === 'boolean') await config.update('wordWrap', body.wrap ? 'on' : 'off', vscode.ConfigurationTarget.Global);
      } else if (body.command === 'terminalPanel') {
        if (body.visible) {
          await terminals.run('focusTerminal');
          await vscode.commands.executeCommand('workbench.action.positionPanelBottom');
          await vscode.commands.executeCommand('workbench.action.alignPanelCenter');
          if (body.toggleMaximized) await vscode.commands.executeCommand('workbench.action.toggleMaximizedPanel');
        } else {
          await vscode.commands.executeCommand('workbench.action.closePanel');
        }
      } else if (body.command === 'workbench.action.togglePanel') {
        await terminals.run('toggleTerminal');
      } else if (terminals.actions.has(body.command)) {
        result = await terminals.run(body.command, body);
      } else if (catalog.actions.has(body.command)) {
        result = await catalog.run(body.command, body);
      } else if (body.command === 'openFile') {
        // Preserve the remote authority; file: would ask the browser's local
        // filesystem provider and can hang opening a remote document.
        const uri = vscode.workspace.workspaceFolders[0].uri.with({path: body.path});
        lastCommand = 'openFile: loading document';
        const document = await vscode.workspace.openTextDocument(uri);
        lastCommand = 'openFile: showing document';
        await vscode.window.showTextDocument(document, {preview: false});
        lastCommand = 'openFile: complete';
      } else if (commands.has(body.command)) {
        result = await vscode.commands.executeCommand(body.command);
      } else { throw Error('Unknown command'); }
      res.end(JSON.stringify({result: result ?? null}));
    } catch (e) {
      // A client that went away in the middle of its request has nobody left to answer.
      if (res.destroyed || res.headersSent) { try { res.end(); } catch {} return; }
      res.writeHead(400); res.end(JSON.stringify({error: String(e.message || e)}));
    }
  });
  server.listen(0, '127.0.0.1', () => {
    fs.writeFileSync(record, JSON.stringify({port: server.address().port}), {mode: 0o600});
    lease();
  });
  server.on('error', () => {});
  context.subscriptions.push({dispose() {
    const port = server.address()?.port; if (eventWaiter) eventWaiter([]); server.close();
    // A replacement window may already have written a newer bridge record.
    try { if (JSON.parse(fs.readFileSync(record, 'utf8')).port === port) fs.unlinkSync(record); } catch {}
  }});
};
