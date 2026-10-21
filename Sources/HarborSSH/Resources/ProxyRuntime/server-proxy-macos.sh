#!/bin/bash
# server-proxy-macos.sh — reverse proxy for A100 / RTX 4090 through this Mac.
#
# Architecture (one hop, no nesting):
#
#   server:11088 ──bridge──> ~/.rp-a100.<t>.sock ──ssh -R──> Mac:10811 ─┐
#   server:11083 ──bridge──> ~/.rp-rtx4090.<t>.sock ──ssh -R──> Mac:10812 ─┤ gateway-shaper
#                                                                          └─> Mac:10810 (mihomo) ──> DIRECT (usa) / Clash Party:10808 (china)
#
# The gateway on 10810 never moves, so switching modes or restarting Clash
# Party never drops the tunnels.  Each tunnel is one dedicated, un-shared ssh
# process supervised by launchd; interactive/editor sessions use separate
# multiplexed connections and cannot disturb the tunnels.
#
# aTrust queues without limit: one 3 MB transfer pushed the tunnel RTT from
# 0.2 s to 15-30 s and stalled every terminal and request behind it.  So each
# direction is paced just below what the path carries — the bridge on the
# server for server -> Mac, the gateway shaper here for Mac -> server — using
# the round trip the bridge measures through the tunnel every few seconds.
# That same probe is the liveness check: the Mac-side watchdog no longer opens
# ssh sessions to guess (it restarted healthy tunnels 888 times in ten days
# whenever a probe ran past its 15 s budget), and a bridge that cannot reach
# the Mac closes its port so shells fail fast instead of hanging.
#
# Bundled and maintained by HarborSSH. Reuses existing launchd service identities.
# Usage: server-proxy-macos.sh {usa|china|status|check|stop|restart|install|setup-servers|logs|doctor}

set -uo pipefail   # deliberately not -e: partial failures must still report

# Bump when the runtime contract (agents, ports, bridge protocol) changes.  A
# stale app bundle must never downgrade a newer installed runtime.
RUNTIME_VERSION=20

ROOT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
SELF_PATH="$ROOT_DIR/$(basename "$0")"
RUN_DIR="$HOME/Library/Application Support/server-reverse-proxy"
BIN_DIR="$RUN_DIR/bin"
LOG_DIR="$RUN_DIR/logs"
MIHOMO_DIR="$RUN_DIR/mihomo"
STATE_FILE="$RUN_DIR/mode"
VERSION_FILE="$RUN_DIR/runtime-version"
SECRET_FILE="$RUN_DIR/controller-secret"
GATEWAY_CONFIG="$MIHOMO_DIR/config.yaml"
SHAPER_SCRIPT="$BIN_DIR/gateway-shaper.py"
RUNTIME_SCRIPT="$BIN_DIR/server-proxy-macos.sh"
SERVER_SNIPPET="$BIN_DIR/server-bashrc-proxy.sh"
BRIDGE_SCRIPT="$BIN_DIR/loopback-bridge.py"

PREFIX='com.felix.server-proxy'
GATEWAY_PORT=10810
CONTROLLER_PORT=9095
HEALTH_PORT=10809
CLASH_PORT=10808
CLASH_APP_NAME="${CLASH_APP_NAME:-Clash Party}"
SSH_KEY="$HOME/.ssh/id_ed25519_server_proxy"
UID_NUM="$(id -u)"

HOSTS='a100 rtx4090'

# ---------------------------------------------------------------- host table

host_ip()      { case "$1" in a100) echo "${HARBOR_A100_HOST:-a100.example.org}" ;; rtx4090) echo "${HARBOR_RTX4090_HOST:-rtx4090.example.org}" ;; esac; }
host_user()    { case "$1" in a100) echo "${HARBOR_A100_USER:-user}" ;; rtx4090) echo "${HARBOR_RTX4090_USER:-user}" ;; esac; }
host_port()    { case "$1" in a100) echo 11088 ;; rtx4090) echo 11083 ;; esac; }
host_ports()   { case "$1" in a100) echo '11088,11089,11090,11091' ;; rtx4090) echo '11083,11084,11085,11086' ;; esac; }
host_relay()   { case "$1" in a100) echo 10811 ;; rtx4090) echo 10812 ;; esac; }
host_shell()   { case "$1" in a100) echo "${HARBOR_A100_SSH_ALIAS:-a100}" ;; rtx4090) echo "${HARBOR_RTX4090_SSH_ALIAS:-rtx4090}" ;; esac; }
host_label()   { case "$1" in a100) echo 'A100' ;; rtx4090) echo 'RTX 4090' ;; esac; }
host_key()     { case "$1" in a100) echo A100 ;; rtx4090) echo RTX ;; esac; }
host_home()    { printf "/home/%s\n" "$(host_user "$1")"; }

