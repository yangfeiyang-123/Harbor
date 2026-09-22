# Remote simulation displays

Open **Remote Display**, add a profile, and select its server. Harbor can open
an existing viewer or launch your configured project command and then view it.
It does not install Isaac Sim, MuJoCo, Gazebo, ROS, or other simulators for you.

## Web and desktop viewers

- **Web viewer / noVNC:** enter the remote HTTP address, for example
  `http://127.0.0.1:6080/vnc.html?resize=remote`, and enable an SSH tunnel.
  The listening port on the Mac is bound to loopback.
- **VNC:** use a `vnc://` address and the installed macOS VNC client.
- **Other simulators:** use their browser streaming interface or a configured
  noVNC desktop. MuJoCo, PyBullet, Genesis, Gazebo/ROS, and Webots presets are
  connection starting points, not bundled simulation engines.

For project launch integration, configure the working directory and launch
command in the profile. A project's `scripts/replay_remote.sh` can be detected.
Only processes started and tracked by Harbor are eligible for its stop control.

## Optional Isaac Sim WebRTC viewer

NVIDIA's `@nvidia/omniverse-webrtc-streaming-library` is separately licensed and
is not included in the public repository or standard app archive. Read
[NVIDIA's licensing information](https://docs.omniverse.nvidia.com/ov-web-sdk/latest/common/legal.html)
and the package's license before downloading or using it. This setup does not
grant redistribution rights.

If your use is covered by NVIDIA's terms, install **Node.js 22+**, clone Harbor,
and run the following from its source directory:

```sh
bash scripts/install-isaac-viewer.sh
```

The script shows the license source and asks you to confirm that you have
reviewed the applicable terms before downloading. It builds Harbor's viewer
integration and places the result at:

```text
~/Library/Application Support/HarborSSH/IsaacViewer/
```

It does not modify or re-sign Harbor.app. Choose **Reload** on the viewer after
installation. To remove the optional viewer, move that directory to Trash.

Use an Isaac profile such as `isaac://gpu.example.org:49100`. A compatible
Chromium browser is needed for this viewer. The current integration uses
**TCP 49100** for signaling and **UDP 47998** for media, so the media address
must be reachable through your network/VPN. A local SSH web tunnel alone is
insufficient. Close other clients if the simulation permits only one viewer.

GPU encoding support, driver and simulator versions, firewall policy, and
NVIDIA's own streaming requirements still apply. Use NVIDIA's documentation
for your installed simulator version; Harbor is not affiliated with NVIDIA.
