# Files & Code

Harbor uses Code-OSS through code-server as its editor. Open a folder from the start
page, a server row, or **Open Folder…**. The first use downloads a verified runtime once on that
machine. A local project runs locally; a remote project runs on its SSH server.
Code-OSS owns the integrated terminal, its tabs, splits and remote PTY sessions.

## Extensions and languages

Press **Shift+Command+X** to browse Open VSX, or use **Extensions: Install from
VSIX…** in the command palette. JavaScript/TypeScript, HTML/CSS, JSON and Markdown
have built-in language support. Install compatible extensions for other languages,
such as Pyright for Python, clangd for C/C++, or LaTeX Workshop for TeX. Their
interpreters, compilers and language servers must exist on the project machine.
Opening a file does not install its language tools automatically.

This is a real extension host, not a list of suggested plugins. It is not the
Microsoft Marketplace or Cursor's proprietary services. Extensions with restricted
licenses, desktop-only dependencies, or unsupported APIs may not work. Workspace
Trust remains enabled; review the project and publisher before enabling code.

## Layout and keyboard

- **Command+P / Shift+Command+P**: Quick Open / Command Palette.
- **Command+F / Shift+Command+F**: Find in file / search the project.
- **Command+S**: Save.
- **Command+B**: show or hide the sidebar. **Command+J**: show or hide Terminal.
- **Option+Z**: Terminal Mode / Files & Code.
- **Option+X**: maximize or restore Terminal within the editor column.
- **Control+Shift+`**: a new terminal, separate from splitting.
- **Command+D / Command+H** in a terminal: split the active terminal.
  **Command+D** in the editor keeps Code-OSS's next-match selection behavior.
- **Command+,**: open or close Settings, a panel over the window.
- **Shift+Command+N**: another Harbor window. **Command+1…9**: the Nth window when several are
  gathered as tabs of one (9 is the last).

These three are taken before the page sees them. Left to Code-OSS, Command+, would load its own
Settings editor first and Shift+Command+N would ask the browser for another page of the server.

Explorer, Search, Source Control, Run and Extensions sit in a horizontal row
centered above the sidebar. Narrow sidebars put additional views in a dropdown
arrow. Explorer starts directly with its contents, without a separate Explorer
title and ellipsis row. A compact title bar provides connection and layout controls;
the full sidebar and status bar belong to Code-OSS.

Harbor has no view of its own in the editor's sidebar. Its places are in the
bar above the editor, which shows its controls when the pointer is on it: the
server and the folder, each with its menu, and **…** with **Reverse Proxy**,
**Remote Display**, **Folders in Windows…**, **Switch Folder…** and **Close
Folder**. The same are commands in the Command Palette under **Harbor:** (with
**Start Page**, **Open Folder…**, **Add Server…**, **Settings** and **Terminal
Mode**), and in the menu bar. Closing a folder does not delete it from disk.

**Reverse Proxy** and **Remote Display** are pages that fill the window under a
slim bar of their own, like the editor and the terminal: the page's name in the
middle and, at the leading end, the way back to where the page was opened from
(the folder's name when that was the editor, **Start** from the start page).
The earlier shell around these pages, a sidebar of servers under a toolbar, is
gone; servers are listed on the start page, where they are also dragged into
another order.

The editor's clipboard is this Mac's pasteboard. A web page may read the
clipboard only with a permission that an embedded view cannot be given (for text
copied in another application WebKit wants its own "Paste" bubble clicked, and
refuses otherwise), and the editor's terminal pastes by reading the clipboard:
Command+V there ended in "Unable to read from the browser's clipboard". The
editor is Harbor's own page, so reading and writing text go through Harbor to
the pasteboard, as in a desktop editor. Only the page's top frame on its own
address is answered. Pasting pictures, and a paste the keyboard delivers to an
editor or an extension's view, work as before.

When the editor loses its server it says so itself, in one place: first a quiet
"Attempting to reconnect…" at the bottom right and, when it lasts, the same
as a dialog with **Reconnect Now**, **Dismiss** and **Reload Window**.
It keeps trying on its own. Harbor adds no notice of its own for this (there
used to be a second one at the top right, with its own Reconnect button). Its
part is the connection underneath: the page loads through port forwards of the
server's shared ssh connection, and when that connection has died they are put
back on the same local ports, so the editor's next attempt gets through and
nothing is loaded again. **Reload Window**, from that dialog or anywhere else,
is a connection from the start (a new ssh connection if needed, the editor's
service made sure of, the page and its command service found again), which is
what the Reconnect button did.

Folders that tools fill and nobody edits are left out of file watching:
environments (`.venv`, `venv`, `.venvs`, `.conda`, `.tox`), installed packages
(`site-packages`, `node_modules`) and caches (`.cache`, `__pycache__`,
`.mypy_cache`, `.pytest_cache`, `.ruff_cache`, `.ipynb_checkpoints`, `.eggs`,
`.omc`, `wandb`). The watcher needs one inotify watch for every folder it watches,
and a server allows an account a fixed number of them (65,536 on most of these
servers, shared by everyone who uses the account). A project with a few
environments in it has more folders than that, and the editor then says "Unable
to watch for file changes". The list is `files.watcherExclude` in Settings: a
new profile starts with it, and a profile from before gets the missing entries
added once, keeping whatever was set there, a folder switched back on included.
Folders a person works in (`runs`, `results`, `data`) stay watched; one that
grows very large can be added in Settings.

There is one **Terminal** panel, using Code-OSS's built-in terminal. User terminals,
task terminals and extension terminals all use that same service. It occupies only
the editor column; the sidebar stays full height. **Problems**, **Output**,
**Debug Console** and **Ports** remain available. Splitting inherits the active
shell's current directory. Terminal appearance, profiles and keyboard behavior are
configured through the ordinary **Terminal › Integrated** settings.

Existing remote Harbor sessions are preserved separately during migration. Choose
**… → Resume Previous Session…** in the bar (it is there while the server has such
sessions), or run **Harbor: Resume Previous Session…** from the Command Palette, and
select a session to resume it inside a built-in terminal. This explicitly moves its active attachment to the current window; its
remote process keeps running. Harbor never attaches to these sessions automatically
or starts a replacement shell when the old process has already exited.

**Option+Z** keeps the same editor web view loaded while displaying Terminal Mode
with the built-in terminal tabs and controls. Returning restores the sidebar's
previous visibility. **Option+X** and **Command+B** change the local workbench
layout without waiting for an SSH command round trip. A brief fade accompanies
layout transitions and respects Reduce Motion. Panel visibility and maximization
stay in sync when switching directories or reconnecting.

Editor groups, tabs, selection, completion, Find and terminal rendering use
Code-OSS. Terminal shortcuts apply when a terminal is focused. Resize boundaries draw one line
and have a larger grab area. There is no built-in AI chat panel.

**Command+,** opens Settings as a panel over the window: theme and mode, motion, glass,
font sizes, the number of views above the sidebar, and the mode-switch shortcut, with a live
preview, and below those every setting of the editor and its extensions. Esc or a click outside
closes it; the buttons at its top right open `settings.json`, fill the window, and close.
Workspace-specific editor and terminal overrides remain scoped to the project.

Set **Harbor: Appearance** to **anthropic**, **anthropic-light** or **anthropic-dark**
for Harbor's Anthropic palettes; **system**, **light** and **dark** select the neutral
ones. **tide**, **kelp**, **dusk**, **fog** and **lighthouse** select the other families,
each with **-light** and **-dark** to pin a mode. The editor can also use other themes through **Workbench: Color Theme**.

## Windows, switching and the sidebar row

- The dot beside a server on the start page means Harbor holds a connection to it. It is
  read from the control sockets on this Mac (`ssh -O check` on the socket terminals share
  and on the editor's own), for every window at once, every 20 seconds while Harbor is in
  front and after an editor starts or stops. No connection is opened or kept for it. A
  master that ssh keeps after its last use (`ControlPersist`) is a connection too.
  Launching Harbor connects to nothing.
- **New Terminal** on the start page (and **Command+T** there) is a terminal and
  nothing else: Harbor's own terminal view fills the window, in this Mac's home
  directory, under a slim bar that names it and leads back to the start page.
  It has the keys of any terminal: **Command+D** splits it to the right and
  **Shift+Command+D** below (a new pane starts in the directory of the one it was
  split from), **Command+T** adds a tab, **Option+Command+Left/Right** (or
  Up/Down) goes to the pane before or after, **Shift+Command+[** and **]** to the
  tab before or after, and **Command+W** closes the pane in use, asking first while
  its shell runs. The bar has the same as buttons at its trailing end. A pane has
  a title only beside another pane, and the row of tabs is there only once there
  is more than one, so one terminal still fills the window with nothing around it. No
  editor is started, so there is nothing to load and no folder to trust. A server's
  **New Terminal** (right click on the server) is the same in its login directory.
  There is one per window for this Mac and one for each server; asking again returns
  to it (all its panes and tabs), and `exit` in the last of them returns to the start page. A pane
  that has only lost its connection keeps the page, with its Reconnect. A server's
  terminal page is saved when Harbor quits and returned to by the same New Terminal;
  the one on this Mac is not. Neither leaves anything in the recent folders. Option+Z
  and Control+` are the shell's on this page.
