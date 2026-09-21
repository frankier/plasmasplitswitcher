# PLAN — Plasma Split Switcher (per-column Alt+Tab for KWin tiling)

Per-column window switcher for KWin 6.7: Alt+Tab behaves exactly like Plasma's
normal switcher, except that when the focused window is inside a tiled column the
list is limited to that column and the popup is centred/sized inside the column,
without touching the other column.

Target environment (verified on this machine):

- KWin / Plasma **6.7.5**, Fedora 44, Wayland session.
- User's tiling config (from `~/.config/kwinrc`):
  `[Tiling][<output-uuid>][<desktop-uuid>] tiles={"layoutDirection":"horizontal","tiles":[{"width":0.25},{"width":0.5},{"width":0.25}]}`
  → the root tile is horizontal, so its direct children are columns.
- No `[TabBox]` section in `kwinrc` yet → stock defaults are in effect
  (`LayoutName=thumbnail_grid`, `HighlightWindows=true`, `ShowOnActiveScreen`).

## 1. Goal and acceptance criteria

1. While the focused window is in a tiled column, Alt+Tab / Alt+Shift+Tab shows
   **only windows of that column**.
2. The popup appears **centred inside that column** and never overlaps the other
   column; it shrinks to fit narrow columns.
3. Nothing outside the popup is affected (no screen-wide dimming).
4. While the focused window is *not* in a tiled column (floating, quick-tiled,
   single tile, no tiling), the switcher is **indistinguishable from stock
   Plasma** — same look, same list, same screen-centred position.
5. Everything else stays stock: MRU ordering (`FocusChainSwitching`), current
   desktop/activity filtering, minimized handling, wrap-around, wheel, click,
   close-button, thumbnails, Alt-release activation.

Accepted trade-off: this cannot be a single QML artifact. KWin builds the window
list in C++ (`ClientModel`) *before* the switcher QML is instantiated
(`src/tabbox/tabbox.cpp`: `reset()` → `createModel()` → `show()` →
`TabBoxHandlerPrivate::show()`), and Tab/Shift+Tab navigation is C++
(`TabBoxHandler::nextPrev`). The QML can only render. Therefore the design uses
two artifacts: a KWin script that filters the model, and a switcher package that
positions the popup.

## 2. Research findings that the design depends on

| Fact | Where |
| --- | --- |
| Tab list is built in C++ before QML load; nav is C++ over the model | `src/tabbox/tabbox.cpp`, `src/tabbox/tabboxhandler.cpp` |
| Model filter is `checkDesktop && checkActivity && checkApplications && checkMinimized && checkMultiScreen && wantsTabFocus() && !skipSwitcher()` | `TabBoxHandlerImpl::clientToAddToList`, `src/tabbox/tabbox.cpp` |
| `skipSwitcher` is a writable property: `Q_PROPERTY(bool skipSwitcher … WRITE setSkipSwitcher)` | `src/window.h` |
| `setSkipSwitcher()` passes through `rules()->checkSkipSwitcher()` and calls `updateWindowRules(Rules::SkipSwitcher)` | `Window::setSkipSwitcher`, `src/window.cpp` |
| `applyWindowRules()` re-applies the *current* value, it does not reset it | `src/window.cpp` |
| Switcher QML is created in a `QQmlContext` child of the scripting engine, so `KWin.Workspace.*` is available | `TabBoxHandlerPrivate::show()`, `src/tabbox/tabboxhandler.cpp`; shipped `coverswitch`/`flipswitch` already use `KWin.Workspace.currentActivity` |
| `KWin.Workspace` exposes `activeWindow`, `activeScreen`, `currentDesktop`, `Q_INVOKABLE rootTile(output, desktop)` | `src/scripting/workspace_wrapper.h` |
| `window.tile` → `Tile*`; `Tile.parent`, `Tile.tiles`, `Tile.windows`, `Tile.relativeGeometry`, `Tile.absoluteGeometry` are Q_PROPERTYs; `CustomTile.layoutDirection` is the orientation enum | `src/window.h`, `src/tiles/tile.h`, `src/tiles/customtile.h` |
| `Tile::absoluteGeometry()` is already in **global** workspace coordinates (`clientArea(MaximizeArea, output).x + rel.x*width`) | `src/tiles/tile.cpp` |
| Default layout `thumbnail_grid` ships at `/usr/share/kwin-wayland/tabbox/thumbnail_grid/`; layout chosen by `[TabBox] LayoutName` / `[TabBoxAlternative] LayoutName`; current-app modes reuse those configs | `TabBoxConfig::defaultLayoutName()`, `TabBox::loadConfig()` |
| Package install path: `<GenericDataLocation>/kwin/tabbox/<id>` (also `/usr/share/kwin-wayland/tabbox/`), `KPackageStructure: "KWin/WindowSwitcher"`, `X-Plasma-API: "declarativeappletscript"` | stock `metadata.json`, `createSwitcherItem()` |
| Stock `thumbnail_grid` is GPL-2.0-or-later (Chris Holland, Nate Graham) | file header |

