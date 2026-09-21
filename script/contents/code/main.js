/*
    Plasma Split Switcher - KWin script

    Per-column Alt+Tab for KWin's built-in tiling.

    KWin builds the window list for its switcher (the "tab box") in C++ before
    the switcher QML is loaded, and Tab/Shift+Tab navigation happens in C++ over
    that model.  The QML can only render.  Therefore the window set is filtered
    here, through the writable `Window.skipSwitcher` property, while the
    companion WindowSwitcher package (switcher/) only positions the popup.

    The popup reads the same filtering back through `skipSwitcher` (the tabbox
    QML cannot read this script's configuration), so the two always agree.

    SPDX-FileCopyrightText: 2025 Frankie Robertson <frankier@frankier.name>
    SPDX-License-Identifier: GPL-2.0-or-later
*/

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

// Set to true to also log every re-sync.  Leave false for normal use: sync()
// runs on nearly every window event.  A line is always logged when the
// focused window moves between groups and for the whole-screen fallback.
var verbose = false;

// How the switcher groups tiled windows:
//   "columns" - windows that share a column (side by side) stay together.
//               In a 2x2 grid the left and right quarters form one group each.
//   "rows"    - windows that share a row (stacked) stay together.
//   "regions" - every direct child of the root tile is its own group.
//
// Set in System Settings > Window Management > KWin Scripts > Plasma Split
// Switcher > Configure.  Keep in sync with contents/config/main.xml; the
// switcher package does not read this value, it derives the group from the
// skipSwitcher flags set below.
var groupingMode = "columns";

function readGroupingMode() {
    // Enum entries store the choice name, but accept a numeric index and any
    // capitalisation so a hand-edited kwinrc cannot break the script.
    var value = String(readConfig("Grouping", "columns")).toLowerCase();
    if (value === "rows" || value === "1") {
        return "rows";
    }
    if (value === "regions" || value === "2") {
        return "regions";
    }
    return "columns";
}

// `print()` and `console.log()` are debug-level and are dropped by the default
// Qt logging rules, so use console.info(), which reaches the journal.
function log(message) {
    if (verbose) {
        console.info("plasmasplitswitcher: " + message);
    }
}

// ---------------------------------------------------------------------------
// Group resolution
//
// Keep this in sync with switcherAreaFor() in switcher/contents/ui/main.qml.
// ---------------------------------------------------------------------------

/** Returns the root tile `w` lives in, or null when `w` is not tiled. */
function rootTileForWindow(w) {
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
    return root;
}

/** True when the two spans match within `tolerance` pixels. */
function sameSpan(startA, lengthA, startB, lengthB, tolerance) {
    return Math.abs(startA - startB) <= tolerance &&
           Math.abs(lengthA - lengthB) <= tolerance;
}

/** Collects every leaf tile under `tile` into `out`. */
function collectLeafTiles(tile, out) {
    var children = tile.tiles;
    if (!children || children.length === 0) {
        out.push(tile);
        return out;
    }
    for (var i = 0; i < children.length; ++i) {
        collectLeafTiles(children[i], out);
    }
    return out;
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

/**
 * Returns the windows that share the switcher group of `w`, or null when `w`
 * has no group.
 *
 * With no group (floating, quick-tiled, single tile, no tiling at all) the
 * caller unskips every window, which restores the full stock switcher.
 */
function groupWindowsFor(w) {
    var leaf = w ? w.tile : null;
    if (!leaf) {
        return null; // floating or quick-tiled window
    }

    var root = rootTileForWindow(w);
    if (!root || root === leaf) {
        return null; // a single tile filling the screen
    }
    if (!root.tiles || root.tiles.length < 2) {
        return null; // nothing to group
    }

    if (groupingMode === "regions") {
        // A region is the direct child of the root tile that contains `w`.
        // Its shape follows the root's split direction: a column when the root
        // is horizontal, a row when it is vertical.
        var region = leaf;
        while (region.parent && region.parent !== root) {
            region = region.parent;
        }
        if (region.parent !== root) {
            return null;
        }
        return collectWindows(region, []);
    }

    // Columns and rows are pure geometry, so a 2x2 grid is split into left and
    // right columns regardless of how KWin nested the tiles.
    var activeGeometry = leaf.absoluteGeometry;
    var leaves = collectLeafTiles(root, []);
    var group = [];
    for (var i = 0; i < leaves.length; ++i) {
        var geometry = leaves[i].absoluteGeometry;
        var matches = groupingMode === "rows"
            ? sameSpan(geometry.y, geometry.height,
                       activeGeometry.y, activeGeometry.height, 1.0)
            : sameSpan(geometry.x, geometry.width,
                       activeGeometry.x, activeGeometry.width, 1.0);
        if (matches) {
            collectWindows(leaves[i], group);
        }
    }
    return group;
}

/** A stable, readable key for the bounding box of a group. */
function groupKey(windows) {
    if (!windows || windows.length === 0) {
        return "none";
    }
    var minX = Infinity;
    var minY = Infinity;
    var maxX = -Infinity;
    var maxY = -Infinity;
    for (var i = 0; i < windows.length; ++i) {
        var tile = windows[i].tile;
        if (!tile) {
            continue;
        }
        var geometry = tile.absoluteGeometry;
        minX = Math.min(minX, geometry.x);
        minY = Math.min(minY, geometry.y);
        maxX = Math.max(maxX, geometry.x + geometry.width);
        maxY = Math.max(maxY, geometry.y + geometry.height);
    }
    if (!isFinite(minX)) {
        return "none";
    }
    return Math.round(minX) + "," + Math.round(minY) + " " +
           Math.round(maxX - minX) + "x" + Math.round(maxY - minY);
}

// ---------------------------------------------------------------------------
// Filtering
// ---------------------------------------------------------------------------

// Re-entrancy guard: writing skipSwitcher emits skipSwitcherChanged, which the
// connections below also answer.
var syncing = false;
var lastGroupKey = "";

/**
 * Marks every window that is not in the focused window's group with
 * `skipSwitcher = true`.  With no group, every window is unskipped, which
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
        // Re-read on every sync: KWin reparses kwinrc when the settings panel
        // writes it, and this picks the new mode up on the next window event.
        groupingMode = readGroupingMode();

        var active = workspace.activeWindow;
        var group = active ? groupWindowsFor(active) : null;
        var key = groupKey(group);
        if (key !== lastGroupKey) {
            console.info("plasmasplitswitcher: switcher group " + key +
                         " [" + groupingMode + "]" +
                         (group ? " (" + group.length + " window(s))" : " (whole screen)"));
            lastGroupKey = key;
        } else {
            log("re-synced without a group change");
        }

        var all = workspace.windowList();
        for (var i = 0; i < all.length; ++i) {
            var w = all[i];
            var skip = group ? (group.indexOf(w) === -1) : false;
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

groupingMode = readGroupingMode(); // also refreshed by sync()

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
