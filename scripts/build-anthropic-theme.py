#!/usr/bin/env python3
"""Generate Sources/HarborSSH/Resources/Themes/anthropic.json from design tokens.

The palette is Harbor's own design in the spirit of anthropic.com: ivory paper,
warm ink, one clay accent, matte surfaces. Edit TOKENS, then run this script.
It refuses to write a palette whose text falls below its contrast floor.
"""
import json
from pathlib import Path

TOKENS = {
    "light": dict(
        name="Anthropic Light", canvas="#FAF9F5", chrome="#F3F1EA", raised="#FFFFFF",
        hover="#ECEAE1", selected="#E4E1D6", line="#E2DFD5", line_strong="#CDCAC0",
        ink="#1F1E1D", ink2="#5E5D59", ink3="#87867F", ink4="#B3B1A8",
        accent="#D97757", accent_text="#B5532F", accent_strong="#C15F3C", on_accent="#FFFFFF",
        button="#B5532F", button_hover="#A34A29", tint=0.17,
        selection="#E6DCCB", selection_soft="#EFE9DD", find="#F3C96B", find_soft="#F8E2A8", word="#DCE6F0",
        success="#4A7436", warning="#8A5F00", error="#B93A3A", info="#2C6AA0",
        added="#DDEBD3", removed="#F6DAD5", shadow="#1F1E1D1F",
        syntax=dict(comment="#8A887F", keyword="#B5532F", string="#4A7436", number="#8A5F00", constant="#8A5F00",
                    variable="#1F1E1D", type="#7A4E9E", function="#2C6AA0", tag="#B5532F", property="#1B7570",
                    operator="#5E5D59", invalid="#B93A3A", heading="#1F1E1D", link="#B5532F"),
        ansi=["#1F1E1D", "#B93A3A", "#4A7436", "#8A5F00", "#2C6AA0", "#7A4E9E", "#1B7570", "#6F6D66",
              "#5E5D59", "#C8442F", "#4F8038", "#9A6A00", "#2F74B0", "#8A58B0", "#1D7F78", "#141413"],
    ),
    "dark": dict(
        name="Anthropic Dark", canvas="#262624", chrome="#1F1E1D", raised="#30302E",
        hover="#33332F", selected="#3D3D39", line="#3A3A36", line_strong="#4D4C47",
        ink="#F0EEE6", ink2="#C2C0B6", ink3="#9C9A92", ink4="#6B6A64",
        accent="#D97757", accent_text="#E8906F", accent_strong="#D97757", on_accent="#1F1E1D",
        button="#C4633F", button_hover="#D97757", tint=0.20,
        selection="#4D463C", selection_soft="#3B3833", find="#8A6A1F", find_soft="#5A4A22", word="#34404D",
        success="#A3C283", warning="#E2B866", error="#EC8173", info="#8DB7E0",
        added="#2F3B2A", removed="#45302D", shadow="#00000066",
        syntax=dict(comment="#8C8A82", keyword="#E8906F", string="#A3C283", number="#E2B866", constant="#E2B866",
                    variable="#F0EEE6", type="#C6A8E2", function="#8DB7E0", tag="#E8906F", property="#7CC6BD",
                    operator="#C2C0B6", invalid="#EC8173", heading="#F0EEE6", link="#E8906F"),
        ansi=["#3D3D39", "#EC8173", "#A3C283", "#E2B866", "#8DB7E0", "#C6A8E2", "#7CC6BD", "#C2C0B6",
              "#6B6A64", "#F59B8E", "#B8D49B", "#EFCB85", "#A8CBEC", "#D8C0EE", "#98D8D0", "#FAF9F5"],
    ),
}


