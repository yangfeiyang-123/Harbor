#!/usr/bin/env python3
"""Generate Harbor's own theme families under Sources/HarborSSH/Resources/Themes.

Five families, each a light and a dark palette, from the same design tokens as the
Claude theme (scripts/build-anthropic-theme.py): a canvas, a slightly darker chrome,
raised surfaces, four ink steps and one accent. That script's `palette` turns the
tokens into the color roles Harbor and its editor use, and its `check` refuses a
palette whose text falls below its contrast floor; both are used as they are.

    Tide        fog-blue paper, deep-sea navy, one sea-blue accent
    Kelp        lichen paper, pine black, moss green
    Dusk        lilac paper, aubergine, violet
    Fog         grays only: the accent is ink, and syntax is spoken quietly
    Lighthouse  white and pitch black at full contrast, one amber beam

Edit THEMES, then run this script. It writes one <family>.json per family.
"""
import importlib.util
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("harbor_theme_base", HERE / "build-anthropic-theme.py")
base = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(base)

THEMES = {
    "tide": {
        "light": dict(
            name="Tide Light", canvas="#F6F9FC", chrome="#ECF1F6", raised="#FFFFFF",
            hover="#E3EAF1", selected="#D8E2EC", line="#D9E1EA", line_strong="#C0CCD8",
            ink="#16222E", ink2="#4A5B6C", ink3="#73838F", ink4="#A9B6C2",
            accent="#2B7FC4", accent_text="#1F68A8", accent_strong="#2473B8", on_accent="#FFFFFF",
            button="#1F68A8", button_hover="#1A5A93", tint=0.16,
            selection="#CFE3F6", selection_soft="#E2EEF8", find="#F5D36E", find_soft="#FAE8AE", word="#DCE8D8",
            success="#2A7449", warning="#855D00", error="#BC3737", info="#1F68A8",
            added="#D9EEDD", removed="#F8DADA", shadow="#16222E1F",
            syntax=dict(comment="#74838F", keyword="#1F68A8", string="#2A7449", number="#95560F", constant="#95560F",
                        variable="#16222E", type="#0A7580", function="#6748B4", tag="#1F68A8", property="#A3416A",
                        operator="#4A5B6C", invalid="#BC3737", heading="#16222E", link="#1F68A8"),
            ansi=["#16222E", "#BC3737", "#2A7449", "#855D00", "#1F68A8", "#6748B4", "#0A7580", "#5F7082",
                  "#4A5B6C", "#C7403F", "#2F8052", "#906600", "#2473B8", "#7355C4", "#0B818D", "#0E1820"],
        ),
        "dark": dict(
            name="Tide Dark", canvas="#0F1A24", chrome="#0B141C", raised="#172532",
            hover="#1A2A38", selected="#223546", line="#1E2E3C", line_strong="#2F4355",
            ink="#E3ECF4", ink2="#B3C2D0", ink3="#8496A8", ink4="#566879",
            accent="#4FA3E3", accent_text="#74B8EE", accent_strong="#4FA3E3", on_accent="#0B141C",
            button="#2473B8", button_hover="#2B7FC4", tint=0.22,
            selection="#1F4466", selection_soft="#1A3349", find="#7A6220", find_soft="#4C4222", word="#23403A",
            success="#8FD3A5", warning="#E6C16A", error="#F08A84", info="#74B8EE",
            added="#16332A", removed="#3D2226", shadow="#00000066",
            syntax=dict(comment="#738699", keyword="#74B8EE", string="#8FD3A5", number="#E9B872", constant="#E9B872",
                        variable="#E3ECF4", type="#6FD0D6", function="#B5A2F2", tag="#74B8EE", property="#F09BBB",
                        operator="#B3C2D0", invalid="#F08A84", heading="#E3ECF4", link="#74B8EE"),
            ansi=["#223546", "#F08A84", "#8FD3A5", "#E6C16A", "#74B8EE", "#B5A2F2", "#6FD0D6", "#B3C2D0",
                  "#566879", "#F7A8A3", "#A9E0BA", "#F1D48E", "#97CBF4", "#CBBDF7", "#92DEE3", "#F6F9FC"],
        ),
    },
    "kelp": {
        "light": dict(
            name="Kelp Light", canvas="#F7F8F3", chrome="#EDF0E6", raised="#FFFFFF",
            hover="#E4E8DB", selected="#D9DFCD", line="#DCE1D2", line_strong="#C3CAB6",
            ink="#1B231A", ink2="#505B4C", ink3="#767F70", ink4="#ABB3A4",
            accent="#5C9A45", accent_text="#366E23", accent_strong="#447E30", on_accent="#FFFFFF",
            button="#366E23", button_hover="#2D5F1C", tint=0.16,
            selection="#D5E6C8", selection_soft="#E5EEDC", find="#F2D06B", find_soft="#F8E6A9", word="#D7E4EC",
            success="#366E23", warning="#855D00", error="#B23C2C", info="#2A678F",
            added="#DCEBD0", removed="#F5DAD3", shadow="#1B231A1F",
            syntax=dict(comment="#778071", keyword="#366E23", string="#8F5415", number="#A04235", constant="#A04235",
                        variable="#1B231A", type="#2A678F", function="#0C6F61", tag="#366E23", property="#755598",
                        operator="#505B4C", invalid="#B23C2C", heading="#1B231A", link="#366E23"),
            ansi=["#1B231A", "#B23C2C", "#366E23", "#855D00", "#2A678F", "#755598", "#0C6F61", "#636D5E",
                  "#505B4C", "#BE4533", "#3D7A28", "#8F6500", "#2F74A0", "#8463A8", "#0E7B6B", "#121811"],
        ),
        "dark": dict(
            name="Kelp Dark", canvas="#141B16", chrome="#0F1511", raised="#1D2620",
            hover="#212B24", selected="#2A372E", line="#253028", line_strong="#37463B",
            ink="#E6ECE2", ink2="#B8C3B4", ink3="#8A978A", ink4="#5C685D",
            accent="#8CC474", accent_text="#A2D58B", accent_strong="#8CC474", on_accent="#0F1511",
            button="#3F7A2C", button_hover="#4A8635", tint=0.20,
            selection="#2F4A2C", selection_soft="#253626", find="#7A6420", find_soft="#4B4322", word="#23384A",
            success="#A2D58B", warning="#E4C26B", error="#EE8F7F", info="#86BCE0",
            added="#1D3320", removed="#40251F", shadow="#00000066",
            syntax=dict(comment="#7A8A7A", keyword="#A2D58B", string="#E5BC7A", number="#F0A090", constant="#F0A090",
                        variable="#E6ECE2", type="#86BCE0", function="#78D1BE", tag="#A2D58B", property="#C9B0E6",
                        operator="#B8C3B4", invalid="#EE8F7F", heading="#E6ECE2", link="#A2D58B"),
            ansi=["#2A372E", "#EE8F7F", "#A2D58B", "#E4C26B", "#86BCE0", "#C9B0E6", "#78D1BE", "#B8C3B4",
                  "#5C685D", "#F5ABA0", "#B9E2A7", "#EED48F", "#A5CFEC", "#DAC8EF", "#98DFD0", "#F7F8F3"],
        ),
    },
    "dusk": {
        "light": dict(
            name="Dusk Light", canvas="#F9F7FB", chrome="#F0ECF4", raised="#FFFFFF",
            hover="#E8E2EE", selected="#DED6E7", line="#E0D9E7", line_strong="#C9BFD3",
            ink="#201A29", ink2="#584F66", ink3="#7E758B", ink4="#B3ABBE",
            accent="#8A63D2", accent_text="#6B46B8", accent_strong="#7A54C6", on_accent="#FFFFFF",
            button="#6B46B8", button_hover="#5C3AA3", tint=0.14,
            selection="#E0D3F5", selection_soft="#ECE4F8", find="#F4CF6C", find_soft="#F9E6AB", word="#D6E7E4",
            success="#2B7350", warning="#855C00", error="#BE3752", info="#2A68A1",
            added="#D8EEDF", removed="#F8D9DF", shadow="#201A291F",
            syntax=dict(comment="#80778D", keyword="#6B46B8", string="#2B7350", number="#A94D26", constant="#A94D26",
                        variable="#201A29", type="#AB3675", function="#2A68A1", tag="#6B46B8", property="#0D7379",
                        operator="#584F66", invalid="#BE3752", heading="#201A29", link="#6B46B8"),
            ansi=["#201A29", "#BE3752", "#2B7350", "#855C00", "#2A68A1", "#6B46B8", "#0D7379", "#6A6177",
                  "#584F66", "#C93F5E", "#308059", "#906400", "#2F74B3", "#7852C4", "#0F7F86", "#150F1C"],
        ),
        "dark": dict(
            name="Dusk Dark", canvas="#1A1622", chrome="#14111B", raised="#241F2F",
            hover="#282234", selected="#332B42", line="#2C2639", line_strong="#413852",
            ink="#ECE7F3", ink2="#BFB6CD", ink3="#9188A2", ink4="#625972",
            accent="#A98BEB", accent_text="#BDA5F2", accent_strong="#A98BEB", on_accent="#14111B",
            button="#7A57CC", button_hover="#8A68D8", tint=0.20,
            selection="#3E3160", selection_soft="#2F2746", find="#7A6220", find_soft="#4B4124", word="#1F3D40",
            success="#8AD2A8", warning="#EBC06D", error="#F28BA0", info="#86B9EE",
            added="#1A3329", removed="#40222C", shadow="#00000066",
            syntax=dict(comment="#857C9A", keyword="#BDA5F2", string="#8AD2A8", number="#F2A77C", constant="#F2A77C",
                        variable="#ECE7F3", type="#F092C0", function="#86B9EE", tag="#BDA5F2", property="#74D0D2",
                        operator="#BFB6CD", invalid="#F28BA0", heading="#ECE7F3", link="#BDA5F2"),
            ansi=["#332B42", "#F28BA0", "#8AD2A8", "#EBC06D", "#86B9EE", "#BDA5F2", "#74D0D2", "#BFB6CD",
                  "#625972", "#F7A9B9", "#A6DFBD", "#F2D391", "#A6CDF4", "#D0BEF7", "#95DEE0", "#F9F7FB"],
        ),
    },
    "fog": {
        "light": dict(
            name="Fog Light", canvas="#F7F7F6", chrome="#EEEEEC", raised="#FFFFFF",
            hover="#E5E5E3", selected="#DBDBD8", line="#DFDFDC", line_strong="#C6C6C2",
            ink="#1C1D1F", ink2="#55575B", ink3="#7C7E82", ink4="#B2B4B7",
            accent="#6E7781", accent_text="#3A4149", accent_strong="#4A525B", on_accent="#FFFFFF",
            button="#3A4149", button_hover="#2B3138", tint=0.14,
            selection="#D9DEE5", selection_soft="#E7EAEE", find="#F1D680", find_soft="#F7E8B4", word="#E0E2DD",
            success="#3A744A", warning="#7F5B09", error="#AE403B", info="#39678D",
            added="#DFECDF", removed="#F3DEDC", shadow="#1C1D1F1F",
            syntax=dict(comment="#7E8084", keyword="#565A92", string="#48694F", number="#855C35", constant="#855C35",
                        variable="#1C1D1F", type="#3A677A", function="#754A68", tag="#565A92", property="#655C43",
                        operator="#55575B", invalid="#AE403B", heading="#1C1D1F", link="#3A4149"),
            ansi=["#1C1D1F", "#AE403B", "#3A744A", "#7F5B09", "#39678D", "#754A68", "#3A677A", "#66686C",
                  "#55575B", "#B94741", "#417F52", "#89630C", "#40739D", "#825475", "#417386", "#111214"],
        ),
        "dark": dict(
            name="Fog Dark", canvas="#1B1C1E", chrome="#151617", raised="#25262A",
            hover="#2A2B2F", selected="#34363B", line="#2E3034", line_strong="#45474D",
            ink="#E8E8E6", ink2="#BBBCBB", ink3="#8E9093", ink4="#606266",
            accent="#A9B1BA", accent_text="#C9D0D8", accent_strong="#A9B1BA", on_accent="#151617",
            button="#66707C", button_hover="#74808D", tint=0.18,
            selection="#3A4350", selection_soft="#2C3138", find="#7A6625", find_soft="#4A4326", word="#33383A",
            success="#93C9A0", warning="#DFC27A", error="#E8958E", info="#93BCDD",
            added="#1F3024", removed="#3A2523", shadow="#00000066",
            syntax=dict(comment="#808286", keyword="#B4B8E8", string="#A9CDB3", number="#DDB88E", constant="#DDB88E",
                        variable="#E8E8E6", type="#9CC7D8", function="#D9B3CC", tag="#B4B8E8", property="#C9C59A",
                        operator="#BBBCBB", invalid="#E8958E", heading="#E8E8E6", link="#C9D0D8"),
            ansi=["#34363B", "#E8958E", "#93C9A0", "#DFC27A", "#93BCDD", "#D9B3CC", "#9CC7D8", "#BBBCBB",
                  "#606266", "#F0AFA9", "#ACD8B7", "#E9D298", "#AECEE8", "#E5C8DA", "#B5D6E3", "#F7F7F6"],
        ),
    },
    "lighthouse": {
        "light": dict(
            name="Lighthouse Light", canvas="#FFFFFF", chrome="#F4F4F2", raised="#FFFFFF",
            hover="#EAEAE7", selected="#DEDEDA", line="#D0D0CB", line_strong="#A9A9A3",
            ink="#0B0C0E", ink2="#3A3D42", ink3="#6B6F76", ink4="#A0A4AA",
            accent="#E0A100", accent_text="#7A5600", accent_strong="#B07C00", on_accent="#FFFFFF",
            button="#1B1E23", button_hover="#0B0C0E", tint=0.20,
            selection="#FBE7A8", selection_soft="#FDF2CF", find="#A9D4FF", find_soft="#D4E9FF", word="#E3E3DF",
            success="#1F6F3A", warning="#7A5600", error="#B3261E", info="#1558A6",
            added="#D5F0DB", removed="#FBD9D6", shadow="#0B0C0E26",
            syntax=dict(comment="#6B6F76", keyword="#7A3E9D", string="#1F6F3A", number="#A5450F", constant="#A5450F",
                        variable="#0B0C0E", type="#1558A6", function="#7A5600", tag="#7A3E9D", property="#0C6B74",
                        operator="#3A3D42", invalid="#B3261E", heading="#0B0C0E", link="#7A5600"),
            ansi=["#0B0C0E", "#B3261E", "#1F6F3A", "#7A5600", "#1558A6", "#7A3E9D", "#0C6B74", "#5C6067",
                  "#3A3D42", "#C62F26", "#257F43", "#8A6200", "#1A66BE", "#8A49AF", "#0E7A84", "#000000"],
        ),
        "dark": dict(
            name="Lighthouse Dark", canvas="#0B0C0E", chrome="#060708", raised="#16181C",
            hover="#1B1E23", selected="#262A31", line="#2A2E35", line_strong="#454A54",
            ink="#F5F5F2", ink2="#C9CBCF", ink3="#9498A0", ink4="#5E626A",
            accent="#F2C230", accent_text="#F5CF57", accent_strong="#F2C230", on_accent="#0B0C0E",
            button="#8F6400", button_hover="#A67500", tint=0.18,
            selection="#4A3F12", selection_soft="#2E2810", find="#1F4E7A", find_soft="#183552", word="#2A2E35",
            success="#7EE09A", warning="#F5CF57", error="#FF8A80", info="#7CC0FF",
            added="#10301C", removed="#3F1A18", shadow="#00000080",
            syntax=dict(comment="#8A8E96", keyword="#D4A5F5", string="#8EE5A6", number="#FFB07A", constant="#FFB07A",
                        variable="#F5F5F2", type="#7CC0FF", function="#F5CF57", tag="#D4A5F5", property="#6EDDE0",
                        operator="#C9CBCF", invalid="#FF8A80", heading="#F5F5F2", link="#F5CF57"),
            ansi=["#262A31", "#FF8A80", "#8EE5A6", "#F5CF57", "#7CC0FF", "#D4A5F5", "#6EDDE0", "#C9CBCF",
                  "#5E626A", "#FFACA5", "#AEEFC0", "#FADF8C", "#A3D3FF", "#E3C4F9", "#9BE9EB", "#FFFFFF"],
        ),
    },
}


