# ~/.reverse-proxy.sh — managed from the Mac by server-proxy-macos.sh.
#
# Sourced from ~/.bashrc *before* the "not running interactively -> return"
# guard.  That is the whole point: VS Code Remote-SSH and Cursor run their
# extension host, git, pip and npm in NON-interactive shells, which the old
# `[[ -t 1 ]]` version skipped entirely — the reason the proxy "worked in the
# terminal but not in the editor".
#
# Hard rule: this file must stay silent on a non-interactive shell.  scp and
# rsync speak a binary protocol over the same stream, and one stray byte of
# output corrupts every transfer.
#
# The __RP_*__ placeholders are filled per server by `setup-servers`, because
# the two boxes differ: A100 reaches Chinese mirrors directly (faster than the
# tunnel, so they bypass it), RTX 4090 has no direct egress at all (bypassing
# would hang), and RTX 4090's resolv.conf lists unreachable public resolvers
# first, which made every lookup wait 8-16 s before the campus DNS answered.

# The tunnel publishes the port it actually managed to claim; these boxes are
# shared and the primary is sometimes taken by a long-running job.
RP_PORT_FILE="$HOME/.reverse-proxy-port"
RP_PORT_DEFAULT=__RP_PORT__
_rp_read_port() {
    local p
    p=$(cat "$RP_PORT_FILE" 2>/dev/null)
    case "$p" in ''|*[!0-9]*) p=$RP_PORT_DEFAULT ;; esac
    printf '%s' "$p"
}
RP_PORT=$(_rp_read_port)
RP_NO_PROXY='__RP_NO_PROXY__'
RP_RES_OPTIONS='__RP_RES_OPTIONS__'
# 1 when the host reaches the internet on its own (A100), 0 when the tunnel is
# the only way out (RTX 4090).
RP_DIRECT_EGRESS='__RP_DIRECT_EGRESS__'

# glibc resolver tuning for hosts whose resolv.conf starts with dead servers.
if [ -n "$RP_RES_OPTIONS" ] && [ -z "${RES_OPTIONS:-}" ]; then
    export RES_OPTIONS="$RP_RES_OPTIONS"
fi

proxy_off() {
    unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
    export no_proxy="$RP_NO_PROXY"
    export NO_PROXY="$RP_NO_PROXY"
}

# A loopback connect is refused instantly when the tunnel is gone, so this is
# cheap enough to run on every shell start.  The bridge closes its listener
# while the Mac does not answer through the tunnel, so "port open" now means
# "path verified within the last minute", not just "a process exists".
_rp_tunnel_up() { (exec 3<>"/dev/tcp/127.0.0.1/$RP_PORT") 2>/dev/null; }

_rp_export() {
    export http_proxy="http://127.0.0.1:$RP_PORT"
    export https_proxy="$http_proxy"
    export all_proxy="socks5h://127.0.0.1:$RP_PORT"
    export HTTP_PROXY="$http_proxy"
    export HTTPS_PROXY="$https_proxy"
    export ALL_PROXY="$all_proxy"
    export no_proxy="$RP_NO_PROXY"
    export NO_PROXY="$RP_NO_PROXY"
}

proxy_on() {
    RP_PORT=$(_rp_read_port)
    if ! _rp_tunnel_up; then
        [ "${1:-}" = --quiet ] || echo "reverse proxy unavailable on 127.0.0.1:$RP_PORT" >&2
        # Where the tunnel is the only way out, keep the variables: a closed
        # port refuses at once, and the shell works again when the tunnel
        # returns.  Dropping them left a terminal opened during a one-minute
        # outage without a proxy for good, and Codex started from it went
        # straight to a DNS-poisoned address for chatgpt.com.
        if [ "$RP_DIRECT_EGRESS" = 1 ]; then proxy_off; else _rp_export; fi
        return 1
    fi
    _rp_export
    [ "${1:-}" = --quiet ] || echo "reverse proxy ON -> 127.0.0.1:$RP_PORT"
}

proxy_status() {
    RP_PORT=$(_rp_read_port)
    if _rp_tunnel_up; then
        printf 'tunnel   : up (127.0.0.1:%s)\n' "$RP_PORT"
        printf 'exit IP  : %s\n' "$(curl -fsS --max-time 25 --proxy "http://127.0.0.1:$RP_PORT" https://api.ipify.org 2>/dev/null || echo unreachable)"
    else
        printf 'tunnel   : down (127.0.0.1:%s)\n' "$RP_PORT"
    fi
    printf 'http_proxy=%s\n' "${http_proxy:-<unset>}"
    printf 'no_proxy =%s\n' "${no_proxy:-<unset>}"
}

# Applies to every SSH session, interactive or not.  Export RP_NO_AUTO=1 to
# opt a single session out.
if [ -n "${SSH_CONNECTION:-}" ] && [ -z "${RP_NO_AUTO:-}" ]; then
    proxy_on --quiet >/dev/null 2>&1 || true   # proxy_on picks the fallback itself
fi
