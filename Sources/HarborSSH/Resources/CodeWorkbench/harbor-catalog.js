'use strict';
// Everything the editor and its extensions let you configure, for Harbor's
// Settings panel. The panel carries the catalog of this Code-OSS build and its
// built-in extensions; this module adds the extensions installed on this
// server, reports what is set for the user and for the folder, and writes one
// value at a time. Objects are edited in settings.json, which it can open.
const vscode = require('vscode');
const zlib = require('zlib');

const plain = value => value === null || ['boolean', 'number', 'string'].includes(typeof value);
function entry(key, schema) {
  const out = {key};
  if (typeof schema.type === 'string' || Array.isArray(schema.type)) out.type = schema.type;
  if ('default' in schema && JSON.stringify(schema.default ?? null).length <= 2000) out.default = schema.default;
  if (Array.isArray(schema.enum) && schema.enum.every(plain)) out.enum = schema.enum;
  const options = schema.markdownEnumDescriptions || schema.enumDescriptions;
  if (Array.isArray(options)) out.enumDescriptions = options.map(item => typeof item === 'string' ? item : '');
  if (Array.isArray(schema.enumItemLabels)) out.enumItemLabels = schema.enumItemLabels.map(item => typeof item === 'string' ? item : '');
  const description = schema.markdownDescription ?? schema.description;
  if (typeof description === 'string') out.description = description;
  const deprecated = schema.markdownDeprecationMessage ?? schema.deprecationMessage;
  if (typeof deprecated === 'string') out.deprecated = deprecated;
  for (const name of ['minimum', 'maximum', 'order']) if (typeof schema[name] === 'number') out[name] = schema[name];
  if (typeof schema.scope === 'string') out.scope = schema.scope;
  if (schema.editPresentation === 'multilineText') out.multiline = true;
  if (Array.isArray(schema.tags)) out.tags = schema.tags.filter(tag => typeof tag === 'string');
  if (schema.items && typeof schema.items === 'object' && !Array.isArray(schema.items)) {
    out.items = {};
    if (typeof schema.items.type === 'string') out.items.type = schema.items.type;
    if (Array.isArray(schema.items.enum) && schema.items.enum.every(plain)) out.items.enum = schema.items.enum;
  }
  return out;
}

// One group per `contributes.configuration` section of an extension.
function contributed(builtin) {
  const groups = [];
  for (const extension of vscode.extensions.all) {
    const manifest = extension.packageJSON || {};
    if (!!manifest.isBuiltin !== builtin) continue;
    const configuration = manifest.contributes?.configuration;
    const sections = Array.isArray(configuration) ? configuration : configuration ? [configuration] : [];
    const name = manifest.displayName || manifest.name || extension.id;
    sections.forEach((section, index) => {
      const properties = section && typeof section.properties === 'object' && section.properties || {};
      const settings = Object.entries(properties).filter(([, schema]) => schema && typeof schema === 'object')
        .map(([key, schema]) => entry(key, schema));
      if (!settings.length) return;
      groups.push({extension: extension.id, name, title: typeof section.title === 'string' && section.title || name,
        order: typeof section.order === 'number' ? section.order : index, settings});
    });
  }
  return groups;
}

// Every registered setting, from the schema the editor validates settings.json
// against. This document is large and crosses to the extension host, so it is
// only used to build the catalog Harbor ships (scripts/build-settings-catalog.py).
async function registered() {
  const documents = new Map();
  const load = async id => {
    if (!documents.has(id)) documents.set(id, JSON.parse((await vscode.workspace.openTextDocument(vscode.Uri.parse(id))).getText()));
    return documents.get(id);
  };
  const root = 'vscode://schemas/settings/default', schema = await load(root), settings = [];
  for (const [key, value] of Object.entries(schema.properties || {})) {
    if (!value || typeof value !== 'object' || key.startsWith('[')) continue;
    let resolved = value;
    // Settings that can differ per language are kept once, in another schema.
    if (typeof value.$ref === 'string') {
      const [id, pointer = ''] = value.$ref.split('#');
      let target = await load(id || root);
      for (const part of pointer.split('/').filter(Boolean)) target = target?.[decodeURIComponent(part).replace(/~1/g, '/').replace(/~0/g, '~')];
      if (target && typeof target === 'object') resolved = {...target, ...value};
    }
    settings.push(entry(key, resolved));
  }
  return settings;
}

function values() {
  const config = vscode.workspace.getConfiguration(), user = {}, workspace = {};
  for (const section of Object.keys(config)) {
    if (typeof config[section] === 'function' || section.startsWith('[')) continue;
    const found = config.inspect(section);
    if (found?.globalValue !== undefined) user[section] = found.globalValue;
    const local = found?.workspaceFolderValue ?? found?.workspaceValue;
    if (local !== undefined) workspace[section] = local;
  }
  return {user, workspace, trusted: vscode.workspace.isTrusted};
}

const writable = value => plain(value) && (typeof value !== 'string' || value.length <= 4000)
  || Array.isArray(value) && value.length <= 200 && value.every(item => typeof item === 'string' && item.length <= 1000);

exports.install = function install() {
  const actions = new Set(['settingsCatalog', 'settingsValues', 'settingsUpdate', 'settingsJson']);
  async function run(command, body) {
    if (command === 'settingsCatalog') {
      if (body.full !== true) return {groups: contributed(false)};
      const full = {version: vscode.version, settings: await registered(), groups: contributed(true), installed: contributed(false)};
      return {deflated: zlib.deflateRawSync(Buffer.from(JSON.stringify(full))).toString('base64')};
    }
    if (command === 'settingsValues') return values();
    if (command === 'settingsUpdate') {
      const {key, value, scope, remove} = body;
      if (typeof key !== 'string' || key.length > 200 || !/^[A-Za-z0-9_\-]+(\.[A-Za-z0-9_\-]+)+$/.test(key)) throw Error('Invalid setting');
      if (remove !== true && !writable(value)) throw Error('This value is edited in settings.json');
      const target = scope === 'workspace' ? vscode.ConfigurationTarget.Workspace : vscode.ConfigurationTarget.Global;
      await vscode.workspace.getConfiguration().update(key, remove === true ? undefined : value, target);
      return values();
    }
    // settingsJson: the file behind a scope, with the cursor on one setting if asked.
    const reveal = typeof body.key === 'string' && body.key.length <= 200 ? {revealSetting: {key: body.key, edit: true}} : undefined;
    await vscode.commands.executeCommand(body.scope === 'workspace' ? 'workbench.action.openWorkspaceSettingsFile' : 'workbench.action.openSettingsJson', reveal);
    return null;
  }
  return {actions, run};
};
