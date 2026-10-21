#!/usr/bin/env python3
"""Rewire ~/.bashrc to source ~/.reverse-proxy.sh, and drop the legacy blocks.

Runs on the server. Idempotent: re-running replaces the managed marker block
and leaves everything else alone.
"""

import os
import re
import shutil
import sys
import time

BASHRC = os.path.expanduser("~/.bashrc")
BEGIN = "# >>> reverse-proxy (managed by server-proxy-macos.sh) >>>"
END = "# <<< reverse-proxy (managed by server-proxy-macos.sh) <<<"

BLOCK = "\n".join([
    BEGIN,
    "# Must stay above the non-interactive guard below so that VS Code / Cursor",
    "# background processes inherit the proxy too.",
    '[ -f "$HOME/.reverse-proxy.sh" ] && . "$HOME/.reverse-proxy.sh"',
    END,
])


def drop_function(text, name):
    """Remove `name() { ... }` where the closing brace sits at column 0."""
    start = re.search(r"^%s\s*\(\)\s*\{\s*$" % re.escape(name), text, re.M)
    if not start:
        return text
    end = re.search(r"^\}\s*$", text[start.end():], re.M)
    if not end:
        return text
    return text[:start.start()] + text[start.end() + end.end():].lstrip("\n")


def main():
    if not os.path.exists(BASHRC):
        open(BASHRC, "w").close()
    with open(BASHRC, "r", encoding="utf-8", errors="surrogateescape") as fh:
        text = fh.read()

    original = text
    backup = "%s.before-reverse-proxy-%s" % (BASHRC, time.strftime("%Y%m%d-%H%M%S"))

    # 1. strip a previous managed block, with the blank lines that set it off below
    text = re.sub(re.escape(BEGIN) + r".*?" + re.escape(END) + r"\n*",
                  "", text, flags=re.S)

    # 2. strip the legacy top-of-file no_proxy block
    text = re.sub(
        r"^# Keep VS Code's local AgentHost/IPC traffic.*?\nfi\n",
        "", text, flags=re.S | re.M)

    # 3. strip the legacy auto-enable guarded by `-t 1` (that guard is exactly
    #    why non-interactive editor shells never got the proxy)
    text = re.sub(
        r'^if \[\[ -n "\$SSH_CONNECTION" && -t 1 \]\]; then\n\s*proxy_on[^\n]*\nfi\n',
        "", text, flags=re.M)

    # 4. strip the legacy function definitions; ~/.reverse-proxy.sh owns them now
    for fn in ("proxy_on", "proxy_off", "_rp_tunnel_up", "proxy_status"):
        text = drop_function(text, fn)

    # 5. insert the managed block after the leading comment header, one blank line below it.
    #    Taking the block out (step 1) and putting it in here undo each other exactly, so a
    #    second run finds nothing to change (it used to rewrite the file, and add a backup,
    #    on each of the next two runs).
    lines = text.split("\n")
    block = BLOCK.split("\n")
    for i, line in enumerate(lines):
        if line.strip() and not line.lstrip().startswith("#"):
            lines[i:i] = block + [""]
            break
    else:
        while lines and not lines[-1].strip():
            lines.pop()
        lines += ([""] if lines else []) + block + [""]
    text = "\n".join(lines)
    text = re.sub(r"\n{4,}", "\n\n\n", text)

    if text == original:
        print("bashrc already current")
        return

    shutil.copy2(BASHRC, backup)
    with open(BASHRC, "w", encoding="utf-8", errors="surrogateescape") as fh:
        fh.write(text)
    print("patched; backup at %s" % backup)


if __name__ == "__main__":
    main()
