# Harbor

A native macOS workbench for local and SSH projects, built with SwiftUI, AppKit, OpenSSH and an embedded Code-OSS editor. The interface, menus, settings, dialogs, and accessibility labels are in English. Server names, folder names, file contents, and terminal output retain their original text.

**Source version: 0.36.0 (build 78).** [中文](README.zh-CN.md) · [Releases](https://github.com/yangfeiyang-123/Harbor/releases)

## Current workbench

Code-OSS (with Open VSX extensions and its integrated terminal) is now Harbor's only editor; the earlier lightweight editor, its explorer and its previews were removed. Harbor itself contributes what Code-OSS does not have: servers, folder workspaces, windows, forwarding, remote display and appearance.

- **Start page** with Open Folder, Open File, recent folders and servers, plus
  four interactive dolls. Claude wears a brown cowboy hat; Codex is a blue
  terminal robot. Hover to greet, click to bounce, or drag and release a doll.
- **Windows**: Shift+Command+N opens another workbench window with its own server and folder. A folder is shown by one window at a time.
- A window is a workspace of folders on any servers. **Option+Tab** steps through the folders of the window, most recently shown first; type to find any other. **Folders in Windows** leads the start page and arranges them: a library of every server and folder on the left, each window as a column, and New Window; closed windows come back from there with one click.
- **Claude Light / Dark** and five more theme families (Tide, Kelp, Dusk, Fog, Lighthouse), a motion setting, and one Settings panel: Harbor's pages with a live preview, and every editor and extension setting with search.
- The row of views above the sidebar shows a fixed number of icons (four by default); the rest open from the arrow.

See [Files & Code](docs/code-workbench.md) and [Getting started](docs/getting-started.md).

## Open Harbor

The installed app is `/Applications/Harbor.app`. Open **Harbor** from Spotlight or Finder → Applications.

On first launch, Harbor imports concrete server aliases from `~/.ssh/config`, preserving existing keys, jump hosts, and proxy settings. It does not modify SSH configuration. You can also add servers manually. Password and first-host verification prompts appear in the terminal. A server's password is asked for once: Harbor keeps it in the login keychain and answers ssh with it from the next connection (see [Passwords](#passwords)).

## Folders

A folder on this Mac or on a server opens as a workspace: the editor (Code-OSS) on that folder, with its own files, tabs and integrated terminals. The editor keeps what it had open; unsaved changes still need to be saved before quitting.

- **Start page ▸ Open Folder…** (Command+Option+O) chooses a folder on this Mac in the system's panel. For a folder on a server, use the folder button on the server's row, or right-click the server and choose **Open Folder…**: Harbor's own browser lists what the typed path leads to, hidden folders included. Browsing is read-only; **Open Folder** confirms, **Cancel** leaves everything as it was.
- A click on a server's row opens the folder that window last showed there.
- **Recent** on the start page lists the folders that were opened, grouped by server, newest first. Search matches folder names, paths and server names. The **×** of a row removes only the shortcut. Twelve are kept.
- The **…** menu in the bar above the editor has **Switch Folder…** (also Option+Tab), **Folders in Windows…**, **Close Folder**, Reverse Proxy and Remote Display. Closing a folder takes it out of Harbor's list, not off the disk; it is refused while the editor has unsaved changes.
- A folder is shown by one window at a time. **Folders in Windows…** (Option+Shift+Command+W) arranges which window keeps which folder, and brings closed windows back.

## Terminals and shortcuts

There are three places for a terminal:

- **In the editor**: its integrated terminal panel (Command+J), split and tabbed with the editor's own keys. Option+Z switches the window between Files & Code and a terminal that fills it.
- **The terminal page**: **Start page ▸ New Terminal** (Command+T) is a shell on this Mac filling the window, with nothing around it; right-click a server and choose **New Terminal** for one there. Asking again returns to it. A server's terminal page is kept when Harbor quits: its shells go on running there, and New Terminal for that server returns to them.
- **A terminal window**: Command+N. It belongs to the application, not to the window it was asked for from.

Servers share one OpenSSH ControlMaster, retained for eight hours after the last terminal closes.

| Action | Shortcut |
| --- | --- |
| New window | Shift+Command+N |
| Start page | Shift+Command+H |
| Switch between a window's folders | Option+Tab |
| Folders in Windows | Option+Shift+Command+W |
| Switch between windows gathered as tabs | Command+1 … Command+9 (9 is the last tab) |
| Open Folder / Open File | Command+Option+O / Command+O |
| New terminal window | Command+N |
| New terminal (start page), or a new tab (terminal page and windows) | Command+T, or Control+Shift+backtick |
| Split right / down (terminal page) | Command+D / Shift+Command+D |
| Split right / down (terminal window) | Command+D / Command+H |
| Previous / next pane | Option+Command+← / Option+Command+→ |
| Previous / next terminal tab | Shift+Command+[ / Shift+Command+] |
| Close the pane in use (terminal page) | Command+W |
| Switch Files / Terminal mode (a workspace) | Option+Z; configurable in Settings |
| Maximize / restore the terminal panel | Option+X |
| Show / hide the terminal panel | Command+J |
| Switch editor / terminal focus | Control+backtick |
| Quick Open / Command Palette | Command+P / Shift+Command+P |
| Search in Project | Shift+Command+F |
| Go to Symbol / Line | Shift+Command+O / Control+G |
| Show / hide the sidebar | Command+B |
| Close the active file | Command+W |
| Find / save | Command+F / Command+S |
| Increase / decrease / reset font size | Command+= / Command+minus / Shift+Command+0 |

Where there is no workspace or terminal on screen (the start page, Reverse Proxy, Remote Display), Command+H hides Harbor as in any Mac application, and the keys of a workspace do nothing.

In a terminal page or window, a split group is one tab; a new terminal is a tab of its own. Nested splits keep their proportions and the focused pane. Drag the dividers to resize. A pane has its title bar, with a close button, once there is more than one.

New terminals are named after their starting folder. A split starts in the folder its source pane is in, including after `cd`. Double-click a terminal's title or use its context menu to rename it; an empty name goes back to the folder's. Drag a tab's edge to set its width.

Select text and press Command+C, or right-click and choose Copy. In programs that use the mouse, hold Shift while dragging to select. Control+C still interrupts the command in front.

A terminal on a server runs under Harbor's own small terminal host there, so it survives a lost connection: **Reconnect** in the pane returns to the same shell, with what it printed meanwhile. A shell is kept for a day without anyone attached. When the server no longer has it, Reconnect starts a new one. See [terminal recovery](docs/terminal-recovery.md).

### Dragging and ordering

- Drag a terminal tab to an insertion line to reorder the tabs. Drop it on another tab's center to merge the two into a split.
- Drag a pane's title to another pane's left, right, top or bottom to arrange a split. Drag it between the tabs to make it a tab of its own.
- Drag servers on the start page to reorder them. The order and the servers' icons are kept.

## Appearance and accessibility

**Harbor → Settings…** (Command+,) opens over the current window and has two choices for color: a theme (Claude, Standard, Tide, Kelp, Dusk, Fog or Lighthouse) and a mode (System, Light or Dark). Hovering a theme previews it in the miniature workbench on the right without applying it. Anthropic Light uses ivory paper, warm ink and a clay accent; Anthropic Dark uses warm charcoal with the same accent. Both are Harbor's own palettes, generated by `scripts/build-anthropic-theme.py`, which refuses to write colors that fall below their contrast floor. Tide (sea blue), Kelp (moss green), Dusk (violet), Fog (grays only) and Lighthouse (full contrast with an amber accent) are made the same way by `scripts/build-themes.py`. The editor, its terminal, Harbor's terminal windows and native pages all follow the same choice.

**Motion** is Full, Subtle or Off; macOS Reduce Motion always limits Harbor to Subtle. **Liquid Glass** applies to the neutral themes; Claude and the five families after it use matte surfaces. Interface, editor and terminal font sizes are separate.

## Connections and reverse proxy

Reconnecting one disconnected terminal recovers other disconnected terminals on that server, including other folder workspaces. Names, widths, directories, and layouts are retained; healthy terminals and other servers are not restarted. Authentication happens on the first connection and is reused by the remaining terminals.

New remote terminals use Harbor’s private Python PTY host. Reconnecting attaches to the original shell instead of starting it again; commands are never rerun. See [terminal recovery](docs/terminal-recovery.md).

Harbor includes custom remote, local, and SOCKS5 forwarding, plus an optional managed proxy runtime. The managed runtime requires installation-specific SSH, VPN, and gateway settings; the public host table contains example destinations. Configure it before use; ordinary SSH workspaces do not require it. See [managed proxy setup](docs/reverse-proxy-tuning.md). Managed status distinguishes a running process from an actual remote HTTP 204 check.

Each managed tunnel is paced in both directions. The bridge on the server measures the round trip to the Mac through the tunnel every few seconds and slows server → Mac traffic as soon as that delay grows; the gateway shaper on the Mac does the same for Mac → server traffic using the reported value. This keeps aTrust’s queue short, so terminals and editors stay responsive while wandb, pip, or model downloads run. The same probe is the liveness check: a bridge that cannot reach the Mac closes its port so `proxy_on` fails fast, and the Mac-side watchdog only checks local services instead of opening SSH sessions. Status shows the current rates as `A100_SHAPE` / `RTX_SHAPE`. Set `RP_SHAPE=0` in the tunnel environment to disable pacing. Measurements, reasons, and limits are in [reverse proxy tuning](docs/reverse-proxy-tuning.md).

Custom forwards authenticate without asking anything: with SSH keys, or with the password Harbor keeps for a server that takes one (see [Passwords](#passwords)). Aliases with existing forwards are not reused for extra forwards, avoiding duplicate ports. If GatewayPorts exposes a custom remote listener on all interfaces, Harbor stops it and explains why. Starting a tunnel is distinct from verifying an HTTP request; non-HTTP services require their own client validation. Quitting closes Harbor’s custom forwards; managed proxy services continue independently.

Import and startup resolve SSH configuration before merging duplicate aliases for the same effective host, user, port, jump/proxy settings, and keys. Configuration is backed up first; references and searchable aliases migrate with it. Different destinations remain separate.

## Passwords

Harbor's terminals run OpenSSH with Harbor itself as its askpass program (`SSH_ASKPASS`, `SSH_ASKPASS_REQUIRE=force`), so ssh's questions reach Harbor first. A password question (`user@host's password:`, or keyboard-interactive `(user@host) Password:`) is answered from the login keychain when a password is kept for that server and account. Anything else — a new host key, a key's passphrase, a one-time code — is asked in the terminal exactly as ssh asks it, and so is a password not kept yet.

- A typed password is kept at once, as a generic password named "Harbor SSH · user@host", and given without asking only after a connection with it has been made. One ssh asks for again in the same connection was refused: it is dropped and asked for again. One typed for a connection that was never made is not given; the next connection asks.
- The keychain is reached through `/usr/bin/security`, which reads again what it added without a dialog, so a new build of Harbor (ad-hoc signed) does not ask for the login password. As with an SSH key without a passphrase, a program running as you can read a kept password; it is encrypted on disk with the login keychain.
- **Edit Server ▸ Password ▸ Forget Password** removes the server's passwords; **Remove Server** does too, after asking, and closes the server’s terminals and forwarding rules with it. Keys and agents work as before: a server that takes a key never asks.
- The editor and the file browser have no terminal to ask in. When a server refuses them for want of a password (`user@host: Permission denied (…password…)`), Harbor makes the server's shared connection itself: with the kept password, or with one typed in a password dialog, kept the same way. ssh then runs with no terminal and `NumberOfPasswordPrompts=1`, and the askpass program answers that one password and nothing else: with nothing to give it stops ssh rather than let it send an empty password the server would count as a failed attempt. A new host key is still confirmed in a terminal.
- Everything else Harbor runs over ssh without a terminal — custom forwarding rules, Remote Display's tunnel and checks, the editor putting its connection back — uses the kept password the same way (`ServerPasswords.quiet`: no terminal, one password, nothing asked). A server with keys only is reached exactly as before. The managed A100 / RTX 4090 proxies keep using their keys.

## Local data

Data lives in `~/Library/Application Support/HarborSSH/`: server configuration, forwarding rules, and recent server/folder references in `recent-workspaces.json`. Config files use mode 600 and the directory mode 700. Server passwords are not stored here but in the login keychain (below). Terminal command/output logging was removed in version 0.5; current terminals retain in-memory scrollback. Corrupt configuration is preserved and further writes pause until it is repaired.

## Build and validation

Requires macOS 14 or later. Building requires Swift 6 and the macOS 26 SDK; the bundle targets the current Mac’s architecture.

```bash
swift test --disable-sandbox --build-system native
bash scripts/build-app.sh release
python3 scripts/install-app.py
open /Applications/Harbor.app
```

The build creates `.build/Harbor.app`. The installer verifies its signature, replaces `/Applications/Harbor.app`, moves the previous bundle to Trash, and removes the generated app copy. It preserves running processes; quit and reopen when convenient to load the update. The app is ad-hoc signed locally, not Developer ID notarized.

SwiftTerm is pinned to v1.20.0 (`5d14406844143538cd8f8851d2d8a67c1fe443e5`) in `vendor/SwiftTerm`, with its MIT license. Harbor makes `becomeFirstResponder` overridable to track split focus without changing its behavior. Unused termcast/documentation dependencies are removed from the local manifest; `Package.upstream.swift` retains the original.

See [validation](docs/validation.md) for current evidence and limitations, and [Files & Code design](docs/IDE-DESIGN.md) for implementation notes. Development can use `HARBOR_DATA_DIR` for isolated data and `HARBOR_NO_IMPORT=1` to disable personal SSH import. Preview bundles ending in `.preview` can embed `HarborPreviewDataDirectory` so isolation survives LaunchServices relaunches.

### Terminal recovery (0.19)

Open terminals keep rendered output when reconnecting. Harbor checkpoints changed terminal buffers every 15 seconds and saves synchronously before a normal quit. On relaunch, terminal names, directories, ordering, split proportions and selection are restored without starting commands or reconnecting automatically. Click **Reconnect** to continue. Detached windows are reopened with their original groups.

**Saved Output** in a disconnected pane, or **View Saved Output…** in the terminal context menu, opens a selectable text copy even if the remote application clears its screen on reconnect. Recovery is a rendered text snapshot, not a replay of terminal escape codes; syntax colors and images are not archived. Each open terminal keeps up to 8 MB, within its 20,000-line terminal buffer, under the private `TerminalRecovery` folder in Harbor's data directory. Explicitly closing a terminal removes its recovery copy. A crash may lose the last 15 seconds since the checkpoint.

New remote terminals no longer use tmux. Harbor installs a small, versioned Python 3 stdlib helper in a private user-owned temporary directory. It retains each remote PTY independently of SSH, with bounded output replay and a 24-hour disconnect grace period. Existing tmux terminals retain their original IDs so ongoing processes are not interrupted. Reopening a recent directory creates a new Harbor-hosted terminal. Server restarts, process exits and expired sessions cannot be revived; saved output remains available and Harbor explicitly asks you to create a new terminal. See [behavior and limits](docs/terminal-recovery.md).

### Remote Display (0.18)

Open **Remote Display** from the start page, from **…** in the bar above the editor, or from the Connection menu. It fills the window under a slim bar that leads back to where it was opened from. Save server-specific connections for embedded web/noVNC viewers, Isaac Sim WebRTC in Chrome/Edge, or native VNC in macOS Screen Sharing. Includes private SSH TCP tunnels, separate windows, full screen and on-demand renderer cleanup. A running server-side display service is required; see [connection types and setup](docs/remote-display.md).