# Hosts that bypass the tunnel.  A100 reaches Chinese mirrors directly and
# faster than the tunnel; RTX 4090's firewall accepts the TCP handshake and
# then drops everything, so bypassing there only hangs pip/conda/npm.
RP_NO_PROXY_BASE='localhost,127.0.0.1,::1,172.18.0.0/16,169.254.0.0/16,169.254.169.254,metadata.google.internal,.internal,.local'
host_no_proxy() {
    case "$1" in
        a100) printf '%s,%s' "$RP_NO_PROXY_BASE" 'pypi.org,.pypi.org,.pythonhosted.org,.tuna.tsinghua.edu.cn,.bfsu.edu.cn,.ustc.edu.cn,.aliyun.com,.anaconda.com,.anaconda.org,.pytorch.org,.npmjs.org' ;;
        *)    printf '%s' "$RP_NO_PROXY_BASE" ;;
    esac
}
# RTX 4090's /etc/resolv.conf lists 1.1.1.1 and 8.8.8.8 (unreachable from the
# campus) before the campus resolver; glibc waited 8-16 s per lookup.
host_res_options() { case "$1" in rtx4090) echo 'timeout:1 attempts:2' ;; *) echo '' ;; esac; }
# 1 = the host has its own way out, so a shell may drop the proxy while the tunnel is down.
host_direct_egress() { case "$1" in a100) echo 1 ;; *) echo 0 ;; esac; }

# ---------------------------------------------------------------- primitives

log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }

# macOS ships no coreutils timeout; python3 from the Command Line Tools is
# always present and gives us a hard wall clock on any child process.
run_timeout() {
    local seconds="$1"; shift
    /usr/bin/python3 -c '
import subprocess, sys
try:
    raise SystemExit(subprocess.run(sys.argv[2:], timeout=float(sys.argv[1])).returncode)
except subprocess.TimeoutExpired:
    raise SystemExit(124)
' "$seconds" "$@"
}

port_open() { nc -z -G 2 -w 2 "$1" "$2" >/dev/null 2>&1; }

# The managed VPN profile requires a utun route to its configured host.
# Other network setups can use Harbor's custom forwarding rules.
route_ready() {
    /sbin/route -n get "$(host_ip a100)" 2>/dev/null |
        /usr/bin/grep -Eq 'interface:[[:space:]]+utun[0-9]+'
}

gateway_up() { port_open 127.0.0.1 "$GATEWAY_PORT"; }
clash_up()   { port_open 127.0.0.1 "$CLASH_PORT"; }
health_up()  {
    [ "$(curl -sS --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 3 \
        "http://127.0.0.1:$HEALTH_PORT/" 2>/dev/null)" = 204 ]
}
shaper_up() {
    local host
    health_up || return 1
    for host in $HOSTS; do port_open 127.0.0.1 "$(host_relay "$host")" || return 1; done
    return 0
}
shaper_status_json() { curl -sS --noproxy '*' --max-time 3 "http://127.0.0.1:$HEALTH_PORT/status" 2>/dev/null; }

# ----------------------------------------------------------------- launchd

label() { printf '%s.%s' "$PREFIX" "$1"; }
plist_path() { printf '%s/Library/LaunchAgents/%s.%s.plist' "$HOME" "$PREFIX" "$1"; }

agent_loaded()  { launchctl print "gui/$UID_NUM/$(label "$1")" >/dev/null 2>&1; }
agent_running() { launchctl print "gui/$UID_NUM/$(label "$1")" 2>/dev/null | grep -q 'state = running'; }
agent_pid()     {
    launchctl print "gui/$UID_NUM/$(label "$1")" 2>/dev/null |
        awk '/^[[:space:]]*pid = /{print $3; exit}'
}

write_agent() {
    local name="$1"; shift
    local path arg
    path="$(plist_path "$name")"
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
        echo '<plist version="1.0"><dict>'
        printf '  <key>Label</key><string>%s</string>\n' "$(label "$name")"
        echo '  <key>ProgramArguments</key><array>'
        for arg in "$@"; do printf '    <string>%s</string>\n' "$arg"; done
        echo '  </array>'
        echo '  <key>EnvironmentVariables</key><dict>'
        printf '    <key>HOME</key><string>%s</string>\n' "$HOME"
        echo '    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>'
        echo '  </dict>'
        echo '  <key>RunAtLoad</key><true/>'
        echo '  <key>KeepAlive</key><true/>'
        echo '  <key>ThrottleInterval</key><integer>10</integer>'
        echo '  <key>ProcessType</key><string>Background</string>'
        printf '  <key>StandardOutPath</key><string>%s/%s.log</string>\n' "$LOG_DIR" "$name"
        printf '  <key>StandardErrorPath</key><string>%s/%s.log</string>\n' "$LOG_DIR" "$name"
        printf '  <key>WorkingDirectory</key><string>%s</string>\n' "$RUN_DIR"
        echo '</dict></plist>'
    } >"$path"
}

start_agent() {
    local name="$1"
    if agent_loaded "$name"; then
        launchctl kickstart "gui/$UID_NUM/$(label "$1")" >/dev/null 2>&1
    else
        launchctl bootstrap "gui/$UID_NUM" "$(plist_path "$name")" >/dev/null 2>&1
    fi
}

restart_agent() { launchctl kickstart -k "gui/$UID_NUM/$(label "$1")" >/dev/null 2>&1; }

stop_agent() {
    local i
    launchctl bootout "gui/$UID_NUM/$(label "$1")" >/dev/null 2>&1
    launchctl remove "$(label "$1")" >/dev/null 2>&1
    # launchd loads ~/Library/LaunchAgents at every login, so a leftover plist
    # would quietly undo "stop" on the next reboot.
    rm -f "$(plist_path "$1")"
    # bootout is asynchronous; a bootstrap that races it fails with EEXIST.
    for i in 1 2 3 4 5 6 7 8 9 10; do
        agent_loaded "$1" || break
        sleep 0.5
    done
    return 0
}

