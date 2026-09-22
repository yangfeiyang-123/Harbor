# Getting started

## Servers and folders

Use the server sidebar's **+** button to add a connection, or import aliases from
`~/.ssh/config`. A typical configuration looks like this:

```sshconfig
Host lab
    HostName gpu.example.org
    User researcher
    IdentityFile ~/.ssh/id_ed25519

Host lab-behind-gateway
    HostName compute.internal.example.org
    User researcher
    ProxyJump lab
```

Use your own hostnames and account. Confirm unfamiliar host-key fingerprints
through your server administrator. Password prompts and key passphrases are
handled by OpenSSH. Key authentication or an existing SSH agent makes file and
port-forwarding workflows easier.

Select a server and open a terminal. The top folder selector keeps independent
directory workspaces; **+** opens the directory browser. Click subfolders, then
confirm. Files & Code keeps one terminal visible at a time with a terminal list,
while terminal mode restores the group's split layout.

The local machine is available in the sidebar too. Local folders support
**Show in Finder**; remote folders are browsed inside Harbor.

## Useful shortcuts

| Action | Shortcut |
| --- | --- |
| Switch terminal / Files & Code | Option+Z (customizable in Settings) |
| Maximize / restore the terminal panel | Option+X |
| New terminal workspace | Control+Shift+` |
| Split right / split down | Command+D / Command+H |
| Switch terminal workspaces | Command+1 … Command+9 |
| Rename a selected terminal or file | Return |
| Close a selected terminal / delete a selected file | Command+Delete |
| Copy / paste | Command+C / Command+V |
| Copy a file path | Command+Option+C |
| Quick Open | Command+P |
| Search in project | Command+Shift+F |
| Command palette | Command+Shift+P |
| Save / find in file | Command+S / Command+F |
| Toggle explorer / terminal panel | Command+B / Command+J |
| Increase / decrease terminal font | Command+Plus / Command+Minus |

Arrow keys navigate a selected terminal list; when the terminal itself has
focus, they go to the shell instead. Command-click toggles file selection and
Shift-click selects a range. Clicking the file list's blank area selects the
workspace root for New File, New Folder, and Paste.

## Transfers

Drop a local file, folder, or the macOS screenshot thumbnail onto a remote
folder. The drop highlight shows the destination. Use the context menu to
download a remote item. The status area shows transfer progress and details.
Downloads with an unknown total show transferred bytes until completion rather
than an invented percentage. Existing-file conflicts are reported.

Dragging an item onto a terminal inserts a quoted path. It does not execute a
command. Dragging a folder into the editor opens a directory workspace.

## Data and reconnecting

Local data lives under `~/Library/Application Support/HarborSSH/`; Settings can
open the data folder. It contains profiles, workspace state, and terminal
recovery buffers. Treat these as private. UI preferences are stored in macOS
user defaults. The `HARBOR_DATA_DIR` environment variable can override the data
directory for an isolated development run.

Remote sessions use a small Python helper installed through SSH. The helper
keeps the PTY separate from its network connection. Reconnecting to a surviving
session preserves its process, working directory, environment, and output.
Closing Harbor saves local layout/output and detaches remote sessions; local
shells and app-managed forwarding close. Explicitly closing a terminal ends it.

## Known limits

- This is an early public release, tested on Apple silicon. It is not notarized.
- Remote file operations and persistent terminals require Python 3 on the remote
  host. Linux is the main tested remote platform. It is not a Windows SSH client
  environment emulator.
- A reboot, process termination, or removal of the remote helper's state can
  end a session. Saved output is not a guarantee that its process is still alive.
- Harbor uses your existing network and VPN routes; it does not install or
  configure a VPN. If connection fails, first check ordinary `ssh your-alias`.
- Remote displays need an already configured streaming server. WebRTC media
  needs network reachability beyond a TCP-only SSH web tunnel.
- The code editor is CodeMirror-based, not the VS Code extension platform.
  Language servers, debugging adapters, and AI chat are not included.
