#!/usr/bin/env python3
"""One-time migration of this Mac's Harbor previews; never copies transcript text into recents."""
from pathlib import Path
import datetime
import json
import os
import plistlib
import shutil
import subprocess
import sys

main = Path.home() / "Library/Application Support/HarborSSH"
sources = [main, Path("/private/tmp/harbor-v02-qa"), Path("/private/tmp/harbor-v03-qa"), Path("/private/tmp/harbor-v04-qa")]
bundles = ["app.harbor.ssh", "app.harbor.ssh.preview", "app.harbor.ssh.v3.preview", "app.harbor.ssh.v4.preview"]

def read(root, name):
    p = root / name
    return json.loads(p.read_text()) if p.exists() else []

profiles = read(main, "servers.json")
by_id = {p["id"]: p for p in profiles}
remap = {}
for source in sources[1:]:
    for p in read(source, "servers.json"):
        match = next((q for q in profiles if q["id"] == p["id"] or all(q.get(k) == p.get(k) for k in ["host", "user", "port", "identityFile"])), None)
        if match is None:
            profiles.append(p); by_id[p["id"]] = p; match = p
        remap[p["id"]] = match["id"]

items = read(main, "recent-workspaces.json")
latest = {}
def real_directory(path):
    return path and not path.startswith(("/tmp/harbor-", "/private/tmp/harbor-"))

def add(server, directory, opened, tmux=None):
    server = remap.get(server, server)
    if server is not None and server not in by_id:
        return
    if directory and not real_directory(directory):
        directory = None
    if directory:
        directory = directory.rstrip("/") or "/"
        if server is None:
            directory = os.path.realpath(os.path.expanduser(directory))
    item = {"serverName": by_id[server]["name"] if server else "本机", "openedAt": opened}
    if server: item["serverID"] = server
    if directory: item["directory"] = directory
    if tmux: item["tmuxName"] = tmux
    items.append(item)

for source in sources:
    for record in read(source, "history.json"):
        if record.get("exitCode") not in [None, 0]:
            continue
        server = remap.get(record.get("serverID"), record.get("serverID"))
        latest[server] = max(latest.get(server, 0), record["startedAt"])
        add(server, record.get("workingDirectory"), record["startedAt"], record.get("tmuxName"))

preferences = {}
for bundle in bundles:
    path = Path.home() / "Library/Preferences" / (bundle + ".plist")
    if not path.exists(): continue
    prefs = plistlib.loads(path.read_bytes()); preferences[bundle] = path
    for key, value in prefs.items():
        if not key.startswith("workspace."): continue
        identity = key.split(".")[1]
        server = None if identity == "local" else remap.get(identity, identity)
        paths = [value] if key.endswith(".root") and isinstance(value, str) else value if key.endswith(".recent") and isinstance(value, list) else []
        for index, directory in enumerate(paths):
            if real_directory(directory): add(server, directory, latest.get(server, 0) - index - 0.5)

result = []
seen = set()
for item in sorted(items, key=lambda item: item["openedAt"], reverse=True):
    key = (item.get("serverID"), item.get("directory"))
    if key not in seen:
        seen.add(key); result.append(item)
result = result[:12]
print(json.dumps({"profiles": len(profiles), "recent": result}, ensure_ascii=False, indent=2))
if "--apply" not in sys.argv: sys.exit(0)

commands = subprocess.check_output(["/bin/ps", "-axo", "comm="], text=True)
if any("Harbor" in line and "/Contents/MacOS/" in line for line in commands.splitlines()):
    raise SystemExit("A Harbor app is running; close it before consolidating its data.")

stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
archive = main / "Archive" / stamp
archive.mkdir(parents=True, mode=0o700)
os.chmod(main / "Archive", 0o700)
for name in ["servers.json", "forwards.json", "recent-workspaces.json"]:
    if (main / name).exists(): shutil.copy2(main / name, archive / name)
for name in ["history.json", "Transcripts"]:
    if (main / name).exists(): shutil.move(str(main / name), str(archive / name))
for source in sources[1:]:
    if source.exists(): shutil.move(str(source), str(archive / source.name))
for bundle, path in preferences.items():
    shutil.copy2(path, archive / (bundle + ".plist"))
for p in profiles: p["recordOutput"] = False
for name, value in [("servers.json", profiles), ("recent-workspaces.json", result)]:
    temp = main / (name + ".migration-tmp")
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2)); os.chmod(temp, 0o600); os.replace(temp, main / name)
print("Private legacy data archived at:", archive)
