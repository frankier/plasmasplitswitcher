# Plasma Split Switcher

Per-group Alt+Tab for KWin's built-in tiling (per-column by default). The rest of this README and most of the codebase
was generated via DeepSeek Flash v4.1.

When the focused window is in a tiled group, the window switcher shows only
the windows of that group, and the popup is centred and sized inside the
group.  By default the groups are the tiling *columns*, so the four quarters
of a 2x2 grid belong to the left or the right column.  When the focused window
is not in a group (floating, quick-tiled, single tile, no tiling at all), the
switcher is the stock Plasma switcher: same list, same look, same screen-centred
position.

Target: KWin / Plasma 6.7 on Wayland (developed and tested against
KWin 6.7.5 on Fedora 44).

## Behaviour

- Alt+Tab / Alt+Shift+Tab and Meta+Tab / Meta+Shift+Tab show only the windows
  of the focused window's group.
- The popup is centred on that group and shrinks its thumbnail cells so it
  never spills into a neighbouring group.
- Nothing outside the popup changes: no screen-wide dimming.
- Everything else stays stock: MRU ordering, desktop/activity filtering,
  minimized handling, wrap-around, wheel, click, close buttons, thumbnails,
  release-to-activate.
- The alternative mode and the "current application" modes use the same
  filtering and positioning.

## Grouping modes

The grouping is chosen in System Settings > Window Management > KWin Scripts >
Plasma Split Switcher > Configure:

| Mode | A 2x2 grid, focused top-left | Notes |
| --- | --- | --- |
| **Columns** (default) | top-left + bottom-left | windows that share a column stay together |
| **Rows** | top-left + top-right | windows that share a row stay together |
| **Regions** | top-left + top-right | each direct child of the root tile is its own group; this follows the tiling tree instead of the screen geometry, like the original column-only code |

Columns and rows are pure geometry, so a 2x2 grid is split into left and right
columns no matter how KWin nested the tiles.  In `regions` mode a vertical root
produces row groups, where the original column-only code fell back to the full
stock list.  The choice is stored as `Grouping` in the
`[Script-plasmasplitswitcher]` group of `kwinrc`.

The KWin script owns the grouping.  The switcher layout recovers the group from
the `skipSwitcher` flags the script sets, so the popup always matches the list
without reading the setting itself.

## Install

```sh
./install.sh
```

The script installs both packages with `kpackagetool6`, writes the required
`kwinrc` keys and asks KWin to reconfigure.  It is safe to run again.

Use `./install.sh --dry-run` to see what it would do, and `--force` to replace
an existing non-default `[TabBox] LayoutName`.

Revert with:

```sh
./install.sh --uninstall
```

That removes both packages, restores the stock `thumbnail_grid` layout and
clears the `skipSwitcher` flags the script set on running windows.

To install by hand instead:

```sh
kpackagetool6 --type KWin/WindowSwitcher --install switcher/
kpackagetool6 --type KWin/Script          --install script/

kwriteconfig6 --file kwinrc --group TabBox             --key LayoutName plasmasplitswitcher
kwriteconfig6 --file kwinrc --group TabBoxAlternative  --key LayoutName plasmasplitswitcher
kwriteconfig6 --file kwinrc --group TabBox             --key HighlightWindows false
kwriteconfig6 --file kwinrc --group TabBoxAlternative  --key HighlightWindows false
kwriteconfig6 --file kwinrc --group Plugins            --key plasmasplitswitcherEnabled true

qdbus org.kde.KWin /KWin reconfigure
```

## How it works

KWin builds the switcher's window list in C++ before the switcher QML is
loaded, and Tab navigation is handled in C++ over that list.  The QML can only
render.  The feature therefore uses two artifacts:

- **`script/`** — a KWin script that sets the writable `Window.skipSwitcher`
  property on windows outside the focused window's group.  The window list
  is genuinely filtered, so navigation, ordering and activation stay stock.
  It also owns the grouping mode (see the settings panel above).
- **`switcher/`** — a `KWin/WindowSwitcher` package.  It is a vendored copy of
  KWin's stock `thumbnail_grid` layout with a marked patch that centres the
  popup on the focused window's group instead of the screen and shrinks the
  thumbnail cells to fit narrow groups.  With no group it behaves exactly
  like the stock layout (same position, size and contents).

Both artifacts are required.  The switcher layout cannot read the script's
configuration, so it recovers the group from the `skipSwitcher` flags the
script sets on the windows: the popup is the bounding box of the offered
windows that share the focused window's tile tree.  Without the script no
window is skipped, so the popup falls back to the tiling area instead of the
group.

