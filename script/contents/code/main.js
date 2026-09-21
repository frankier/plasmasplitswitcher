/*
    Plasma Split Switcher - KWin script

    Per-column Alt+Tab for KWin's built-in tiling.

    KWin builds the window list for its switcher (the "tab box") in C++ before
    the switcher QML is loaded, and Tab/Shift+Tab navigation happens in C++ over
    that model.  The QML can only render.  Therefore the window set is filtered
    here, through the writable `Window.skipSwitcher` property, while the
    companion WindowSwitcher package (switcher/) only positions the popup.

    SPDX-FileCopyrightText: 2025 Frankie Robertson <frankier@frankier.name>
    SPDX-License-Identifier: GPL-2.0-or-later
*/

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

// Set to true to also log every re-sync.  Leave false for normal use: sync()
// runs on nearly every window event.  A line is always logged when the
// focused window moves between columns and the whole-screen fallback.
var verbose = false;

// `print()` and `console.log()` are debug-level and are dropped by the default
// Qt logging rules, so use console.info(), which reaches the journal.
function log(message) {
    if (verbose) {
        console.info("plasmasplitswitcher: " + message);
    }
}

// ---------------------------------------------------------------------------
// Column resolution
//
// Keep this in sync with columnTileFor() in switcher/contents/ui/main.qml.
// ---------------------------------------------------------------------------

/**
 * Returns the tiling column that contains `w`, or null when `w` is not in a
 * column.
 *
 * A column is the direct child of the root tile that contains `w`, but only
 * when the root tile splits its children side by side.  Layouts whose root tile
 * splits into full-width rows, floating windows, quick-tiled windows and
 * single-tile layouts all return null, which restores the stock switcher.
 */
function columnTileForWindow(w) {
    if (!w) {
        return null;
    }
    var leaf = w.tile;
    if (!leaf) {
        return null; // floating or quick-tiled window
    }

    var root = leaf;
    while (root.parent) {
        root = root.parent;
    }
    if (root === leaf) {
        return null; // a single tile filling the screen
    }

    var column = leaf;
    while (column.parent && column.parent !== root) {
        column = column.parent;
    }
    if (column.parent !== root) {
        return null;
    }

    // Only Tile properties are used on purpose: `layoutDirection` lives on
    // CustomTile and is not guaranteed.  A direct child that is narrower than
    // the root has to be a column.
    var rootGeometry = root.relativeGeometry;
    var columnGeometry = column.relativeGeometry;
    if (!(columnGeometry.width < rootGeometry.width - 0.0001)) {
        return null; // the root splits into rows, not columns
    }
    return column;
}

/** Collects every window of `tile` and its descendants into `out`. */
function collectWindows(tile, out) {
    var windows = tile.windows;
    for (var i = 0; i < windows.length; ++i) {
        out.push(windows[i]);
    }
    var children = tile.tiles;
    for (var j = 0; j < children.length; ++j) {
        collectWindows(children[j], out);
    }
    return out;
}

// ---------------------------------------------------------------------------
// Filtering
// ---------------------------------------------------------------------------

// Re-entrancy guard: writing skipSwitcher emits skipSwitcherChanged, which the
// connections below also answer.
var syncing = false;
var lastColumnKey = "";

function columnKey(tile) {
    if (!tile) {
        return "none";
    }
    var g = tile.absoluteGeometry;
    return Math.round(g.x) + "," + Math.round(g.y) + " " +
           Math.round(g.width) + "x" + Math.round(g.height);
}

/**
 * Marks every window that is not in the focused window's column with
 * `skipSwitcher = true`.  With no column, every window is unskipped, which
 * restores the full stock switcher.
 *
 * `Window.setSkipSwitcher()` passes the value through the window rules, so a
 * deliberate "Skip Switcher" rule always wins and is never overridden.
 */
function sync() {
    if (syncing) {
        return;
    }
    syncing = true;
    try {
        var active = workspace.activeWindow;
        var column = active ? columnTileForWindow(active) : null;
        var inColumn = column ? collectWindows(column, []) : null;

        var key = columnKey(column);
        if (key !== lastColumnKey) {
            console.info("plasmasplitswitcher: switcher area " + key +
                         (inColumn ? " (" + inColumn.length + " window(s))" : " (whole screen)"));
            lastColumnKey = key;
        } else {
            log("re-synced without a column change");
        }

        var all = workspace.windowList();
        for (var i = 0; i < all.length; ++i) {
            var w = all[i];
            var skip = inColumn ? (inColumn.indexOf(w) === -1) : false;
            if (w.skipSwitcher !== skip) {
                w.skipSwitcher = skip;
            }
        }
    } finally {
        syncing = false;
    }
}

// ---------------------------------------------------------------------------
// Triggers
// ---------------------------------------------------------------------------

function watchWindow(w) {
    w.tileChanged.connect(sync);
    // `Window.tile` reads the requested tile, which is committed separately.
    w.requestedTileChanged.connect(sync);
    w.skipSwitcherChanged.connect(sync);
}

function watchAllWindows() {
    var all = workspace.windowList();
    for (var i = 0; i < all.length; ++i) {
        watchWindow(all[i]);
    }
}

workspace.windowAdded.connect(function (w) {
    watchWindow(w);
    sync();
});
workspace.windowRemoved.connect(sync);
workspace.windowActivated.connect(sync);
workspace.currentDesktopChanged.connect(sync);
workspace.currentActivityChanged.connect(sync);
workspace.screensChanged.connect(sync);
workspace.screenOrderChanged.connect(sync);
options.configChanged.connect(sync);

watchAllWindows();
sync();