# launchd keeps the ProgramArguments it was bootstrapped with; a rewritten
# plist only takes effect after bootout + bootstrap.
reload_agent() {
    local name="$1"; shift
    stop_agent "$name"
    write_agent "$name" "$@"
    start_agent "$name"
}

# ----------------------------------------------------------------- gateway

controller_secret() {
    if [ ! -s "$SECRET_FILE" ]; then
        /usr/bin/python3 -c 'import secrets; print(secrets.token_hex(16))' >"$SECRET_FILE"
        chmod 600 "$SECRET_FILE"
    fi
    cat "$SECRET_FILE"
}

find_mihomo() {
    if [ -n "${MIHOMO_BIN:-}" ] && [ -x "$MIHOMO_BIN" ]; then echo "$MIHOMO_BIN"; return 0; fi
    local c
    for c in /opt/homebrew/bin/mihomo /usr/local/bin/mihomo "$(command -v mihomo 2>/dev/null)"; do
        [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return 0; }
    done
    return 1
}

write_gateway_config() {
    local secret
    secret="$(controller_secret)"
    cat >"$GATEWAY_CONFIG" <<YAML
# Generated by server-proxy-macos.sh — edits are overwritten.
# Fixed local endpoint for both reverse tunnels.  Mode changes only flip the
# EXIT selector, so the tunnels never see the listener go away.
mixed-port: $GATEWAY_PORT
allow-lan: false
bind-address: 127.0.0.1
mode: rule
log-level: warning
ipv6: false
unified-delay: true
tcp-concurrent: true
find-process-mode: 'off'
external-controller: 127.0.0.1:$CONTROLLER_PORT
secret: '$secret'
profile:
  store-selected: true
dns:
  enable: false
proxies:
  - name: clash-upstream
    type: http
    server: 127.0.0.1
    port: $CLASH_PORT
proxy-groups:
  - name: EXIT
    type: select
    proxies:
      - DIRECT
      - clash-upstream
# The listener on a server is a loopback port without a password, and the servers
# are shared: everyone with an account there can use it.  What they must not get
# through it is this Mac's own loopback (other proxies, notebooks, model servers,
# this runtime's controller).  The one thing a tunnel needs here is the health
# endpoint, which the bridge and the path check ask through the tunnel.
rules:
  - AND,((IP-CIDR,127.0.0.1/32,no-resolve),(DST-PORT,$HEALTH_PORT)),DIRECT
  - IP-CIDR,127.0.0.0/8,REJECT,no-resolve
  - IP-CIDR,0.0.0.0/8,REJECT,no-resolve
  - IP-CIDR6,::1/128,REJECT,no-resolve
  - IP-CIDR6,::/128,REJECT,no-resolve
  - DOMAIN,localhost,REJECT
  - DOMAIN-SUFFIX,localhost,REJECT
  - MATCH,EXIT
YAML
    chmod 600 "$GATEWAY_CONFIG"
}

api() {
    local method="$1" path="$2" body="${3:-}"
    if [ -n "$body" ]; then
        curl -sS --noproxy '*' --max-time 5 -X "$method" \
            -H "Authorization: Bearer $(controller_secret)" \
            -H 'Content-Type: application/json' -d "$body" \
            "http://127.0.0.1:$CONTROLLER_PORT$path" 2>/dev/null
    else
        curl -sS --noproxy '*' --max-time 5 -X "$method" \
            -H "Authorization: Bearer $(controller_secret)" \
            "http://127.0.0.1:$CONTROLLER_PORT$path" 2>/dev/null
    fi
}

current_exit() {
    api GET /proxies/EXIT |
        /usr/bin/python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("now",""))
except Exception: print("")' 2>/dev/null
}

set_exit() {
    local target="$1" i
    for i in 1 2 3; do
        api PUT /proxies/EXIT "{\"name\":\"$target\"}" >/dev/null
        [ "$(current_exit)" = "$target" ] && return 0
        sleep 0.5
    done
    return 1
}

ensure_gateway() {
    local mihomo i
    mkdir -p "$MIHOMO_DIR"
    write_gateway_config
    if agent_running gateway && gateway_up; then return 0; fi

    if ! mihomo="$(find_mihomo)"; then
        echo 'mihomo not found. Install it with: brew install mihomo' >&2
        return 1
    fi
    write_agent gateway "$mihomo" -d "$MIHOMO_DIR" -f "$GATEWAY_CONFIG"
    start_agent gateway
    for i in $(seq 1 60); do
        gateway_up && return 0
        sleep 0.5
    done
    echo "Gateway did not open 127.0.0.1:$GATEWAY_PORT; see $LOG_DIR/gateway.log" >&2
    return 1
}

shaper_args() {
    local host
    printf '%s\n' /usr/bin/python3 "$SHAPER_SCRIPT" --health "$HEALTH_PORT" --upstream "$GATEWAY_PORT"
    for host in $HOSTS; do printf -- '--relay\n%s=%s=%s\n' "$host" "$(host_relay "$host")" "$(host_ip "$host")"; done
}

# The `health` launchd identity is kept; it now runs the gateway shaper, which
# serves the health endpoint and both relay ports.
ensure_shaper() {
    local i args=()
    if agent_running health && shaper_up; then return 0; fi
    while IFS= read -r line; do args+=("$line"); done < <(shaper_args)
    reload_agent health "${args[@]}"
    for i in $(seq 1 40); do
        shaper_up && return 0
        sleep 0.25
    done
    return 1
}

