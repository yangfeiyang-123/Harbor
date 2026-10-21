'use strict';
// Harbor's Settings window is the one place for preferences: its own and the
// editor and terminal options listed in harbor-synced-settings.json. The native
// app owns their persisted values and sends them to every server's editor;
// editing one here (the Code-OSS Settings editor, settings.json) sends it back.
// Acknowledgements protect user edits from an older native snapshot still in
// flight over the local bridge.
const vscode = require('vscode');
const {randomUUID} = require('crypto');
const schema = require('./harbor-settings-schema.json');
const synced = require('./harbor-synced-settings.json');
const numeric = (min, max, integer = false) => value => typeof value === 'number' && Number.isFinite(value)
  && value >= min && value <= max && (!integer || Number.isInteger(value));
const choices = list => value => list.includes(value);
const boolean = value => typeof value === 'boolean';
const specs = {
  // Every family and mode the schema lists: the native app adds a family there and nowhere else here.
  'harbor.appearance': {valid: choices(schema.properties['harbor.appearance'].enum)},
  'harbor.motion': {valid: choices(['full', 'subtle', 'off'])},
  'harbor.activityBar.visibleItems': {valid: numeric(1, 12, true)},
  'harbor.interfaceFontSize': {valid: numeric(11, 20)},
  'harbor.liquidGlassEnabled': {valid: boolean},
  'harbor.modeSwitchShortcut': {valid: value => typeof value === 'string' && value.length <= 40 && /^(?:(?:ctrl|alt|shift|cmd)\+){1,4}[^+\s]$/.test(value)},
};
const text = max => value => typeof value === 'string' && value.length <= max && !/[\u0000-\u001f\u007f]/.test(value);
for (const item of synced) {
  const valid = item.type === 'boolean' ? boolean : item.type === 'number' ? numeric(item.min, item.max, item.integer === true)
    : item.type === 'choice' ? choices(item.values) : text(item.max);
  // `always` settings were shared before the Settings window was unified.
  specs[item.key] = {standard: true, unified: item.always !== true, fallback: item.default, valid};
}
exports.configuration = schema;
exports.install = function install(context, dispatch) {
  const known = new Map(), pending = new Map(), native = new Map();
  let initialized = false, disposed = false, tail = Promise.resolve();
  const migrationNeeded = !context.globalState.get('harborPreferencesVersion');
  // The first time this editor meets the unified Settings window, what the user
  // had already chosen here wins and is taken up by Harbor.
  const unifiedNeeded = !context.globalState.get('harborUnifiedSettingsVersion');
  const enqueue = operation => {
    const result = tail.then(() => disposed ? undefined : operation());
    tail = result.catch(() => {}); return result;
  };
  function inspected(key) { return vscode.workspace.getConfiguration().inspect(key) || {}; }
  function current(key) {
    // Native preferences are application/user settings. A folder's settings.json
    // must not silently change every Harbor window or another server's terminal.
    const config = inspected(key);
    return config.globalValue === undefined ? config.defaultValue : config.globalValue;
  }
  async function write(key, value) {
    if (current(key) === value) { known.set(key, value); return; }
    known.set(key, value);
    // A setting this editor build does not register rejects; the rest must still be applied.
    try { await vscode.workspace.getConfiguration().update(key, value, vscode.ConfigurationTarget.Global); } catch {}
  }
  function send(key, value) {
    const id = randomUUID();
    pending.set(key, {id, value}); known.set(key, value);
    dispatch({action: 'preference', key, value: JSON.stringify(value), id});
  }
  function warn(key) {
    vscode.window.showWarningMessage(`Harbor could not apply ${key}. Its previous value has been restored.`);
  }
  const listener = vscode.workspace.onDidChangeConfiguration(event => {
    if (!initialized || disposed) return;
    for (const [key, spec] of Object.entries(specs)) {
      if (!event.affectsConfiguration(key)) continue;
      const value = current(key);
      if (value === known.get(key)) continue;
      if (!spec.valid(value)) {
        // Invalid Harbor settings must not appear applied while native state
        // still uses a different value.
        const previous = pending.get(key)?.value ?? native.get(key);
        if (previous !== undefined) enqueue(async () => { await write(key, previous); warn(key); });
        continue;
      }
      send(key, value);
    }
  });
  context.subscriptions.push(listener, {dispose() { disposed = true; pending.clear(); }});

  return function update(preferences) {
    if (!preferences || typeof preferences.values !== 'object' || !preferences.values) return Promise.resolve();
    // Copy only scalar allowlisted settings. Queued work cannot observe a caller
    // mutating its payload, and arbitrary configuration keys never cross over.
    const values = Object.fromEntries(Object.entries(preferences.values).filter(([key, value]) => specs[key]?.valid(value)));
    const acks = {...preferences.acknowledgements};
    return enqueue(async () => {
      const first = !initialized;
      initialized = true;
      for (const [key, value] of Object.entries(values)) {
        const previous = native.get(key), awaiting = pending.get(key);
        native.set(key, value);
        if (awaiting) {
          if (acks[key] !== awaiting.id) continue;
          pending.delete(key);
          if (value !== awaiting.value) warn(key);
          await write(key, value);
        } else if (first) {
          const existing = inspected(key).globalValue;
          // Existing editor customizations are authoritative on migration. The
          // bootstrap already seeded new editors from Harbor's font/wrap values.
          if ((migrationNeeded || unifiedNeeded && specs[key].unified) && specs[key].standard && existing !== undefined && specs[key].valid(existing) && existing !== value) {
            send(key, existing);
          } else {
            await write(key, value);
          }
        } else if (previous !== value) {
          await write(key, value);
        }
      }
      if (first && unifiedNeeded) {
        // Options Harbor has no value for yet: adopt what this editor was customized to.
        for (const [key, spec] of Object.entries(specs)) {
          if (!spec.unified || key in values || pending.has(key)) continue;
          const existing = inspected(key).globalValue;
          if (existing !== undefined && existing !== spec.fallback && spec.valid(existing)) send(key, existing);
        }
      }
      if (first) {
        // From here on only a change is reported. A setting Harbor holds no value for has its
        // present one noted: setting it for one folder, which changes nothing for the user,
        // must not be taken for a new preference and written into every other editor.
        for (const key of Object.keys(specs)) if (!known.has(key)) known.set(key, current(key));
      }
      if (first && Object.keys(values).length) {
        await context.globalState.update('harborPreferencesVersion', 1);
        await context.globalState.update('harborUnifiedSettingsVersion', 1);
      }
    });
  };
};