Chosen answers from the clarification round:

- **Base layout:** vendor stock `thumbnail_grid`; non-column cases behave exactly
  like stock.
- **Filtering:** KWin script maintains `skipSwitcher` (model genuinely filtered;
  navigation stays stock).
- **Dimming:** turn `HighlightWindows` off.
- **Column fit:** shrink thumbnail cells to fit the column width.

## 3. Architecture

```
      Alt+Tab
         │
         ▼
  ┌──────────────────────┐   builds filtered ClientModel
  │ KWin script          │──────────────┐
  │ (KWin/Script, JS)    │              │
  │ syncs skipSwitcher   │              ▼
  │ to the focused column│   ┌────────────────────────────┐
  └──────────────────────┘   │ KWin WindowSwitcher package│
         ▲                   │ (vendored thumbnail_grid)  │
         │ activeWindow /    │ centres + sizes popup on   │
         │ tileChanged /     │ the column; stock otherwise│
         │ window add/remove │                            │
  ┌──────┴───────┐           └────────────────────────────┘
  │ KWin tiling  │
  └──────────────┘
```

Responsibilities:

- **Script** owns *which windows are visible* (the window set).
- **Package** owns *where the popup is drawn* (geometry).
- Neither touches selection order, activation, or the popup contents.

### 3.1 Column definition (shared)

Given the focused window `w`:

1. `leaf = w.tile`. If null (floating) → no column.
2. Walk `leaf.parent` to the top → `root`.
3. `root === leaf` (no split, single full-screen tile) → no column.
4. `col` = the direct child of `root` that contains `leaf`
   (`while (col.parent !== root) col = col.parent`).
5. A direct child counts as a column only if the root's children are side by
   side, i.e. `col.relativeGeometry.width < root.relativeGeometry.width`
   (equivalently `CustomTile.layoutDirection === Horizontal`, if the enum is
   reachable). Otherwise (root splits into full-width rows) → no column.
6. All leaf tiles under `col` (recursive over `.tiles`) provide the window set and
   `col.absoluteGeometry` provides the geometry.

Rationale: this matches KWin's built-in tiling as used here (root horizontal →
columns; nested vertical splits inside a column), covers the 2×2 grid and the
user's 3-column layout, and auto-degrades to stock behaviour for layouts that
have no columns.

Why geometric step 5 instead of the enum: a `Tile*`-typed property is exposed to
QML/JS as `Tile`; `layoutDirection` is declared on `CustomTile`, so property
lookup works at runtime but is not statically visible (qmllint/qmlcachegen
warnings) and can regress across KWin versions. The geometry test uses only
properties declared on `Tile`.

## 4. Component 1 — KWin script (`KWin/Script`, JS)

