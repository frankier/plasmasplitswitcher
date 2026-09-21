/*
    Plasma Split Switcher - reset helper

    Clears the `skipSwitcher` flag that the main script sets on windows outside
    the focused tiling column.  Run it when the script was disabled or removed
    without a chance to restore the flags.

    This file is loaded and run by install.sh --uninstall.  It can also be run
    by hand from the KWin debug console or with:

        qdbus org.kde.KWin /Scripting \
            org.kde.kwin.Scripting.loadScript \
            $PWD/tools/reset-skip-switcher.js plasmasplitswitcher-reset

    SPDX-FileCopyrightText: 2025 Frankie Robertson <frankier@frankier.name>
    SPDX-License-Identifier: GPL-2.0-or-later
*/

(function () {
    var all = workspace.windowList();
    var cleared = 0;
    for (var i = 0; i < all.length; ++i) {
        // Window rules win, so a deliberate "Skip Switcher" rule survives.
        if (all[i].skipSwitcher) {
            all[i].skipSwitcher = false;
            ++cleared;
        }
    }
    console.info("plasmasplitswitcher: cleared skipSwitcher on " + cleared + " window(s)");
})();
