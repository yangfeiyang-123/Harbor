# Managed proxy setup

Harbor's ordinary SSH workspaces and custom local, remote and SOCKS5 forwards do
not require the managed proxy runtime. The optional managed profile integrates a
Mac-side mihomo gateway, an existing VPN route and two SSH hosts. It is intended
for installations that provide those services.

The public runtime's host table contains example destinations. Configure
`Sources/HarborSSH/Resources/ProxyRuntime/server-proxy-macos.sh` for your own
installation before enabling its managed services. Environment overrides are:

| Variable | Default | Purpose |
| --- | --- | --- |
| `HARBOR_A100_HOST` | `a100.example.org` | First host's SSH destination |
| `HARBOR_A100_USER` | `user` | First host's SSH account |
| `HARBOR_A100_SSH_ALIAS` | `a100` | First host's shell shortcut |
| `HARBOR_RTX4090_HOST` | `rtx4090.example.org` | Second host's SSH destination |
| `HARBOR_RTX4090_USER` | `user` | Second host's SSH account |
| `HARBOR_RTX4090_SSH_ALIAS` | `rtx4090` | Second host's shell shortcut |

Supply these settings to the process invoking the script. If services are
installed under launchd, configure their environment or customize the host
table; an interactive shell's exports are not automatically inherited by GUI
applications or launchd. Review the SSH key, remote home paths, port table,
VPN route check and gateway configuration for your environment too.

The runtime keeps its configuration and logs under
`~/Library/Application Support/server-reverse-proxy/`. Existing service names
remain compatible with earlier installations. Installation and mode commands
change local services and remote setup; use `status` and `doctor` to inspect a
configured installation first.

## Traffic pacing and status

Each managed tunnel measures round-trip delay through the bridge and paces
traffic in both directions. This avoids building a large queue on a constrained
VPN path. Status reports the current shaping rates as `A100_SHAPE` and
`RTX_SHAPE`. Set `RP_SHAPE=0` in the tunnel environment to disable pacing.

A running process is not evidence that the gateway works: the managed status
also performs an HTTP 204 check. Custom forwarding to a non-HTTP service needs
validation with that service's client. Managed services continue independently
of Harbor, while Harbor's custom forwarding rules stop when the app quits.
