/*
    Plasma Split Switcher - nested test layout (2x2)

    Builds a 2x2 grid with a *vertical* root (two rows, each split into two
    columns), so the left and right quarters are not direct children of the
    root.  The default "columns" grouping must still put the top-left and
    bottom-left windows in one group.  Prints diagnostics with the PSSNESTED
    prefix.  Run by tools/nested-test.sh --layout 2x2.

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
root.split(2); // vertical: two rows
var top = root.tiles[0];
var bottom = root.tiles[1];
top.relativeGeometry = { x: 0.0, y: 0.0, width: 1.0, height: 0.5 };
bottom.relativeGeometry = { x: 0.0, y: 0.5, width: 1.0, height: 0.5 };
top.split(1); // horizontal: two columns in the top row
bottom.split(1); // horizontal: two columns in the bottom row
top.tiles[0].relativeGeometry = { x: 0.0, y: 0.0, width: 0.5, height: 0.5 };
top.tiles[1].relativeGeometry = { x: 0.5, y: 0.0, width: 0.5, height: 0.5 };
bottom.tiles[0].relativeGeometry = { x: 0.0, y: 0.5, width: 0.5, height: 0.5 };
bottom.tiles[1].relativeGeometry = { x: 0.5, y: 0.5, width: 0.5, height: 0.5 };

var clients = footClients();
out("clients=" + clients.length);
if (clients.length >= 1) {
    out("manage-top-left=" + top.tiles[0].manage(clients[0]));
}
if (clients.length >= 2) {
    out("manage-top-right=" + top.tiles[1].manage(clients[1]));
}
if (clients.length >= 3) {
    out("manage-bottom-left=" + bottom.tiles[0].manage(clients[2]));
}
if (clients.length >= 4) {
    out("manage-bottom-right=" + bottom.tiles[1].manage(clients[3]));
}
if (clients.length >= 1) {
    // The top-left quarter must group with the bottom-left quarter.
    workspace.activeWindow = clients[0];
}
out("ready");
