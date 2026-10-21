# Third-party notices

Harbor's original code is licensed under the [MIT License](LICENSE).
Third-party components retain their own copyrights and licenses. The MIT
license at the repository root does not relicense them.

| Component | Use | License and attribution |
| --- | --- | --- |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | Native terminal emulator, with Harbor patches | [MIT](vendor/SwiftTerm/LICENSE), Miguel de Icaza and upstream terminal authors. See [vendoring notes](vendor/SwiftTerm/HARBOR.md). |
| [Visual Studio Code](https://github.com/microsoft/vscode) | Theme color roles | [MIT](Sources/HarborSSH/Resources/Themes/LICENSE.txt), Microsoft Corporation. |

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
# On-demand Code-OSS workbench

Harbor can download code-server 4.140.0 from Coder's official GitHub releases.
code-server is MIT-licensed and includes Code-OSS and its own dependency notices.
The downloaded runtime retains its original LICENSE and notices. Harbor pins and
verifies each platform archive with SHA-256. Extensions come from Open VSX and
retain their individual licenses; they are not bundled with Harbor.

- https://github.com/coder/code-server
- https://github.com/microsoft/vscode
- https://open-vsx.org/
