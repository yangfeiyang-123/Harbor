#!/usr/bin/env python3
"""Expose the SSH-forwarded Unix socket as 127.0.0.1:PORT on the server.

Fed to python over ssh's stdin and run as the tunnel's own remote command, so
there is one process tree and one lifetime: nothing is installed on the server.

Why a Unix socket instead of a plain `-R 127.0.0.1:PORT`:

1.  A100's sshd sets `GatewayPorts yes`, which forces every remote TCP
    forward onto the wildcard address.  A user-owned socket (mode 0600) plus
    this loopback-only listener keeps the proxy off the campus network.
2.  RTX 4090's sshd runs with ClientAlive disabled, so a dead session can hold
    a forwarded TCP port for hours.

Why the socket path is unique per connection (~/.rp-HOST.<epoch>.sock):
sshd refuses to bind a path that already exists, and a dead session keeps its
path for up to 90 s on A100 and indefinitely on RTX 4090.  With a shared path
every reconnect died with "remote port forwarding failed" until an extra ssh
session cleaned up.  A fresh path always binds; this bridge retires its
predecessor (pid file, verified through /proc) and removes old paths itself.

What else this bridge does, and why:

*   Probes the Mac through the tunnel (GET /rp on the gateway's health
    endpoint) and measures the round trip.  Three misses close the listener so
    `proxy_on` fails fast instead of every pip/git/curl hanging on a dead path;
    twelve misses end the process, which ends ssh and lets launchd rebuild the
    tunnel.  The Mac-side watchdog no longer opens ssh sessions to guess.
*   Paces server -> Mac bytes with a token bucket steered by that round trip.
    aTrust queues without limit: one 3 MB transfer pushed the tunnel RTT from
    0.2 s to 15-30 s and stalled every terminal and request behind it.  Sending
    just below what the path carries keeps the queue empty.  The gateway on
    the Mac paces the other direction with the RTT this bridge reports.
*   Keeps two delay targets (v15): 0.4 s of queue while a connection to an
    interactive host (Codex, Claude) used the path in the last 30 s, 1.5 s
    and a faster ramp while only bulk is on it, so transfers get what the
    path carries when nobody is waiting on a round trip.  The probe tells
    the Mac how long ago that was (ia=) and the answer (X-Rp-Ia) says the
    same for every tunnel on the Mac, since they share the aTrust path.
    A single late probe no longer cuts the rate: aTrust jitters that much
    on its own.
*   Grants the same tokens to senders outside the proxy (serve_tokens):
    Harbor's file downloads ask before every slice they write to ssh.
*   Hands those tokens out one small slice per turn: quiet connections first,
    backlogged ones in rotation, and anyone waiting 2 s before newcomers
    (Pacer._next).  One shared first-come bucket let three wandb uploads hold
    every other connection's next packet for 5 s, so Codex's TLS handshakes
    took 11-17 s and its requests timed out.
"""

import collections
import os
import signal
import socket
import sys
import threading
import time

SOCKET_PATH = os.environ["RP_SOCKET"]
HOST = os.environ.get("RP_HOST", "tunnel")
# Ordered candidates, not one hard-coded port: these boxes are shared and a
# long-running job once sat on 11083 for eight days.  The port actually chosen
# is published to PORT_FILE so the shell profile and the Mac read it.
LISTEN_PORTS = [int(x) for x in os.environ["RP_PORTS"].split(",") if x.strip()]
PORT_FILE = os.environ.get("RP_PORT_FILE", os.path.expanduser("~/.reverse-proxy-port"))
PID_FILE = os.environ.get("RP_PID_FILE", os.path.expanduser("~/.rp-%s.pid" % HOST))
HEALTH = os.environ.get("RP_HEALTH", "127.0.0.1:10809")
BIND_RETRY_SECONDS = 90.0
PRIMARY_GRACE = 15.0      # seconds to wait for the primary port before using a fallback

RATE_MIN = int(os.environ.get("RP_RATE_MIN", 4 * 1024))
PAUSE_SECONDS = float(os.environ.get("RP_PAUSE", 8.0))   # sending stops this long after repeated timeouts at the floor
RATE_MAX = int(os.environ.get("RP_RATE_MAX", 8 * 1024 * 1024))
RATE_INIT = int(os.environ.get("RP_RATE_INIT", 32 * 1024))
SLACK_HIGH = 0.40   # target = base + max(0.4 s, base): a probe costs two network round trips, so jitter doubles too
SLACK_BULK = float(os.environ.get("RP_SLACK_BULK", 1.5))   # the slack while nothing interactive used the path lately
INTERACTIVE_WINDOW = float(os.environ.get("RP_INTERACTIVE_WINDOW", 30.0))  # seconds an interactive byte keeps the tight target
INTERACTIVE_HOSTS = tuple(h.strip().lower() for h in os.environ.get(
    "RP_INTERACTIVE_HOSTS", "openai.com,chatgpt.com,anthropic.com,claude.ai").split(",") if h.strip())
