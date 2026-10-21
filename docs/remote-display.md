# Remote Display

Harbor 0.18 provides a display connection manager. Open **Remote Display** in the sidebar or the monitor button in the workbench toolbar, then **Add Remote Display**. Choose a server, simulator preset, viewer type and the address of a running display service. Save, then Connect.

Saved connections are grouped by server. Settings reopen disconnected; Harbor does not automatically start simulators, install software on servers, or consume GPU memory at launch. Removing a connection removes its Harbor configuration, not the remote simulator or files.

## Connection types

| Simulator | Display route | Requirement |
| --- | --- | --- |
| Isaac Sim / Isaac Lab | WebRTC web viewer in Chrome or Edge | Installed version's web viewer and livestream service; reachable signaling and UDP media ports |
| MuJoCo / PyBullet / Genesis | GPU-capable VNC desktop, noVNC, or a separately deployed web viewer | Run the native viewer inside the remote desktop; headless training alone has no desktop window |
| Gazebo / ROS / RViz | Gzweb frontend or VNC/noVNC desktop | Gzweb's WebSocket bridge must also be reachable; use desktop mode for the full native interface |
| Webots | Web streaming page or VNC/noVNC desktop | Enable Webots streaming and enter the complete viewer page URL |
| Other simulators / Viser | Custom Web Viewer | Existing HTTP(S) application with compatible browser graphics |

These are protocol integrations, not claims that every simulator version has been tested. Isaac Sim is deliberately opened in Chromium because its official web viewer targets Chromium; Harbor's embedded WebKit is not advertised as a compatible Isaac Sim client. Older Isaac Sim installations may require their version-specific native NVIDIA client or a separately deployed web frontend.

## SSH and addresses

For a web service listening on the remote server at `127.0.0.1:6080`, use `http://127.0.0.1:6080/vnc.html?resize=remote` and enable **Connect through SSH**. Harbor selects a local loopback port and forwards TCP to the URL's host/port as reached from the SSH server. Path, query and fragment are preserved. The viewer must use the forwarded origin for same-port WebSockets. If the application advertises other hosts or ports, configure its web proxy or make those endpoints reachable over VPN.

For native VNC, choose **Screen Sharing (VNC)** and use e.g. `vnc://127.0.0.1:5901`. Harbor keeps the SSH tunnel open while macOS Screen Sharing is used. VNC authentication is handled by Screen Sharing, not stored by Harbor.

SSH uses your configured keys/agent and aliases, with noninteractive authentication and a dedicated forwarding process. It never terminates the SSH master or other terminal connections. **Disconnect** closes only this display's tunnel/viewer. A server or VPN disconnect is reported; use Connect again to recreate the tunnel.

For HTTPS, turn SSH forwarding off and use the original VPN-reachable hostname to retain normal certificate validation. Harbor does not bypass certificate checks. Alternatively, use a loopback-only HTTP endpoint behind SSH.

Isaac Sim WebRTC media uses UDP in addition to the TCP signaling/web endpoints. Forwarding only the web page does not forward the media. Configure the advertised address for your VPN and verify both media/signaling reachability. Isaac Sim A100 livestreaming is unsupported because A100 lacks NVENC.

## Display lifecycle

Embedded web/noVNC sessions support keyboard and mouse input, reload, a separate window and full screen. Detach moves the same WKWebView without opening a second streaming client. The web renderer is released when you leave an embedded display; its tunnel stays available for returning. Detached windows remain active until closed. External browser and Screen Sharing windows are managed by those applications.

Nonpersistent browser storage and session-scoped renderers keep the app light and avoid retaining viewer credentials across app launches. Saved configuration is private (`remote-displays.json`, mode 0600). Credentials should be entered in the viewer instead of the saved URL. A corrupt configuration file is not overwritten.

## Server setup and diagnostics

**Check Server** reads the GPU names, common display executables on PATH and listening TCP ports. Conda environments and containers may contain tools not found on PATH. It does not start or kill any server process.

For an already configured VNC desktop, a standard noVNC bridge can serve it locally:

```sh
# Run from an existing noVNC checkout. Adjust the VNC port to your desktop.
./utils/novnc_proxy --vnc localhost:5901 --listen localhost:6080
```

The display desktop must have working graphics support. Installing VNC alone does not guarantee Vulkan/OpenGL rendering, and Isaac Sim should normally use its native streaming path.

## Earlier remote-display validation (0.19)

- Private persistence, URL/protocol validation and loopback-only forwarding tests.
- Embedded HTML keyboard/control interaction, resizing, detach and renderer release.
- Real 2A6000 SSH tunnel carrying a temporary MuJoCo 3.3.7 simulation: JPEG frames plus same-origin WebSocket pause/play/reset controls. Fixture uses OSMesa software rendering and isolated temporary dependencies, not the user's training environment.
- Tunnel shutdown verified without ending the remote simulator.
- Isaac Sim WebRTC, full VNC desktops, Gazebo and Webots were not exercised against installed services in this run; they require the corresponding server-side service.

References: [Isaac Sim](https://docs.isaacsim.omniverse.nvidia.com/latest/installation/manual_livestream_clients.html), [noVNC](https://github.com/novnc/noVNC#quick-start), [MuJoCo](https://mujoco.readthedocs.io/en/stable/python.html#interactive-viewer), [Gzweb](https://github.com/gazebo-web/gzweb), [Webots](https://www.cyberbotics.com/doc/guide/web-streaming).

## Project simulation launcher (0.20)

In a remote project, open **Remote Display → View Current Project**. Harbor finds
`scripts/replay_remote.sh`, remembers the project and resolved SSH hostname, starts
it if no stream is listening, and opens a Chromium app window that connects automatically.
A project without this launcher opens a one-time setup form. Its saved **Launch Command**
is executed with Bash in the selected **Project Directory** only after Start & View.
The Isaac address is `isaac://host:49100`, reached directly through the VPN; UDP 47998
must remain reachable. The bundled viewer uses NVIDIA's pinned 5.6.0 WebRTC library,
validated against Isaac Sim 5.1 on 2A6000. It needs Chrome or Edge installed on the Mac.

The control page shows startup progress, a bounded log tail, and **Stop Simulation**
only for a job Harbor created. Jobs persist across app restarts and VPN loss. Reconnect
reuses them. PID start-time and process-group checks protect other jobs from Stop.
If Isaac does not exit after the normal stop request, **Force Stop** becomes available;
it repeats those ownership checks before forcibly ending only that managed process group.
An already-running stream started in a terminal is reused but never stopped by Harbor.
The private remote metadata/log directory is `~/.local/state/harbor/displays/<profile-id>`.
Only one Isaac viewer may connect at a time; close the NVIDIA client before using Harbor's viewer.
Disconnect closes the local asset service; the viewer then disconnects its media after
its heartbeat expires. The simulator keeps running until explicitly stopped or it exits.

The viewer is a separate Chromium window, not an embedded WKWebView. All launch/stop
controls stay in Harbor. Runtime contains no Node dependency: only immutable, compiled
viewer assets (about 620 KB JS) are served on loopback with a per-session URL token.
Rebuild assets with `cd viewer && npm ci --ignore-scripts && npm run build`.

0.20 validation: the native Start & View button launched a new HumanoidBadminton
replay on 2A6000 and automatically opened a live G1 robot stream. Normal/forced stop
and port release were checked against that QA process. Existing external streams were
reused without taking ownership. Eleven Swift regression tests ran with zero failures
and one optional legacy tunnel test skipped. Other simulator installations were not
revalidated for this launcher release.
