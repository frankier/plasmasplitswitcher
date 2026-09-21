#!/usr/bin/env python3
"""Inject keys into an Xvfb-hosted nested KWin via XTEST.

Usage: xtest_inject.py <display> <spec>...
  d<keysym>  key down
  u<keysym>  key up
  t<keysym>  tap
  s<ms>      sleep

keysym is an X11 keysym name such as Control_L, Alt_L, Shift_L, F8.

SPDX-License-Identifier: GPL-2.0-or-later
"""
import sys
import time

from Xlib import X, XK, display
from Xlib.ext import xtest


_DISPLAY = None


def wm_name(win):
    try:
        name = win.get_wm_name()
    except Exception:
        name = None
    if name:
        return name
    try:
        atom = _DISPLAY.intern_atom("_NET_WM_NAME")
        utf8 = _DISPLAY.intern_atom("UTF8_STRING")
        prop = win.get_full_property(atom, utf8)
        if prop:
            return prop.value.decode()
    except Exception:
        pass
    return None


def find_window(win, predicate):
    name = wm_name(win)
    if name and predicate(name):
        return win
    try:
        children = win.query_tree().children
    except Exception:
        children = []
    for child in children:
        found = find_window(child, predicate)
        if found:
            return found
    return None


def main():
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    global _DISPLAY
    d = display.Display(sys.argv[1])
    _DISPLAY = d
    root = d.screen().root

    win = None
    for _ in range(20):
        win = find_window(root, lambda n: "Compositor" in n)
        if win is not None:
            break
        d.sync()
        time.sleep(0.5)
    if win is None:
        # fall back to a large child of the root
        best = None
        best_area = 0
        for child in root.query_tree().children:
            try:
                g = child.get_geometry()
            except Exception:
                continue
            area = g.width * g.height
            if area > best_area:
                best, best_area = child, area
        win = best
    if win is None:
        print("xtest_inject: no window found", file=sys.stderr)
        return 1

    try:
        print("xtest_inject: focusing %r" % (wm_name(win),), file=sys.stderr)
    except Exception:
        pass
    win.set_input_focus(X.RevertToParent, X.CurrentTime)
    d.sync()
    time.sleep(0.3)

    for spec in sys.argv[2:]:
        kind, name = spec[0], spec[1:]
        if kind == "s":
            time.sleep(int(name) / 1000.0)
            continue
        keysym = XK.string_to_keysym(name)
        if keysym == 0:
            print("xtest_inject: unknown keysym %s" % name, file=sys.stderr)
            return 2
        keycode = d.keysym_to_keycode(keysym)
        if keycode == 0:
            print("xtest_inject: no keycode for %s" % name, file=sys.stderr)
            return 2
        if kind == "d":
            xtest.fake_input(d, X.KeyPress, keycode)
        elif kind == "u":
            xtest.fake_input(d, X.KeyRelease, keycode)
        elif kind == "t":
            xtest.fake_input(d, X.KeyPress, keycode)
            d.sync()
            time.sleep(0.05)
            xtest.fake_input(d, X.KeyRelease, keycode)
        d.sync()
        time.sleep(0.05)

    d.sync()
    return 0


if __name__ == "__main__":
    sys.exit(main())