DRAIN_SECONDS = 1.5    # bulk is held this long when interactive traffic returns, so the longer queue can empty
GROW_TIGHT = 0.10      # rate increase per probe near the baseline under the tight target
GROW_BULK = 0.25       # the same while only bulk is on the path
GROW_MAX = int(os.environ.get("RP_GROW_MAX", 65536))   # bytes/s added per probe at most: above 256 KB/s the climb is linear
RISE = 0.30            # seconds a sample must exceed its predecessor by to count as a queue in the making
RISE_FROM = GROW_MAX / GROW_BULK   # bytes/s; below this the path's own jitter outweighs anything our rate adds, so a rise means nothing
PROBE_PAUSE_AGE = 6.0  # an unanswered probe this old while at the floor pauses sending
FLOW_HALF_LIFE = 5.0   # seconds; decay of a connection's recent bytes
QUIET_MAX_SLICES = 8   # a new message is quiet only if its connection sent less than this many slices recently
QUIET_MIN_BYTES = 8192 # quiet allowance per message never below this: a TLS server flight must fit at the floor
STARVE_AFTER = 2.0     # seconds; the shortest wait that lets a connection go before everyone who arrived later

PROBE_TIMEOUT = float(os.environ.get("RP_PROBE_TIMEOUT", 45.0))
# Constant cadence: the Mac-side shaper treats a probe that arrives later than
# scheduled as delay evidence, so the schedule must not depend on traffic.
PROBE_INTERVAL = float(os.environ.get("RP_PROBE_INTERVAL", 2.0))
PROBE_IDLE = PROBE_INTERVAL
PROBE_MAX_PENDING = 8
DEGRADE_AFTER = int(os.environ.get("RP_DEGRADE_AFTER", 6))   # consecutive misses before the listener closes
EXIT_AFTER = int(os.environ.get("RP_EXIT_AFTER", 40))        # consecutive misses before ssh is allowed to die


def log(message):
    # stderr is the ssh session.  Once that is gone a write raises, and the two places that say
    # why the bridge is about to exit would never get as far as exiting.
    try:
        sys.stderr.write("bridge: %s\n" % message)
        sys.stderr.flush()
    except (OSError, ValueError):
        pass


def human(rate):
    if rate >= 1024 * 1024:
        return "%.1fM/s" % (rate / 1024.0 / 1024.0)
    return "%dK/s" % (rate / 1024.0)


class Flow:
    """One connection's place in a pacer: recent bytes (decaying with FLOW_HALF_LIFE) and turn state."""

    __slots__ = ("sent", "stamp", "waiting_since", "wake", "idle", "quiet_left", "new_read", "pause_limit", "interactive")

    def __init__(self):
        self.sent = 0.0
        self.stamp = time.monotonic()
        self.waiting_since = 0.0
        self.wake = None         # Condition on the pacer's lock, created on first use
        self.idle = True         # nothing was queued before the next bytes (pump sets it; a new connection starts idle)
        self.quiet_left = 0      # bytes of the current message still sent in the quiet class
        self.new_read = True     # the next consume starts a new read (pump sets it)
        self.pause_limit = 0.0   # a pause holds the current read until then
        self.interactive = None  # True once the first bytes named an interactive host; None until they were seen

    def recent(self, now):
        return self.sent * 0.5 ** ((now - self.stamp) / FLOW_HALF_LIFE)

    def charge(self, n, now):
        self.sent = self.recent(now) + n
        self.stamp = now