# ----------------------------------------------------------------- tunnels

tunnel_job() { printf 'tunnel-%s' "$1"; }
tunnel_log() { printf '%s/tunnel-%s.log' "$LOG_DIR" "$1"; }
log_size()   { wc -c <"$(tunnel_log "$1")" 2>/dev/null | tr -d ' ' || echo 0; }

# The bridge reports on the tunnel's own stderr, so the Mac learns its state
# from the log instead of opening ssh sessions.  The last line that is not a
# pacing notice decides: "bridge: ready"/"restored" mean the server port is
# open and the path was just verified; anything after that (an ssh error, a
# reconnect notice, "degraded") means it is not.
tunnel_last_event() {
    grep -v -E '^bridge: ([a-z0-9]+ )?rate |^bridge: retired |^bridge: removed ' "$(tunnel_log "$1")" 2>/dev/null |
        grep -v '^[[:space:]]*$' | tail -n 1
}
tunnel_state() {
    local line
    agent_running "$(tunnel_job "$1")" || { echo down; return; }
    line="$(tunnel_last_event "$1")"
    case "$line" in
        'bridge: ready '*|'bridge: restored '*) echo up ;;
        'bridge: no answer'*) echo degraded ;;
        *) echo connecting ;;
    esac
}
tunnel_port() {
    grep -e '^bridge: ready port=' -e '^bridge: restored port=' "$(tunnel_log "$1")" 2>/dev/null |
        tail -n 1 | sed -n 's/.*port=\([0-9][0-9]*\).*/\1/p'
}
# A tunnel (re)started at log offset N is ready once a fresh ready line
# appears after N; an untouched tunnel is ready when its state says so.
tunnel_ready() {
    local host="$1" offset="$2" restarted="$3"
    if [ "$restarted" = 1 ]; then
        tail -c +"$((offset + 1))" "$(tunnel_log "$host")" 2>/dev/null | grep -q '^bridge: ready '
    else
        [ "$(tunnel_state "$host")" = up ]
    fi
}

# Stops the bridge and clears its paths on the server.  Only used on an
# explicit stop; reconnects need no separate ssh session any more.  The pid
# file can be left over from a bridge that was killed, with its number given to
# another process since: only a process that is this host's bridge is signalled.
clear_remote_listener() {
    local host="$1" ip user home
    ip="$(host_ip "$host")"; user="$(host_user "$host")"; home="$(host_home)"
    run_timeout 30 /usr/bin/ssh -F /dev/null -o BatchMode=yes -o ConnectTimeout=20 \
        -o ControlMaster=no -o ControlPath=none \
        -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes \
        -i "$SSH_KEY" "$user@$ip" \
        "p=\$(cat $home/.rp-$host.pid 2>/dev/null); case \"\$p\" in ''|*[!0-9]*) p='' ;; esac; [ -n \"\$p\" ] && tr '\\0' '\\n' </proc/\$p/environ 2>/dev/null | grep -qx 'RP_HOST=$host' && kill \"\$p\" 2>/dev/null; rm -f $home/.rp-$host.pid $home/.rp-$host.sock $home/.rp-$host.*.sock; exit 0" \
        >/dev/null 2>&1
    return 0
}

# Probes ride the warm multiplexed master (instant after the first call).  A
# wedged master would fake a failure, so a negative result is always confirmed
# on a fresh unshared connection before we believe it.  Only user-triggered
# checks use these; nothing automatic does.
remote_run() {
    local host="$1" seconds="$2" cmd="$3"
    if run_timeout "$seconds" /usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=20 \
        "$(host_shell "$host")" "$cmd" >/dev/null 2>&1; then
        return 0
    fi
    run_timeout "$seconds" /usr/bin/ssh -F /dev/null -o BatchMode=yes -o ConnectTimeout=20 \
        -o ControlMaster=no -o ControlPath=none -o StrictHostKeyChecking=accept-new \
        -o IdentitiesOnly=yes -i "$SSH_KEY" \
        "$(host_user "$host")@$(host_ip "$host")" "$cmd" >/dev/null 2>&1
}

remote_capture() {
    local host="$1" seconds="$2" cmd="$3" out
    out="$(run_timeout "$seconds" /usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=20 \
        "$(host_shell "$host")" "$cmd" 2>/dev/null)"
    if [ -n "$out" ]; then printf '%s' "$out"; return 0; fi
    run_timeout "$seconds" /usr/bin/ssh -F /dev/null -o BatchMode=yes -o ConnectTimeout=20 \
        -o ControlMaster=no -o ControlPath=none -o StrictHostKeyChecking=accept-new \
        -o IdentitiesOnly=yes -i "$SSH_KEY" \
        "$(host_user "$host")@$(host_ip "$host")" "$cmd" 2>/dev/null
}

# The bridge publishes whichever port it managed to claim, so every probe reads
# it back rather than assuming the primary is the one in use.
RP_PORT_EXPR='p=$(cat ~/.reverse-proxy-port 2>/dev/null); case "$p" in ""|*[!0-9]*) p=%s ;; esac'

