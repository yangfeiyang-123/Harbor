'use strict';
// Terminals belong to Code-OSS's real terminal/PTY service. Harbor only supplies
// navigation and initial names; it does not emulate a terminal in a webview.
const vscode = require('vscode');
const fs = require('fs');
const os = require('os');
const path = require('path');
const {randomUUID} = require('crypto');
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const builtin = {
  splitTerminal: 'workbench.action.terminal.split',
  toggleTerminal: 'workbench.action.terminal.toggleTerminal',
  renameTerminal: 'workbench.action.terminal.rename',
  closeTerminal: 'workbench.action.terminal.kill',
  focusNextTerminal: 'workbench.action.terminal.focusNext',
  focusPreviousTerminal: 'workbench.action.terminal.focusPrevious'
};
const validPath = value => typeof value === 'string' && path.isAbsolute(value) && !value.includes('\0');
const cwdPath = value => typeof value === 'string' ? value : value?.fsPath;
const legacyDirectory = value => value === '~' ? os.homedir()
  : typeof value === 'string' && value.startsWith('~/') ? path.join(os.homedir(), value.slice(2)) : value;

exports.install = function(context) {
  const metadata = new WeakMap(), resumed = new Map();
  let previous = new Map();
  function track(terminal) {
    if (!metadata.has(terminal)) {
      const info = {id: randomUUID()}; metadata.set(terminal, info);
      Promise.resolve(terminal.processId).then(pid => {
        if (Number.isSafeInteger(pid) && pid > 0) info.processId = pid;
      }).catch(() => {});
    }
    return metadata.get(terminal);
  }
  function describe(terminal) {
    const info = track(terminal);
    const integratedCwd = cwdPath(terminal.shellIntegration?.cwd);
    const initialCwd = cwdPath(terminal.creationOptions?.cwd);
    const legacySessionID = terminal.creationOptions?.env?.HARBOR_LEGACY_SESSION_ID;
    return {...info, name: terminal.name, active: terminal === vscode.window.activeTerminal,
      cwd: integratedCwd || initialCwd,
      cwdSource: integratedCwd ? 'shellIntegration' : initialCwd ? 'initial' : undefined,
      ...(uuid.test(legacySessionID || '') ? {legacySessionID} : {})};
  }
  function find(id) {
    return vscode.window.terminals.find(terminal => track(terminal).id === id);
  }
  function create(options) {
    const terminal = vscode.window.createTerminal({...options, location: vscode.TerminalLocation.Panel});
    track(terminal); terminal.show(false); return terminal;
  }
  function python() {
    for (const directory of (process.env.PATH || '').split(path.delimiter)) {
      if (!path.isAbsolute(directory)) continue;
      const candidate = path.join(directory, 'python3');
      try { fs.accessSync(candidate, fs.constants.X_OK); return candidate; } catch {}
    }
    return '/usr/bin/python3';
  }
  async function run(action, options = {}) {
    if (action === 'newTerminal') {
      const directory = options.cwd ?? cwdPath(vscode.window.activeTerminal?.shellIntegration?.cwd)
        ?? vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
      if (!validPath(directory)) throw Error('A terminal needs an absolute workspace directory');
      const name = typeof options.name === 'string' && options.name.trim() ? options.name.trim().slice(0, 200)
        : path.basename(directory) || directory;
      return describe(create({name, cwd: directory}));
    }
    if (action === 'resumePreviousSession') {
      let id = options.id;
      if (id === undefined) {
        if (!previous.size) { await vscode.window.showInformationMessage('No previous Harbor sessions are available in this workspace.'); return null; }
        const chosen = await vscode.window.showQuickPick([...previous.values()].map(session =>
          ({label: session.name, description: session.directory, id: session.id})), {title: 'Resume Previous Session', placeHolder: 'Choose a session to attach to this window'});
        if (!chosen) return null;
        id = chosen.id;
      }
      const session = previous.get(id);
      if (!session) throw Error('This previous session is not available in the current workspace');
      const existing = resumed.get(session.id) || vscode.window.terminals.find(terminal =>
        terminal.creationOptions?.env?.HARBOR_LEGACY_SESSION_ID === session.id);
      if (existing && vscode.window.terminals.includes(existing)) { existing.show(false); return describe(existing); }
      // Raw attach runs inside an ordinary Code-OSS terminal. It reattaches the
      // existing daemon's PTY and never creates/kills its shell. This operation
      // is deliberately only reachable through an explicit user action.
      const terminal = create({name: session.name, cwd: session.directory,
        shellPath: python(), shellArgs: [path.join(context.extensionPath, 'legacy-terminal-host.py'), 'attach', session.id, '--sanitize-replay'],
        env: {HARBOR_LEGACY_SESSION_ID: session.id}});
      resumed.set(session.id, terminal); return describe(terminal);
    }
    if (action === 'terminalInput') {
      // Without an id the text goes to the terminal the user is in (a path dropped on it).
      const terminal = options.id === undefined ? vscode.window.activeTerminal : find(options.id);
      if (!terminal) throw Error('Unknown terminal');
      if (typeof options.text !== 'string' || options.text.length > 8192 || options.text.includes('\0')) throw Error('Invalid terminal input');
      terminal.sendText(options.text, false); return null;
    }
    if (action === 'closeTerminal' && options.id !== undefined) {
      const terminal = find(options.id);
      if (!terminal) throw Error('Unknown terminal');
      terminal.dispose(); return null;
    }
    if (action === 'focusTerminal') {
      if (options.id !== undefined) {
        const terminal = find(options.id);
        if (!terminal) throw Error('Unknown terminal');
        terminal.show(false); return describe(terminal);
      }
      await vscode.commands.executeCommand('workbench.action.terminal.focus'); return null;
    }
    if (builtin[action]) { await vscode.commands.executeCommand(builtin[action]); return null; }
    throw Error('Unknown terminal action');
  }
  const names = ['newTerminal', 'splitTerminal', 'focusTerminal', 'toggleTerminal', 'renameTerminal', 'closeTerminal',
    'focusNextTerminal', 'focusPreviousTerminal', 'resumePreviousSession'];
  for (const name of names) context.subscriptions.push(vscode.commands.registerCommand('harbor.' + name, options => run(name, options)));
  context.subscriptions.push(vscode.window.onDidOpenTerminal(track), vscode.window.onDidCloseTerminal(terminal => {
    for (const [id, candidate] of resumed) if (candidate === terminal) resumed.delete(id);
  }));
  return {
    actions: new Set([...names, 'terminalInput']), run,
    status: () => vscode.window.terminals.map(describe),
    previousSessions: () => [...previous.values()],
    updateNativeState(state) {
      previous = new Map((Array.isArray(state.legacyTerminals) ? state.legacyTerminals : [])
        .filter(item => uuid.test(item?.id || '') && typeof item.name === 'string' && validPath(legacyDirectory(item.directory)))
        .map(item => [item.id, {id: item.id, name: item.name.slice(0, 200), directory: legacyDirectory(item.directory)}]));
    }
  };
};
