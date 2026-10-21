#!/usr/bin/env python3
"""Mac-side tunnel gateway: health endpoint plus one paced relay per tunnel.

Each reverse tunnel forwards its server-side socket to a relay port here
(a100 -> 10811, rtx4090 -> 10812) instead of straight into mihomo (10810).
The relay copies bytes both ways.  In the Mac -> server direction it paces
them with a token bucket whose rate follows the round-trip time that the
server's bridge measures through the tunnel and reports on every probe
(GET /rp?host=..&rtt=..).

Why: aTrust queues without limit.  A single 3 MB transfer pushed the
tunnel's RTT from 0.2 s to 15-30 s (qa/reverse-proxy-2026-09-13), and
every terminal, editor and proxied request waited behind it.  Sending just
below what the path can carry keeps that queue empty; the bridge applies
the same rule to server -> Mac traffic (wandb uploads and friends).

The tokens go out one small slice per turn: quiet connections first,
backlogged ones in rotation (Pacer._next).  A bulk download delays a TLS
handshake or a streamed Codex answer by a slice or two, not by seconds.

Two delay targets (v15): 0.4 s of queue while a connection to an
interactive host (Codex, Claude) used the path in the last 30 s -- seen
here in the CONNECT line, or reported by the bridge (ia=) -- and 1.5 s
with a faster ramp while only bulk is on it, so Harbor's uploads get
what the path carries when nobody is waiting on a round trip.  Every
tunnel rides the same aTrust path, so the mark is shared across relays
(share_interactive) and handed back to each bridge (X-Rp-Ia).

GET /            -> 204   liveness, used by remote_path_ok and Harbor's probe
GET /rp?host=..  -> 204   records the bridge's RTT / rate sample and how long ago it saw interactive
                          traffic; answers with X-Rp-Ia, the same for all tunnels on this Mac
GET /status      -> 200   JSON with the current rate, relay port and server address of every relay

A relay port also answers TOKEN_HELLO (serve_tokens): Harbor takes upload
tokens there, so its file transfers share the bucket instead of bypassing it.
"""

import argparse
import collections
import errno
import json
import os
import signal
import socket
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

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
PROBE_IDLE = 2.0    # bridge probe cadence; a later arrival counts as delay
FLOW_HALF_LIFE = 5.0   # seconds; decay of a connection's recent bytes
QUIET_MAX_SLICES = 8   # a new message is quiet only if its connection sent less than this many slices recently
QUIET_MIN_BYTES = 8192 # quiet allowance per message never below this: a TLS server flight must fit at the floor
STARVE_AFTER = 2.0     # seconds; the shortest wait that lets a connection go before everyone who arrived later


def log(message):
    sys.stderr.write("%s shaper: %s\n" % (time.strftime("%H:%M:%S"), message))
    sys.stderr.flush()


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


PACERS = {}
RELAYS = {}   # name -> {"port": relay port here, "host": the server's address}, shown in /status
HEALTH_PORT = 10809


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


def relay(client, pacer, upstream_addr):
    try:
        first = client.recv(65536)
        while first and len(first) < len(TOKEN_HELLO) and TOKEN_HELLO.startswith(first):
            more = client.recv(65536)   # the start of a hello: the rest is a segment behind
            if not more:
                break
            first += more
    except OSError:
        first = b""
    if first.startswith(TOKEN_HELLO):
        # Harbor on this Mac, about to upload through its own ssh connection.
        serve_tokens(client, pacer, first[len(TOKEN_HELLO):])
        return
    if not first:
        client.close()
        return
    try:
        upstream = socket.create_connection(upstream_addr, timeout=10)
        upstream.settimeout(None)
    except OSError:
        client.close()
        return
    # The first bytes from the tunnel side reveal the bridge's own probe.  It
    # must not wait behind the bucket, or it would measure this shaper instead
    # of aTrust and the controller would chase its own tail.
    control = first.startswith(b"GET http://127.0.0.1:%d/" % HEALTH_PORT)
    flow = Flow()
    flow.interactive = interactive_request(first)   # the CONNECT line travels the unpaced way
    try:
        upstream.sendall(first)
    except OSError:
        client.close()
        upstream.close()
        return
    threading.Thread(target=pump, args=(client, upstream, None), daemon=True).start()
    pump(upstream, client, None if control else pacer, flow)
    client.close()
    upstream.close()


def serve_relay(listener, pacer, upstream_addr):
    while True:
        try:
            client, _ = listener.accept()
        except OSError as error:
            # Out of descriptors for a moment (many connections at once) must not end this relay:
            # its port stayed open with nobody behind it, which nothing here noticed.  A listener
            # that is itself gone ends the whole shaper, and launchd starts it again.
            if error.errno in (errno.EBADF, errno.EINVAL, errno.ENOTSOCK):
                log("relay listener lost (%s), exiting" % error)
                os._exit(1)
            time.sleep(0.05)
            continue
        try:
            client.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass
        threading.Thread(target=relay, args=(client, pacer, upstream_addr), daemon=True).start()


class HealthHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urllib.parse.urlsplit(self.path)
        if parsed.path == "/status":
            # Harbor finds a server's relay by "host" and takes upload tokens on "port".
            body = json.dumps({name: dict(pacer.describe(), **RELAYS[name]) for name, pacer in PACERS.items()}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
            return
        if parsed.path == "/rp":
            query = urllib.parse.parse_qs(parsed.query)
            pacer = PACERS.get(query.get("host", [""])[0])
            if pacer is not None:
                rtt = query.get("rtt", [""])[0]
                if rtt == "timeout":
                    pacer.report(None)
                else:
                    try:
                        pacer.report(max(0.0, float(rtt)))
                    except ValueError:
                        pass
                rate = query.get("rate", [""])[0]
                if rate.isdigit():
                    pacer.peer_rate = int(rate)
                try:
                    pacer.interval = max(1.0, float(query.get("interval", [""])[0]))
                except ValueError:
                    pass
                try:
                    # Seconds since the bridge saw interactive traffic ("none" otherwise), as of
                    # when it sent this probe; the transit is at most its last round trip.
                    # Erring old keeps the mark from gaining one transit per crossing.
                    pacer.interactive_seen(time.monotonic() - float(query.get("ia", [""])[0]) - (pacer.rtt or 0.0))
                except ValueError:
                    pass
                pacer.last_report = time.monotonic()
        self.send_response(204)
        self.send_header("Cache-Control", "no-store")
        if parsed.path == "/rp":
            age = interactive_age_all()
            self.send_header("X-Rp-Ia", "none" if age is None else "%.1f" % age)
        self.end_headers()

    def log_message(self, format, *args):
        return


def interactive_age_all():
    """Seconds since any relay on this Mac carried interactive traffic, or None."""
    ages = [a for a in (p.interactive_age() for p in PACERS.values()) if a is not None]
    return min(ages) if ages else None


def share_interactive():
    """Every relay rides one aTrust path: Codex on the A100 waits in the queue
    an upload to the RTX 4090 builds, so an interactive mark on any pacer
    tightens all of them.  Each pacer ignores a stamp it already has."""
    stamps = [p.interactive_at for p in PACERS.values() if p.interactive_at is not None]
    if stamps:
        latest = max(stamps)
        for p in PACERS.values():
            p.interactive_seen(latest)


def watch_arrivals():
    """The bridge probes on a fixed cadence; a probe that has not arrived by
    then is sitting in a queue, and its lateness is delay evidence."""
    while True:
        time.sleep(1.0)
        share_interactive()
        now = time.monotonic()
        for pacer in PACERS.values():
            last = getattr(pacer, "last_report", None)
            if last is None:
                continue
            # One second of slack covers the bridge's scheduling granularity.
            late = now - last - pacer.interval - 1.0
            if late > 0:
                pacer.pressure(late)


def raise_descriptor_limit():
    """launchd starts jobs with room for 256 descriptors; every proxied connection takes two."""
    try:
        import resource
        soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
        want = 8192 if hard == resource.RLIM_INFINITY else min(8192, hard)
        if soft < want:
            resource.setrlimit(resource.RLIMIT_NOFILE, (want, hard))
    except (ImportError, ValueError, OSError):
        pass


def main():
    global HEALTH_PORT
    raise_descriptor_limit()
    parser = argparse.ArgumentParser()
    parser.add_argument("--health", type=int, default=10809)
    parser.add_argument("--upstream", type=int, default=10810)
    parser.add_argument("--relay", action="append", default=[], metavar="NAME=PORT[=HOST]")
    args = parser.parse_args()
    HEALTH_PORT = args.health
    upstream_addr = ("127.0.0.1", args.upstream)

    for spec in args.relay:
        name, _, rest = spec.partition("=")
        port, _, host = rest.partition("=")
        if not name or not port.isdigit():
            parser.error("bad --relay %r" % spec)
        pacer = Pacer(name)
        PACERS[name] = pacer
        RELAYS[name] = {"port": int(port), "host": host or None}
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", int(port)))
        listener.listen(128)
        threading.Thread(target=serve_relay, args=(listener, pacer, upstream_addr), daemon=True).start()
        log("relay %s 127.0.0.1:%s -> 127.0.0.1:%d (%s)" % (
            name, port, args.upstream, "paced" if pacer.enabled else "unpaced"))

    server = ThreadingHTTPServer(("127.0.0.1", args.health), HealthHandler)
    server.daemon_threads = True
    threading.Thread(target=watch_arrivals, daemon=True).start()

    def stop(*_):
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        while True:
            time.sleep(3600)
    finally:
        server.shutdown()


if __name__ == "__main__":
    main()