class Pacer:
    """Delay-steered token bucket: gentle increase, multiplicative decrease.

    Every probe through the tunnel yields a round trip; the lowest recent
    value is the empty-queue baseline, and the target is that baseline plus
    a slack.  While bytes flow and probes come back under the target, the
    rate grows per probe, scaled by how far below the target the delay sits
    (nothing left to gain once it approaches the target).  It shrinks when
    the delay stands over the target (x0.7) or exceeds it by 2 s (x0.4), at
    most once every 2 s, and drops to the floor on a timeout.

    Two targets (runtime v15).  While something interactive used the path
    in the last INTERACTIVE_WINDOW seconds -- a connection whose first
    bytes named one of INTERACTIVE_HOSTS, such as Codex talking to
    chatgpt.com -- the slack is SLACK_HIGH (0.4 s), so its requests wait
    behind at most that much queue.  Otherwise only bulk is on the path
    (wandb uploads, pip, Harbor's file transfers), nobody is waiting on a
    round trip, and the slack is SLACK_BULK (1.5 s) with a faster increase:
    a longer standing queue costs nothing there and lets the rate find what
    the path carries.  When interactive traffic returns the rate halves and
    bulk is held for DRAIN_SECONDS, so that queue empties first.

    One sample over the target is not evidence (`_over`).  aTrust adds
    0.5-1.5 s to a single round trip on its own several times a minute, at
    any load; up to v14 each of those cut the rate by 30 % and the increase
    took eight probes to win it back, so the rate never left the 4-30 KB/s
    band while the path carried ten times that.  A decrease now needs two
    consecutive samples over the target, or one more than 2 s over it.  A
    sample that rose RISE over its predecessor at a rate of RISE_FROM or
    more is a queue in the making even under the target: the rate holds,
    and a late probe right after it does cut.  Below RISE_FROM the same
    rule pinned the rate at the floor for 90 s on 2026-10-03 (jitter rose
    by that much every other probe), so it does not apply there.  Above
    256 KB/s the increase is a fixed GROW_MAX per probe: on 2026-10-02 a
    25 % climb went from 285 to 548 KB/s in two probes on a path that
    carries about 300, and aTrust answered with a 30 s round trip that
    took a minute to clear.

    The delay estimate is not only the last completed round trip.  A probe
    that is still outstanding longer than the target is already evidence of
    a queue, so its age counts too (`pressure`).  Waiting for it to come
    back was the failure of the first version: by the time a 15 s answer
    arrived, the rate had been too high for 15 s and the queue held 30 s.
    Samples from probes sent before the last decrease are stale and do not
    trigger another one.

    The path this was built for (aTrust, US <-> campus) carried between 80
    and 440 KB/s one way depending on the hour, so the floor is 4 KB/s and
    the first rate 32 KB/s: four pacers share one pipe.
    """

    def __init__(self, name):
        self.name = name
        self.enabled = os.environ.get("RP_SHAPE", "1") != "0"
        self.rate = float(min(max(RATE_INIT, RATE_MIN), RATE_MAX))
        self.tokens = 0.0
        self.stamp = time.monotonic()
        self.lock = threading.Lock()
        self.wake = threading.Condition(self.lock)
        self.waiting = []
        self.samples = collections.deque(maxlen=120)
        self.moved = 0
        self.moved_at = 0.0
        self.rtt = None
        self.updated = None
        self.peer_rate = None
        self.interval = PROBE_IDLE
        self._last_decrease = 0.0
        self._last_log = 0.0
        self._paused_until = 0.0
        self._pause_began = 0.0
        self._timeouts = 0
        self._last_sample = None     # (completed at, round trip) of the previous probe, for `_over`
        self._rising = False         # that probe rose RISE over its own predecessor: a queue was building
        self._bulk_hold_until = 0.0  # non-quiet flows wait until then once interactive traffic has returned
        self.interactive_at = None   # monotonic time of the last byte to or from an interactive host

    @property
    def burst(self):
        return max(self.rate * 0.25, 16384.0)

    @property
    def chunk(self):
        """Bytes per turn: about 0.1 s at the current rate, never more than the bucket holds."""
        return int(min(65536.0, max(1024.0, self.rate * 0.1)))

    def consume(self, n, flow):
        """Wait for `flow`'s turn and the tokens; return how many of `n` bytes may go now.

        The first version let any caller take the shared bucket into debt and
        made the next caller repay it: a 64 KB wandb write held a 1.5 KB TLS
        handshake for 5 s, once per round trip, and Codex timed out.  Now a
        turn is one slice (`chunk`, sized when it is granted, so a rate drop
        cannot leave debt behind) and only tokens that already exist are spent.
        `_next` decides whose turn it is.

        A pause exists so the path's queue can drain and interactive traffic
        gets through (report/pressure).  So quiet connections are never held
        by it; everyone else is held for PAUSE_SECONDS from the start of the
        pause or of their read, whichever is later, and then sends one slice
        per PAUSE_SECONDS while the pause lasts.  Holding only new reads, as a
        first version did, let backlogged uploads keep sending through the
        pause while every handshake waited 8 s and Codex timed out.
        """
        if n <= 0:
            return 0
        with self.lock:
            now = time.monotonic()
            self.moved_at = now
            if not self.enabled:
                self.moved += n
                return n
            if flow.wake is None:
                flow.wake = threading.Condition(self.lock)
            if flow.interactive:
                old = self.rate
                self._interactive(now, now)
                if self._settle(old, now):
                    self._log(old, "interactive traffic")
            if flow.new_read:
                flow.new_read = False
                flow.pause_limit = now + PAUSE_SECONDS
            if flow.idle:
                # Everything this connection had was sent before these bytes
                # arrived: a new message, not the tail of a backlog.  An upload
                # that stops between flow-control windows looks the same, but
                # it has sent too much recently to count as quiet.
                flow.idle = False
                if flow.recent(now) < QUIET_MAX_SLICES * self.chunk:
                    flow.quiet_left = max(2 * self.chunk, QUIET_MIN_BYTES)
            flow.waiting_since = now
            self.waiting.append(flow)
            try:
                while True:
                    now = time.monotonic()
                    self.tokens = min(self.tokens + (now - self.stamp) * self.rate, self.burst)
                    self.stamp = now
                    head = self._next(now)
                    if head is None:
                        # A pause or a drain holds every waiter: sleep until
                        # the first held read may go.
                        until = min(self._held_until(f, now) for f in self.waiting)
                        flow.wake.wait(max(0.01, until - now))
                        continue
                    if head is not flow:
                        # Priorities shift with time (aging, decay, pause
                        # limits), so the head may not know it is the head.
                        head.wake.notify()
                        timeout = 2.0
                        if self._holding(now):
                            # Nobody is told when a hold expires; wake for it.
                            held = self._held_until(flow, now)
                            if held > now:
                                timeout = min(timeout, held - now)
                        flow.wake.wait(timeout)
                        continue
                    take = min(n, self.chunk)
                    if self.tokens >= take:
                        self.tokens -= take
                        self.moved += take
                        if self._paused_until > now and flow.quiet_left <= 0:
                            flow.pause_limit = now + PAUSE_SECONDS
                        flow.quiet_left = max(0, flow.quiet_left - take)
                        flow.charge(take, now)
                        return take
                    flow.wake.wait(min((take - self.tokens) / self.rate, 0.5))
            finally:
                self.waiting.remove(flow)
                self._kick(time.monotonic())

    def _pause(self, now):
        """Lock held.  Start or extend a pause."""
        if self._paused_until <= now:
            self._pause_began = now
        self._paused_until = max(self._paused_until, now + PAUSE_SECONDS)

    def _holding(self, now):
        """Lock held.  True while a pause or a drain holds non-quiet flows."""
        return self._paused_until > now or self._bulk_hold_until > now

    def _held_until(self, f, now):
        """Lock held.  When `f` may send again under a pause or a drain; quiet connections are never held."""
        if f.quiet_left > 0:
            return 0.0
        until = self._bulk_hold_until
        if self._paused_until > now:
            until = max(until, f.pause_limit, self._pause_began + PAUSE_SECONDS)
        return until

    def _kick(self, now):
        """Lock held.  Wake the connection whose turn it is, if any."""
        head = self._next(now) if self.waiting else None
        if head is not None:
            head.wake.notify()

    def _next(self, now):
        """Lock held.  The waiting connection whose turn it is; None while a pause or a drain holds them all.

        During a pause or a drain, connections held by it (`_held_until`) are skipped.
        Among the rest:

        1. Anyone who has waited longer than STARVE_AFTER and than two full
           rotations of the current waiters, oldest first, so a stream of new
           connections cannot shut out an established one.  Waiting through
           an ordinary rotation is not starvation: with dozens of backlogged
           uploads a turn comes round only every few seconds, and counting
           that as starvation put every upload ahead of every handshake.
        2. Quiet connections, fewest recent bytes first, for two slices of
           each new message: new connections, and connections whose socket
           was empty before the message (pump notices) and that sent little
           recently.  That covers handshakes, keystrokes, and requests and
           answers on a long-lived connection such as Codex's.  A backlogged
           upload never finds its socket empty, and the two-slice limit keeps
           new downloads from stalling a streamed answer.
        3. Everyone else in arrival order: one slice each in turn.
        """
        holding = self._holding(now)
        starved = max(STARVE_AFTER, 2.0 * len(self.waiting) * self.chunk / self.rate)
        best, best_key = None, None
        for f in self.waiting:
            if holding and self._held_until(f, now) > now:
                continue
            if now - f.waiting_since >= starved:
                key = (0, 0.0, f.waiting_since)
            elif f.quiet_left > 0:
                key = (1, f.recent(now), f.waiting_since)
            else:
                key = (2, 0.0, f.waiting_since)
            if best_key is None or key < best_key:
                best, best_key = f, key
        return best

    def busy(self, within=6.0):
        with self.lock:
            return time.monotonic() - self.moved_at < within

    def relaxed(self, now):
        """True while nothing interactive used the path for INTERACTIVE_WINDOW: bulk may hold a longer queue."""
        return self.interactive_at is None or now - self.interactive_at >= INTERACTIVE_WINDOW

    def _target(self, now):
        """Lock held.  Delay above which a queue is assumed; None before the first sample."""
        if not self.samples:
            return None
        base = min(self.samples)
        return base + max(SLACK_BULK if self.relaxed(now) else SLACK_HIGH, base)

    def _over(self, delay, now, margin=0.0):
        """Lock held.  True when `delay` is evidence of a standing queue.

        One round trip over the target is not: aTrust adds 0.5-1.5 s to a
        single probe on its own several times a minute, at any load.  A
        queue our bytes built is still there at the next probe, so it takes
        two consecutive samples over the target -- or one more than 2 s
        over it, which no jitter explains and which must not wait -- or
        one over it right after a sample that rose by RISE, because a
        rising round trip under the target is a queue already building.
        """
        target = self._target(now)
        if target is None or delay <= target + margin:
            return False
        if delay > target + margin + 2.0:
            return True
        prev = self._last_sample
        return prev is not None and now - prev[0] <= 2.5 * PROBE_IDLE and (
            prev[1] > target or (self._rising and self.rate >= RISE_FROM))

    def _shrink(self, delay, sent_at, now, margin=0.0):
        """Lock held.  True when the delay called for a decrease (applied or in hold-off)."""
        if not self._over(delay, now, margin):
            return False
        if sent_at < self._last_decrease or now - self._last_decrease < 2.0:
            return True
        factor = 0.4 if delay > self._target(now) + 2.0 else 0.7
        self.rate = max(float(RATE_MIN), self.rate * factor)
        self._last_decrease = now
        return True

    def interactive_seen(self, stamp):
        """Bytes to or from an interactive host at monotonic time `stamp` (seen here, or reported by the peer)."""
        with self.lock:
            now = time.monotonic()
            old = self.rate
            self._interactive(stamp, now)
            announce = self._settle(old, now)
        if announce:
            self._log(old, "interactive traffic")

    def interactive_age(self):
        """Seconds since the last interactive byte, or None; the bridge reports it to the Mac with each probe."""
        with self.lock:
            return None if self.interactive_at is None else max(0.0, time.monotonic() - self.interactive_at)

    def _interactive(self, stamp, now):
        """Lock held.  Note interactive traffic at `stamp`.

        Its return after INTERACTIVE_WINDOW switches the target from
        SLACK_BULK to SLACK_HIGH.  The queue the relaxed target allowed is
        still on the path, so the rate halves and non-quiet flows are held
        for DRAIN_SECONDS: the interactive connection's own bytes go at
        once, and the queue in front of them empties instead of growing.
        """
        if self.interactive_at is not None and stamp <= self.interactive_at:
            return
        if self.relaxed(now) and now - stamp < INTERACTIVE_WINDOW:
            # A mark that is already outside the window changes nothing.
            self.rate = max(float(RATE_MIN), self.rate * 0.5)
            self._last_decrease = now
            self._bulk_hold_until = max(self._bulk_hold_until, now + DRAIN_SECONDS)
        self.interactive_at = stamp

    def _settle(self, old, now):
        self.tokens = min(self.tokens, self.burst)
        # The rate or pause just changed: let the connection whose turn it is
        # recompute now, and never depend on its timed wait alone.
        self._kick(now)
        announce = abs(self.rate - old) >= old * 0.25 and now - self._last_log > 30
        if announce:
            self._last_log = now
        return announce

    def report(self, rtt):
        """A completed probe: seconds, or None for a timeout."""
        with self.lock:
            now = time.monotonic()
            moved, self.moved = self.moved, 0
            self.rtt = rtt
            self.updated = now
            old = self.rate
            if rtt is None:
                # A timeout at the floor means even the floor is too much for
                # the path right now: stop sending for a while so the queue
                # can drain and interactive sessions get through.
                self._timeouts += 1
                if self.rate <= RATE_MIN and self._timeouts >= 2:
                    self._pause(now)
                self.rate = float(RATE_MIN)
                self._last_decrease = now
            else:
                self._timeouts = 0
                self.samples.append(rtt)
                base = min(self.samples)
                target = self._target(now)
                sent_at = now - rtt
                prev = self._last_sample
                rose = prev is not None and now - prev[0] <= 2.5 * PROBE_IDLE and rtt - prev[1] >= RISE
                if self._shrink(rtt, sent_at, now):
                    pass
                elif moved == 0:
                    # Idle: drift back toward the starting rate so traffic that
                    # resumes later does not burst at a stale high rate.
                    self.rate = max(float(min(RATE_INIT, self.rate)), self.rate * 0.95)
                elif rose and self.rate >= RISE_FROM:
                    pass   # the round trip is climbing at this rate: hold it
                elif sent_at > self._last_decrease and now - self._last_decrease > 3.0:
                    gain = max(0.0, min(1.0, (target - rtt) / (target - base)))  # 1 at the baseline, 0 at the target
                    if gain > 0:
                        # At least 8 KB/s per probe near the baseline, so a
                        # pacer parked at the floor recovers in seconds, not
                        # minutes; a quarter per probe while only bulk is on
                        # the path, so a transfer reaches 300 KB/s in 30 s;
                        # never more than GROW_MAX, so one probe's lag cannot
                        # push the path far past what it carries.
                        grow = GROW_BULK if self.relaxed(now) else GROW_TIGHT
                        step = min(float(GROW_MAX), max(8192.0, self.rate * grow)) * gain
                        self.rate = min(float(RATE_MAX), self.rate + step)
                self._last_sample = (now, rtt)
                self._rising = rose
            announce = self._settle(old, now)
        if announce:
            self._log(old, "timeout" if rtt is None else "%.2fs" % rtt)

    def pressure(self, age):
        """Delay evidence from a probe that has been outstanding for `age` seconds."""
        with self.lock:
            now = time.monotonic()
            old = self.rate
            # An outstanding probe is a weaker signal than a completed one
            # (it may still return on time), so it needs half a second more.
            self._shrink(age, now - age, now, margin=0.5)
            if self.rate <= RATE_MIN and age > PROBE_PAUSE_AGE:
                self._pause(now)
            announce = self._settle(old, now)
        if announce:
            self._log(old, "%.1fs outstanding" % age)

    def _log(self, old, why):
        log("%s rate %s -> %s (%s, base %.2fs, %s target)" % (
            self.name, human(old), human(self.rate), why,
            min(self.samples) if self.samples else 0.0,
            "bulk" if self.relaxed(time.monotonic()) else "tight"))

    def describe(self):
        with self.lock:
            now = time.monotonic()
            return {
                "rate": int(self.rate) if self.enabled else None,
                "peer_rate": self.peer_rate,
                "rtt": self.rtt,
                "base": min(self.samples) if self.samples else None,
                "target": round(self._target(now), 2) if self.samples else None,
                "mode": "bulk" if self.relaxed(now) else "tight",
                "age": None if self.updated is None else round(now - self.updated, 1),
            }