remote_port_listening() {
    remote_run "$1" "${2:-30}" \
        "$(printf "$RP_PORT_EXPR" "$(host_port "$1")"); ss -ltnH \"sport = :\$p\" 2>/dev/null | grep -q LISTEN"
}

# End-to-end proof: server -> tunnel -> Mac gateway -> Mac health endpoint.
# Uses no internet, so it is valid in either mode and either country.
remote_path_ok() {
    remote_run "$1" 45 \
        "$(printf "$RP_PORT_EXPR" "$(host_port "$1")"); test \"\$(curl -sS --noproxy '' -o /dev/null -w '%{http_code}' --max-time 20 --proxy http://127.0.0.1:\$p http://127.0.0.1:$HEALTH_PORT/ 2>/dev/null)\" = 204"
}

remote_exit_ip() {
    remote_capture "$1" 45 \
        "$(printf "$RP_PORT_EXPR" "$(host_port "$1")"); curl -fsS --noproxy '' --max-time 25 --proxy http://127.0.0.1:\$p https://api.ipify.org"
}

start_tunnel() {
    local host="$1"
    write_agent "$(tunnel_job "$host")" /bin/bash "$RUNTIME_SCRIPT" _tunnel "$host"
    start_agent "$(tunnel_job "$host")"
}

stop_tunnel() {
    local host="$1"
    stop_agent "$(tunnel_job "$host")"
    clear_remote_listener "$host" &
}

# Supervised body of one tunnel.  launchd owns the restart policy; this exec's
# into ssh so there is exactly one process and one owner of the connection.
# Everything ssh needs is on the command line (-F /dev/null): the tunnel must
# not inherit a RemoteForward or other drift from ~/.ssh/config.
run_tunnel() {
    local host="$1" i sock
    [ -n "$(host_ip "$host")" ] || { echo "unknown host: $host" >&2; exit 2; }

    for i in $(seq 1 60); do
        route_ready && break
        sleep 10
    done
    route_ready || { log "aTrust route unavailable; retrying"; exit 0; }

    for i in $(seq 1 60); do
        gateway_up && port_open 127.0.0.1 "$(host_relay "$host")" && break
        sleep 5
    done
    gateway_up || { log "local gateway 127.0.0.1:$GATEWAY_PORT down; retrying"; exit 0; }
    port_open 127.0.0.1 "$(host_relay "$host")" || { log "relay 127.0.0.1:$(host_relay "$host") down; retrying"; exit 0; }

    reconnect_backoff "$host"
    sock="$(host_home)/.rp-$host.$(date +%s).sock"
    log "connecting $(host_label "$host") reverse tunnel :$(host_port "$host") via 127.0.0.1:$(host_relay "$host")"
    # The bridge is the tunnel's own remote command, piped in over stdin: nothing
    # is installed on the server and the two share a single lifetime.
    exec /usr/bin/ssh -F /dev/null \
        -o User="$(host_user "$host")" -o IdentityFile="$SSH_KEY" -o IdentitiesOnly=yes \
        -o BatchMode=yes -o RequestTTY=no -o ControlMaster=no -o ControlPath=none \
        -o StrictHostKeyChecking=accept-new -o ExitOnForwardFailure=yes \
        -o ConnectTimeout=30 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 \
        -o TCPKeepAlive=no -o Compression=no \
        -o IgnoreUnknown=WarnWeakCrypto -o WarnWeakCrypto=no \
        -R "$sock:127.0.0.1:$(host_relay "$host")" \
        "$(host_ip "$host")" \
        "RP_SOCKET=$sock RP_HOST=$host RP_PORTS=$(host_ports "$host") RP_HEALTH=127.0.0.1:$HEALTH_PORT exec python3 -" \
        <"$BRIDGE_SCRIPT"
}

# launchd restarts a failed job every ThrottleInterval.  For a tunnel that
# cannot connect at all that is a connection storm against the server's sshd,
# which then starts refusing everything (including our own diagnostics).  Back
# off geometrically while runs keep dying young, and reset once one survives.
reconnect_backoff() {
    local host="$1" stamp_file count_file last now count wait_for
    stamp_file="$RUN_DIR/.last-start-$host"
    count_file="$RUN_DIR/.fail-count-$host"
    now="$(date +%s)"
    last="$(cat "$stamp_file" 2>/dev/null)"
    count="$(cat "$count_file" 2>/dev/null)"
    case "$count" in ''|*[!0-9]*) count=0 ;; esac

    # The stamp is when ssh itself was last started (written below, after the
    # wait): the wait must not count as time the connection survived, or the
    # third attempt always looked like a fresh start and the waits never grew.
    case "$last" in ''|*[!0-9]*) last='' ;; esac
    if [ -n "$last" ] && [ "$((now - last))" -lt 60 ]; then
        count=$((count + 1))
    else
        count=0
    fi
    printf '%s\n' "$count" >"$count_file"

    if [ "$count" -gt 0 ]; then
        wait_for=$((count * 15))
        [ "$wait_for" -gt 120 ] && wait_for=120
        log "$(host_label "$host") reconnect attempt $count, waiting ${wait_for}s"
        sleep "$wait_for"
    fi
    date +%s >"$stamp_file"
}

