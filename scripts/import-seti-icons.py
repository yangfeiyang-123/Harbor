#!/usr/bin/env python3
"""Import the MIT Seti file icons from the user's installed Cursor (no runtime dependency)."""
import json
import math
from pathlib import Path
import shutil
import struct
import sys
import zlib


def unpack_woff(source: bytes) -> bytes:
    """Repackage WOFF's losslessly compressed sfnt tables for native Core Text."""
    signature, flavor, _, count, _, total, *_ = struct.unpack_from(">4sIIHHIHHIIIII", source)
    if signature != b"wOFF":
        raise ValueError("Expected a WOFF 1 font")
    selector = int(math.log2(count))
    result = bytearray(struct.pack(">IHHHH", flavor, count, 16 * 2**selector, selector, count * 16 - 16 * 2**selector))
    result.extend(bytes(count * 16))
    head = None
    for index in range(count):
        tag, offset, compressed, length, checksum = struct.unpack_from(">4sIIII", source, 44 + index * 20)
        table = source[offset:offset + compressed]
        if compressed < length:
            table = zlib.decompress(table)
        if len(table) != length:
            raise ValueError("Invalid font table length")
        start = len(result)
        struct.pack_into(">4sIII", result, 12 + index * 16, tag, checksum, start, length)
        result.extend(table)
        result.extend(bytes((-length) % 4))
        if tag == b"head":
            head = start
    if head is None or len(result) != total:
        raise ValueError("Invalid sfnt font")
    struct.pack_into(">I", result, head + 8, 0)
    checksum = sum(struct.unpack(">" + "I" * (len(result) // 4), result)) & 0xFFFFFFFF
    struct.pack_into(">I", result, head + 8, (0xB1B0AFBA - checksum) & 0xFFFFFFFF)
    return bytes(result)


def main():
    extensions = Path(sys.argv[1] if len(sys.argv) > 1 else "/Applications/Cursor.app/Contents/Resources/app/extensions")
    source = extensions / "theme-seti"
    theme = json.loads((source / "icons/vs-seti-icon-theme.json").read_text())
    names, suffixes = {}, {}
    # Seti uses VS Code language IDs for common files. Resolve the installed
    # built-in language associations once, then prefer Seti's explicit rules.
    for package in sorted(extensions.glob("*/package.json")):
        for language in json.loads(package.read_text()).get("contributes", {}).get("languages", []):
            icon = theme["languageIds"].get(language.get("id"))
            if not icon:
                continue
            names.update({name.lower(): icon for name in language.get("filenames", [])})
            suffixes.update({suffix.lstrip(".").lower(): icon for suffix in language.get("extensions", [])})
    names.update({name.lower(): icon for name, icon in theme["fileNames"].items()})
    suffixes.update({suffix.lower(): icon for suffix, icon in theme["fileExtensions"].items()})
    definitions = {}
    for key, definition in theme["iconDefinitions"].items():
        if key.endswith("_light") or "fontCharacter" not in definition:
            continue
        light = theme["iconDefinitions"].get(key + "_light", definition)
        definitions[key] = {
            "character": chr(int(definition["fontCharacter"].lstrip("\\"), 16)),
            "dark": definition.get("fontColor", "#f0f0f0"), "light": light.get("fontColor", "#141414"),
        }
    # Cursor brand glyphs are SVG overrides, not part of Seti's MIT font.
    names = {key: value for key, value in names.items() if value in definitions}
    suffixes = {key: value for key, value in suffixes.items() if value in definitions}
    output = Path(__file__).resolve().parent.parent / "Sources/HarborSSH/Resources/Themes/Seti"
    output.mkdir(parents=True, exist_ok=True)
    (output / "seti.ttf").write_bytes(unpack_woff((source / "icons/seti.woff").read_bytes()))
    (output / "icons.json").write_text(json.dumps({"file": theme["file"], "definitions": definitions,
        "fileNames": names, "fileExtensions": suffixes}, ensure_ascii=False, sort_keys=True, indent=2) + "\n")
    shutil.copyfile(source / "ThirdPartyNotices.txt", output / "LICENSE.txt")
    print(f"Imported {len(definitions)} Seti glyphs, {len(suffixes)} extensions and {len(names)} file names")


if __name__ == "__main__":
    main()