PACER = Pacer(HOST)


# ------------------------------------------------------------------ plumbing

def interactive_request(data):
    """True when the first bytes of a proxied connection name an interactive host.

    HTTP proxy clients open with `CONNECT host:port HTTP/1.1` or a request
    with an absolute URI; that is what http_proxy/https_proxy produce for
    Codex, Claude Code, pip and curl.  SOCKS clients send their destination
    in a later message and are not recognised (they count as bulk).
    """
    line = data.split(b"\n", 1)[0].rstrip(b"\r")
    parts = line.split(b" ")
    if len(parts) < 2:
        return False
    target = parts[1]
    if parts[0].upper() == b"CONNECT":
        host = target.rsplit(b":", 1)[0]
    elif b"://" in target:
        host = target.split(b"://", 1)[1].split(b"/", 1)[0].rsplit(b":", 1)[0]
    else:
        return False
    host = host.strip(b"[]").decode("ascii", "replace").lower()
    return any(host == h or host.endswith("." + h) for h in INTERACTIVE_HOSTS)


def pump(src, dst, pacer, flow=None):
    if flow is None:
        flow = Flow()
    # MSG_DONTWAIT on a socket with a timeout waits out the whole timeout, so
    # the empty-socket check is only made on blocking sockets (all of ours).
    check_idle = pacer is not None and src.gettimeout() is None
    first = True
    try:
        while True:
            if check_idle:
                try:
                    data = src.recv(65536, socket.MSG_DONTWAIT)
                except BlockingIOError:
                    flow.idle = True
                    data = src.recv(65536)
            else:
                data = src.recv(65536)
            if not data:
                break
            if pacer is None:
                dst.sendall(data)
                continue
            if first:
                first = False
                if flow.interactive is None:
                    # The proxy client's first bytes name its destination.
                    flow.interactive = interactive_request(data)
            flow.new_read = True
            view = memoryview(data)
            while view:
                granted = pacer.consume(len(view), flow)
                dst.sendall(view[:granted])
                view = view[granted:]
    except OSError:
        pass
    finally:
        for sock in (src, dst):
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


