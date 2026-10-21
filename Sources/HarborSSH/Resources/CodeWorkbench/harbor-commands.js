'use strict';
const vscode = require('vscode');

// Harbor's own places and actions, in the Command Palette. (They used to be a
// "Harbor" view in the Explorer, which led back to the app's old sidebar.) Only
// the name of an action crosses to the app, which resolves it against what it
// knows: nothing here names a host, a path or a command line.
const actions = {
  'harbor.addServer': 'addServer', 'harbor.settings': 'settings',
  'harbor.openFolder': 'openFolder', 'harbor.closeFolder': 'closeFolder', 'harbor.switchFolder': 'switchFolder',
  'harbor.foldersInWindows': 'organizer', 'harbor.startPage': 'recent',
  'harbor.reverseProxy': 'proxy', 'harbor.remoteDisplay': 'display', 'harbor.terminalMode': 'terminalMode'
};
exports.actions = actions;
exports.install = function(context, dispatch) {
  for (const [command, action] of Object.entries(actions)) {
    context.subscriptions.push(vscode.commands.registerCommand(command, () => dispatch({action})));
  }
};