# One watchdog, one owner, local checks only.  Tunnel liveness is the
# bridge's job (it probes the Mac through the tunnel and exits when the path
# is dead) plus ssh's own ServerAlive; launchd restarts whatever exits.
run_monitor() {
    local host
    while true; do
        sleep 60
        route_ready || continue
        [ -s "$STATE_FILE" ] || continue

        if ! gateway_up; then
            log 'gateway down, restarting'
            restart_agent gateway
            sleep 10
            continue
        fi
        if ! shaper_up; then
            log 'gateway shaper down, restarting'
            ensure_shaper || log 'gateway shaper did not come back'
        fi
        for host in $HOSTS; do
            if ! agent_running "$(tunnel_job "$host")"; then
                log "$(host_label "$host") tunnel job not running, starting"
                start_tunnel "$host"
            fi
        done
    done
}

# ------------------------------------------------------------------ status

shape_line() {
    local host="$1" json="$2"
    [ -n "$json" ] || return 0
    printf '%s' "$json" | /usr/bin/python3 -c '
import json, sys
host = sys.argv[1]
def rate(v):
    if v is None: return "off"
    return "%.1fM/s" % (v / 1048576.0) if v >= 1048576 else "%dK/s" % (v / 1024.0)
try:
    d = json.load(sys.stdin)[host]
except Exception:
    sys.exit(0)
rtt = "n/a" if d.get("rtt") is None else "%.2fs" % d["rtt"]
base = "" if d.get("base") is None else " base %.2fs" % d["base"]
age = "" if d.get("age") is None else " (%ds ago)" % d["age"]
print("down %s, up %s, rtt %s%s%s" % (rate(d.get("rate")), rate(d.get("peer_rate")), rtt, base, age))
' "$host" 2>/dev/null
}

status_block() {
    local full="${1:-0}" host key mode exit_now json line
    mode="$(cat "$STATE_FILE" 2>/dev/null)"
    exit_now="$(current_exit)"
    case "$exit_now" in
        DIRECT) mode=usa ;;
        clash-upstream) mode=china ;;
        *) [ -n "$mode" ] || mode=unknown ;;
    esac

    printf 'MODE=%s\n' "$mode"
    printf 'ROUTE=%s\n'   "$(route_ready && echo up || echo down)"
    printf 'GATEWAY=%s\n' "$(gateway_up  && echo up || echo down)"
    printf 'HEALTH=%s\n'  "$(health_up   && echo up || echo down)"
    printf 'SHAPER=%s\n'  "$(shaper_up   && echo up || echo down)"
    printf 'CLASH=%s\n'   "$(clash_up    && echo up || echo down)"
    json="$(shaper_status_json)"

    for host in $HOSTS; do
        key="$(host_key "$host")"
        if agent_running "$(tunnel_job "$host")"; then
            printf '%s_JOB=up\n' "$key"
        else
            printf '%s_JOB=down\n' "$key"
        fi
        if [ "$full" != 0 ]; then
            if remote_path_ok "$host"; then
                printf '%s_TUNNEL=up\n' "$key"
                printf '%s_HTTP=204\n' "$key"
            elif remote_port_listening "$host" 30; then
                printf '%s_TUNNEL=stale\n' "$key"
            else
                printf '%s_TUNNEL=down\n' "$key"
            fi
        else
            printf '%s_TUNNEL=%s\n' "$key" "$(tunnel_state "$host")"
        fi
        printf '%s_PORT=%s\n' "$key" "$(tunnel_port "$host")"
        line="$(shape_line "$host" "$json")"
        [ -n "$line" ] && printf '%s_SHAPE=%s\n' "$key" "$line"
    done

    if [ "$full" = 1 ]; then
        printf 'LOCAL_IP=%s\n' "$(curl -fsS --noproxy '*' --max-time 15 https://api.ipify.org 2>/dev/null)"
        printf 'GATEWAY_IP=%s\n' "$(curl -fsS --max-time 20 --proxy "http://127.0.0.1:$GATEWAY_PORT" https://api.ipify.org 2>/dev/null)"
        for host in $HOSTS; do
            printf '%s_IP=%s\n' "$(host_key "$host")" "$(remote_exit_ip "$host")"
        done
    fi
}

# ----------------------------------------------------------------- install

install_file() {
    local src="$1" dst="$2"
    [ -f "$src" ] || return 0
    [ "$src" = "$dst" ] && return 0
    install -m 600 "$src" "$dst" 2>/dev/null
    return 0
}

installed_version() {
    sed -n 's/^RUNTIME_VERSION=\([0-9][0-9]*\)$/\1/p' "$RUNTIME_SCRIPT" 2>/dev/null | head -n 1
}

# A tunnel's state and port are read from its log: the last "ready" line and
# the last line that is not a pacing notice.  A tunnel that has been up for days
# wrote those long ago, so the part that is kept starts with them (and at the
# start of a line); without that a healthy tunnel read as "connecting", and the
# next mode switch waited its full 150 s for it.
rotate_log() {
    local path="$1" ready event
    [ -f "$path" ] || return 0
    if [ "$(wc -c <"$path" | tr -d ' ')" -gt 2000000 ]; then
        ready="$(grep -e '^bridge: ready port=' -e '^bridge: restored port=' "$path" 2>/dev/null | tail -n 1)"
        event="$(grep -v -E '^bridge: ([a-z0-9]+ )?rate |^bridge: retired |^bridge: removed ' "$path" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -n 1)"
        {
            [ -n "$ready" ] && printf '%s\n' "$ready"
            [ -n "$event" ] && [ "$event" != "$ready" ] && printf '%s\n' "$event"
            tail -c 200000 "$path" 2>/dev/null | sed 1d
        } >"$path.tmp" 2>/dev/null && cat "$path.tmp" >"$path"
        rm -f "$path.tmp"
    fi
}

