#!/usr/bin/env bash
#
# Re-sync helper for the vendored thumbnail_grid window switcher.
#
# KWin ships the stock layout we patch at
# /usr/share/kwin-wayland/tabbox/thumbnail_grid/.  KWin upgrades can change it,
# which means our vendored copy (switcher/contents/ui/main.qml) may have drifted.
#
# This script:
#   1. checks the installed stock file against the revision we vendored from
#      (tools/upstream-thumbnail_grid.sha256),
#   2. prints the diff between the installed stock file and our patched copy.
#
# Anything in the diff that is not inside a "plasmasplitswitcher patch" block
# has to be re-applied by hand.
#
# Usage:
#   tools/check-upstream-diff.sh [path/to/stock/contents/ui/main.qml]
#
# Environment:
#   KWIN_STOCK_SWITCHER  same as the positional argument
#
# SPDX-License-Identifier: GPL-2.0-or-later

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(dirname "$here")"
ours="$repo/switcher/contents/ui/main.qml"
recorded="$here/upstream-thumbnail_grid.sha256"

stock="${1:-${KWIN_STOCK_SWITCHER:-}}"
if [[ -z "$stock" ]]; then
    for candidate in \
        /usr/share/kwin-wayland/tabbox/thumbnail_grid/contents/ui/main.qml \
        /usr/share/kwin/tabbox/thumbnail_grid/contents/ui/main.qml; do
        if [[ -f "$candidate" ]]; then
            stock="$candidate"
            break
        fi
    done
fi

if [[ -z "$stock" || ! -f "$stock" ]]; then
    printf 'error: could not find the stock thumbnail_grid main.qml.\n' >&2
    printf '       Pass it as an argument or set KWIN_STOCK_SWITCHER.\n' >&2
    exit 2
fi

expected="$(awk 'NR == 1 { print $1 }' "$recorded")"
actual="$(sha256sum "$stock" | awk '{ print $1 }')"

printf 'stock:    %s\n' "$stock"
printf 'vendored: %s\n' "$expected"
printf 'installed: %s\n\n' "$actual"

if [[ "$expected" == "$actual" ]]; then
    printf 'OK: the installed stock layout matches the vendored revision.\n'
    printf '    Every diff below is our patch and must sit inside a\n'
    printf '    "plasmasplitswitcher patch" block.\n'
else
    printf 'WARNING: upstream thumbnail_grid changed since this copy was vendored.\n'
    printf '         Re-vendor it and re-apply the marked patch blocks, then update\n'
    printf '         tools/upstream-thumbnail_grid.sha256.\n'
fi
printf '\n'

diff -u --label "stock (upstream)" "$stock" --label "ours (patched)" "$ours" || true
