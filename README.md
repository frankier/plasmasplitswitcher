# Plasma Split Switcher

Per-column Alt+Tab for KWin's built-in tiling. The rest of this README and most of the codebase
was generated via DeepSeek Flash v4.1.

When the focused window is in a tiled column, the window switcher shows only
the windows of that column, and the popup is centred and sized inside the
column.  When the focused window is not in a column (floating, quick-tiled,
single tile, no tiling at all), the switcher is the stock Plasma switcher:
same list, same look, same screen-centred position.

Target: KWin / Plasma 6.7 on Wayland (developed and tested against
KWin 6.7.5 on Fedora 44).

## Behaviour

- Alt+Tab / Alt+Shift+Tab and Meta+Tab / Meta+Shift+Tab show only the windows
  of the focused window's column.
- The popup is centred on that column and shrinks its thumbnail cells so it
  never spills into a neighbouring column.
- Nothing outside the popup changes: no screen-wide dimming.
- Everything else stays stock: MRU ordering, desktop/activity filtering,
  minimized handling, wrap-around, wheel, click, close buttons, thumbnails,
  release-to-activate.
- The alternative mode and the "current application" modes use the same
  filtering and positioning.

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
  property on windows outside the focused window's column.  The window list
  is genuinely filtered, so navigation, ordering and activation stay stock.
- **`switcher/`** — a `KWin/WindowSwitcher` package.  It is a vendored copy of
  KWin's stock `thumbnail_grid` layout with a marked patch that centres the
  popup on the focused window's column instead of the screen and shrinks the
  thumbnail cells to fit narrow columns.  With no column it behaves exactly
  like the stock layout (same position, size and contents).

Both artifacts are required.  Without the script the popup is still centred on
the column, but the window list is not filtered; without the package the list
is filtered, but the popup is centred on the screen.

A "column" is the direct child of the root tile that contains the focused
window, and only when the root tile splits its children side by side.  Layouts
whose root tile splits into full-width rows, floating windows, quick-tiled
windows and single-tile layouts all fall back to stock behaviour.  Only
properties declared on `Tile` are used, so no `CustomTile` API is required.

## Configuration

`install.sh` sets:

| Group | Key | Value | Why |
| --- | --- | --- | --- |
| `TabBox`, `TabBoxAlternative` | `LayoutName` | `plasmasplitswitcher` | use the patched layout |
| `TabBox`, `TabBoxAlternative` | `HighlightWindows` | `false` | the popup is inside one column, so screen-wide dimming would spill into the other column |
| `Plugins` | `plasmasplitswitcherEnabled` | `true` | load the filter script |

Everything else, including MRU ordering and desktop/activity filtering, is left
to the stock TabBox configuration.

## Limitations

- **Window rules win.** `skipSwitcher` is applied through the window rules, so
  a deliberate "Skip Switcher" rule is never overridden.  The opposite is also
  true: a rule that forces `skipSwitcher = false` will keep that window in the
  list even when it is outside the column.
- **Other scripts that set `skipSwitcher`.** This script only ever sets the
  property, and another script that also uses it may fight over the values.
  In particular, do not enable KWin's optional `synchronizeskipswitcher`
  system script: it copies `skipTaskbar` to `skipSwitcher` on every window and
  would undo the filter.
- **Disabling the plugin.** Removing or disabling the script while windows are
  open leaves the flags set.  Use `./install.sh --uninstall` (which clears
  them) or restart KWin.
- **Columns only.** A layout whose root tile splits into full-width rows is
  treated as having no columns and falls back to stock behaviour.
- **Global dimming.** `HighlightWindows = false` applies to both tab box
  configurations; re-enable it manually if you prefer the dimming.
- **All-desktop / all-activity modes.** If you configure the tab box to show
  windows from all desktops or activities, windows of other desktops and
  activities are treated as outside the column and are hidden.
- **Vendored layout.** `switcher/contents/ui/main.qml` is a copy of KWin's
  stock `thumbnail_grid`.  Re-sync it after a KWin upgrade; see below.

## Development

### Headless nested test

```sh
tools/nested-test.sh
```

This runs a complete KWin inside an invisible Xvfb display, so nothing appears
on the real screen and the real session keeps its focus.  It builds a
two-column layout, opens the switcher with XTEST, and checks that the popup is
centred inside the column and that only the column's windows are offered.

Requirements: `kwin_wayland`, `Xvfb`, `dbus-run-session`, `kglobalacceld`,
`foot`, `kpackagetool6`, `qdbus`, `journalctl`, and `python3` with
`python-xlib`.

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