def check(tokens):
    """The Claude theme's floors, and the ones Harbor's own pages add: body text is read at 7:1
    on every surface it is set on, and a dark and a light palette are never the same paper."""
    base.check(tokens)
    for surface in ("canvas", "chrome", "raised"):
        ratio = base.contrast(tokens["ink"], tokens[surface])
        assert ratio >= 7, "%s ink on %s is %.2f" % (tokens["name"], surface, ratio)
    tint = base.clay_tint(tokens)
    assert base.contrast(tokens["ink"], tint) >= 7, "%s ink on the selected row is %.2f" % (tokens["name"], base.contrast(tokens["ink"], tint))
    for key in ("success", "warning", "error", "info"):
        ratio = base.contrast(tokens[key], tokens["canvas"])
        assert ratio >= 4.5, "%s %s on canvas is %.2f" % (tokens["name"], key, ratio)
    assert tokens["added"] != tokens["removed"]


if __name__ == "__main__":
    directory = HERE.parent / "Sources/HarborSSH/Resources/Themes"
    for family, modes in THEMES.items():
        assert set(modes) == {"light", "dark"}, family
        for tokens in modes.values():
            check(tokens)
        assert modes["light"]["canvas"] != modes["dark"]["canvas"]
        target = directory / (family + ".json")
        target.write_text(json.dumps({mode: base.palette(tokens) for mode, tokens in modes.items()}, indent=2) + "\n")
        print("Wrote", target)