TOKEN_HELLO = b"RP-TAKE\n"
TOKEN_MAX = 1 << 20


def serve_tokens(sock, pacer, buf=b""):
    """Grant this pacer's tokens to a transfer that travels outside the proxy.

    Harbor's own file transfers ride its ssh connection, so the bucket never
    saw them: one 500 MB upload filled aTrust's queue, the tunnel RTT went to
    21 s and Codex on the server timed out for half an hour.  Such a sender
    now opens a connection here, says TOKEN_HELLO, asks for N bytes ("N\n")
    before each slice and sends only what it is granted ("G\n").  To the
    scheduler it is one more backlogged connection: quiet connections still
    go first, the rate controller sees its bytes and can grow past the idle
    rate, and a pause holds it like any other bulk flow.
    """
    flow = Flow()
    try:
        while True:
            while b"\n" not in buf:
                if len(buf) > 64:
                    return
                data = sock.recv(4096)
                if not data:
                    return
                buf += data
            line, buf = buf.split(b"\n", 1)
            want = int(line)
            if not 0 < want <= TOKEN_MAX:
                return
            flow.new_read = True
            sock.sendall(b"%d\n" % pacer.consume(want, flow))
    except (OSError, ValueError):
        pass
    finally:
        try:
            sock.close()
        except OSError:
            pass


