#!/usr/bin/env bash
#
# Headless nested test for Plasma Split Switcher.
#
# Runs a complete KWin inside an invisible Xvfb display, so nothing appears on
# the real screen and the real session keeps its focus.  Inside it:
#   * builds a tiling layout,
#   * activates the window of one group,
#   * presses the "Walk Through Windows" shortcut with XTEST,
#   * checks that the popup is centred inside that group and that only the
#     group's windows are offered by the switcher.
#
# Requirements: kwin_wayland, Xvfb, dbus-run-session, kglobalacceld, foot,
# kpackagetool6, qdbus, journalctl, and python3 with python-xlib
# (package python3-xlib).
#
# Usage: tools/nested-test.sh [--layout columns|2x2] [--grouping columns|rows|regions] [--keep]
#   --layout columns  left column: 1 window, right column: 2 (default)
#   --layout 2x2      vertical root, two rows of two columns; the top-left
#                     must group with the bottom-left in "columns" mode
#   --grouping MODE   value for [Script-plasmasplitswitcher] Grouping (default
#                     columns); also sets the independent expectation
#   --keep            keep the temporary directory for inspection
#
# SPDX-License-Identifier: GPL-2.0-or-later

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(dirname "$here")"

keep=false
layout="columns"
grouping="columns"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep)
            keep=true
            shift
            ;;
        --layout)
            layout="${2:-}"
            shift 2
            ;;
        --grouping)
            grouping="${2:-}"
            shift 2
            ;;
        *)
            printf 'error: unknown option: %s\n' "$1" >&2
            exit 2
            ;;
    esac
done

plugin_id="plasmasplitswitcher"

case "$grouping" in
    columns|rows|regions) ;;
    *)
        printf 'error: unknown grouping: %s (expected columns, rows or regions)\n' "$grouping" >&2
        exit 2
        ;;
esac

case "$layout" in
    columns)
        # root horizontal: left leaf, right column with two stacked leaves.
        layout_js="$here/nested/layout.js"
        window_count=3
        case "$grouping" in
            rows) expected_offered=1; expected_hidden=2 ;;
            *)    expected_offered=2; expected_hidden=1 ;;
        esac
        ;;
    2x2)
        # root vertical, each row split into two columns.
        layout_js="$here/nested/layout-2x2.js"
        window_count=4
        expected_offered=2
        expected_hidden=2
        ;;
    *)
        printf 'error: unknown layout: %s (expected columns or 2x2)\n' "$layout" >&2
        exit 2
        ;;
esac

first_tool() {
    local tool
    for tool in "$@"; do
        if command -v "$tool" >/dev/null 2>&1; then
            printf '%s\n' "$tool"
            return 0
        fi
    done
    return 1
}

for tool in kwin_wayland Xvfb dbus-run-session kpackagetool6 foot journalctl python3; do
    command -v "$tool" >/dev/null 2>&1 || {
        printf 'error: required tool not found: %s\n' "$tool" >&2
        exit 1
    }
done
[[ -x /usr/libexec/kglobalacceld ]] || {
    printf 'error: /usr/libexec/kglobalacceld not found\n' >&2
    exit 1
}
python3 -c 'import Xlib' 2>/dev/null || {
    printf 'error: python3 cannot import Xlib (install python3-xlib)\n' >&2
    exit 1
}
qdbus="$(first_tool qdbus6 qdbus-qt6 qdbus)" || {
    printf 'error: no qdbus tool found\n' >&2
    exit 1
}

pick_display() {
    local n
    for n in $(seq 97 120); do
        if [[ ! -e "/tmp/.X11-unix/X$n" ]]; then
            printf ':%s\n' "$n"
            return 0
        fi
    done
    return 1
}

run_dir="$(mktemp -d "${TMPDIR:-/tmp}/plasmasplitswitcher-test.XXXXXX")"

# KWin and its clients require a private runtime directory.  Reuse the
# caller's, but fall back to one inside the test directory when there is none
# (headless runs, CI containers).
if [[ -z "${XDG_RUNTIME_DIR:-}" || ! -d "${XDG_RUNTIME_DIR}" ]]; then
    XDG_RUNTIME_DIR="$run_dir/runtime"
    mkdir -p "$XDG_RUNTIME_DIR"
    chmod 700 "$XDG_RUNTIME_DIR"
    export XDG_RUNTIME_DIR
