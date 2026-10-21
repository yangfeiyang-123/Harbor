#!/bin/bash
# Development runner for assisted sessions. The Claude desktop session cannot
# type into Terminal, so it writes small request scripts (swift build, swift
# test, packaging, launching a preview bundle) to .build/claude/req-<id>.sh.
# This loop runs each one once, as you, and stores its output next to it.
# Read a request before it runs with: cat .build/claude/req-*.sh
# Stop at any time with Control+C; nothing keeps running afterwards.
set -u
cd "$(dirname "$0")/.."
dir=.build/claude
mkdir -p "$dir"
echo "Harbor dev runner ready in $PWD. Press Control+C to stop."
# The sign of life is written beside the loop, so one long request does not make it look stopped.
( while kill -0 $$ 2>/dev/null; do date +%s > "$dir/alive"; sleep 5; done ) &
heartbeat=$!
current=""
trap 'kill "$heartbeat" 2>/dev/null' EXIT
# A request that was running when the runner is stopped is reported as interrupted, so nothing waits for it.
trap '[ -n "$current" ] && echo 130 > "$dir/res-$current.done"; exit 130' INT TERM
while true; do
  for request in "$dir"/req-*.sh; do
    [ -f "$request" ] || continue
    id="${request##*/req-}"; id="${id%.sh}"
    [ -f "$dir/res-$id.done" ] && continue
    # Claimed before it runs: a request that was interrupted, or that a second runner also
    # sees, is not run again from the top.
    mkdir "$dir/res-$id.claim" 2>/dev/null || continue
    echo "[$(date +%H:%M:%S)] $id: $(head -c 160 "$request" | tr '\n' ' ')"
    # No keyboard: a request that asks for input gets an end of file, not this Terminal.
    current=$id
    bash "$request" > "$dir/res-$id.log" 2>&1 < /dev/null
    echo $? > "$dir/res-$id.done"; current=""
    echo "[$(date +%H:%M:%S)] $id finished with exit code $(cat "$dir/res-$id.done")"
  done
  sleep 1
done