install_runtime() {
    mkdir -p "$RUN_DIR" "$BIN_DIR" "$LOG_DIR" "$MIHOMO_DIR"
    chmod 700 "$RUN_DIR"
    # launchd cannot exec from ~/Desktop (TCC denies it), so everything the
    # agents touch lives under Application Support.
    if [ "$SELF_PATH" != "$RUNTIME_SCRIPT" ]; then
        install -m 700 "$0" "$RUNTIME_SCRIPT"
    fi
    install_file "$ROOT_DIR/gateway-shaper.py"        "$SHAPER_SCRIPT"
    install_file "$ROOT_DIR/server-bashrc-proxy.sh"   "$SERVER_SNIPPET"
    install_file "$ROOT_DIR/patch-server-bashrc.py"   "$BIN_DIR/patch-server-bashrc.py"
    install_file "$ROOT_DIR/loopback-bridge.py"       "$BRIDGE_SCRIPT"
    rm -f "$BIN_DIR/reverse-proxy-health.py" "$BIN_DIR/a100-bridge.py"
    local f
    for f in "$LOG_DIR"/*.log; do rotate_log "$f"; done
    return 0
}

start_all() {
    local host rc=0 restart=0 off new i ok was_up=0
    install_runtime
    if agent_running gateway && gateway_up; then was_up=1; fi
    ensure_gateway || return 1
    # Tunnels and the shaper keep running across mode switches.  They are only
    # restarted when the runtime contract changed, so new code takes effect.
    [ "$(cat "$VERSION_FILE" 2>/dev/null)" = "$RUNTIME_VERSION" ] || restart=1
    # A gateway that was already running read its rules when it started.
    if [ "$restart" = 1 ] && [ "$was_up" = 1 ]; then
        restart_agent gateway
        for i in $(seq 1 60); do
            sleep 0.5
            gateway_up && break
        done
    fi
    if [ "$restart" = 1 ] && agent_loaded health; then stop_agent health; fi
    ensure_shaper  || log 'gateway shaper did not start (tunnels will wait for it)'
    write_agent monitor /bin/bash "$RUNTIME_SCRIPT" _monitor
    # A running monitor keeps executing the code it was started with.
    if [ "$restart" = 1 ] && agent_running monitor; then restart_agent monitor; else start_agent monitor; fi
    for host in $HOSTS; do
        off="$(log_size "$host")"; new=0
        if agent_running "$(tunnel_job "$host")"; then
            if [ "$restart" = 1 ]; then
                write_agent "$(tunnel_job "$host")" /bin/bash "$RUNTIME_SCRIPT" _tunnel "$host"
                restart_agent "$(tunnel_job "$host")"
                new=1
            fi
        else
            start_tunnel "$host"
            new=1
        fi
        eval "off_$host=$off; new_$host=$new"
    done
    printf '%s\n' "$RUNTIME_VERSION" >"$VERSION_FILE"

    # Readiness comes from the tunnel logs (the bridge reports on ssh's
    # stderr), never from extra ssh sessions.  Bounded to 150 s.
    for i in $(seq 1 75); do
        ok=1
        for host in $HOSTS; do
            eval "off=\$off_$host; new=\$new_$host"
            tunnel_ready "$host" "$off" "$new" || ok=0
        done
        [ "$ok" = 1 ] && break
        sleep 2
    done
    return $rc
}

stop_all() {
    local host
    rm -f "$STATE_FILE"
    stop_agent monitor
    for host in $HOSTS; do stop_tunnel "$host"; done
    stop_agent health
    stop_agent gateway
    wait 2>/dev/null
    return 0
}

# -------------------------------------------------------------------- modes

cmd_usa() {
    install_runtime
    if ! route_ready; then
        echo 'The managed host has no VPN route. Configure the host and connect its VPN first.' >&2
        status_block 0
        return 1
    fi
    printf 'usa\n' >"$STATE_FILE"
    start_all || { status_block 0; return 1; }
    set_exit DIRECT || { log 'could not switch gateway to DIRECT'; status_block 0; return 1; }
    status_block 2
}

cmd_china() {
    install_runtime
    if ! route_ready; then
        echo 'The managed host has no VPN route. Configure the host and connect its VPN first.' >&2
        status_block 0
        return 1
    fi
    printf 'china\n' >"$STATE_FILE"
    if ! clash_up; then
        open -a "$CLASH_APP_NAME" >/dev/null 2>&1 || open -a 'Mihomo Party' >/dev/null 2>&1 || true
        local i
        for i in $(seq 1 120); do clash_up && break; sleep 1; done
    fi
    start_all || { status_block 0; return 1; }
    if ! clash_up; then
        echo "Clash Party is not listening on 127.0.0.1:$CLASH_PORT — pick a profile/node in the app." >&2
        status_block 0
        return 1
    fi
    set_exit clash-upstream || { log 'could not switch gateway to the Clash upstream'; status_block 0; return 1; }
    status_block 2
}

# Installs ~/.reverse-proxy.sh on both servers and rewires ~/.bashrc to source
# it above the non-interactive guard, so VS Code / Cursor background processes
# get the proxy too — not just tty shells.
setup_servers() {
    local host snippet rc=0
    install_runtime
    for host in $HOSTS; do
        snippet="$RUN_DIR/.snippet-$host"
        sed -e "s|__RP_PORT__|$(host_port "$host")|" \
            -e "s|__RP_NO_PROXY__|$(host_no_proxy "$host")|" \
            -e "s|__RP_RES_OPTIONS__|$(host_res_options "$host")|" \
            -e "s|__RP_DIRECT_EGRESS__|$(host_direct_egress "$host")|" \
            "$SERVER_SNIPPET" >"$snippet"
        printf '%s: ' "$(host_label "$host")"
        if ! run_timeout 60 /usr/bin/scp -q -o BatchMode=yes -o ConnectTimeout=25 \
            "$snippet" "$BIN_DIR/patch-server-bashrc.py" \
            "$(host_shell "$host"):" >/dev/null 2>&1; then
            echo 'upload failed'; rc=1; continue
        fi
        run_timeout 60 /usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=25 \
            "$(host_shell "$host")" \
            "mv -f ~/.snippet-$host ~/.reverse-proxy.sh && chmod 600 ~/.reverse-proxy.sh && python3 ~/patch-server-bashrc.py && rm -f ~/patch-server-bashrc.py" \
            || rc=1
        rm -f "$snippet"
    done
    return $rc
}

cmd_doctor() {
    local host json
    echo "== local =="
    printf 'runtime version : %s (installed %s)\n' "$RUNTIME_VERSION" "$(installed_version)"
    printf 'route(aTrust)   : %s\n' "$(route_ready && echo ok || echo MISSING)"
    printf 'gateway :%s     : %s\n' "$GATEWAY_PORT" "$(gateway_up && echo ok || echo down)"
    printf 'health  :%s     : %s\n' "$HEALTH_PORT" "$(health_up && echo ok || echo down)"
    for host in $HOSTS; do
        printf 'relay   :%s     : %s (%s)\n' "$(host_relay "$host")" "$(port_open 127.0.0.1 "$(host_relay "$host")" && echo ok || echo down)" "$host"
    done
    printf 'clash   :%s     : %s\n' "$CLASH_PORT" "$(clash_up && echo ok || echo down)"
    printf 'EXIT selector   : %s\n' "$(current_exit)"
    printf 'mihomo binary   : %s\n' "$(find_mihomo || echo MISSING)"
    echo "== launchd =="
    local n
    for n in gateway health monitor tunnel-a100 tunnel-rtx4090; do
        printf '%-16s: loaded=%s running=%s pid=%s\n' "$n" \
            "$(agent_loaded "$n" && echo yes || echo no)" \
            "$(agent_running "$n" && echo yes || echo no)" \
            "$(agent_pid "$n")"
    done
    echo "== tunnels (from logs, no ssh) =="
    json="$(shaper_status_json)"
    for host in $HOSTS; do
        printf '%-9s state:%s port:%s\n' "$(host_label "$host")" "$(tunnel_state "$host")" "$(tunnel_port "$host")"
        printf '          shaping: %s\n' "$(shape_line "$host" "$json")"
        printf '          last: %s\n' "$(tunnel_last_event "$host")"
    done
    echo "== servers (ssh) =="
    for host in $HOSTS; do
        printf '%-9s listen:%s  path:%s\n' "$(host_label "$host")" \
            "$(remote_port_listening "$host" 30 && echo ok || echo no)" \
            "$(remote_path_ok "$host" && echo ok || echo no)"
    done
    echo "== recent log lines =="
    tail -n 8 "$LOG_DIR"/tunnel-*.log "$LOG_DIR"/gateway.log "$LOG_DIR"/health.log 2>/dev/null
}

mkdir -p "$RUN_DIR" "$BIN_DIR" "$LOG_DIR" "$MIHOMO_DIR" 2>/dev/null

# A bundle older than the installed runtime must not win: hand over instead.
if [ "$SELF_PATH" != "$RUNTIME_SCRIPT" ] && [ -x "$RUNTIME_SCRIPT" ]; then
    have="$(installed_version)"
    if [ -n "$have" ] && [ "$have" -gt "$RUNTIME_VERSION" ]; then
        echo "installed runtime v$have is newer than this copy (v$RUNTIME_VERSION); using the installed one" >&2
        exec /bin/bash "$RUNTIME_SCRIPT" "$@"
    fi
fi

case "${1:-status}" in
    usa)     cmd_usa ;;
    china)   cmd_china ;;
    status)  status_block "${2:-0}" ;;
    check)   status_block 2 ;;
    stop)    stop_all; echo 'STOPPED=1'; status_block 0 ;;
    restart)
        install_runtime
        for h in $HOSTS; do restart_agent "$(tunnel_job "$h")"; done
        restart_agent gateway
        sleep 3
        status_block 0
        ;;
    install) install_runtime; echo "installed to $BIN_DIR" ;;
    setup-servers) setup_servers ;;
    logs)    tail -n 60 "$LOG_DIR"/*.log ;;
    doctor)  cmd_doctor ;;
    _tunnel) run_tunnel "${2:?missing host}" ;;
    _monitor) run_monitor ;;
    *)
        echo 'Usage: server-proxy-macos.sh {usa|china|status|check|stop|restart|install|setup-servers|logs|doctor}' >&2
        exit 2
        ;;
esac