fi

display="$(pick_display)" || {
    printf 'error: no free X display found\n' >&2
    exit 1
}
socket="pss-nested-$$"
start_ts="$(date '+%Y-%m-%d %H:%M:%S')"

cleanup() {
    if [[ -n "${xvfb_pid:-}" ]]; then
        kill -TERM "$xvfb_pid" 2>/dev/null || true
    fi
    if [[ -n "${session_pid:-}" ]]; then
        kill -TERM -"$session_pid" 2>/dev/null || kill -TERM "$session_pid" 2>/dev/null || true
    fi
    sleep 1
    if [[ "$keep" == true ]]; then
        printf 'kept test directory: %s\n' "$run_dir"
    else
        rm -rf "$run_dir"
    fi
}
trap cleanup EXIT

mkdir -p "$run_dir/config" "$run_dir/data" "$run_dir/log"

# ---------------------------------------------------------------------------
# Isolated configuration and packages
# ---------------------------------------------------------------------------

cat > "$run_dir/config/kwinrc" <<EOF
[Plugins]
plasmasplitswitcherEnabled=true

[TabBox]
LayoutName=plasmasplitswitcher
HighlightWindows=false

[TabBoxAlternative]
LayoutName=plasmasplitswitcher
HighlightWindows=false

[Script-$plugin_id]
Grouping=$grouping
EOF

cat > "$run_dir/config/kglobalshortcutsrc" <<'EOF'
[kwin]
Walk Through Windows=Ctrl+Alt+Shift+F8,Ctrl+Alt+Shift+F8,Walk Through Windows
EOF

# The oracle must be told which grouping mode the script will read.
sed "s/var GROUPING = \"columns\";/var GROUPING = \"$grouping\";/" \
    "$here/nested/dump.js" > "$run_dir/dump.js"

XDG_DATA_HOME="$run_dir/data" kpackagetool6 --type KWin/WindowSwitcher \
    --install "$repo/switcher" >/dev/null
XDG_DATA_HOME="$run_dir/data" kpackagetool6 --type KWin/Script \
    --install "$repo/script" >/dev/null

# ---------------------------------------------------------------------------
# Inner session: kglobalacceld + headless-windowed KWin inside Xvfb
# ---------------------------------------------------------------------------

cat > "$run_dir/inner.sh" <<INNER
#!/usr/bin/env bash
set -u
export XDG_CONFIG_HOME="$run_dir/config"
export XDG_DATA_HOME="$run_dir/data"
export XDG_CURRENT_DESKTOP=KDE
export DISPLAY="$display"
export WAYLAND_DISPLAY="$socket"
# Without this KWin logs through journald, which is absent in containers; the
# nested session's console output would be lost.  Force it to stderr instead.
export QT_FORCE_STDERR_LOGGING=1

/usr/libexec/kglobalacceld >> "$run_dir/log/session.log" 2>&1 &
/usr/bin/env kwin_wayland --x11-display "$display" --socket "$socket" \
    --width 1600 --height 900 >> "$run_dir/log/session.log" 2>&1 &
kwin_pid=\$!
trap 'kill -TERM \$kwin_pid 2>/dev/null' EXIT

for _ in \$(seq 1 60); do
    $qdbus org.kde.KWin /KWin org.kde.KWin.supportInformation >/dev/null 2>&1 && break
    sleep 0.5
done

run_js() {
    local id
    id=\$($qdbus org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript "\$1" "\$2" 2>/dev/null)
    [ -n "\$id" ] && $qdbus org.kde.KWin /Scripting/Script\$id org.kde.kwin.Script.run >/dev/null 2>&1
    sleep 1
}

for _ in \$(seq 1 $window_count); do
    foot -T pss-window >> "$run_dir/log/foot.log" 2>&1 &
done
sleep 5

run_js "$layout_js" pss-layout
sleep 1

# Hold the shortcut so the switcher stays open while we inspect it.
python3 "$here/xtest-inject.py" "$display" \
    dControl_L dAlt_L dShift_L tF8 s5000 uShift_L uAlt_L uControl_L \
    >> "$run_dir/log/inject.log" 2>&1 &
