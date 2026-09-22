# Third-party notices

Harbor's original code is licensed under the [MIT License](LICENSE).
Third-party components retain their own copyrights and licenses. The MIT
license at the repository root does not relicense them.

| Component | Use | License and attribution |
| --- | --- | --- |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | Native terminal emulator, with Harbor patches | [MIT](vendor/SwiftTerm/LICENSE), Miguel de Icaza and upstream terminal authors. See [vendoring notes](vendor/SwiftTerm/HARBOR.md). |
| [CodeMirror](https://codemirror.net/) and Lezer | Offline code editor and language parsers | MIT; full dependency notices in [THIRD-PARTY-LICENSES.txt](Sources/HarborSSH/Resources/Editor/THIRD-PARTY-LICENSES.txt). |
| [Marked](https://github.com/markedjs/marked) | Markdown rendering | MIT; included in the editor notices. |
| [DOMPurify](https://github.com/cure53/DOMPurify) | HTML sanitization | Apache-2.0 OR MPL-2.0; distributed under the Apache-2.0 option, with its full notice in the editor notices. |
| [Visual Studio Code](https://github.com/microsoft/vscode) | Theme color roles | [MIT](Sources/HarborSSH/Resources/Themes/LICENSE.txt), Microsoft Corporation. |
| [Seti UI](https://github.com/jesseweed/seti-ui) | File icon font and mappings | [MIT](Sources/HarborSSH/Resources/Themes/Seti/LICENSE.txt), Jesse Weed and contributors. |

The file workspace uses a neutral palette inspired by common editors. Harbor
does not bundle Cursor executable code, trademarks, AI services, or extensions.
The optional native glass appearance was independently implemented using Apple's
public APIs; [design references](Resources/LiquidGlass-SOURCES.txt) are retained.

## Optional Isaac Sim WebRTC integration

The NVIDIA Omniverse WebRTC Streaming Library is **not** included in this
repository or in the standard Harbor release archive. It is separately licensed
by NVIDIA. The `viewer/` directory contains Harbor's integration code and a
dependency manifest, not a copy of NVIDIA's implementation.

Users who have the appropriate NVIDIA license can build and install the optional
viewer for their own use. See [remote display setup](docs/remote-display.md).
Do not redistribute an app or viewer bundle containing the NVIDIA library
without ensuring that its license permits your distribution.
