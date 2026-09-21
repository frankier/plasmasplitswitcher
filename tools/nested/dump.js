/*
    Plasma Split Switcher - nested test dump

    Runs the same column resolution as script/contents/code/main.js, then prints
    the active column, the open switcher popup (if any) and the skipSwitcher
    state of every `foot` window.  Run by tools/nested-test.sh while the
    switcher is held open.

    SPDX-License-Identifier: GPL-2.0-or-later
*/

function out(s) {
    console.error("PSSDUMP " + s);
}

function columnTileForWindow(w) {
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
    var column = leaf;
    while (column.parent && column.parent !== root) {
        column = column.parent;
    }
    if (column.parent !== root) {
        return null;
    }
    var rootGeometry = root.relativeGeometry;
    var columnGeometry = column.relativeGeometry;
    if (!(columnGeometry.width < rootGeometry.width - 0.0001)) {
        return null;
    }
    return column;
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
var column = active ? columnTileForWindow(active) : null;
out("column " + (column ? tileGeometry(column) : "none"));

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