inject_pid=\$!
sleep 2
run_js "$run_dir/dump.js" pss-dump
wait \$inject_pid 2>/dev/null || true
echo done > "$run_dir/done"
INNER
chmod +x "$run_dir/inner.sh"

Xvfb "$display" -screen 0 1600x900x24 -ac -nolisten tcp >/dev/null 2>&1 &
xvfb_pid=$!
sleep 1

setsid dbus-run-session -- "$run_dir/inner.sh" >"$run_dir/log/outer.log" 2>&1 &
session_pid=$!

# ---------------------------------------------------------------------------
# Wait, collect, tear down
# ---------------------------------------------------------------------------

for _ in $(seq 1 120); do
    [[ -f "$run_dir/done" ]] && break
    sleep 0.5
done

# KWin logs script console output through the Qt "js" category.  In the
# journal the prefix is dropped, on stderr it is kept as "js: ", so strip any
# such prefix before matching.
collect_results() {
    sed -E 's/^[A-Za-z0-9_.]+: //' | grep -E '^(PSSDUMP|PSSNESTED) ' || true
}

results="$(journalctl --since "$start_ts" --no-pager -o cat 2>/dev/null \
    | collect_results)"
if [[ -z "$results" ]]; then
    # Some setups send console output to the compositor's stderr instead.
    results="$(grep -E 'PSSDUMP |PSSNESTED ' "$run_dir/log/session.log" 2>/dev/null \
        | collect_results)"
fi

if [[ -z "$results" ]]; then
    printf '\nFAIL: no test output collected.\n' >&2
    printf '      See %s/log/session.log and the journal for KWin messages.\n' "$run_dir" >&2
    exit 1
fi
if [[ "${PSS_TEST_VERBOSE:-}" == 1 ]]; then
    printf '%s\n' "$results"
fi

column="$(printf '%s\n' "$results" | grep -m1 '^PSSDUMP column ' | awk '{ print $3, $4, $5, $6 }' || true)"
popup="$(printf '%s\n' "$results" | grep -m1 '^PSSDUMP popup '  | awk '{ print $3, $4, $5, $6 }' || true)"
not_skipped="$(printf '%s\n' "$results" | grep -c 'skip=false' || true)"
skipped="$(printf '%s\n' "$results" | grep -c 'skip=true' || true)"

printf 'active column (x y w h): %s\n' "${column:-none}"
printf 'switcher popup (x y w h): %s\n' "${popup:-not opened}"
printf 'windows offered: %s, hidden: %s\n\n' "$not_skipped" "$skipped"

status=0
if [[ -z "$column" || "$column" == "none" ]]; then
    printf 'FAIL: the active window was not recognised as being in a column\n' >&2
    status=1
fi
if [[ -z "$popup" ]]; then
    printf 'FAIL: the switcher popup did not open\n' >&2
    status=1
fi

if [[ -n "$column" && -n "$popup" && "$column" != "none" ]]; then
    read -r cx cy cw ch <<<"$column"
    read -r px py pw ph <<<"$popup"

    if (( px < cx || py < cy || px + pw > cx + cw || py + ph > cy + ch )); then
        printf 'FAIL: popup is not contained in the column\n' >&2
        status=1
    fi
    if (( pw > cw )); then
        printf 'FAIL: popup is wider than the column\n' >&2
        status=1
    fi
    # centred, allowing a few pixels of rounding
    if (( (px + pw / 2) - (cx + cw / 2) > 20 || (cx + cw / 2) - (px + pw / 2) > 20 )); then
        printf 'FAIL: popup is not centred on the column\n' >&2
        status=1
    fi
fi

if (( not_skipped != expected_offered )); then
    printf 'FAIL: expected the %s windows of the active group to be offered, got %s\n' \
        "$expected_offered" "$not_skipped" >&2
    status=1
fi
if (( skipped != expected_hidden )); then
    printf 'FAIL: expected the %s windows outside the group to be hidden, got %s\n' \
        "$expected_hidden" "$skipped" >&2
    status=1
fi

if (( status != 0 )); then
    printf '\ncollected output:\n%s\n' "$results" >&2
fi

if (( status == 0 )); then
    printf 'PASS: popup centred inside the group; only the group windows are offered.\n'
fi
exit "$status"