`script/contents/code/main.js`, `X-Plasma-API: javascript` (same shape as the
user's existing `ultrawidewindows` script).

State:

- `filtered` — set of windows we currently marked `skipSwitcher = true`.

Core:

```js
function columnTileForWindow(w) {
    const leaf = w && w.tile;
    if (!leaf) return null;                       // floating / quick-tiled
    let root = leaf;
    while (root.parent) root = root.parent;
    if (root === leaf) return null;               // single tile
    let col = leaf;
    while (col.parent && col.parent !== root) col = col.parent;
    if (col.parent !== root) return null;
    const r = root.relativeGeometry, c = col.relativeGeometry;
    if (!(c.width < r.width - 0.0001)) return null; // rows, not columns
    return col;
}

function collectWindows(tile, out) {
    for (let i = 0; i < tile.windows.length; ++i) out.push(tile.windows[i]);
    for (let i = 0; i < tile.tiles.length; ++i) collectWindows(tile.tiles[i], out);
    return out;
}

function sync() {
    const active = workspace.activeWindow;
    const col = active ? columnTileForWindow(active) : null;
    // `win.tile.windows` and `workspace.windowList()` return the same QObject
    // instances, so plain object identity is enough for the membership test.
    const inColumn = col ? collectWindows(col, []) : [];
    const all = workspace.windowList();
    for (let i = 0; i < all.length; ++i) {
        const w = all[i];
        const wantSkip = col ? inColumn.indexOf(w) === -1 : false;
        if (w.skipSwitcher !== wantSkip) w.skipSwitcher = wantSkip;
    }
}
```

Sketched only. Final code must guard re-entrancy (`skipSwitcher` writes emit
`skipSwitcherChanged`, which the script also listens to). Setting `skipSwitcher`
on non-client windows (panels, desktops) is harmless because the model only ever
considers clients; the desktop "Peek at Desktop" entry is appended by KWin
outside `clientToAddToList` and therefore stays visible.

Triggers (`sync()` on each; cheap, list is small):

- script start (`Component`/`main.js` top level) and after each tile change;
- `workspace.windowActivated`;
- `workspace.windowAdded` / `workspace.windowRemoved` (also connect the new
  window's `tileChanged` and re-sync);
- per-window `tileChanged`, `skipSwitcherChanged` re-sync guard;
- `workspace.currentDesktopChanged`, `workspace.currentActivityChanged`,
  `workspace.screensChanged`.

Semantics:

- Focused window in a column → every window **not** in that column gets
  `skipSwitcher = true`; column windows get `false`.
- No column → every window gets `false` (restores the full stock list).
  Windows whose `skipSwitcher` is forced by a user rule stay skipped, because
  `setSkipSwitcher()` runs `rules()->checkSkipSwitcher()`; this also means we can
  never override a deliberate "Skip Switcher" rule.
- Because the C++ model is rebuilt from this state on every `reset()`, MRU order,
  wrap-around, wheel, click and Alt-release activation are all stock.

Effect on other switcher modes: the same filter applies to Alt+`` (current
application), Meta+Tab (alternative), and border activations. This is intended
and consistent; it is called out in the README.

## 5. Component 2 — KWin WindowSwitcher package

`switcher/contents/ui/main.qml` is a **verbatim copy** of
`/usr/share/kwin-wayland/tabbox/thumbnail_grid/contents/ui/main.qml`, plus a
minimal, isolated patch. Keep the diff small and comment it clearly so the
upstream file can be re-synced on every KWin upgrade.

Patch points (all inside the existing `KWin.TabBoxSwitcher` root and its
`Instantiator` delegate):

1. Add column resolution + geometry on the root:

   ```qml
   // --- plasmasplitswitcher patch ---
   readonly property var activeColumn: columnTileFor(KWin.Workspace.activeWindow)
   readonly property rect switcherArea: activeColumn ? activeColumn.absoluteGeometry
                                                     : tabBox.screenGeometry
   function columnTileFor(w) { /* same algorithm as §3.1 */ }
   ```

2. Dialog placement — replace the two hard-coded centre expressions:

   ```qml
   x: switcherArea.x + switcherArea.width  * 0.5 - dialogMainItem.width  * 0.5
   y: switcherArea.y + switcherArea.height * 0.5 - dialogMainItem.height * 0.5
   ```

   `Tile.absoluteGeometry` is already global, so no output offset is needed.
   Clamp `x`/`y` into `switcherArea` so frame margins cannot spill into the
   neighbouring column.

3. Bounds — replace
   `maxWidth: tabBox.screenGeometry.width * 0.9`,
   `maxHeight: tabBox.screenGeometry.height * 0.7` with values derived from
   `switcherArea` (same `0.9` / `0.7` factors, so the non-column case is
   bit-identical to stock).

4. Adaptive cells (the "shrink to fit" answer). The stock code derives
   `maxGridColumnsByWidth` from `cellWidth`, and a 25 % column makes that zero
   (division by zero in `gridRows`). Add an adaptive `thumbnailWidth` that is
   computed *before* `cellWidth` and is clamped so it equals the stock value
   whenever the area is the full screen:

   ```qml
   readonly property real usableWidth: switcherArea.width - <frame margins> - 2 * largeSpacing
   readonly property real targetColumns: Math.max(1, Math.min(count, 2))
   readonly property int thumbnailWidth: Math.round(Math.max(
       Kirigami.Units.iconSizes.huge,
       Math.min(Kirigami.Units.gridUnit * 16, usableWidth / targetColumns)))
   ```

   Keep `thumbnailHeight = thumbnailWidth / dialogMainItem.screenFactor`, i.e.
   keep the *screen* aspect for the thumbnails — only the cell size shrinks, so
   thumbnails are never distorted.

5. Fallback: with `activeColumn === null`, `switcherArea === tabBox.screenGeometry`
   and the adaptive formula returns the stock `gridUnit * 16`, so the popup is
   identical to stock `thumbnail_grid` (position, size, layout, contents).

Because only one layout can be active, this package also *is* the non-column
switcher; that is what keeps requirement 4 achievable.

## 6. Configuration

Applied by `install.sh` (idempotent, with `--dry-run`), or documented for manual
use:

```sh
kpackagetool6 --type KWin/WindowSwitcher --install switcher/
kpackagetool6 --type KWin/Script          --install script/

kwriteconfig6 --file kwinrc --group TabBox             --key LayoutName plasmasplitswitcher
kwriteconfig6 --file kwinrc --group TabBoxAlternative  --key LayoutName plasmasplitswitcher
kwriteconfig6 --file kwinrc --group TabBox             --key HighlightWindows false
kwriteconfig6 --file kwinrc --group Plugins            --key plasmasplitswitcherEnabled true

qdbus org.kde.KWin /KWin reconfigure     # applies tabbox config + reloads scripts
```

Both `[TabBox]` and `[TabBoxAlternative]` are set so all four walk-through modes
(Alt+Tab, Alt+Shift+Tab, Meta+Tab, and their current-application variants) get
column behaviour and column positioning.

`install.sh` also prints how to revert (restore `LayoutName=thumbnail_grid`,
delete the `HighlightWindows` key, disable the plugin) and refuses to overwrite
an existing non-default `LayoutName` without `--force`.

## 7. Repository layout

```
plasmasplitswitcher/
├── PLAN.md
├── README.md                      # user-facing: install, behaviour, limitations
├── LICENSE                        # GPL-2.0-or-later
├── install.sh                     # kpackagetool6 + kwriteconfig6 + reconfigure
├── script/                        # KWin/Script package (plugin id: plasmasplitswitcher)
│   ├── metadata.json
│   └── contents/code/main.js
├── switcher/                      # KWin/WindowSwitcher package (layout name: plasmasplitswitcher)
│   ├── metadata.json
│   └── contents/ui/main.qml       # vendored thumbnail_grid + marked patch
└── tools/
    └── check-upstream-diff.sh     # diff our main.qml against the installed stock file
```

`script/metadata.json` mirrors the user's existing script
(`KPackageStructure: "KWin/Script"`, `X-Plasma-API: "javascript"`,
`X-Plasma-MainScript: "code/main.js"`, `License: GPL-2.0-or-later`).
`switcher/metadata.json` mirrors the stock one
(`KPackageStructure: "KWin/WindowSwitcher"`, `X-Plasma-API: "declarativeappletscript"`, `Id: plasmasplitswitcher`,
`License: GPL-2.0-or-later`, icon + i18n name kept minimal).
`tools/check-upstream-diff.sh` diffs the vendored file against
`/usr/share/kwin-wayland/tabbox/thumbnail_grid/contents/ui/main.qml` so KWin
upgrades are noticed.

## 8. Implementation steps

1. Scaffold repo: LICENSE, README stub, both `metadata.json`, empty packages.
2. Implement §3.1 column resolution + §4 script; log via `print()`.
3. Verify the filter alone (stock switcher, no package yet): Alt+Tab shows only
   the column's windows, and full list for floating windows.
4. Vendor `thumbnail_grid` verbatim; add the marked patch (§5) in one commit with
   the stock file so the diff stays reviewable.
5. Implement adaptive cell sizing; test with 25 %, 50 % and full-width columns.
6. `install.sh` + README (behaviour, limitations, revert, upgrade re-sync).
7. Manual test matrix (§9) on Wayland, then polish logging/edge cases.

## 9. Verification matrix

| # | Scenario | Expected |
| --- | --- | --- |
| 1 | 2 windows in column A, 2 in column B, focus A, Alt+Tab | only A's 2 windows; MRU order; popup inside A |
| 2 | Alt+Shift+Tab, wrap-around at both ends, mouse wheel | stock behaviour within A |
| 3 | Hold Alt, tab to second window, release | that window activates; focus stays in A |
| 4 | Focus floating window, Alt+Tab | full list, screen-centred, stock look/size |
| 5 | Focus quick-tiled (Meta+Arrow) window | stock fallback |
| 6 | Column 0.25 screen width | popup fits inside column, no overflow/clip, cells shrunk |
| 7 | Column 0.5 and full-width single tile | no distortion; single tile → stock fallback |
| 8 | Move focused window to another column (drag / tile editor / Meta+Shift+Arrow) | filter follows immediately (`tileChanged`) |
| 9 | Close/open windows, open a new window in the focused column | filter stays correct |
| 10 | Switch virtual desktop / output while tiled | re-sync; no stale `skipSwitcher` |
| 11 | Window with a user rule "Skip Switcher" inside the focused column | stays skipped (rule wins) |
| 12 | Alt+`` and Meta+Tab inside a column | filtered to column; popup inside column |
| 13 | Disable the script, re-run Alt+Tab | full stock list, popup still column-centred (documents the dependency) |
| 14 | After `kwin_wayland` restart | script auto-loads; no stale state |

Debug aids: `qdbus org.kde.KWin /KWin supportInformation` (TabBox config),
`qdbus org.kde.KWin /Scripting`, journal: `journalctl -f _COMM=kwin_wayland`.

## 10. Risks and mitigations

1. **`skipSwitcher` is a real, user-visible window property.** Mitigation: only
   ever set it, never rely on it elsewhere; user rules always win; reset to
   `false` on unload; document; keep the script small and auditable. If a future
   KWin stops using `skipSwitcher` in `clientToAddToList`, the filter silently
   stops working — covered by test 3/#1 and the README note.
2. **Vendored `thumbnail_grid` drifts on KWin upgrades.** Mitigation:
   `tools/check-upstream-diff.sh`; keep the patch inside marked blocks.
3. **`KWin.Workspace` / `Tile` API in switcher QML is not a documented stable
   contract.** It is already used by shipped switchers
   (`coverswitch`/`flipswitch`), so it is de-facto supported; column detection
   avoids the `CustomTile`-only enum and uses `Tile` properties only.
4. **Duplicate window list state** (script filter vs. package geometry could
   disagree, e.g. script not running). Mitigation: package positioning is
   independent of the filter and degrades gracefully; README documents that both
   artifacts are required.
5. **`HighlightWindows=false` is global.** Accepted (user choice); the README
   states how to re-enable it.
6. **Snap/quick-tile windows have `Tile` objects too.** Mitigation: the
   root==leaf and width checks make quick-tiles fall back to stock.
7. **Rules re-application.** `applyWindowRules()` re-applies the current
   `skipSwitcher` value through the same rules check, so it does not undo the
   filter; re-sync on desktop/activity change covers the rest.

## 11. Explicit assumptions / open points

- Column = direct child of a horizontally split root tile (§3.1). A layout whose
  root splits into full-width rows falls back to stock rather than inventing a
  "column".
- Scope is all four walk-through modes (shared `[TabBox]` /
  `[TabBoxAlternative]` layouts).
- Current desktop/activity filtering is left to stock tabbox config; the script
  only adds the column constraint.
- Distribution is local installation only (no distro packaging), install via
  `kpackagetool6`.
- Possible future, cleaner variant (out of scope): upstream a small KWin patch
  adding a `switcherArea` property on `TabBoxSwitcher` (and, ideally, a model
  filter hook), which would remove both the vendored copy and the
  `skipSwitcher` mutation. Worth proposing upstream once the local version
  proves the UX.
