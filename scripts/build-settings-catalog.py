#!/usr/bin/env python3
"""Build the settings catalog Harbor ships for its Settings panel.

The catalog lists every setting of the bundled Code-OSS build and its built-in
extensions, so the panel never has to pull a megabyte of schema through a slow
tunnel. Regenerate it whenever bootstrap.py moves to another code-server:

  1. HARBOR_PREVIEW_WORK=/private/tmp/harbor-preview-$(id -u)/work scripts/dev-preview.sh qa
  2. with the preview window in front, ask its probe for the full catalog:
       {"action": "command", "name": "settingsCatalog", "extra": {"full": true}, "save": "<dump.json>"}
  3. scripts/build-settings-catalog.py <dump.json>
"""
import base64
import json
import re
import sys
import zlib
from pathlib import Path

root = Path(__file__).resolve().parent.parent
resources = root / "Sources/HarborSSH/Resources/CodeWorkbench"


def main() -> None:
    dump = json.loads(Path(sys.argv[1]).read_text())
    full = json.loads(zlib.decompress(base64.b64decode(dump["deflated"]), -15))
    runtime = re.search(r'^VERSION = "([^"]+)"', (resources / "bootstrap.py").read_text(), re.M).group(1)
    groups = full["groups"]
    owned = {setting["key"] for group in groups + full["installed"] for setting in group["settings"]}
    # The schema resolves what a manifest leaves out (theme lists, defaults set by other extensions).
    registered = {setting["key"]: setting for setting in full["settings"]}
    for group in groups:
        group["settings"] = [{**setting, **registered.get(setting["key"], {})} for setting in group["settings"]]
    core = sorted((setting for setting in full["settings"] if setting["key"] not in owned), key=lambda item: item["key"])
    line = lambda value: json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    out = ['{"runtime":%s,"editor":%s,' % (line(runtime), line(full["version"])), '"settings":[']
    out.append(",\n".join(line(setting) for setting in core))
    out.append('],\n"groups":[')
    out.append(",\n".join(line(group) for group in groups))
    out.append("]}")
    target = resources / "code-settings-catalog.json"
    target.write_text("\n".join(out) + "\n")
    json.loads(target.read_text())
    print(f"{target.relative_to(root)}: {len(core)} editor settings, {sum(len(g['settings']) for g in groups)} from "
          f"{len({g['extension'] for g in groups})} built-in extensions, {target.stat().st_size // 1024} KB")


if __name__ == "__main__":
    main()
