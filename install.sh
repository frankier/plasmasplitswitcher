#!/usr/bin/env bash
#
# Plasma Split Switcher installer.
#
# Installs both packages and applies the KWin configuration needed for
# per-column Alt+Tab.  Running it again is safe: it upgrades instead of
# installing when a package is already present.
#
# Usage:
#   ./install.sh [--dry-run] [--force] [--uninstall]
#
#   --dry-run    Print what would be done, change nothing.
#   --force      Overwrite an existing non-default [TabBox] LayoutName.
#   --uninstall  Remove both packages and restore the stock switcher config.
#
# SPDX-License-Identifier: GPL-2.0-or-later

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_pkg="$here/script"
switcher_pkg="$here/switcher"

plugin_id="plasmasplitswitcher"
layout="$plugin_id"
stock_layout="thumbnail_grid"
kwinrc="kwinrc"

dry_run=false
force=false
uninstall=false

usage() {
    sed -n '3,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
    case "$arg" in
        --dry-run) dry_run=true ;;
        --force) force=true ;;
        --uninstall) uninstall=true ;;
        -h|--help) usage; exit 0 ;;
        *)
            printf 'error: unknown option: %s\n' "$arg" >&2
            usage >&2
            exit 2
            ;;
    esac
done

run() {
    if "$dry_run"; then
        printf '  [dry-run] %s\n' "$*"
    else
        printf '  %s\n' "$*"
        "$@"
    fi
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------

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

kpackagetool="$(first_tool kpackagetool6 kpackagetool5)" \
    || die "kpackagetool6/kpackagetool5 not found"
kwriteconfig="$(first_tool kwriteconfig6 kwriteconfig5)" \
    || die "kwriteconfig6/kwriteconfig5 not found"
kreadconfig="$(first_tool kreadconfig6 kreadconfig5)" \
    || die "kreadconfig6/kreadconfig5 not found"

if [[ "$(id -u)" -eq 0 ]]; then
    printf 'warning: running as root installs for root, not for your session.\n' >&2
    printf '         Run this as the user that runs KWin.\n' >&2
fi

read_config() {
    # read_config <group> <key> -> prints the value, empty when unset
    "$kreadconfig" --file "$kwinrc" --group "$1" --key "$2" 2>/dev/null || true
}

write_config() {
    run "$kwriteconfig" --file "$kwinrc" --group "$1" --key "$2" "$3"
}

delete_config() {
    run "$kwriteconfig" --file "$kwinrc" --group "$1" --key "$2" --delete
}

qdbus_tool() {
    first_tool qdbus6 qdbus-qt6 qdbus || true
}

reconfigure_kwin() {
    local qdbus
    qdbus="$(qdbus_tool)"
    if [[ -z "$qdbus" ]]; then
        printf 'warning: no qdbus tool found; run "qdbus org.kde.KWin /KWin reconfigure" yourself.\n' >&2
        return 0
    fi
    if "$dry_run"; then
        printf '  [dry-run] %s org.kde.KWin /KWin reconfigure\n' "$qdbus"
        return 0
    fi
    if ! "$qdbus" org.kde.KWin /KWin reconfigure >/dev/null 2>&1; then
        printf 'warning: could not ask KWin to reconfigure; log out and back in.\n' >&2
    fi
}

# Runs a KWin script once, then unloads it again.  Silently does nothing when
# KWin is not running or the script engine is unavailable.
run_kwin_script() {
    local qdbus file="$1" name="$2" id
    qdbus="$(qdbus_tool)"
    [[ -n "$qdbus" ]] || return 0
    if "$dry_run"; then
        printf '  [dry-run] %s org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript %s %s\n' \
            "$qdbus" "$file" "$name"
        return 0
    fi
    id="$("$qdbus" org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript "$file" "$name" 2>/dev/null)" || return 0
    [[ "$id" =~ ^[0-9]+$ ]] || return 0
    "$qdbus" org.kde.KWin /Scripting/Script"$id" org.kde.kwin.Script.run >/dev/null 2>&1 || true
    "$qdbus" org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript "$name" >/dev/null 2>&1 || true
}

unload_kwin_script() {
    local qdbus name="$1"
    qdbus="$(qdbus_tool)"
    [[ -n "$qdbus" ]] || return 0
    if "$dry_run"; then
        printf '  [dry-run] %s org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript %s\n' "$qdbus" "$name"
        return 0
    fi
    "$qdbus" org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript "$name" >/dev/null 2>&1 || true
}

install_package() {
    # install_package <package-type> <package-dir> <id>
    local type="$1" dir="$2" id="$3"
    if "$kpackagetool" --type "$type" --list 2>/dev/null | grep -qx "$id"; then
        run "$kpackagetool" --type "$type" --upgrade "$dir"
    else
        run "$kpackagetool" --type "$type" --install "$dir"
    fi
}

remove_package() {
    local type="$1" id="$2"
    if "$kpackagetool" --type "$type" --list 2>/dev/null | grep -qx "$id"; then
        run "$kpackagetool" --type "$type" --remove "$id"
    else
        printf '  %s is not installed\n' "$id"
    fi
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

if "$uninstall"; then
    printf 'Removing Plasma Split Switcher...\n'
    # Stop filtering first, then put every window back into the switcher.
    # Removing a package does not unload an already running script, and an
    # unloaded script cannot restore the flags, so both steps are explicit.
    unload_kwin_script "$plugin_id"
    run_kwin_script "$here/tools/reset-skip-switcher.js" "${plugin_id}-reset"

    remove_package "KWin/WindowSwitcher" "$plugin_id"
    remove_package "KWin/Script" "$plugin_id"

    write_config TabBox LayoutName "$stock_layout"
    write_config TabBoxAlternative LayoutName "$stock_layout"
    delete_config TabBox HighlightWindows
    delete_config TabBoxAlternative HighlightWindows
    delete_config "Script-$plugin_id" Grouping
    write_config Plugins "${plugin_id}Enabled" false

    reconfigure_kwin

    cat <<'EOF'

Done.  If Alt+Tab still shows a reduced list, restart KWin (log out and back
in, or run "kwin_wayland --replace") so the skipSwitcher flags are cleared.
EOF
    exit 0
fi

# ---------------------------------------------------------------------------
# Guard against clobbering a switcher layout the user chose
# ---------------------------------------------------------------------------

for group in TabBox TabBoxAlternative; do
    current="$(read_config "$group" LayoutName)"
    if [[ -n "$current" && "$current" != "$stock_layout" && "$current" != "$layout" && "$force" != true ]]; then
        cat >&2 <<EOF
error: [$group] LayoutName is already set to "$current".
       Refusing to overwrite it.  Re-run with --force to replace it, or set
       the layout manually:
         $kwriteconfig --file kwinrc --group $group --key LayoutName $layout
EOF
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

printf 'Installing Plasma Split Switcher...\n'
install_package "KWin/WindowSwitcher" "$switcher_pkg" "$plugin_id"
install_package "KWin/Script" "$script_pkg" "$plugin_id"

printf '\nApplying configuration...\n'
write_config TabBox LayoutName "$layout"
write_config TabBoxAlternative LayoutName "$layout"
# HighlightWindows dims every other window; the popup is inside a column, so
# screen-wide dimming would spill over into the neighbouring column.
write_config TabBox HighlightWindows false
write_config TabBoxAlternative HighlightWindows false
write_config Plugins "${plugin_id}Enabled" true

reconfigure_kwin

cat <<EOF

Done.

Both artifacts are required:
  * the KWin script filters the window list (skipSwitcher),
  * the WindowSwitcher layout positions the popup on the group.

The grouping can be changed in System Settings > Window Management > KWin
Scripts > Plasma Split Switcher > Configure (Columns by default).

To go back to stock:
  ./install.sh --uninstall
  # or by hand:
  $kpackagetool --type KWin/WindowSwitcher --remove $plugin_id
  $kpackagetool --type KWin/Script --remove $plugin_id
  $kwriteconfig --file kwinrc --group TabBox --key LayoutName $stock_layout
  $kwriteconfig --file kwinrc --group TabBoxAlternative --key LayoutName $stock_layout
  $kwriteconfig --file kwinrc --group TabBox --key HighlightWindows --delete
  $kwriteconfig --file kwinrc --group TabBoxAlternative --key HighlightWindows --delete
  $kwriteconfig --file kwinrc --group Plugins --key ${plugin_id}Enabled false
  qdbus org.kde.KWin /KWin reconfigure
EOF