- The start page opens from the top down (name, agents, then the columns) and is on
  screen at launch without a loading screen; its lists appear when the saved data
  has been read.
- A folder that is opening shows its server and name in the middle of the window
  with one line under it that fills as the editor gets nearer: paced by how long
  that server took the last time, and following the bytes while the editor itself is
  being sent. When the editor is ready the page fades and the title travels into the
  window's bar. Nothing in Harbor spins; every wait is that one line.
- **‹ Start** at the leading end of the bar (and **Shift+Command+H**) goes back to
  the start page from any page, with the editor in front as well (where the key
  would otherwise be the editor's Replace in Files). A folder that is opening has **Stop** (or Esc): the
  window returns to what it showed before and no longer keeps that folder.
- With several windows gathered as tabs, the tab bar is put away: in full screen it
  comes down with the menu bar, in a window it appears while the pointer is in the
  title row. It lies over the page and takes no room. **Window ▸ Always Show Tab
  Bar** keeps it on screen.
- Switching between open folders is a short fade from one editor to the other. The
  editor that is leaving stays on screen until the one arriving has drawn itself, so
  the window is never blank in between.
- The Dock menu has **New Window**. A folder dropped on the Dock icon (or opened
  with Harbor in Finder) goes to the window that already shows it, else to a window
  on its start page, else to a new window. Dropped on the start page it opens there;
  dropped on an editor it opens in that window, and on the editor's terminal its
  path is typed, quoted.
- This Mac is listed under its host name.
- **Shift+Command+N** opens another workbench window on the start page. Each window
  has its own server, folder, editor and terminals. A folder that is already open
  elsewhere offers **Show That Window** instead of a second editor.
- A window is a workspace: the folders it keeps, on whichever servers they are.
  **Option+Tab** steps through the folders of the window it is pressed in, the one
  on screen first and then the most recently shown. Keep Option held and press Tab
  to step, release to switch. Each row names its server. Typing finds any folder
  Harbor knows: the window's own first, then the others under **Not in this
  window**, and Return opens the chosen one here (it joins this window). A window
  that keeps no folder yet lists the library, and there letting go of Option opens
  nothing; Return or a click does. Switching changes the window it was asked in and
  never which window is in front. Option+Q is no longer taken by Harbor.
- A server chosen in the sidebar or on the start page comes up on a folder the
  window already has open (an editor running, then one it keeps), and only then on
  the folder chosen there last.
- **Folders in Windows** (the card that leads the start page, under **Windows**;
  the Window menu, **Shift+Option+Command+W**; or the link at the foot of the
  Option+Tab list) arranges which folder is in which
  window. On the left is the **Library**: every server, opened out to the folders
  that were opened on it (the most recent first), each saying which window it is
  in. Beside it every window is a column with the folders it keeps, and at the end
  is **New Window**. A window that keeps no folder and has no name is not a
  workspace and has no column: Harbor as it starts shows the library and **New
  Window**, and nothing else. A folder is dragged from the library into the window it should
  be in (or moved with its menu), and dragged back to the library, or removed with
  its cross, to leave the window. **New Window** adds a column for a window that
  does not exist yet: name it, fill it from the library, and it opens when the
  organizer closes, on its first folder, keeping the others. An empty one is
  dropped. The columns are centered as one group: a column that is added fades
  in while the others move apart for it, and only when they no longer fit do the
  windows scroll beside the library. A folder is in one window at a time; moving it closes its editor in the
  window it leaves (its files and what runs in its terminals are untouched), and
  is refused while that editor has unsaved changes.
- The plus beside a server in the library (or the one in the library's header) adds
  a folder on that server without opening it: type a path and the folders it leads
  to are listed as you type, or browse; the house goes to the home directory. On
  this Mac the system's panel is used. A folder's menu removes it from the library.
- A further window that is closed with folders in it is listed under **Recent
  Windows** at the foot of the library, by its name or its folders. A click plans it
  again: it leaves that list and is a column at the end, with those folders and
  that name, like any new window (taking the column away puts it back in the list).
- Harbor starts with one window that keeps no folder and has no name. What the
  first window kept when Harbor was last open is listed under **Recent Windows**
  too, under the name it had. Opening Harbor makes no workspace: when the
  organizer closes, the first window planned there is this window itself (rather
  than a second one beside an empty first), on its first folder, and the others
  open as tabs beside it.
- The start page lists the last three closed windows under **Folders in
  Windows**. A click opens one again at once, with its folders: as this window
  while it is no workspace yet, else as a further tab.
- Harbor's windows are tabs of one window by default. Closing **Folders in
  Windows** gathers the windows that are apart into one, and a window planned
  there opens as a new tab, in front. **Command+1…9** switches between them, and
  the tab bar stays put away until the pointer goes up to it, so no window loses a
  row. A window stands on its own with **Window ▸ Keep Window Separate** (or
  **Keep as a Separate Window** in its column's menu in the organizer); it is then
  left alone until that is switched off. Dragging a tab out, or Window ▸ Move Tab
  to New Window, takes it out until the organizer is closed the next time.
- Windows gathered as tabs (the system does this in full screen) keep the bar that
  switches server and folder: the tab bar gets its own row, under the title row in a
  window and above Harbor's bar in full screen. **Command+1…9** selects a tab.
- A window is named after its server and folder, which is what its tab, the Window
  menu and Mission Control show. **Window ▸ Rename Window…**, a double click on the
  tab, or a right click on Harbor's bar gives it a name of its own; a blank name goes
  back to the server and folder. In Harbor's own bar a named window reads
  **name · server · folder**, the name a little larger; without a name it is the
  server and folder.
- Drag a folder from Explorer onto the editor area to open it as its own workspace;
  hold Option to open it in a new window.
- **Harbor: Activity Bar: Visible Items** (default 4) fixes how many views sit in the
  row above the sidebar; the rest open from the arrow after them. Drag icons to
  reorder. The sidebar cannot be dragged narrower than that row and dragging never
  hides it — use **Command+B**.
- While a divider is dragged, extension panels keep their width and catch up when
  the pointer pauses, so a heavy panel does not stall the drag.

## Lean profile

Harbor is meant to be used with extensions and command-line agents. The built-in
assistant surfaces (chat, agent mode, AI inline suggestions, the empty-editor and
terminal hints) are switched off once per profile, and the bundled assistant
extension plus a few unused built-ins are removed from Harbor's private runtime copy.
Word and language-server completion are unchanged, and every setting can be turned
back on in Settings. Extensions such as Claude Code or Codex use their own panels and
are not affected.

## Runtime and storage

The supported runtime targets are macOS and Linux on ARM64/x86-64. Python 3 and
Open VSX access for extensions are required; the runtime comes from the Mac or is
downloaded on the server, whichever is faster (below). Linux must satisfy the pinned code-server release's native library
requirements. The runtime is about 200 MB compressed and needs additional disk and
memory for its extension host and language tools.

Harbor installs to its local data folder under `CodeOSS`, or
`~/.local/share/harbor/code-oss` remotely. It does not modify shell profiles, request
root access, replace an existing VS Code installation, or open a public port.
Editor traffic is authenticated and uses loopback listeners; remote access is
tunneled through SSH. Telemetry and automatic editor updates are disabled.

One service is shared per machine and Harbor profile. Hidden, clean workbenches
release their web view after five minutes. The service can shut down after thirty
minutes without a client lease when no terminal processes remain. Code-OSS hot-exit backups and installed extensions
remain on disk. Save important work normally; this cannot preserve a running
process across a server restart. Persistent terminal sessions can reconnect to the
same PTY during a seven-day reconnection window after a network interruption while the Code-OSS service and its PTY host
are still running. Process revival after a service restart is different from
reattaching to a surviving process.

## Embedded host layout

The pinned code-server 4.140.0 workbench receives hash-checked host integration
changes. They remove duplicate title chrome, reclaim Explorer's title-row height,
center the native activity bar with its existing overflow handling, and preserve
the built-in Terminal and status bar. A fixed local layout-action interface avoids
remote round trips for panel and sidebar changes. Standard new/split commands,
extension-created terminals and task terminals retain Code-OSS behavior.

These changes activate only under Harbor's document-start embedding flag;
ordinary browser clients keep the upstream behavior. Code-OSS owns the grid and
panel sizing. The installer verifies the upstream workbench hash before applying
or upgrading a complete known patch revision. Unknown or modified runtime versions
are rejected instead of patching unverified code. The upstream Code-OSS/code-server
licenses are retained in the downloaded runtime.

## When the editor is shown

The opening page covers the editor until Harbor's command service in it answers (it routes
Harbor's keys and commands). An editor that has drawn itself is not kept behind it for long: after
eight seconds it is shown with a note, and Harbor goes on looking for the service in the background
(for up to half an hour, allowing a slower round trip after the first tries). A folder that holds
Harbor's own runtime and extensions (`~/.local/share/harbor/code-oss`, so a login directory) is
shown at once: until the folder is trusted the editor keeps every extension stored in it off,
Harbor's too, and the question is the editor's to ask. Trusting it ("Restricted Mode" in the status
bar) starts the command service, and Harbor connects then. The note says so only while the
editor is in fact in Restricted Mode (the status bar item it shows only then); a folder trusted
before opens trusted.

An editor that is drawn, not in Restricted Mode, not "Activating Extensions…", and has no command
service after two minutes is loaded again, once per opening: an extension host was seen to wait for
good after a first install, and a reload started it.

## Getting the editor to a server

On first use a server reports which build it is missing. The Mac downloads that release once into
`~/Library/Caches/app.harbor.ssh/CodeOSS`, verifies its SHA-256, and copies it into a smaller archive (about
66 MB) without the built-in assistant's extension and native runtime, which it can send over the existing ssh
connection (through the transfer pacer on a managed tunnel). The upload continues from where it stopped.

Which way is faster depends on the server, so it is measured once per start. The server downloads the
release (about 230 MB) for six seconds, all at once, from GitHub and from each relay of GitHub's downloads in
`bootstrap.py` (`DOWNLOAD_MIRRORS`: ghfast.top, gh-proxy.com, ghproxy.net), timing each from its first bytes.
The Mac then sends its package for fifteen seconds, and the server says how much of it arrived; those bytes
are kept and continued. If downloading from the fastest source would take less than 80% of the remaining
upload, the server downloads from there, and from GitHub itself if that relay stops; otherwise the Mac goes
on sending. A server behind a network that reaches none of them gets the upload, as before. Whatever the
source, the release is installed only if its SHA-256 is the pinned one, so a relay can delay but not alter
it. The relays are third parties that see the server's address and the file it asks for, nothing else.
If the Mac cannot fetch or send the package, the server downloads the official release itself, from the
fastest source it measured, also resumably.

The receiving side is a short Python program, not `cat`. It takes a lock (`<archive>.slim.lock`) so that only
one upload writes the file at a time: a second window opening the same server waits and asks again instead of
appending into the same file. An upload that continues must find this package's own first bytes on the server,
compared by SHA-256 and not only by length; otherwise it starts over. A package that arrived whole and still
fails its checksum is deleted and sent once more, and only when that also fails does the server fetch the
full release. If an earlier attempt already left the complete official release there, it is verified and used
instead of being downloaded again. The archive is unpacked inside the data directory, which may be reached
through a symbolic link (a home directory on another disk): members are checked against its resolved path.

While a server workspace is open, the web view talks to a small proxy on this Mac. Requests for the editor's
own program files (`/stable-…/static/out` and `/static/node_modules`: scripts, styles, fonts, WebAssembly) are
answered from the Mac's copy of the same build; everything else, including the websocket to the extension
host, is passed through unchanged.

## What an update leaves behind

A new layout revision gets its own runtime and its own copy of each client's profile, so an older
Harbor that is still running is never disturbed. Once the new revision's editor runs on a machine,
`bootstrap.py` removes what the earlier ones left there (`prune`):

- runtimes of other revisions and the runtime from before revisions existed, unless an editor started
  from one still answers, another Mac's Harbor used it within the last 30 days, or some client there
  has not moved to revisions yet;
- this Mac's profiles for other revisions and its pre-revision profile, a day after the new one first
  started and only while no editor runs from them (terminals can outlive an update for days);
- earlier versions of Harbor's own extensions, when the editor is started rather than reused;
- directories an interrupted install or migration left.

Another client's profile is never touched. `{"op": "prune", "dryRun": true}` lists what would go;
`"force": true` skips the day's wait. On the Mac, trimmed packages of earlier releases are swept from
`~/Library/Caches/<bundle id>/CodeOSS` when the current one is built or used, and each install moves the
replaced app bundle to the Trash. Tests make their preference suites through `TestDefaults`, which
deletes the files macOS would otherwise leave in `~/Library/Preferences` after every run.

## Settings

The Settings panel owns Harbor's preferences and the editor and terminal options listed in
`harbor-synced-settings.json`. A value chosen there is written to every editor's user settings; a value
changed in `settings.json` comes back. Options nobody has chosen are left to each editor, so the default
a page shows for one must be the editor's own (a test holds the list to that).

Everything else is under **All settings** in the same panel, arranged like the editor's Settings editor
and searchable. `code-settings-catalog.json` lists the settings of the bundled Code-OSS build and its
built-in extensions; `scripts/build-settings-catalog.py` regenerates it from a running preview whenever
`bootstrap.py` moves to another code-server (a test compares the two versions). At run time the bridge
adds only what cannot be known in advance: the settings of extensions installed on that server
(`settingsCatalog`), the values set for the user and for the folder (`settingsValues`), one write at a
time (`settingsUpdate`: booleans, numbers, text and lists of text; objects are edited in `settings.json`,
which `settingsJson` opens at the setting). These are saved with that server's editor (User) or in the
folder's `.vscode/settings.json` (Workspace). When Code-OSS's own Settings editor opens, the extension
closes its tab and asks Harbor to show the panel instead. That editor opens in a modal block, and the
page script holds each new block back (hidden) until it is known to show something else, reports a
Settings editor to Harbor at once and closes it locally, so it is never drawn and nothing waits for a
round trip to the server; the extension's later report of the same event is then ignored.