def luminance(color):
    channels = [int(color[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    r, g, b = [c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4 for c in channels]
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b):
    high, low = sorted((luminance(a), luminance(b)), reverse=True)
    return (high + 0.05) / (low + 0.05)


def alpha(color, value):
    return color[:7] + "%02X" % round(value * 255)


def mix(base, color, amount):
    """`amount` of `color` over `base`, as an opaque color."""
    return "#" + "".join("%02X" % round(int(base[i:i + 2], 16) * (1 - amount) + int(color[i:i + 2], 16) * amount) for i in (1, 3, 5))


def clay_tint(t):
    return mix(t["canvas"], t["accent"], t["tint"])


def palette(t):
    c, ansi = {}, t["ansi"]
    def put(value, *keys):
        for key in keys:
            c[key] = value
    put(t["ink"], "foreground", "editor.foreground", "sideBar.foreground", "sideBarTitle.foreground", "titleBar.activeForeground",
        "tab.activeForeground", "list.activeSelectionForeground", "list.inactiveSelectionForeground", "list.focusForeground",
        "list.hoverForeground", "input.foreground", "dropdown.foreground", "menu.foreground", "editorWidget.foreground",
        "editorHoverWidget.foreground", "editorSuggestWidget.foreground", "notifications.foreground", "terminal.foreground",
        "terminalCursor.foreground", "editorCursor.foreground", "editorLineNumber.activeForeground", "panelTitle.activeForeground",
        "activityBar.foreground", "activityBarTop.foreground", "sideBarSectionHeader.foreground", "textPreformat.foreground",
        "breadcrumb.focusForeground", "breadcrumb.activeSelectionForeground", "quickInput.foreground", "peekViewTitleLabel.foreground",
        "settings.headerForeground", "button.secondaryForeground", "badge.foreground", "keybindingLabel.foreground",
        "commandCenter.foreground", "commandCenter.activeForeground", "tab.unfocusedActiveForeground", "pickerGroup.foreground")
    put(t["accent_strong"], "terminalCursor.foreground", "editorCursor.foreground")
    put(t["ink2"], "descriptionForeground", "icon.foreground", "statusBar.foreground", "tab.inactiveForeground", "breadcrumb.foreground",
        "panelTitle.inactiveForeground", "activityBar.inactiveForeground", "activityBarTop.inactiveForeground",
        "titleBar.inactiveForeground", "tab.unfocusedInactiveForeground", "editorCodeLens.foreground", "statusBar.noFolderForeground",
        "statusBar.debuggingForeground", "statusBarItem.remoteForeground", "peekViewTitleDescription.foreground",
        "commandCenter.inactiveForeground", "list.deemphasizedForeground", "gitDecoration.ignoredResourceForeground")
    put(t["ink3"], "editorLineNumber.foreground", "input.placeholderForeground", "editorGhostText.foreground", "disabledForeground",
        "editorInlayHint.foreground", "editorInlayHint.typeForeground", "editorInlayHint.parameterForeground",
        "git.blame.editorDecorationForeground", "textSeparator.foreground")
    put(t["ink4"], "editorWhitespace.foreground", "editorRuler.foreground")
    put(t["canvas"], "editor.background", "panel.background", "terminal.background", "tab.activeBackground", "breadcrumb.background",
        "editorGutter.background", "terminalCursor.background", "editorGroup.emptyBackground", "minimap.background",
        "peekViewEditor.background", "peekViewEditorGutter.background", "walkThrough.embeddedEditorBackground",
        "editorStickyScroll.background", "settings.focusedRowBackground", "notebook.editorBackground")
    put(t["chrome"], "sideBar.background", "activityBar.background", "activityBarTop.background", "statusBar.background",
        "titleBar.activeBackground", "titleBar.inactiveBackground", "tab.inactiveBackground", "editorGroupHeader.tabsBackground",
        "editorGroupHeader.noTabsBackground", "sideBarSectionHeader.background", "statusBar.noFolderBackground",
        "statusBar.debuggingBackground", "statusBarItem.remoteBackground", "peekViewResult.background", "peekViewTitle.background",
        "textBlockQuote.background", "textCodeBlock.background", "textPreformat.background", "editorInlayHint.background",
        "editorInlayHint.typeBackground", "editorInlayHint.parameterBackground", "sideBarStickyScroll.background",
        "panelSectionHeader.background", "keybindingLabel.background", "commandCenter.background")
    put(t["raised"], "editorWidget.background", "editorHoverWidget.background", "editorSuggestWidget.background", "menu.background",
        "input.background", "dropdown.background", "dropdown.listBackground", "notifications.background", "quickInput.background",
        "breadcrumbPicker.background", "debugToolBar.background", "settings.textInputBackground", "settings.numberInputBackground",
        "settings.dropdownBackground", "settings.checkboxBackground", "checkbox.background", "notificationCenterHeader.background",
        "commandCenter.activeBackground", "debugExceptionWidget.background", "editorMarkerNavigation.background")
    put(t["hover"], "list.hoverBackground", "tab.hoverBackground", "tab.unfocusedHoverBackground", "button.secondaryBackground",
        "toolbar.hoverBackground", "statusBarItem.hoverBackground", "editorSuggestWidget.selectedBackground",
        "menubar.selectionBackground", "badge.background", "button.secondaryHoverBackground", "list.dropBackground",
        "editorGroup.dropBackground", "statusBarItem.activeBackground", "statusBarItem.prominentBackground",
        "statusBarItem.prominentHoverBackground", "toolbar.activeBackground", "inputOption.hoverBackground")
    put(t["selected"], "list.activeSelectionBackground", "list.inactiveSelectionBackground", "list.focusBackground",
        "quickInputList.focusBackground", "menu.selectionBackground", "peekViewResult.selectionBackground",
        "inputOption.activeBackground", "editorBracketMatch.background", "settings.rowHoverBackground")
    put(t["ink"], "menu.selectionForeground", "quickInputList.focusForeground", "peekViewResult.selectionForeground",
        "inputOption.activeForeground", "peekViewResult.fileForeground", "editorSuggestWidget.selectedForeground")
    put(t["ink2"], "peekViewResult.lineForeground")
    put(t["line"], "panel.border", "sideBar.border", "titleBar.border", "statusBar.border", "tab.border", "editorGroup.border",
        "editorGroupHeader.tabsBorder", "editorWidget.border", "editorHoverWidget.border", "editorSuggestWidget.border",
        "menu.border", "input.border", "dropdown.border", "notifications.border", "widget.border", "pickerGroup.border",
        "peekView.border", "editorOverviewRuler.border", "editorStickyScroll.border", "sideBarStickyScroll.border",
        "panelStickyScroll.border", "terminalStickyScroll.border", "sideBarSectionHeader.border", "menu.separatorBackground",
        "button.secondaryBorder", "commandCenter.border", "commandCenter.inactiveBorder", "commandCenter.activeBorder",
        "checkbox.border", "settings.textInputBorder", "settings.numberInputBorder", "settings.dropdownBorder",
        "notificationCenter.border", "notificationToast.border", "debugExceptionWidget.border", "merge.border",
        "tab.unfocusedHoverBorder", "sash.hoverBorder", "panelTitle.border", "keybindingLabel.border",
        "keybindingLabel.bottomBorder", "textBlockQuote.border", "editorIndentGuide.background1", "tree.inactiveIndentGuidesStroke",
        "editorWidget.resizeBorder", "settings.headerBorder", "activityBarTop.dropBorder")
    put(t["line_strong"], "editorIndentGuide.activeBackground1", "tree.indentGuidesStroke", "editorBracketMatch.border",
        "scrollbarSlider.activeBackground", "editorGroup.dropIntoPromptBorder")
    put(t["accent_strong"], "focusBorder", "tab.activeBorderTop", "progressBar.background", "activityBarBadge.background",
        "panelTitle.activeBorder", "activityBarTop.activeBorder", "activityBar.activeBorder", "inputOption.activeBorder",
        "settings.modifiedItemIndicator", "editorSuggestWidget.focusHighlightForeground", "list.focusHighlightForeground",
        "extensionButton.prominentBackground", "notebook.focusedCellBorder", "editorLightBulb.foreground")
    put(t["accent_text"], "textLink.foreground", "list.highlightForeground", "editorSuggestWidget.highlightForeground",
        "editorLink.activeForeground", "notificationLink.foreground", "textLink.activeForeground",
        "terminal.findMatchBorder", "editorOverviewRuler.findMatchForeground")
    put(t["on_accent"], "activityBarBadge.foreground", "extensionButton.prominentForeground")
    put(t["accent"], "extensionButton.prominentHoverBackground", "tab.unfocusedActiveBorderTop")
    put(alpha(t["line"], 0), "tab.activeBorder", "tab.unfocusedActiveBorder", "editor.lineHighlightBorder", "tab.lastPinnedBorder")
    # Clay is the one accent. It marks what is chosen or acted on: the primary
    # button, the selected row, the active view, the line being edited, the
    # divider being dragged. Everything at rest stays ivory and ink.
    put(t["button"], "button.background", "statusBarItem.remoteBackground", "extensionButton.prominentBackground")
    put("#FFFFFF", "button.foreground", "button.separator", "statusBarItem.remoteForeground", "extensionButton.prominentForeground")
    put(t["button_hover"], "button.hoverBackground", "extensionButton.prominentHoverBackground", "statusBarItem.remoteHoverBackground")
    put(clay_tint(t), "list.activeSelectionBackground", "quickInputList.focusBackground", "menu.selectionBackground",
        "editorSuggestWidget.selectedBackground", "inputOption.activeBackground", "badge.background", "list.dropBackground")
    put(t["accent_text"], "list.activeSelectionIconForeground", "quickInputList.focusIconForeground", "activityBar.foreground",
        "activityBarTop.foreground", "editorLineNumber.activeForeground", "pickerGroup.foreground", "terminal.tab.activeBorder",
        "panelTitleBadge.background")
    put(t["accent"], "sash.hoverBorder", "editorGroup.dropIntoPromptBorder", "list.focusAndSelectionOutline")
    put(alpha(t["accent"], .55), "editorBracketMatch.border")
    put(alpha(t["accent"], .18), "editorGroup.dropBackground")
    put(t["selection"], "editor.selectionBackground", "terminal.inactiveSelectionBackground", "selection.background")
    put(alpha(t["selection"], .85), "terminal.selectionBackground")
    put(t["selection_soft"], "editor.inactiveSelectionBackground", "editor.selectionHighlightBackground")
    put(alpha(t["hover"], .55), "editor.lineHighlightBackground", "editor.hoverHighlightBackground")
    put(t["find"], "editor.findMatchBackground", "minimap.findMatchHighlight", "terminal.findMatchBackground")
    put(t["find_soft"], "editor.findMatchHighlightBackground", "peekViewEditor.matchHighlightBackground",
        "peekViewResult.matchHighlightBackground", "terminal.findMatchHighlightBackground", "searchEditor.findMatchBackground")
    put(alpha(t["find_soft"], .45), "editor.findRangeHighlightBackground", "editor.rangeHighlightBackground")
    put(t["word"], "editor.wordHighlightBackground", "editor.snippetTabstopHighlightBackground")
    put(alpha(t["info"], .22), "editor.wordHighlightStrongBackground")
    put(alpha(t["ink3"], .30), "scrollbarSlider.background", "minimapSlider.background")
    put(alpha(t["ink3"], .50), "scrollbarSlider.hoverBackground", "minimapSlider.hoverBackground")
    put(alpha(t["ink3"], .65), "minimapSlider.activeBackground")
    put(t["shadow"], "widget.shadow", "scrollbar.shadow")
    put(t["error"], "errorForeground", "editorError.foreground", "list.errorForeground", "inputValidation.errorBorder",
        "notificationsErrorIcon.foreground", "gitDecoration.deletedResourceForeground", "minimap.errorHighlight",
        "editorBracketHighlight.unexpectedBracket.foreground", "testing.iconFailed", "list.invalidItemForeground",
        "editorOverviewRuler.errorForeground", "problemsErrorIcon.foreground")
    put(t["warning"], "list.warningForeground", "editorWarning.foreground", "inputValidation.warningBorder",
        "notificationsWarningIcon.foreground", "gitDecoration.modifiedResourceForeground", "minimap.warningHighlight",
        "editorOverviewRuler.warningForeground", "problemsWarningIcon.foreground", "gitDecoration.conflictingResourceForeground")
    put(t["success"], "gitDecoration.addedResourceForeground", "gitDecoration.untrackedResourceForeground", "testing.iconPassed",
        "terminalCommandDecoration.successBackground", "gitDecoration.stageModifiedResourceForeground")
    put(t["info"], "editorInfo.foreground", "inputValidation.infoBorder", "notificationsInfoIcon.foreground",
        "problemsInfoIcon.foreground", "editorOverviewRuler.infoForeground")
    put(t["raised"], "inputValidation.errorBackground", "inputValidation.warningBackground", "inputValidation.infoBackground")
    put(t["ink"], "inputValidation.errorForeground", "inputValidation.warningForeground", "inputValidation.infoForeground")
    put(alpha(t["added"], .9), "diffEditor.insertedLineBackground")
    put(alpha(t["success"], .28), "diffEditor.insertedTextBackground", "merge.incomingContentBackground")
    put(alpha(t["removed"], .9), "diffEditor.removedLineBackground")
    put(alpha(t["error"], .26), "diffEditor.removedTextBackground")
    put(alpha(t["success"], .45), "merge.incomingHeaderBackground")
    put(alpha(t["info"], .22), "merge.currentContentBackground")
    put(alpha(t["info"], .40), "merge.currentHeaderBackground")
    put(t["chrome"], "diffEditor.unchangedCodeBackground", "diffEditor.unchangedRegionBackground")
    put(t["success"], "editorGutter.addedBackground", "minimapGutter.addedBackground", "editorOverviewRuler.addedForeground")
    put(t["info"], "editorGutter.modifiedBackground", "minimapGutter.modifiedBackground", "editorOverviewRuler.modifiedForeground")
    put(t["error"], "editorGutter.deletedBackground", "minimapGutter.deletedBackground", "editorOverviewRuler.deletedForeground")
    brackets = [t["syntax"]["function"], t["syntax"]["type"], t["syntax"]["property"]]
    for index in range(6):
        c["editorBracketHighlight.foreground%d" % (index + 1)] = brackets[index % 3]
    for key, value in zip(["red", "blue", "yellow", "orange", "green", "purple"],
                          [t["error"], t["info"], t["warning"], t["accent_strong"], t["success"], t["syntax"]["type"]]):
        c["charts." + key] = value
    put(t["ink"], "charts.foreground"); put(t["line_strong"], "charts.lines")
    names = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]
    for index, name in enumerate(names):
        c["terminal.ansi" + name] = ansi[index]
        c["terminal.ansiBright" + name] = ansi[index + 8]
    put(alpha("#000000", .5), "editorUnnecessaryCode.opacity")
    put(t["line"], "terminal.border")
    return {"name": t["name"], "colors": dict(sorted(c.items())), "syntax": t["syntax"], "ansi": ansi}


def check(t):
    floors = {"comment": 3.0}
    for key, color in t["syntax"].items():
        ratio = contrast(color, t["canvas"])
        assert ratio >= floors.get(key, 4.5), "%s %s on canvas is %.2f" % (t["name"], key, ratio)
    for key in ("ink", "ink2"):
        for surface in ("canvas", "chrome", "raised", "selected"):
            assert contrast(t[key], t[surface]) >= 4.5, "%s %s on %s" % (t["name"], key, surface)
    assert contrast(t["ink3"], t["canvas"]) >= 3.0
    assert contrast(t["accent_text"], t["canvas"]) >= 4.5 and contrast(t["accent_text"], t["chrome"]) >= 4.2
    assert contrast(t["on_accent"], t["accent_strong"]) >= 3.0
    for key in ("ink", "ink2"):
        assert contrast(t[key], clay_tint(t)) >= 4.5, "%s %s on the selection tint is %.2f" % (t["name"], key, contrast(t[key], clay_tint(t)))
    assert contrast("#FFFFFF", t["button"]) >= 4.0, "%s button label is %.2f" % (t["name"], contrast("#FFFFFF", t["button"]))
    assert contrast(t["button"], t["canvas"]) >= 3.0
    for index, color in enumerate(t["ansi"]):
        if index not in (0, 8) or t["name"].endswith("Light"):
            assert contrast(color, t["canvas"]) >= (2.0 if index in (0, 8) else 4.0), "%s ansi %d is %.2f" % (t["name"], index, contrast(color, t["canvas"]))


if __name__ == "__main__":
    for tokens in TOKENS.values():
        check(tokens)
    target = Path(__file__).resolve().parent.parent / "Sources/HarborSSH/Resources/Themes/anthropic.json"
    target.write_text(json.dumps({mode: palette(tokens) for mode, tokens in TOKENS.items()}, indent=2) + "\n")
    print("Wrote", target)
