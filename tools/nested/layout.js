/*
    Plasma Split Switcher - nested test layout

    Builds a two-column tiling layout and moves the `foot` windows into it:
    the left column gets one window, the right column is split vertically and
    gets two.  The window in the right column is then activated, so the KWin
    script must restrict the switcher to that column.

    Prints diagnostics with the PSSNESTED prefix.  Run by tools/nested-test.sh.

    SPDX-License-Identifier: GPL-2.0-or-later
*/

function out(s) {
    console.error("PSSNESTED: " + s);
}

function footClients() {
    var all = workspace.windowList();
    var result = [];
    for (var i = 0; i < all.length; ++i) {
        var w = all[i];
        if (w && w.normalWindow && String(w.resourceClass) === "foot") {
            result.push(w);
        }
    }
    return result;
}

var root = workspace.rootTile(workspace.activeScreen, workspace.currentDesktop);
while (root.tiles.length > 0) {
    root.tiles[0].remove();
}
root.split(1);
var left = root.tiles[0];
var right = root.tiles[1];
left.relativeGeometry = { x: 0.0, y: 0.0, width: 0.5, height: 1.0 };
right.relativeGeometry = { x: 0.5, y: 0.0, width: 0.5, height: 1.0 };
right.split(2); // vertical: two rows inside the right column
right.tiles[0].relativeGeometry = { x: 0.5, y: 0.0, width: 0.5, height: 0.5 };
right.tiles[1].relativeGeometry = { x: 0.5, y: 0.5, width: 0.5, height: 0.5 };

var clients = footClients();
out("clients=" + clients.length);
if (clients.length >= 1) {
    out("manage-left=" + left.manage(clients[0]));
}
if (clients.length >= 2) {
    out("manage-right-top=" + right.tiles[0].manage(clients[1]));
}
if (clients.length >= 3) {
    out("manage-right-bottom=" + right.tiles[1].manage(clients[2]));
}
if (clients.length >= 2) {
    workspace.activeWindow = clients[1];
}
out("ready");