A group is chosen from the focused window's tile tree (see the grouping modes
above).  Floating windows, quick-tiled windows and single-tile layouts have no
group and fall back to stock behaviour.  Only properties declared on `Tile`
are used, so no `CustomTile` API is required.

## Configuration

`install.sh` sets:

| Group | Key | Value | Why |
| --- | --- | --- | --- |
| `TabBox`, `TabBoxAlternative` | `LayoutName` | `plasmasplitswitcher` | use the patched layout |
| `TabBox`, `TabBoxAlternative` | `HighlightWindows` | `false` | the popup is inside one group, so screen-wide dimming would spill into the other group |
| `Plugins` | `plasmasplitswitcherEnabled` | `true` | load the filter script |
| `Script-plasmasplitswitcher` | `Grouping` | `columns` | how tiled windows are grouped; set from the script's settings panel |

Everything else, including MRU ordering and desktop/activity filtering, is left
to the stock TabBox configuration.

## Limitations

- **Window rules win.** `skipSwitcher` is applied through the window rules, so
  a deliberate "Skip Switcher" rule is never overridden.  The opposite is also
  true: a rule that forces `skipSwitcher = false` will keep that window in the
  list even when it is outside the group.  Because the popup is the bounding
  box of the offered windows, such a window also widens the popup.
- **Other scripts that set `skipSwitcher`.** This script only ever sets the
  property, and another script that also uses it may fight over the values.
  In particular, do not enable KWin's optional `synchronizeskipswitcher`
  system script: it copies `skipTaskbar` to `skipSwitcher` on every window and
  would undo the filter.
- **Disabling the plugin.** Removing or disabling the script while windows are
  open leaves the flags set.  Use `./install.sh --uninstall` (which clears
  them) or restart KWin.
- **Global dimming.** `HighlightWindows = false` applies to both tab box
  configurations; re-enable it manually if you prefer the dimming.
- **All-desktop / all-activity modes.** If you configure the tab box to show
  windows from all desktops or activities, windows of other desktops and
  activities are treated as outside the group and are hidden.
- **Vendored layout.** `switcher/contents/ui/main.qml` is a copy of KWin's
  stock `thumbnail_grid`.  Re-sync it after a KWin upgrade; see below.

## Development

### Headless nested test

```sh
tools/nested-test.sh                              # 2-column layout, columns mode
tools/nested-test.sh --layout 2x2                 # 2x2 grid, columns mode
tools/nested-test.sh --layout 2x2 --grouping rows # 2x2 grid, rows mode
```

This runs a complete KWin inside an invisible Xvfb display, so nothing appears
on the real screen and the real session keeps its focus.  It builds a tiling
layout, writes the chosen `Grouping` setting, opens the switcher with XTEST,
and checks that the popup is centred inside the expected group and that only
that group's windows are offered.  `--layout` selects the tiling tree and
`--grouping` selects the setting; both default to `columns`.

Requirements: `kwin_wayland`, `Xvfb`, `dbus-run-session`, `kglobalacceld`,
`foot`, `kpackagetool6`, `qdbus`, `journalctl`, and `python3` with
`python-xlib`.  The test creates its own `XDG_RUNTIME_DIR` when there is none
and forces KWin to log to stderr, so it also runs in a container.

### Continuous integration

`.github/workflows/ci.yml` runs two jobs on every push to `main` and every
pull request:

- **Static checks** run ShellCheck, `bash -n`, `node --check` on the KWin
  JavaScript, `py_compile` on the XTEST helper, and validate both package
  metadata files.
- **Nested KWin** runs the headless test above for `--layout columns`,
  `--layout 2x2`, `--layout 2x2 --grouping rows` and
  `--layout 2x2 --grouping regions`.  It runs in a `fedora:44` container on the
  Ubuntu runner, so the test always sees a current KWin.

### Upstream drift

```sh
tools/check-upstream-diff.sh
```

This compares the installed stock `thumbnail_grid` against the revision this
repository vendored, and prints the diff between it and the patched copy.  Any
difference outside a `plasmasplitswitcher patch` block has to be re-applied by
hand.  After re-syncing, update `tools/upstream-thumbnail_grid.sha256`.

### Reset helper

If the script was disabled without clearing its state, load
`tools/reset-skip-switcher.js` once:

```sh
qdbus org.kde.KWin /Scripting \
    org.kde.kwin.Scripting.loadScript \
    "$PWD/tools/reset-skip-switcher.js" plasmasplitswitcher-reset
```

## License

GPL-2.0-or-later.  See `LICENSE`.

The window switcher layout is derived from KWin's `thumbnail_grid`:

- SPDX-FileCopyrightText: 2020 Chris Holland <zrenfire@gmail.com>
- SPDX-FileCopyrightText: 2023 Nate Graham <nate@kde.org>
