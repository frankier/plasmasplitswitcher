/*
 KWin - the KDE window manager
 This file is part of the KDE project.

 SPDX-FileCopyrightText: 2020 Chris Holland <zrenfire@gmail.com>
 SPDX-FileCopyrightText: 2023 Nate Graham <nate@kde.org>
 SPDX-FileCopyrightText: 2025 Frankie Robertson <frankier@frankier.name>

 SPDX-License-Identifier: GPL-2.0-or-later

 This file is a vendored copy of KWin's stock `thumbnail_grid` window switcher
 with a small patch, marked with "plasmasplitswitcher patch" comments.  See
 tools/check-upstream-diff.sh and README.md for how to re-sync it with a newer
 KWin release.
 */

import QtQuick
import QtQuick.Layouts
import org.kde.plasma.core as PlasmaCore
import org.kde.ksvg as KSvg
import org.kde.plasma.components as PlasmaComponents3
import org.kde.kwin as KWin
import org.kde.kirigami as Kirigami

KWin.TabBoxSwitcher {
    id: tabBox

    // --- plasmasplitswitcher patch: begin ---
    // The rectangle the popup is centred in and clamped to: the bounding box
    // of the focused window's switcher group, or the whole screen when there
    // is no group.
    //
    // The script package owns the grouping (and its settings panel) and marks
    // every window outside the group with `skipSwitcher = true`.  This QML
    // cannot read the script configuration, so it recovers the group from
    // those flags instead: the windows the switcher offers, restricted to the
    // focused window's tile tree.  That keeps the popup in sync with every
    // grouping mode without duplicating the setting.
    readonly property var switcherArea: {
        const area = switcherAreaFor(KWin.Workspace.activeWindow);
        return area !== null ? area : tabBox.screenGeometry;
    }

    // Returns the bounding box of the focused window's group, or null when
    // there is no group (floating, quick-tiled, single tile, no tiling).
    //
    // Windows in another desktop or on another output live in a different root
    // tile and are ignored.  Tile.absoluteGeometry is already in global
    // workspace coordinates, so it can be compared with
    // TabBoxSwitcher.screenGeometry directly.
    //
    // Keep the "no group" conditions in sync with groupWindowsFor() in
    // script/contents/code/main.js.
    function switcherAreaFor(w) {
        if (!w) {
            return null;
        }
        const leaf = w.tile;
        if (!leaf) {
            return null; // floating or quick-tiled window
        }

        let root = leaf;
        while (root.parent) {
            root = root.parent;
        }
        if (root === leaf) {
            return null; // a single tile filling the screen
        }
        if (!root.tiles || root.tiles.length < 2) {
            return null; // nothing to group
        }

        let minX = Infinity;
        let minY = Infinity;
        let maxX = -Infinity;
        let maxY = -Infinity;
        const windows = KWin.Workspace.windows;
        for (let i = 0; i < windows.length; ++i) {
            const other = windows[i];
            if (!other || other.skipSwitcher) {
                continue;
            }
            const tile = other.tile;
            if (!tile) {
                continue;
            }
            let otherRoot = tile;
            while (otherRoot.parent) {
                otherRoot = otherRoot.parent;
            }
            if (otherRoot !== root) {
                continue;
            }
            const geometry = tile.absoluteGeometry;
            minX = Math.min(minX, geometry.x);
            minY = Math.min(minY, geometry.y);
            maxX = Math.max(maxX, geometry.x + geometry.width);
            maxY = Math.max(maxY, geometry.y + geometry.height);
        }

        if (!isFinite(minX)) {
            // Defensive: a rule forcibly skipped every window of the group.
            const geometry = leaf.absoluteGeometry;
            return Qt.rect(geometry.x, geometry.y, geometry.width, geometry.height);
        }
        return Qt.rect(minX, minY, maxX - minX, maxY - minY);
    }
    // --- plasmasplitswitcher patch: end ---

    Instantiator {
        active: tabBox.visible
        delegate: PlasmaCore.Dialog {
            location: PlasmaCore.Types.Floating
            visible: true
            flags: Qt.Popup | Qt.X11BypassWindowManagerHint
            // --- plasmasplitswitcher patch: begin ---
            // Stock centres on the screen; here it centres on `switcherArea`
            // and is clamped so it can never spill into a neighbouring area.
            // With no group, switcherArea is the screen and this is identical
            // to the stock expression.
            x: Math.round(Math.max(tabBox.switcherArea.x,
                    Math.min(tabBox.switcherArea.x + tabBox.switcherArea.width - dialogMainItem.width,
                             tabBox.switcherArea.x + tabBox.switcherArea.width * 0.5 - dialogMainItem.width * 0.5)))
            y: Math.round(Math.max(tabBox.switcherArea.y,
                    Math.min(tabBox.switcherArea.y + tabBox.switcherArea.height - dialogMainItem.height,
                             tabBox.switcherArea.y + tabBox.switcherArea.height * 0.5 - dialogMainItem.height * 0.5)))
            // --- plasmasplitswitcher patch: end ---

            mainItem: FocusScope {
                id: dialogMainItem

                focus: true

                // --- plasmasplitswitcher patch: begin ---
                // Stock uses tabBox.screenGeometry here.  With no group,
                // switcherArea *is* the screen geometry, so these are
                // unchanged for floating windows.
                property int maxWidth: tabBox.switcherArea.width * 0.9
                property int maxHeight: tabBox.switcherArea.height * 0.7
                // --- plasmasplitswitcher patch: end ---
                property real screenFactor: tabBox.screenGeometry.width / tabBox.screenGeometry.height
                property int maxGridColumnsByWidth: Math.floor(maxWidth / thumbnailGridView.cellWidth)

                property int gridColumns: {         // Simple greedy algorithm
                    // respect screenGeometry
                    const c = Math.min(thumbnailGridView.count, maxGridColumnsByWidth);
                    const residue = thumbnailGridView.count % c;
                    if (residue == 0) {
                        return c;
                    }
                    // start greedy recursion
                    return columnCountRecursion(c, c, c - residue);
                }

                property int gridRows: Math.ceil(thumbnailGridView.count / gridColumns)
                property int optimalWidth: thumbnailGridView.cellWidth * gridColumns
                property int optimalHeight: thumbnailGridView.cellHeight * gridRows
                width: Math.min(Math.max(thumbnailGridView.cellWidth, optimalWidth), maxWidth)
                height: Math.min(Math.max(thumbnailGridView.cellHeight, optimalHeight), maxHeight)

                clip: true

                // Step for greedy algorithm
                function columnCountRecursion(prevC, prevBestC, prevDiff) {
                    const c = prevC - 1;

                    // don't increase vertical extent more than horizontal
                    // and don't exceed maxHeight
                    if (prevC * prevC <= thumbnailGridView.count + prevDiff ||
                            maxHeight < Math.ceil(thumbnailGridView.count / c) * thumbnailGridView.cellHeight) {
                        return prevBestC;
                    }
                    const residue = thumbnailGridView.count % c;
                    // halts algorithm at some point
                    if (residue == 0) {
                        return c;
                    }
                    // empty slots
                    const diff = c - residue;

                    // compare it to previous count of empty slots
                    if (diff < prevDiff) {
                        return columnCountRecursion(c, c, diff);
                    } else if (diff == prevDiff) {
                        // when it's the same try again, we'll stop early enough thanks to the landscape mode condition
                        return columnCountRecursion(c, prevBestC, diff);
                    }
                    // when we've found a local minimum choose this one (greedy)
                    return columnCountRecursion(c, prevBestC, diff);
                }

                // Just to get the margin sizes
                KSvg.FrameSvgItem {
                    id: hoverItem
                    imagePath: "widgets/viewitem"
                    prefix: "hover"
                    visible: false
                }

                GridView {
                    id: thumbnailGridView
                    anchors.fill: parent
                    focus: true
                    model: tabBox.model
                    currentIndex: tabBox.currentIndex

                    readonly property int iconSize: Kirigami.Units.iconSizes.huge
                    readonly property int captionRowHeight: Kirigami.Units.gridUnit * 2
                    readonly property int columnSpacing: Kirigami.Units.gridUnit
                    // --- plasmasplitswitcher patch: begin ---
                    // Shrink the thumbnail cells so that a narrow group can
                    // fit them.  `usableWidth` is the group width minus the
                    // item frame and the dialog's own margins; `targetColumns`
                    // is how many cells KWin would like to place side by side.
                    // On a full screen this clamps back to the stock
                    // Kirigami.Units.gridUnit * 16, so the no-group case is
                    // bit-identical to stock.
                    readonly property real usableWidth: Math.max(0, tabBox.switcherArea.width
                            - hoverItem.margins.left - hoverItem.margins.right
                            - 2 * Kirigami.Units.largeSpacing)
                    readonly property int targetColumns: Math.max(1, Math.min(count, 2))
                    readonly property int thumbnailWidth: {
                        const stock = Kirigami.Units.gridUnit * 16;
                        const available = usableWidth / targetColumns;
                        return Math.round(Math.max(Kirigami.Units.iconSizes.huge,
                                                   Math.min(stock, available)));
                    }
                    // --- plasmasplitswitcher patch: end ---
                    readonly property int thumbnailHeight: thumbnailWidth * (1.0/dialogMainItem.screenFactor)
                    cellWidth: hoverItem.margins.left + thumbnailWidth + hoverItem.margins.right
                    cellHeight: hoverItem.margins.top + captionRowHeight + thumbnailHeight + hoverItem.margins.bottom

                    keyNavigationWraps: true
                    highlightMoveDuration: 0

                    delegate: MouseArea {
                        id: thumbnailGridItem
                        width: thumbnailGridView.cellWidth
                        height: thumbnailGridView.cellHeight
                        focus: GridView.isCurrentItem
                        hoverEnabled: true

                        Accessible.name: model.caption
                        Accessible.role: Accessible.ListItem

                        onClicked: {
                            tabBox.model.activate(index);
                        }

                        ColumnLayout {
                            id: columnLayout
                            z: 0
                            spacing: thumbnailGridView.columnSpacing
                            anchors.fill: parent
                            anchors.leftMargin: hoverItem.margins.left * 2
                            anchors.topMargin: hoverItem.margins.top * 2
                            anchors.rightMargin: hoverItem.margins.right * 2
                            anchors.bottomMargin: hoverItem.margins.bottom * 2


                            // KWin.WindowThumbnail needs a container
                            // otherwise it will be drawn the same size as the parent ColumnLayout
                            Item {
                                Layout.fillWidth: true
                                Layout.fillHeight: true

                                KWin.WindowThumbnail {
                                    anchors.fill: parent
                                    wId: windowId
                                }

                                Kirigami.Icon {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    anchors.verticalCenter: parent.bottom
                                    anchors.verticalCenterOffset: Math.round(-thumbnailGridView.iconSize / 4)
                                    width: thumbnailGridView.iconSize
                                    height: thumbnailGridView.iconSize

                                    source: model.icon
                                }

                                PlasmaComponents3.Button {
                                    id: closeButton
                                    anchors {
                                        right: parent.right
                                        top: parent.top
                                        // Deliberately touch the inner edges of the frame
                                        rightMargin: -columnLayout.anchors.rightMargin
                                        topMargin: -columnLayout.anchors.topMargin
                                    }
                                    visible: model.closeable && typeof tabBox.model.close !== 'undefined' &&
                                            (thumbnailGridItem.containsMouse
                                            || closeButton.hovered
                                            || thumbnailGridItem.focus
                                            || Kirigami.Settings.tabletMode
                                            || Kirigami.Settings.hasTransientTouchInput
                                            )
                                    icon.name: 'window-close-symbolic'
                                    onClicked: {
                                        tabBox.model.close(index);
                                    }
                                }
                            }

                            PlasmaComponents3.Label {
                                Layout.fillWidth: true
                                text: model.caption
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                                textFormat: Text.PlainText
                                elide: Text.ElideRight
                            }
                        }
                    } // GridView.delegate

                    highlight: KSvg.FrameSvgItem {
                        imagePath: "widgets/viewitem"
                        prefix: "hover"
                    }

                    onCurrentIndexChanged: tabBox.currentIndex = thumbnailGridView.currentIndex;
                } // GridView

                Kirigami.PlaceholderMessage {
                    anchors.centerIn: parent
                    width: parent.width - Kirigami.Units.largeSpacing * 2
                    icon.source: "edit-none"
                    text: i18ndc("kwin", "@info:placeholder no entries in the task switcher", "No open windows")
                    visible: thumbnailGridView.count === 0
                }

                Keys.onPressed: {
                    if (event.key == Qt.Key_Left) {
                        thumbnailGridView.moveCurrentIndexLeft();
                    } else if (event.key == Qt.Key_Right) {
                        thumbnailGridView.moveCurrentIndexRight();
                    } else if (event.key == Qt.Key_Up) {
                        thumbnailGridView.moveCurrentIndexUp();
                    } else if (event.key == Qt.Key_Down) {
                        thumbnailGridView.moveCurrentIndexDown();
                    } else {
                        return;
                    }

                    thumbnailGridView.currentIndexChanged(thumbnailGridView.currentIndex);
                }
            } // Dialog.mainItem

            onSceneGraphError: () => {
                // This slot is intentionally left blank, otherwise QtQuick may post a qFatal() message on a graphics reset.
            }
        } // Dialog
    } // Instantiator
}
