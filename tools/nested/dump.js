/*
    Plasma Split Switcher - nested test dump

    Independently computes the expected switcher group for the configured
    grouping mode, then prints the open switcher popup (if any) and the
    skipSwitcher state of every `foot` window.  Run by tools/nested-test.sh
    while the switcher is held open.

    tools/nested-test.sh replaces the GROUPING value below to match the
    [Script-plasmasplitswitcher] Grouping setting written into kwinrc.

    SPDX-License-Identifier: GPL-2.0-or-later
*/

var GROUPING = "columns";

function out(s) {
    console.error("PSSDUMP " + s);
}

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

function sameSpan(startA, lengthA, startB, lengthB) {
    return Math.abs(startA - startB) <= 1.0 && Math.abs(lengthA - lengthB) <= 1.0;
}

// Returns an object exposing `absoluteGeometry` for the group that contains
// `w`, or null when `w` has no group.
function groupGeometryForWindow(w) {
    if (!w) {
        return null;
    }
    var leaf = w.tile;
    if (!leaf) {
        return null;
    }
    var root = leaf;
    while (root.parent) {
        root = root.parent;
    }
    if (root === leaf) {
        return null;
    }
    if (!root.tiles || root.tiles.length < 2) {
        return null;
    }

    if (GROUPING === "regions") {
        var region = leaf;
        while (region.parent && region.parent !== root) {
            region = region.parent;
        }
        if (region.parent !== root) {
            return null;
        }
        return { absoluteGeometry: region.absoluteGeometry };
    }

    var activeGeometry = leaf.absoluteGeometry;
    var leaves = collectLeafTiles(root, []);
    var minX = Infinity;
    var minY = Infinity;
    var maxX = -Infinity;
    var maxY = -Infinity;
    for (var i = 0; i < leaves.length; ++i) {
        var g = leaves[i].absoluteGeometry;
        var matches = GROUPING === "rows"
            ? sameSpan(g.y, g.height, activeGeometry.y, activeGeometry.height)
            : sameSpan(g.x, g.width, activeGeometry.x, activeGeometry.width);
        if (matches) {
            minX = Math.min(minX, g.x);
            minY = Math.min(minY, g.y);
            maxX = Math.max(maxX, g.x + g.width);
            maxY = Math.max(maxY, g.y + g.height);
        }
    }
    if (!isFinite(minX)) {
        return null;
    }
    return { absoluteGeometry: { x: minX, y: minY, width: maxX - minX, height: maxY - minY } };
}

function tileGeometry(tile) {
    var g = tile.absoluteGeometry;
    return Math.round(g.x) + " " + Math.round(g.y) + " " +
           Math.round(g.width) + " " + Math.round(g.height);
}

function windowGeometry(w) {
    var g = w.frameGeometry;
    return Math.round(g.x) + " " + Math.round(g.y) + " " +
           Math.round(g.width) + " " + Math.round(g.height);
}

var active = workspace.activeWindow;
var group = active ? groupGeometryForWindow(active) : null;
out("column " + (group ? tileGeometry(group) : "none"));

var all = workspace.windowList();
var footIndex = 0;
for (var i = 0; i < all.length; ++i) {
    var w = all[i];
    if (!w) {
        continue;
    }
    if (w.popupWindow) {
        out("popup " + windowGeometry(w));
    }
    if (w.normalWindow && String(w.resourceClass) === "foot") {
        out("foot " + (footIndex++) + " skip=" + w.skipSwitcher);
    }
}
out("end");