def handle(client):
    # A proxy client always speaks first, so waiting for its first bytes costs
    # nothing; MSG_PEEK leaves them for pump.
    try:
        head = client.recv(len(TOKEN_HELLO), socket.MSG_PEEK)
        for _ in range(40):
            if not head or len(head) == len(TOKEN_HELLO) or not TOKEN_HELLO.startswith(head):
                break
            time.sleep(0.05)   # the start of a hello: the rest is a segment behind
            head = client.recv(len(TOKEN_HELLO), socket.MSG_PEEK)
        hello = head == TOKEN_HELLO
    except OSError:
        hello = False
    if hello:
        client.recv(len(TOKEN_HELLO))
        serve_tokens(client, PACER)
        return
    try:
        upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        # Small kernel buffers keep the backlog in front of sshd short, so the
        # bucket, not the kernel, decides how much is in flight.
        upstream.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 262144)
        upstream.connect(SOCKET_PATH)
    except OSError:
        client.close()
        return
    threading.Thread(target=pump, args=(upstream, client, None), daemon=True).start()
    pump(client, upstream, PACER)
    client.close()
    upstream.close()


def wait_for_socket(timeout=30.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if os.path.exists(SOCKET_PATH):
            try:
                probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                probe.settimeout(2)
                probe.connect(SOCKET_PATH)
                probe.close()
                return True
            except OSError:
                pass
        time.sleep(0.25)
    return False


def try_bind(port):
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 262144)
    try:
        listener.bind(("127.0.0.1", port))
        listener.listen(128)
        # The accept loop looks up once a second, so a listener that was closed
        # under it is let go even where shutdown() does not end the accept.
        listener.settimeout(1.0)
        return listener
    except OSError:
        listener.close()
        return None


def publish_port(port):
    try:
        tmp = "%s.%d.%d.new" % (PORT_FILE, os.getpid(), threading.get_ident())
        with open(tmp, "w") as fh:
            fh.write("%d\n" % port)
        os.replace(tmp, PORT_FILE)
    except OSError as exc:
        log("cannot write %s (%s)" % (PORT_FILE, exc))


