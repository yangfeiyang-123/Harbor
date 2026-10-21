# Changelog

## 0.36.0 — 2026-10-08 (build 78)

- A server's password is asked for once. Harbor's terminals run ssh with
  Harbor as its askpass program: the first time, the password is asked in the
  terminal as before, kept in the login keychain ("Harbor SSH · user@host"),
  and from the next connection given to ssh without asking. A password the
  server refuses (it was changed) is dropped and asked for again; one typed for
  a connection that was never made is not given. Host keys, key passphrases and
  one-time codes are asked in the terminal as ssh asks them, and never kept.
- The editor and the file browser ask too. Opening a folder on a server that
  takes a password and has no connection yet showed "Permission denied
  (publickey,password)" and nothing to type it in. Harbor now connects with the
  kept password, or asks for one in a password dialog and keeps it the same
  way; the connection it makes is shared with the server's terminals.
- Custom forwarding rules (Reverse Proxy ▸ Custom Forwarding), Remote Display,
  and the editor putting its connection back work on a server that takes a
  password: they connect with the password Harbor keeps for it, where they used
  to fail with "Permission denied" for want of a key.
- Edit Server has a Password section: Forget Password removes what is kept for
  the server. Removing a server removes its passwords too.
- Changing the color theme dissolves from the old colors into the new ones.
  It used to repaint the window part by part: the native parts as each was
  drawn again, and the editor only once Code-OSS had put its new theme on, a
  good part of a second later on a distant server, so for a moment the window
  wore two themes. Now every window dissolves the moment the theme is chosen
  (from Settings, the editor's own settings, or anywhere else), and the
  editor holds a picture of itself until its new colors are drawn, then
  dissolves the same way. Under the Settings panel the editor takes its new
  colors in view instead of keeping the old ones until the panel closes. An
  editor shown while Harbor's commands in it are still starting cannot be told
  of a new theme yet: its note now says that its colors follow, and when the
  commands answer it dissolves into them (Harbor knows each of its editor
  themes by its background) instead of changing at a stroke. The picture an
  editor holds while it changes is still, and on a slow server the change
  took many seconds: the editor looked stuck in its old colors and clicks
  seemed to do nothing (they reached the editor unseen). It now stays for at
  most 1.2 seconds, goes at once when the editor is clicked, typed in or
  scrolled, and is not taken at all when the page is slow to give it.
  Motion ▸ Subtle (and Reduce Motion) keeps a short dissolve; Off changes the
  colors at once.
- The library in Folders in Windows scrolls smoothly again; over an editor it
  moved at about ten frames a second, and a little unevenly over the start
  page. A sample of Harbor found it idle meanwhile: the time went into putting
  the window together, which Harbor asked to be done in two expensive ways.
  - The panel's shadow was worked out again from the panel's shape each time,
    a blur the size of the panel for every frame in which the list moved. It
    is now cast from the panel's outline (the Settings panel and the
    Option+Tab list as well).
  - Under the panel the editor's page, with every layer Code-OSS keeps, was
    put together again with it. While Folders in Windows or Settings lies over
    the window the editor is now a picture of itself, its page hidden; when
    the panel goes the page is shown again and the picture leaves once the
    page has drawn.
- Remove Server no longer refuses with "Close this server's active terminals
  first." A terminal that had only lost its connection, or that a window kept
  out of sight, counted as active, and nothing led to it, so such a server
  could not be removed at all; forwarding rules blocked it the same way. Harbor
  now asks once, saying what goes with the server, then closes its terminals
  (ending the shells it keeps for them on the server, when it can still reach
  it) and stops and deletes its forwarding rules. Unsaved editor changes still
  have to be saved first.
- Opening a server's login directory no longer hangs on "Loading Code-OSS…".
  Harbor's own extensions live in `~/.local/share/harbor`, inside that folder,
  and the editor turns off every extension inside a folder it has not been told
  to trust, Harbor's included. Harbor then waited a minute and more for its
  command service behind the opening page, while the editor, finished, waited
  behind it for the folder to be trusted. Now an editor that has drawn itself
  is shown at once in that case, with a note saying to click "Restricted Mode"
  and choose Trust; Harbor connects as soon as that is done.
