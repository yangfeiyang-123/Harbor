Colors resolved from the installed official Visual Studio Code theme-defaults extension on 2026-09-06, including dark_modern/dark_plus/dark_vs and light_modern/light_plus/light_vs inheritance. Only roles used by Harbor are retained. Syntax scopes are mapped to CodeMirror tags.

- https://github.com/microsoft/vscode/blob/main/extensions/theme-defaults/themes/2026-dark.json
- https://github.com/microsoft/vscode/blob/main/extensions/theme-defaults/themes/2026-light.json
- https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/terminal/common/terminalColorRegistry.ts

The 16 ANSI colors use VS Code registry defaults, because the 2026 themes do not override them. An unspecified terminal background inherits panel.background, as in VS Code. Server chrome and SwiftTerm retain vscode-2026.json.


Files & Code (Harbor 0.21.0) reads cursor.json in native workspace surfaces and the offline CodeMirror/Markdown bundle. Colors were read on 2026-09-16 from a local Cursor extension `theme-cursor` (`cursor-themes` 0.0.2):

- `/Applications/Cursor.app/Contents/Resources/app/extensions/theme-cursor/themes/cursor-dark-color-theme.json`
- `/Applications/Cursor.app/Contents/Resources/app/extensions/theme-cursor/themes/cursor-light-color-theme.json`

Syntax scopes are mapped to CodeMirror tags. Missing roles retain Harbor’s existing values. No Cursor executable code, brand assets, AI service, or extensions are bundled. Light editor #FCFCFC, sidebar #F3F3F3; dark editor #181818, sidebar #141414.

File icons (Harbor 0.21.1) use the MIT-licensed Seti UI font and colors, imported from the installed Cursor `vscode-theme-seti` 1.0.0 extension on 2026-09-16. Upstream: https://github.com/jesseweed/seti-ui at 1cac4f30f93cc898103c62dde41823a09b0d7b74. The WOFF tables are losslessly repackaged as TTF for Core Text. `scripts/import-seti-icons.py` resolves the installed language associations and preserves explicit Seti filename/compound-extension rules. Cursor SVG brand overrides are excluded. `Seti/LICENSE.txt` contains the original third-party notice and MIT license. The small font and lookup table are loaded once; there are no web views, network requests, or animation timers for icons.