# -------------------------------------------------------------- predecessor

def pid_is_bridge(pid):
    """True only for a process that carries our RP_HOST in its environment."""
    try:
        with open("/proc/%d/environ" % pid, "rb") as fh:
            entries = fh.read().split(b"\0")
    except OSError:
        return False
    return ("RP_HOST=%s" % HOST).encode() in entries


def predecessors():
    """Every other bridge for this host, found by RP_HOST in /proc/*/environ.

    The pid file alone is not enough: on RTX 4090 sshd runs without
    ClientAlive, so a bridge whose ssh died uncleanly lives on until its own
    probes give up, and by then the pid file names a newer bridge.
    """
    found = set()
    try:
        with open(PID_FILE) as fh:
            found.add(int(fh.read().strip()))
    except (OSError, ValueError):
        pass
    try:
        for name in os.listdir("/proc"):
            if name.isdigit():
                found.add(int(name))
    except OSError:
        pass
    me = os.getpid()
    return sorted(pid for pid in found if pid != me and pid_is_bridge(pid))


def retire_predecessor():
    victims = predecessors()
    for pid in victims:
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
    deadline = time.time() + 5
    alive = list(victims)
    while alive and time.time() < deadline:
        for pid in list(alive):
            try:
                os.kill(pid, 0)
            except OSError:
                alive.remove(pid)
        time.sleep(0.1)
    for pid in alive:
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
    if victims:
        log("retired %d previous bridge(s)" % len(victims))
    directory = os.path.dirname(SOCKET_PATH) or "."
    stale = 0
    try:
        names = os.listdir(directory)
    except OSError:
        names = []
    for name in names:
        if name == ".rp-%s.sock" % HOST or (name.startswith(".rp-%s." % HOST) and name.endswith(".sock")):
            path = os.path.join(directory, name)
            if path != SOCKET_PATH:
                try:
                    os.unlink(path)
                    stale += 1
                except OSError:
                    pass
    if stale:
        log("removed %d stale socket path(s)" % stale)
    try:
        with open(PID_FILE, "w") as fh:
            fh.write("%d\n" % os.getpid())
    except OSError as exc:
        log("cannot write %s (%s)" % (PID_FILE, exc))


def release_pid_file():
    try:
        with open(PID_FILE) as fh:
            mine = fh.read().strip() == str(os.getpid())
    except OSError:
        mine = False
    if mine:
        try:
            os.unlink(PID_FILE)
        except OSError:
            pass


# ------------------------------------------------------------------- bridge

class Bridge:
    def __init__(self):
        self.lock = threading.Lock()          # guards listener/port
        self.state_lock = threading.Lock()    # serialises degrade/restore transitions
        self.listener = None
        self.port = None
        self.degraded = False
        self.stopping = False

    def open(self, retry_seconds):
        """Bind the primary port if at all possible; only a foreign holder moves us on.

        Long-running jobs bake http_proxy=127.0.0.1:<primary> into their
        environment when they start, so landing on a fallback port after a
        reconnect silently cuts them off.  The usual holder of the primary is
        our own predecessor, which is retired above and exits within a few
        seconds, so the primary (or, on a restore, the port we already had)
        is retried for a grace period first.
        """
        deadline = time.time() + retry_seconds
        preferred = LISTEN_PORTS[0] if self.port is None else self.port
        preferred_until = time.time() + min(PRIMARY_GRACE, retry_seconds)
        while True:
            if time.time() < preferred_until:
                candidates = [preferred]
            else:
                candidates = [preferred] + [p for p in LISTEN_PORTS if p != preferred]
            for port in candidates:
                listener = try_bind(port)
                if listener is not None:
                    with self.lock:
                        self.listener, self.port = listener, port
                    publish_port(port)
                    return True
            if time.time() >= deadline:
                log("no free port among %s" % ",".join(str(p) for p in LISTEN_PORTS))
                return False
            time.sleep(1)

    def close(self):
        with self.lock:
            listener, self.listener = self.listener, None
        if listener is not None:
            # close() alone does not end an accept() that another thread is
            # blocked in: the kernel keeps the socket listening until that call
            # returns, which is when the next client connects.  Through a quiet
            # outage the port therefore stayed taken by our own closed
            # listener, the restore could not bind it within the grace period
            # and moved to a fallback, and every program that had started with
            # the old port in its environment was cut off for good (RTX 4090,
            # 2026-10-05: 11083 -> 11084).  shutdown() ends the accept at once.
            try:
                listener.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                listener.close()
            except OSError:
                pass

    def set_degraded(self, flag):
        # Probe threads finish concurrently; without this lock two of them
        # restored at once, the second bind lost the primary port and the
        # first listener was silently dropped.
        with self.state_lock:
            if flag and not self.degraded:
                self.degraded = True
                self.close()
                log("no answer from the Mac through the tunnel; refusing new connections until it returns")
            elif not flag and self.degraded:
                if self.open(20):
                    self.degraded = False
                    log("restored port=%d" % self.port)

    def shutdown(self):
        self.stopping = True
        self.close()
        release_pid_file()


BRIDGE = Bridge()


