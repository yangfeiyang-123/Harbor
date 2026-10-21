# Getting started

## Servers and folders

Use **Connection → Import from SSH Config** to import aliases from `~/.ssh/config`,
or add a connection with the server sidebar's **+** button. In the full editor,
the command palette also provides **Harbor: Add Server…**. A typical configuration
looks like this:

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
through your server administrator. Password prompts and key passphrases appear in
the terminal. A password is asked for once, in the terminal or in a
dialog when a folder is opened: Harbor keeps it in the login
keychain and gives it to ssh from the next connection (Edit Server ▸ Password
▸ Forget Password removes it). Key authentication or an existing SSH agent makes file and
port-forwarding workflows easier.

Select a server and open a directory workspace. In the editor's Explorer, expand
**Harbor → Servers** to switch servers or return to an open directory. Use
**Harbor → Open Folder…** to browse subfolders and confirm a new directory.
The compact title-bar folder selector provides the same workspace access.
**Close Folder** closes a workspace without deleting its files.

The local machine is listed under its host name (for example **Felix-Pro**). Each directory keeps its own editor
state. Files & Code uses Code-OSS through code-server by default. First use
downloads a verified runtime on the project machine; remote workspaces run their
editor service and extensions on the SSH server.

## Editor and terminal

Explorer, Search, Source Control, Run and Extensions appear above the sidebar.
Install compatible extensions through **Open VSX** or **Install from VSIX…**.
Language servers, interpreters and compilers must be available on the project
machine. See [Files & Code](code-workbench.md) for supported runtimes and extension
compatibility.

There is one built-in Code-OSS **Terminal** panel for shells, tasks and extensions.
It sits below the editor column, keeping the sidebar full height. **Option+Z**
switches to full Terminal Mode using the same terminals. Their tabs, splits and
processes are not replaced when the view changes. Splitting inherits the active
shell's current directory.

**Command+,** and **Harbor → Settings** open the same Settings editor. The **Harbor**
section controls app appearance and the editor choice; **Terminal › Integrated**
controls terminal profiles, font size, scrollback and other terminal preferences.

## Useful shortcuts

These shortcuts describe the default Code-OSS editor. Terminal-specific actions
apply while the terminal has focus.

| Action | Shortcut |
| --- | --- |
| Switch terminal / Files & Code | Option+Z (customizable in Settings) |
| Maximize / restore the terminal panel | Option+X |
| New terminal | Control+Shift+` |
| Split active terminal | Command+D or Command+H |
| Close active terminal | Shift+Command+W |
| Copy / paste | Command+C / Command+V |
| Quick Open | Command+P |
| Search in project | Command+Shift+F |
| Command palette | Command+Shift+P |
| Save / find in file | Command+S / Command+F |
| Toggle explorer / terminal panel | Command+B / Command+J |
| Increase / decrease terminal font | Command+Plus / Command+Minus |
| Settings | Command+, |

**Command+D** in the text editor keeps its next-match selection behavior.
**Command+1…9** follows Code-OSS's editor-group bindings, rather than Harbor's
previous terminal-workspace bindings. Use terminal tab context menus or the command
palette for renaming and other terminal actions. **Preferences: Open Keyboard
Shortcuts** shows the active bindings, including extension customizations.

## Data and reconnecting

Local Harbor data lives under `~/Library/Application Support/HarborSSH/`. It
contains profiles, workspace state and lightweight-terminal recovery buffers.
Treat these as private. Native UI preferences are stored in macOS user defaults.
The `HARBOR_DATA_DIR` environment variable overrides the data directory for an
isolated development run.

Code-OSS keeps its runtime and user data under the local `CodeOSS` data folder,
or `~/.local/share/harbor/code-oss` remotely. Its PTY service keeps terminals
separate from the browser connection. Reconnecting within the seven-day window
can return to the same running process while the service and PTY host remain
alive. Idle cleanup does not stop services with live terminal processes.
Code-OSS saves editor hot-exit backups, but saving important work normally is
still necessary. Reviving a shell after restarting a service is different from
reattaching to a surviving shell.

Remote sessions created by earlier Harbor versions still use the Python PTY
helper. **Harbor → Previous Sessions** explicitly resumes a listed session inside
a built-in terminal. This moves the attachment to the current window without
restarting its remote process. Harbor does not take over these sessions
automatically. A dead session is not replaced with a new shell by this action.

## Known limits

- This is an early public release, tested on Apple silicon. It is not notarized.
- Full-editor setup and native remote file operations require Python 3 on the
  project machine. The Code-OSS runtime supports macOS/Linux on ARM64/x86-64,
  subject to the pinned runtime's library requirements. It is not a Windows
  SSH environment emulator.
- A reboot, process termination, or removal of the editor/helper's state can
  end a session. Saved output is not a guarantee that its process is still alive.
- Harbor uses your existing network and VPN routes; it does not install or
  configure a VPN. If connection fails, first check ordinary `ssh your-alias`.
- Remote displays need an already configured streaming server. WebRTC media
  needs network reachability beyond a TCP-only SSH web tunnel.
- Open VSX is not Microsoft's Marketplace. Some extensions depend on restricted
  licenses or unsupported desktop APIs. Additional language servers and debugging
  tools may need installation on the project machine. Harbor does not include
  an AI chat service.