- More generally, an editor that has drawn itself is shown after eight seconds
  even if Harbor's command service has not answered yet (over a slow path that
  took minutes), with a note beside it; Harbor keeps looking for the service,
  for up to half an hour, with longer waits for a slow round trip. A lookup
  that times out while the editor loads (its own traffic fills a slow path, and
  Harbor's small request waits behind it in the same connection) is asked
  again instead of ending in "The file operation timed out" over an editor
  that works.
- The note beside such an editor says "Restricted Mode … choose Trust" only
  while the editor is in Restricted Mode; a folder trusted before (its trust is
  kept in this Mac's editor storage) gets the plain "still starting" note.
- An editor whose extensions never start is loaded again once, by itself. After
  a first install on a new server the editor drew itself, trusted, and its
  extension host waited for good: no extension activated, no command service,
  for over ten minutes, until "Reload Window". Harbor now does that when the
  editor is drawn, not in Restricted Mode, not "Activating Extensions…", and
  has had no command service for two minutes.
- A new server gets the editor the fastest way. Harbor always sent it from the
  Mac (66 MB), which on a path across the Pacific ran at 10–20 KB/s for over an
  hour, while the server could download it in two minutes. Now the server times
  its downloads from GitHub and from relays of it (ghfast.top, gh-proxy.com,
  ghproxy.net) for six seconds, the Mac times its upload for fifteen, and the
  faster way is taken; what was uploaded meanwhile is kept. The release is
  installed only if its SHA-256 is the pinned one, wherever it came from.
  When the server reaches a source that delivers it within a minute, the
  upload is not timed at all. After timing the upload, the question "how much
  arrived?" waits behind the megabytes this Mac had already queued in the
  connection; with a 20-second limit it failed on a slow path, and the whole
  opening with it ("The file operation timed out"), at every reconnect. It now
  has the long limit of a start, and a failure there only means sending on.

## 0.35.0 — 2026-10-07 (build 77)

- New: five theme families, each with a light and a dark palette, beside
  Claude and Standard. Tide is fog-blue paper and deep-sea navy with one
  sea-blue accent; Kelp is lichen paper and pine black with moss green; Dusk
  is lilac paper and aubergine with violet; Fog is grays only, with ink for
  its accent and quiet syntax colors; Lighthouse is white and pitch black at
  full contrast with one amber accent. They are Harbor's own palettes, made
  from the same tokens as the Claude theme by `scripts/build-themes.py`,
  which holds body text to 7:1 on every surface and refuses colors below
  their contrast floor.
- Settings ▸ Appearance: Theme is a menu of the seven families, Mode is
  System, Light or Dark as before, and every family has a light and a dark
  swatch to hover and click. The editor, its terminal, Harbor's terminal
  windows and native pages all follow the choice; the editor gets a
  "Harbor <Family> Light" and "… Dark" color theme for each. Like Claude, the
  new families use matte surfaces: Liquid Glass stays with Standard.
- **Harbor: Appearance** in the editor's settings accepts the new families
  (`tide`, `tide-light`, `tide-dark`, and so on).

## 0.34.2 — 2026-10-06 (build 76)

- What a program copies in the editor's terminal is on the Mac's clipboard.
  Codex and Claude Code on a server, tmux and vim copy by asking the terminal
  to (OSC 52); the editor kept such text in a table of its own and never put
  it on the clipboard, so the program said "copied" and Paste gave what had
  been there before. Harbor's own terminal page already did this.
- Command+C and Copy in the terminal's menu go straight to the clipboard as
  well. They went by a detour the editor takes under WebKit, which fails
  without a word when something was copied in another application since the
  last click in the editor, or when a copy comes with no key press of its own
  (Copy in a menu, copy on selection).

Both are a new runtime revision: the editor is set up again on each server
the first time it is opened there.

## 0.34.1 — 2026-10-06 (build 75)

- Folders in Windows: a folder can be dragged from the library into a window
  again, and from one window to another. The drag is now AppKit's own: a press
  on the row that moves carries the folder to the column it is let go over.
  SwiftUI's drag never began for these rows, so the only way to arrange
  folders was each row's menu. The menu is still there, under the row's dots
  and on a right click; the row holds no menu button of its own any more.
- An editor left for another folder of the window stays loaded, and coming
  back to it is at once, with the page as it was. It used to be let go of
  after five minutes off the screen, so working on two folders in turn loaded
  each again at every return. Up to three editors stay loaded off the screen
  (the default `hiddenEditorsKept` changes the number); beyond that the one
  left longest ago goes, one with unsaved changes never. An editor whose
  renderer stops while it is off the screen loads again when next shown,
  instead of showing its notice then.
- Explorer's folder row (the folder's name, with New File, New Folder, Refresh
  and Collapse) is there in every workspace. In one where Outline and Timeline
  were hidden, the folder view was the sidebar's only view, and Code-OSS then
  merges it with its container and moves that row's actions up into a title
  area the embedded workbench hides. The folder view keeps its own row now
  whether or not the other views are shown (a new runtime revision; the editor
  is set up again on each server the first time it is opened there).

## 0.34.0 — 2026-10-05 (build 74)

An audit of the whole application: what it found, fixed. Nothing here is a
new feature unless it says so.

Terminals on a server (Harbor's terminal host there):

- A terminal no longer ends when it is resized or returned to while a command
  of another user is in front (`sudo -i`, `sudo vim`, a password prompt of
  `sudo`). It ended, and could not be reconnected to until that command was
  over: the host tried to signal the command, was refused, and took that for
  a broken connection.
- Files made in a terminal, or in the editor and its terminals, get the
  permissions the account gives them anywhere else. They were private (600,
  directories 700) because Harbor's helpers make their own files private and
  the shells inherited that.
- A pipe whose reader has left (`yes | head`, `git log | head`) ends quietly
  again, instead of "Broken pipe" and a failure status.
- A program that prints faster than the connection carries is slowed to the
  connection, as over plain ssh. The terminal used to be dropped ("Session
  ended") once four megabytes were waiting, and again at once after
  reconnecting. A connection that takes nothing for thirty seconds is still
  let go of, so a dead one never holds the shell. What a shell printed last
  before it ended arrives the same way; over a slow connection the end of
  `make; exit` used to be cut off after one second.
- Closing a terminal whose shell had already exited no longer reports that
  the remote process "could not be closed while offline".
- When the server no longer has a shell (it exited, or its day without anyone
  attached passed), Reconnect starts a new one instead of failing the same
  way each time. A shell that is left with `exit` says so in its pane, and
  New Terminal for that server starts a new one.
- The command that starts the host is one line run by `sh`, so it also works
  where the account's login shell is csh or tcsh.

The terminal page (Start ▸ New Terminal):

- A server's terminal page is kept when Harbor quits: its shells go on there,
  and New Terminal for that server returns to them. They used to be left
  running out of reach for a day while the quit question promised a way back.
  One on this Mac ends with Harbor, as before. What a further window holds
  comes back as a terminal window.
- Reconnecting a terminal of this page, or one in a window of its own, no
  longer takes the main window to a workspace and starts that workspace's
  editor.
- Closing one pane while another has only lost its connection keeps the page.
  It went to the start page and left the other pane running where nothing
  showed it.
- Option+Z is the shell's here and Control+` does nothing; both used to leave
  the page for an editor. Control+` no longer opens a new tab either.
- Command+W, D and T go by the letter on the key, as the menu's shortcuts do,
  so they are right on AZERTY and Dvorak. So do Command+comma,
  Shift+Command+N and Shift+Command+H wherever they are pressed.
- A burst of output can no longer end a remote terminal: the transport waits
  when the terminal is not being read fast enough.

Pages and keys:

- Command+Q works when the saved terminals could not be read at launch. Quit
  was refused without a word, every time, and Harbor could only be force-quit.
  If saving fails now, Harbor says so and asks.
- On the start page, Reverse Proxy and Remote Display, Command+H hides Harbor
  as in any Mac application, and Command+D and Control+Shift+` start nothing.
  They used to start the selected server's editor in the background, with a
  connection to it.
- Opening a recent folder opens the folder. A terminal of Harbor's own was
  started with it that no page shows: quitting asked about it, Close Folder
  counted it, and Remove Server refused because of it.
- Removing a server, or a folder from the library, leaves the window on the
  page it is on. Editing a server does too.
- A server's Remote Display (right click) leads back to the start page, and
  no longer puts one of the server's folders into the window.
- Command+Option+O away from a workspace is the start page's row: a folder on
  this Mac in the system's panel.
- From a terminal window, Command+T adds a tab to that window and the other
  commands act on the window the terminal belongs to.
- The shortcut recorder refuses keys other commands have (Command+O,
  Shift+Command+N, Shift+Command+D and others).

Windows:

- A further window asks before it closes with unsaved changes or running
  terminals in it (one that has only lost its connection to a server still
  runs there, and counts); shells it has on servers end with it instead of
  running on unseen. The first window keeps what it has, as before.
- A terminal window belongs to the application: it stays when the window it
  was opened from is closed.
- Servers are every window's. A server cannot be removed while another window
  has a terminal or unsaved changes on it; when it is removed, a window that
  was on one of its folders goes to its start page. An edited server's new
  settings reach the folders that are open on it, in every window, for
  whatever connects next (they kept the old address until a restart), and a
  split or a new tab of a terminal that was opened before the edit.
- A folder moved to a new window, or a planned window, opens when the first
  window had been closed. The new window used to come up on its old page.
- A folder is one window's editor: when the window that showed it first goes
  to another folder, the window showing it now takes it over, and a window
  with unsaved changes in it keeps it, also after they are saved. It stays
  its window's while that window looks at Reverse Proxy or Remote Display.

The editor on a server:

- An editor that is busy or still starting is waited for. A second one used
  to be started beside it, taking its record, port and password, and leaving
  the first, with its terminals, out of reach. After a start that timed out,
  the next one waits for the editor that was coming up and uses it, or ends
  it first if it still does not answer.
- The editor is asked directly whether it runs, whatever proxy the server's
  environment names; through one, a running editor looked as if it were down.
- After the editor's extensions restart (an update, "Restart Extensions"),
  Harbor finds its command service again and tells it what the one before
  knew. Unsaved files and terminals were no longer known until the folder was
  opened again.
- Two windows that both need the editor package no longer build it at the
  same time; one could record the other's half-written package, which every
  server then refused for good. A package that does not match its note is
  built again.
- An alias with LocalForward or RemoteForward lines no longer has them
  requested (and later cancelled) along with the editor's own forward; where
  one of them could not be bound the editor did not open.
- A folder with `+` in its path opens that folder. An editor that is hidden
  while its package is still on its way is left to finish. The notice that
  the editor's renderer stopped stays until Reconnect is pressed. A folder
  holding a file name that is not UTF-8 can be browsed. A folder's own
  setting is not taken for a new preference. The command token is no longer
  in the environment of every terminal. Waiting for another window's start
  says so instead of timing out.

Reverse proxy (runtime 20, takes effect the next time a mode is chosen):

- Many connections at once no longer end a relay of the gateway shaper for
  good; its limit of open files is raised.
- The Mac's own loopback is not reachable through the tunnel by address
  (127.0.0.0/8, ::1, localhost), except the health endpoint the tunnel needs.
  The listener on a server has no password and the servers are shared.
- A tunnel that has been up for days reads as up after its log is trimmed
  (it read as "connecting", and a mode switch waited 150 s for it). The wait
  between failed reconnects grows as intended. A bridge whose ssh session is
  gone exits. Stop only signals a process that is the bridge. Setting up the
  servers twice changes `.bashrc` once.

Also: Remote Display refuses an alias that configures forwarding, as
forwarding rules do, and Stop for a simulation waits for the whole job, not
only its launch script. README describes the application as it is.

## 0.33.3 — 2026-10-05 (build 73)

- Pasting into the editor's terminal works for text copied anywhere. It used
  to end in "Unable to read from the browser's clipboard. Please make sure you
  have granted access for this website…" whenever the text came from another
  application: a web page may read the clipboard only with a permission that
  an embedded view has no way to give, and the terminal pastes by reading it.
  The editor is Harbor's own page, not a website, so its reading and writing
  of text now go through Harbor to the Mac's pasteboard, as in a desktop
  editor. The same goes for Paste in a context menu and for an extension that
  reads the clipboard. Only the editor's top frame on its own address is
  answered.

## 0.33.2 — 2026-10-05 (build 72)

- The terminal page (Start ▸ New Terminal) has a terminal's keys. It was one
  terminal and nothing could be done with it; now Command+D splits it to the
  right and Shift+Command+D below, Command+T adds a tab, Option+Command with
  an arrow goes to the pane before or after, Shift+Command+[ and ] to the tab
  before or after, and Command+W closes the pane in use (asking first while
  its shell runs). A new pane or tab starts in the directory of the one it
  came from, and has the keyboard at once.
- The same three actions are buttons at the trailing end of the page's bar
  (new terminal, split right, split down), and the keys are listed under
  Settings ▸ Shortcuts. A pane has a title only beside another pane and the
  row of tabs appears only with a second tab, so one terminal still fills the
  window with nothing around it.

## 0.33.1 — 2026-10-05 (build 71)

- One notice when the editor loses its server, not two. The editor says so
  itself and keeps trying ("Attempting to reconnect…", with Reconnect Now and
  Reload Window); Harbor showed a second notice at the top right for the same
  thing, with a Reconnect button of its own. That one is gone, also for a
  command that could not be sent while the connection was down.
- Harbor puts the connection back instead. The page loads through port
  forwards of the server's shared ssh connection; when that connection has
  died (a path silent for over a minute ends it), the forwards are put back on
  the same local ports, so the editor's next attempt gets through and nothing
  is loaded again.
- Reload Window is a connection from the start: from the reconnect dialog,
  after installing an extension, or from the Command Palette. A page that only
  loaded again came up with a new extension host whose command service Harbor
  did not know, and Harbor's shortcuts went unanswered until its own Reconnect
  was clicked.
- Uploads and downloads to the A100 and RTX 4090 are no longer held to a few
  KB/s while the path carries hundreds (reverse-proxy runtime v18). The pacers
  keep a 0.4 s queue target only while Codex or Claude traffic used either
  tunnel in the last 30 s; with only bulk on the path they allow 1.5 s and ramp four
  times faster, and a single late probe (aTrust's own jitter) no longer cuts
  the rate. `/status` shows the mode. Details in `docs/reverse-proxy-tuning.md`.
- Programs on the A100 and RTX 4090 that were already running keep their
  connection after the tunnel has been unresponsive for a while (reverse-proxy
  runtime v19). The bridge came back on a fallback port (11083 → 11084) when
  nothing had connected during the outage, because its closed listener still
  held the port, and everything started with the old port in its environment
  was cut off until restarted. It closes the listener for good now and comes
  back on the port it had.

## 0.33.0 — 2026-10-05 (build 70)

- The old shell is gone. Reverse Proxy and Remote Display used to open inside
  Harbor's earlier interface, a sidebar of servers under a toolbar, and so did
  every entry of the "Harbor" view in the editor's sidebar that led to them.
  They are pages that fill the window now, under one slim bar like the
  editor's and the terminal's: the page's name in the middle and, at the
  leading end, the way back to where the page was opened from (the folder's
  name from the editor, Start from the start page). The Reverse Proxy page is
  one column, as the start page is.
- The editor's sidebar has no "Harbor" view any more. What it listed is in the
  bar above the editor (shown while the pointer is on it): the server and the
  folder with their menus, and a new "…" menu with Reverse Proxy, Remote
  Display, Folders in Windows…, Switch Folder…, Resume Previous Session… (while
  the server has such sessions) and Close Folder. The same are commands in the
  Command Palette under "Harbor:", and Remote Display joins Reverse Proxy in
  the Connection menu.
- Servers are put in order on the start page: drag one above or below another
  (this was done in the old sidebar).
- "Unable to watch for file changes" no longer comes up for a project with
  environments and caches in it. The file watcher needs one inotify watch per
  folder, and a server allows an account a fixed number (65,536 on most of
  these, shared across a shared account); rl_pt_analyze alone had about
  40,600 folders to watch and sonic2msk about 61,700. Environments, installed packages and
  caches (`.venvs`, `.cache`, `site-packages`, `node_modules`, `.conda`,
  `.tox`, `.ipynb_checkpoints`, `.eggs`, `.omc`, with the ones left out
  before) are not watched now, which brings those two to about 8,800 and
  4,000.
  Existing profiles get the missing entries added once; what was set in
  Settings is kept. Folders you work in (`runs`, `results`, `data`) stay
  watched.

## 0.32.7 — 2026-10-04 (build 69)

- Opening Harbor is not making a workspace. Folders in Windows no longer shows
  an empty "Harbor" column for a window that keeps no folder and has no name:
  it opens with the library and New Window, and nothing else. When it closes,
  the first window planned there is the window you are in (not a second one
  beside an empty first), and the others open as tabs beside it.
- Every closed window is brought back the same way. Reopening one under Recent
  Windows takes it out of that list and adds it as a column at the end, with
  its name and folders; taking the column away puts it back. The first one
  reopened used to vanish from the list and fill the empty "Harbor" column in
  place, which looked as if nothing had appeared on the right.
- A column that is added while the columns no longer fit comes fully into
  view, with New Window after it (it used to stop one column short).
- Folders in Windows leads the start page: a card of its own at the top of the
  left column, under Windows, with its shortcut, and no longer a row under
  More. Under it are the last three closed windows; a click opens one again at
  once with its folders.

## 0.32.6 — 2026-10-04 (build 68)

- The title in a window's bar reads "name · server · folder" when the window
  has a name of its own (it used to show the name alone): the name leads, a
  little larger and firmer, and the server and folder follow in the bar's quiet
  tone. Without a name it is "server · folder" as before. The opening page
  shows the same title large, and it travels into the bar for a named window
  too. The plain terminal page's bar reads the same way.
- The dots between the parts are small round ones at the middle of the
  letters' height, with the same room on either side, in place of the
  typeface's thin low "·".

## 0.32.5 — 2026-10-04 (build 67)

- Harbor starts without a workspace. Its first window used to come back with
  the name and the folders it had the last time; now it starts empty and
  unnamed, and what it kept is listed under Recent Windows in Folders in
  Windows, under its name. Brought back from there while the window is still
  empty, it is that window again (not a second one beside an empty first) and
  comes up on its first folder when the organizer closes.
- On the start page a doll that is carried, clicked or hopping is in front of
  the cards, and is no longer cut off where it rises over its card's edge. It
  can be carried up to the top of the scene (it stopped a third of the way).
  Only while it first drops in does it come from behind its card.

## 0.32.4 — 2026-10-04 (build 66)

- The start page's scene with the dolls takes about a quarter of the main
  thread it took (measured: 1.2–1.4 s of every 3 s before, about 0.35 s now),
  and looks the same. It is drawn in sheets: the dolls every frame, the glow
  on the cards' lines a few times a second, and the cards with their text
  once, after they have settled. And a frame is drawn straight into a picture
  for a layer of its own, instead of taking the whole page through an update
  sixty times a second. A test holds the sheets, laid over one another, to
  the scene drawn in one pass, pixel for pixel; while a doll is carried the
  scene is one pass again, as it passes in front of one card and behind the
  next.
- Shift+Command+H goes to the start page with the editor in front too. There
  the key reached the editor first, which opened Replace in Files.

## 0.32.3 — 2026-10-04 (build 65)

- Scrolling the library in Folders in Windows no longer stutters. Three things
  took the main thread away from it, each only some of the time:
  - On the start page the scene with the dolls kept drawing sixty times a
    second underneath (about 7 ms of every 16). It now holds still while the
    organizer or Settings lies over the page, and runs on from where it was.
  - Over an editor, AppKit worked out again on every frame which views lie
    under the window's title row, by going through all of them (about 2 ms a
    frame). The window is not movable while the organizer covers it, which
    leaves that out; and the page underneath no longer takes part in what is
    gone through for the pointer.
  - The panel's shadow was cast by everything in it and so worked out again
    whenever a list inside moved. It is the panel's shape's alone now (the
    Option+Tab list's as well).
- In the organizer a folder's menu button appears once the pointer rests on
  the row (a right click opens the same menu at any time), and rows passing
  under a pointer at rest while the list scrolls are not each lit up.

## 0.32.2 — 2026-10-04 (build 64)

- Harbor's windows are tabs of one window by default. Done in Folders in
  Windows gathers the windows that are apart into the window it was clicked
  in, and a window planned there opens as a new tab beside them, in front.
  Command+1…9 switches between them as before, and the tab bar stays put away
  until the pointer goes up to it, so no window gives up a row.
- A window can stand on its own: Window ▸ Keep Window Separate, or Keep as a
  Separate Window in the menu of its column in the organizer (which also has
  Rename now). It is marked "Separate" there and is not gathered again until
  that is switched off.

## 0.32.1 — 2026-10-04 (build 63)

- Folders in Windows keeps its columns centered as one group. The library is
  no longer pinned to the left edge: with two or three columns they sit in the
  middle, and when New Window adds one, it fades in while the columns that are
  there move apart to make room, at one pace. Taking a planned window away
  runs the same motion backwards. Only when the columns no longer fit do the
  windows scroll beside the library.

## 0.32.0 — 2026-10-04 (build 62)

- A window is a workspace, and Option+Tab switches between its folders. The
  list is one column now: the folders this window keeps, on whichever servers
  they are, the one on screen first and then the most recently shown. Typing
  finds any other folder, under "Not in this window". A window that keeps no
  folder yet lists the library and waits for Return. Option+Q is no longer
  taken by Harbor (it used to step through a server's folders).
- Folders in Windows is rebuilt around a library. On the left every server
  opens out to the folders that were opened on it, each saying which window it
  is in; beside it every window is a column with the folders it keeps. A
  folder is dragged from the library into a window, and back to leave it. The
  "Not in a window" column is gone: that is the library.
- New Window adds a column for a window that does not exist yet. It fades in,
  takes a name, and is filled from the library like any other; the window
  opens when the organizer closes, on its first folder and keeping the rest.
- A folder is added to the library without opening it: the plus beside a
  server opens the folder browser, which lists what the path typed so far
  leads to and has a button for the home directory.
- A further window that is closed with folders in it is kept under Recent
  Windows in the library, and a click plans it again with those folders.
- Fixed: the first folder opened on a server in one window was missing from
  the other windows' lists until they were restarted.

## 0.31.4 — 2026-10-04 (build 61)

- Switching in a window starts on what the window already has open. A server
  comes up on a folder with an editor running there, else on one the window
  keeps, and only then on the folder chosen last anywhere: from Option+Tab,
  the sidebar and the start page alike. Before, it came up on the last folder
  chosen, open or not, and a step too many opened a folder nobody asked for.
- The Option+Tab list follows the same order. Folders are listed under "Open
  in this window" first (running, then kept; the one shown last leads), and
  the rest under "Not open". Among a window's servers, those with an editor
  running come before those it only keeps a folder of.

## 0.31.3 — 2026-10-04 (build 60)

- The tab bar is put away. With several windows gathered as tabs it took a row
  of every window all the time. In full screen it now comes down with the menu
  bar when the pointer goes to the top of the screen; in a window it appears
  while the pointer is in the title row or on the bar itself. It lies over the
  page for that moment, so nothing underneath is laid out again. Window ▸
  Always Show Tab Bar brings back the old behavior.
- "‹ Start" is at the leading end of the bar on every page with an editor, as
  it is on the terminal page, and is always there. The server and folder menus
  beside it still come with the pointer.
- A folder that is opening can be stopped: Stop on the opening page, or Esc.
  The window goes back to the folder it showed before (or its start page) and
  no longer keeps the folder.
- Folders in Windows is an editor. In each window's column every server opens
  out to the folders that were opened on it, each with a tick for "kept in
  this window", and folds away again. A folder's menu also stops it while it
  is opening and closes it for good (out of Harbor's list; files on disk
  stay). A window is renamed with the pencil beside its name.

## 0.31.2 — 2026-10-03 (build 59)

- Folders in Windows. Each window keeps its own folders, and which folder is
  in which window is now yours to arrange. A folder joins the window it is
  opened in. The organizer (Window ▸ Folders in Windows…, Shift+Option+Command+W;
  also at the foot of the Option+Tab list, in the folder menu of the bar and
  under More on the start page) shows every window as a column of its
  folders: drag a folder to another window, to New Window, or to "Not in a
  window", or use a folder's menu. A folder is in one window at a time; moving
  it closes its editor in the window it leaves (files and running terminals
  are untouched) and is refused while that editor has unsaved changes. The
  first window's folders are remembered between launches.
- Option+Tab follows that: THIS WINDOW lists the servers that have a folder
  kept in this window, whether or not its editor is running, with this
  window's folders first. A folder another window keeps says "in" and that
  window's name, and choosing it moves it here.
- Option+Tab and Option+Q no longer type into the terminal. The key monitor
  gave back every key the switcher had taken, so the list moved and the
  terminal also received the "œ" of Option+Q or the tab; whatever was typed
  to filter the open list went to the terminal as well.
- The Option+Tab list shows its selection and its dots correctly. A server
  that had changed section since the list was last shown (opened, or the
  current one) kept the look it had then: no highlight when selected, no dot.
  The list is now built anew each time it is shown.

## 0.31.1 — 2026-10-03 (build 58)

- Switching between two open folders or servers no longer flashes. Each
  folder's editor is a web view of its own, and one that is put into the
  window needs a moment to draw itself; for that moment the window was blank
  (white, in the light theme), so every switch was a flash and a hard cut. The
  editor that is leaving now stays until the one arriving has drawn, and then
  fades into it. The title in the bar changes the same way. Coming back from
  the start page, the editor fades in; going to a folder that still has to
  open, the editor fades into the opening page.
- Two new built-in dolls on the start page, drawn in code from the pictures
  given for them: Grok is a grey plush rocket with satin fins and red soles,
  Gemini a fluffy blue-to-rainbow monster with a spark in its eyes and a party
  popper in each hand. They follow the pointer, blink, wave and can be picked
  up like the others.

## 0.31.0 — 2026-10-03 (build 57)

- The start page opens from the top down: the name, the line under it, the
  agents, then the two columns row by row. The agents' scene is already under
  way when the columns arrive; before, the lists were there first and the
  scene began afterwards. The layout is unchanged.
- There is no "Loading local data" screen at launch. The start page is on
  screen at once and its lists take their turn when the saved data has been
  read (a tenth of a second). Only a read that takes longer than a second and
  a half says so, in one line at the bottom.
- Start page ▸ New Terminal is one terminal and nothing else: Harbor's own
  terminal fills the window, with a slim bar that names it and leads back to
  the start page. No editor is started for it, so the prompt is there as fast
  as the shell is, and it asks nothing about trusting a folder. `exit` returns
  to the start page. A server's New Terminal is the same on that server. It
  adds nothing to the recent folders.
- Opening a folder shows its server and its name ("4Rtx4090 · Grail") instead
  of "Files & Code". When the editor is ready the page fades away over it and
  the title travels up into the window's bar, shrinking as it goes, and stays
  there: one movement, with no second screen to cut to. The bar's title now
  includes the server. A window with a name of its own keeps that name in the
  bar and the title simply fades.
- Waiting is shown as one thin line that fills from nothing to all of it;
  nothing spins. While an editor opens, the line is paced by how long that
  server took the last time, so it is full about when the editor is there,
  and while the editor itself is being sent it follows the bytes. The editor
  is also noticed sooner once it is up (it was looked for once a second).
- The Dock menu has New Window, which also works with no window open.
- A folder dropped on the Dock icon, or opened with Harbor in Finder, opens:
  in the window that already shows it, else in a window that is on its start
  page, else in a new window, which names the folder from its first frame.
  Started this way, Harbor goes straight to the folder. A folder dropped on
  the start page opens there. Dropped on an editor it opens in that window,
  and dropped on the editor's terminal its path is typed, quoted, as Terminal
  does.
- This Mac is listed under its host name (for example "Felix-Pro") wherever
  it was called "Local".
- Option+Tab remembers across restarts. The order of the servers and the
  folder each one comes up on were kept only while Harbor ran, so after every
  restart, and in every new window, the list was back in sidebar order with
  each server on its first folder. The order is now saved, and a server comes
  up on the folder that was chosen there last.

## 0.30.8 — 2026-10-03 (build 55)

- The standard app now includes the approved start-page dolls: the orange
  Claude plush in a brown cowboy hat and the blue terminal-faced Codex robot,
  alongside Grok's black cat and Gemini's striped flag bearer.
- All four dolls follow the pointer, greet on hover, bounce with particles on
  click, and can be dragged and released back home. They stay on the quay
  after their entrance. Custom doll pictures use the same interactions.
- Background windows show the settled scene immediately. Reduced motion
  keeps feedback static. The designs and interaction tests are part of the
  standard source history so subsequent releases retain them.

## 0.30.7 — 2026-10-03 (build 54)

- The Option+Tab panel groups servers by window. THIS WINDOW lists the servers
  this window has open, each with a lit dot; OTHER WINDOWS lists what the
  other windows have open, with a ring and the window's name; NOT OPEN is the
  rest. A new window starts with nothing under THIS WINDOW, and the panel
  follows the other windows while it is up.
- The dot beside a server on the start page is accurate and the same in every
  window. It said "connected" only for servers the first window had opened a
  terminal on, so a server in use by an editor, or opened in a second window,
  showed nothing. It now asks the control sockets on this Mac (the shared one
  and the editor's own), every 20 seconds while Harbor is in front and right
  after an editor starts or stops. Nothing is kept running for this and the
  network is not touched; a server without a socket costs nothing. A
  connection that ssh keeps open after its last use (ControlPersist) counts
  as connected, because it is.
- Launching Harbor no longer connects to the first server. Launch chose a
  workspace before settling on the start page, and showing the editor for
  that moment started it: an editor left running on that server after every
  launch, and its dot always lit.

## 0.30.6 — 2026-10-03 (build 53)

- Start page ▸ New Terminal (and Command+T there) opens a terminal. It used to
  add one to a workbench that was not on screen, so nothing happened. It now
  shows this Mac's home directory as terminals only, with the editor and the
  sidebar put away; asking again returns there with one more terminal. A
  server's New Terminal does the same in its login directory. The first time,
  the editor asks whether to trust that folder, as it does for any folder.
- A Harbor that keeps running through an update is still called Harbor. The
  installer moved the previous bundle aside as ".HarborSSH-previous-…", and
  the system then asked for folder access under that name. The previous
  bundle now keeps its name inside a folder "Harbor previous version …" in
  the Trash.

## 0.30.5 — 2026-10-03 (build 52)

- A new icon: a clay sun rising over a calm harbor, in the application's own
  warm colors. The prompt is in the sun and its reflection on the water is a
  few lines, the way code looks from a distance. At 16 and 32 pixels it is
  drawn with fewer, heavier shapes.

## 0.30.4 — 2026-10-03 (build 51)

- With two windows gathered as tabs, the bar that switches server and folder is
  visible again. The content reaches the top of the window and the system put
  the tab bar over it: in full screen, where new windows become tabs, exactly
  over that bar. The tab bar now has a row of its own, under the title row in
  a window and above Harbor's bar in full screen.
- Windows have names. A window is called after its server and folder
  ("2A6000 · light-mskmodel") instead of "Harbor", in its tab, the Window menu
  and Mission Control. Window ▸ Rename Window…, a double click on the tab or a
  right click on Harbor's bar gives it a name of its own; a blank name goes
  back to the server and folder.
- Switching servers in one window no longer brings another window forward.
  Option+Tab and the server menu used to go to the folder any window chose
  last on that server, and when another window was showing it, switched to
  that window. Each window now has its own order of servers and its own folder
  on each; a folder another window is showing is never the one a server comes
  up on, and chosen anyway it opens in place as a notice with Show That Window.

## 0.30.3 — 2026-10-03 (build 50)

- The editor installs on a server whose home directory is a symbolic link
  (the RTX 4090: `/home/…` points to `/data/…/home`). The archive was checked
  against the unresolved path, so every file in it looked as if it left the
  directory: "Unsafe path in editor archive."
- Two windows opening the same server no longer send the editor package into
  the same file. The mixture had the right size and the wrong content, the
  server then downloaded the full 228 MB release itself (2.5 hours on that
  path), and that is what ran into the error above. Now one upload writes at a
  time and the other window waits for it; an upload continues only from bytes
  that are this package's own (checked by SHA-256, not by length); a package
  that arrived whole and does not verify is sent once more before the server
  downloads anything.
- A complete official release that an earlier attempt left on the server is
  verified and used instead of being downloaded again.

## 0.30.2 — 2026-10-03 (build 49)

- Updates clean up after themselves. Once a new version's editor runs on a
  machine, Harbor removes what earlier versions left there: the previous
  runtime (about 360 MB on every server), this Mac's profile copies for it and
  for the layout before revisions (a day later), earlier versions of Harbor's
  own extensions, and directories an interrupted install left. Nothing is
  removed that an editor still runs from (terminals can outlive an update),
  that another Mac's Harbor used in the last 30 days, or that belongs to
  another client's profile.
- Trimmed editor packages of earlier releases are swept from the Mac's cache.
- Development: a test run no longer leaves dozens of files in
  `~/Library/Preferences`.

## 0.30.1 — 2026-10-03 (build 48)

- Command+, opens the Settings panel at once. With the editor focused the key
  used to reach Code-OSS first, which loaded and showed its own Settings editor
  (about 0.6 s) before the panel replaced it, after a round trip to the server.
  The key is now Harbor's before the page sees it.
- Opened any other way (Command Palette, an extension's gear), the editor's own
  Settings editor is never drawn: the page holds it back, Harbor shows the
  panel immediately and takes over the filter (`@ext:publisher.name`), and the
  editor closes it without waiting for the server.
- Opening Settings no longer reads the catalog or looks at every installed font
  on the first use (both are prepared in the background after launch), the
  panel's shadow is no longer recast whenever anything inside it changes, and
  typing in the search box updates the list when typing pauses.
- Shift+Command+N with the editor focused opens a Harbor window. It used to
  reach Code-OSS, whose New Window sent the browser to the server's sign-in page.
- Command+1 … Command+9 switch between Harbor windows gathered as tabs of one
  (9 is the last tab). With a single window the keys keep their other meanings.

## 0.30.0 — 2026-10-03 (build 47)

- Settings are one panel inside the workbench window instead of a window of
  their own and a second Settings editor inside Code-OSS. Command+, (or the
  gear) opens it over the window it was asked for in; Esc, the close button or
  a click outside leaves it, and a button makes it fill the window.
- Every setting of the editor and of the extensions on a server is in that
  panel, under the Harbor pages: the editor's own categories (Commonly Used,
  Text Editor, Workbench, Window, Chat, Features, Application, Security,
  Extensions), a search box over all of them, User and Workspace scopes, a
  marker and a filter for what you changed, and Reset / Copy Setting ID per
  setting. Checkboxes, menus, numbers, text and lists are edited in place;
  objects open at the right line of `settings.json`, which the panel's JSON
  button also opens. Harbor ships the catalog of its Code-OSS build (1,600
  settings), so opening the panel on a slow server reads only that server's
  values and the settings of extensions installed there.
- Code-OSS's own Settings editor now gives way to the panel wherever it is
  opened from (menus, Command Palette, an extension's gear, the button in
  `settings.json`).
- Auto save on the Editor page shows what editors actually do until you choose
  (After a delay), and terminal scrollback is applied to every editor again.
  The Editor interface zoom control is gone: this editor build has no such
  setting, so it never took effect, and one failed write could keep the options
  after it from being applied.

## 0.29.1 — 2026-10-02 (build 46)

- Fix Option+Q (and Option+Tab) doing nothing between exactly two folders: a key
  press that reached the switcher twice stepped twice and landed back where it
  started. A press is now acted on once, a held key no longer repeats, the
  window the key was pressed in decides which folder is current, and on the
  start page the first press chooses the most recent entry instead of skipping it.
- Fix full-width punctuation typed with Shift in pinyin ("？", "：", "！") needing
  two presses in the terminal. The input method inserts such text before the
  key is reported, and xterm.js ignored it while Shift was down.

## 0.29.0 — 2026-10-02 (build 45)

- One Settings window. Appearance, Editor, Terminal, Workbench, Shortcuts and
  Advanced pages hold Harbor's preferences and the editor and terminal options
  people change most (fonts, cursors, wrapping, line numbers, minimap, scrollback
  and more). They apply to every window and every server's editor, and the
  preview on the right shows theme, fonts, cursor style and blinking, and the
  terminal before anything else changes. What an editor was already customized
  to is adopted once; other editor and extension settings open from Advanced.
- Servers no longer download the editor. The Mac fetches the release once,
  checks it, leaves out the built-in assistant's payloads (218 MB becomes 66 MB)
  and sends it over the open ssh connection, paced on a managed tunnel and
  resumed after an interruption. A server asks GitHub only if the Mac cannot.
- Opening a folder on a server no longer loads the editor's own program
  (6 MB compressed) over the link: a local proxy answers those files from this
  Mac's copy of the same build. Harbor's extensions are sent once per version
  instead of with every connection.
- Fix connecting after an interrupted first contact: a cut-off upload of the
  service script was installed as an empty file and then run forever. The
  script now carries an end mark and is installed and run only when complete.
- Fix the terminal sending pinyin twice when the input source is switched while
  composing (typing "ls" gave "l sl s"); the unconverted letters are also sent
  without the syllable spaces.
- Option+Tab steps through servers and Option+Q through the folders of the
  selected server, in a two-column panel.
- Explorer files and folders can be dropped on a terminal to type their paths.
- The Claude theme is the default and uses its clay accent for what is chosen
  or acted on: primary buttons, the selected row, the active view, the current
  line number, a divider being dragged. Standard themes remain in Settings.
- The start page's agents are four dolls (orange, blue, black, striped), drawn
  by Harbor; a picture of your own can stand in for any of them.
- A folder that contains Harbor's own files (the home directory) explains the
  editor's Restricted Mode instead of timing out; Settings ▸ Workbench can turn
  the trust question off.

## 0.28.0 — 2026-10-02 (build 44)

- Make Code-OSS the only editor. Remove the lightweight editor, its explorer,
  previews, transfer UI and bundled CodeMirror; folders, servers and windows stay
  native. Files dropped on Harbor or chosen with Open File open in the editor.
- Resume the first Code-OSS download instead of restarting it. The archive is
  about 230 MB; over a slow tunnel the old 15-minute limit ended every attempt
  and threw the bytes away, so the editor never opened. The part is now kept in
  `code-oss/archives/`, the limit is five minutes of silence rather than total
  time, and the start screen shows size, rate and time left. A verified archive
  copied to `archives/code-server-<version>-<platform>.tar.gz` is used as is.
- Always launch on the start page; restored terminals keep running behind it.
  The editor's loading and error screens offer a way back to the start page.
- Add a start page (Open Folder, Open File, recent folders, servers) with a Canvas
  scene of four command-line agents and their paper boats.
- Open several workbench windows (Shift+Command+N), each with its own server and
  folder. One folder is shown by one window at a time.
- Add Option+Tab to switch between servers and folder workspaces, with filtering.
- Replace the Anthropic theme with new Anthropic Light and Anthropic Dark palettes,
  generated from tokens with contrast checks. Appearance is now a theme and a mode.
- Add a native Settings window with a live preview, hover-to-preview themes, and a
  motion setting (Full, Subtle, Off) shared by native pages and the editor.
- Pin a fixed number of views above the sidebar (default four) with the rest behind
  an arrow. The sidebar cannot be dragged narrower than that row or dragged shut.
- Narrow the terminal's scrollbar rail from 14 to 6 points.
- Drag a folder from Explorer onto the editor to open it as a workspace (Option:
  in a new window).
- Hold extension panels at their width while a divider is dragged.
- Turn the built-in assistant surfaces and AI inline suggestions off once per
  profile; remove the bundled assistant extension and unused built-ins from the
  private runtime. Typed completion is unchanged.
- Push unsaved-file and terminal changes from the extension host instead of polling
  every two seconds; cache the service script on servers instead of resending it.

## 0.27.0 — 2026-10-02 (build 43)

- Use the real Code-OSS Terminal for shells, tasks, extensions, splits, search and
  reconnectable PTYs. Remove the native terminal overlay and restore the genuine
  workbench status bar. Previous Harbor sessions remain available through an
  explicit, attach-only recovery action.
- Show compact server/folder controls on title-bar hover without resizing the
  workbench. Keep folder creation adjacent to the selector and use small layout
  buttons. Sidebar and panel actions use a brief local transition.
- Coalesce Markdown preview scrolling to the latest frame without waiting for
  remote images. Stop scanning editor DOM mutations for native overlay geometry.
- Isolate patched runtimes and editor profiles by revision, preserving settings,
  backups and extensions without changing an older running editor.
- Preserve disconnected terminal processes for the seven-day reconnect window;
  switching workspaces no longer shortens their grace period to five minutes.
  Idle cleanup will not stop services with live terminal processes.
- Sanitize legacy terminal replay queries without filtering live output, and
  serialize panel changes so rapid toggles await the final requested layout.
- Migrate older editor profiles away from floating panels, extra panel margins
  and shadows once, while preserving themes and subsequent layout customizations.

## 0.26.1 — 2026-10-02 (build 42)

- Unify Files & Code into one workbench without a separate server toolbar.
  Center activity icons above the sidebar with an overflow dropdown, and remove
  Explorer's redundant title row while reclaiming its layout space.
- Put server and directory switching, Open Folder, Close Folder and Settings in
  the collapsible Harbor section alongside forwarding, remote display and recents.
- Show one native Terminal panel by default beneath the editor column. Keep
  Problems, Output, Debug Console and Ports; show Tasks only when a plugin or task
  creates its own Code-OSS terminal.
- Keep the editor web view and existing native terminal sessions when Option+Z
  switches to Terminal Mode, with terminal workspace tabs across the top.
- Run Option+X panel sizing and Command+B sidebar changes locally without SSH
  round trips. Use a brief transition fade that respects Reduce Motion.
- Keep Command+D/Command+H as split-right/split-down in native terminals, while
  Command+D selects the next match in the editor. Route ordinary new/split terminal
  actions to Harbor without replacing plugin and task terminal APIs.
- Open one Code-OSS Settings editor with Command+, or Harbor → Settings, including
  Harbor appearance and native terminal preferences. Preserve existing editor
  customizations and project-specific overrides during settings synchronization.

## 0.26.0 — 2026-10-02

- Add an on-demand Code-OSS workbench with real Open VSX extension installation,
  language services, editor groups, project search, and persistent editor state.
  Remote editors use private loopback services through existing SSH connections.
- Keep Harbor's terminals, directory workspaces, and session recovery. Idle clean
  editors release their web view; services expire after clients disconnect.
- Put activity icons above Explorer and integrate servers/forwarding in its
  collapsible Harbor section. Use one settings entry and keep the terminal under
  the editor column, with full-height Explorer and synchronized resize controls.
- Fix Chinese IME commits, input-source switching and consumed key releases in
  native terminals, including Kitty keyboard mode used by interactive CLIs.
- Preserve pasted text in Kitty keyboard mode whether bracketed paste is enabled
  or disabled; legitimate repeated text remains unchanged.
- Add the Anthropic Warm Paper theme across the app, editor, and terminal.
- Use single visual dividers with wider drag targets; persist pane sizes only
  after dragging ends. Fix file-load focus races and editor shortcut conflicts.
- Enlarge Find/Replace and strengthen search highlights. Keep the lightweight
  editor available for native previews, screenshot drops, and smaller machines.

## 0.25.1 — 2026-09-29

- Play and seek videos and audio embedded in local or remote HTML reports.
  Serve byte ranges and metadata requests instead of reading each video as a
  single attachment; media is no longer subject to the 25 MB asset limit.
- Read remote media in bounded chunks, cancel loads when a preview closes or
  changes, and reject changed files and resources outside the workspace.

## 0.25.0 — 2026-09-29

- Preview local and remote HTML/HTM files in the file workspace, including
  relative images, stylesheets, JavaScript modules, and data loaded with fetch.
- Switch between the webpage and editable HTML source, find text, save changes,
  and reload linked resources. Preview reports up to 25 MB; UTF-8 source editing
  remains limited to 2 MB.
- Isolate HTML pages from the editor's native bridge, restrict linked file reads
  to the workspace, bound concurrent resource loads, and release hidden previews.

## 0.24.2 — 2026-09-23

- Fix an intermittent application crash when background connection checks finish:
  process output is now read and closed by a single owner, without pending
  FileHandle callbacks racing the pipe shutdown.
- Keep draining output during timeout cleanup, bound retained output, and avoid
  waiting for background SSH processes to close inherited output pipes.

## 0.24.1 — 2026-09-22

- Recover file browsing through a separate SSH connection when open terminals
  exhaust the shared connection's session limit; retain existing terminals.
- Silence terminal bells and prevent historical terminal queries from injecting
  replies into Claude/Codex input during reconnection.
- Restore saved text to terminal scrollback, remove the saved-output banner, and
  refresh terminal geometry and rendering after reconnection or view changes.

## 0.24.0 — 2026-09-21

First public MIT release of Harbor for macOS.

- Native SSH workspaces, split terminals, persistent remote PTY sessions,
  file editing and previews, drag-and-drop, and transfer progress.
- Personal server/VPN setup removed from the public distribution. User-defined
  local, remote and SOCKS forwarding remains available.
- NVIDIA's separately licensed WebRTC implementation is an optional user
  installation, with a setup page included in the public app.
- Standalone Apple silicon app archive, checksums, source build instructions,
  third-party notices, and a macOS test/build workflow.

This release is ad-hoc signed and is not Apple notarized. See the README for
first-launch instructions and the scope of supported remote displays.