def probe(last, interval):
    """One request through the tunnel to the Mac's health endpoint; seconds or None."""
    started = time.monotonic()
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(PROBE_TIMEOUT)
    ok = False
    try:
        sock.connect(SOCKET_PATH)
        age = PACER.interactive_age()
        request = ("GET http://%s/rp?host=%s&rtt=%s&rate=%d&interval=%d&ia=%s HTTP/1.1\r\n"
                   "Host: %s\r\nConnection: close\r\n\r\n"
                   % (HEALTH, HOST, last, int(PACER.rate), int(interval),
                      "none" if age is None else "%.1f" % age, HEALTH))
        sock.sendall(request.encode())
        head = b""
        while b"\r\n\r\n" not in head and len(head) < 4096:
            chunk = sock.recv(4096)
            if not chunk:
                break
            head += chunk
        ok = head.startswith(b"HTTP/1.") and head.split(b"\r\n", 1)[0].split(b" ")[1:2] == [b"204"]
        if ok:
            # The Mac answers with how long ago any of its tunnels carried
            # interactive traffic: they all share the aTrust path, so Codex on
            # the other server tightens this pacer too.
            for line in head.split(b"\r\n")[1:]:
                name, _, value = line.partition(b":")
                if name.strip().lower() == b"x-rp-ia":
                    try:
                        # The age was taken after this probe left, so `started` is a
                        # safe lower bound; using arrival time would make the mark
                        # younger by one transit every time it crosses the tunnel.
                        PACER.interactive_seen(started - float(value.strip()))
                    except ValueError:
                        pass
                    break
    except (OSError, IndexError):
        ok = False
    finally:
        sock.close()
    return time.monotonic() - started if ok else None


class Prober:
    """Probes on a fixed cadence without waiting for answers.

    Each probe runs in its own thread and reports when it returns; the
    controller loop meanwhile feeds the age of the oldest unanswered probe
    to the pacer as delay pressure.  Consecutive misses first close the
    listener (shells fail fast) and eventually end the process so launchd
    rebuilds the tunnel.
    """

    def __init__(self):
        self.lock = threading.Lock()
        self.pending = {}
        self.misses = 0
        self.last = "none"
        self.serial = 0

    def _one(self, serial, interval):
        rtt = probe(self.last, interval)
        with self.lock:
            self.pending.pop(serial, None)
            self.last = "timeout" if rtt is None else "%.3f" % rtt
            if rtt is None:
                self.misses += 1
                misses = self.misses
            else:
                self.misses = 0
                misses = 0
        PACER.report(rtt)
        if misses == 0:
            BRIDGE.set_degraded(False)
        elif misses >= EXIT_AFTER:
            log("no answer from the Mac through the tunnel (%d checks), exiting" % misses)
            BRIDGE.shutdown()
            os._exit(1)
        elif misses >= DEGRADE_AFTER:
            BRIDGE.set_degraded(True)

    def run(self):
        last_sent = 0.0
        while not BRIDGE.stopping:
            now = time.monotonic()
            interval = PROBE_INTERVAL
            with self.lock:
                pending = len(self.pending)
                oldest = min(self.pending.values()) if self.pending else None
            if now - last_sent >= interval and pending < PROBE_MAX_PENDING:
                self.serial += 1
                with self.lock:
                    self.pending[self.serial] = now
                threading.Thread(target=self._one, args=(self.serial, interval), daemon=True).start()
                last_sent = now
            if oldest is not None:
                PACER.pressure(now - oldest)
            time.sleep(1.0)


def guard():
    """Exit when the forward is gone (socket path removed by sshd)."""
    misses = 0
    while not BRIDGE.stopping:
        time.sleep(3)
        if os.path.exists(SOCKET_PATH):
            misses = 0
            continue
        misses += 1
        if misses >= 3:
            log("ssh unix socket disappeared, exiting")
            BRIDGE.shutdown()
            os._exit(1)


def main():
    def stop(*_):
        BRIDGE.shutdown()
        raise SystemExit(0)

    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(sig, stop)
    retire_predecessor()
    if not wait_for_socket():
        log("ssh unix socket never appeared: %s" % SOCKET_PATH)
        return 1
    if not BRIDGE.open(BIND_RETRY_SECONDS):
        return 1
    log("ready port=%d socket=%s pacing=%s" % (BRIDGE.port, SOCKET_PATH, "on" if PACER.enabled else "off"))
    threading.Thread(target=guard, daemon=True).start()
    threading.Thread(target=Prober().run, daemon=True).start()
    accept_loop()
    return 0


def accept_loop(serve=None):
    """Hand each connection to its own thread, on whichever listener is current."""
    serve = serve or handle
    while not BRIDGE.stopping:
        with BRIDGE.lock:
            listener = BRIDGE.listener
        if listener is None:
            time.sleep(0.5)
            continue
        try:
            client, _ = listener.accept()
        except OSError:      # the one-second timeout, or the listener was closed
            continue
        try:
            client.setblocking(True)
            client.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass
        threading.Thread(target=serve, args=(client,), daemon=True).start()


if __name__ == "__main__":
    try:
        sys.exit(main())
    finally:
        release_pid_file()
