#!/usr/bin/env bash
#
# run-nautilus.sh — launch the macOS-port Nautilus build with a working runtime
# environment. Usable from a fresh shell; every Phase 2+ dev workflow and the
# user should launch through this.
#
# Usage:
#   ./run-nautilus.sh [nautilus args...]
#
# Examples:
#   ./run-nautilus.sh                 # open $HOME
#   ./run-nautilus.sh ~/Downloads     # open a specific folder
#   ./run-nautilus.sh --new-window ~  # force a new window
#   ./run-nautilus.sh --quit          # quit the running instance
#
# Environment knobs:
#   NAUTILUS_NO_DBUS=1   Launch without the dev session bus (no-bus mode).
#   NAUTILUS_BIN=path    Override which nautilus binary to run.
#
set -euo pipefail

# Resolve the repo root from this script's location so it works from anywhere.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BREW_PREFIX="${HOMEBREW_PREFIX:-/opt/homebrew}"
INSTALL_PREFIX="$REPO_ROOT/install"
NAUTILUS_BIN="${NAUTILUS_BIN:-$REPO_ROOT/build/src/nautilus}"

if [[ ! -x "$NAUTILUS_BIN" ]]; then
    echo "error: nautilus binary not found at $NAUTILUS_BIN" >&2
    echo "       build it first: ninja -C \"$REPO_ROOT/build\"" >&2
    exit 1
fi

if [[ ! -d "$INSTALL_PREFIX/share/glib-2.0/schemas" ]]; then
    echo "error: install prefix not populated at $INSTALL_PREFIX" >&2
    echo "       run: meson install -C \"$REPO_ROOT/build\"" >&2
    exit 1
fi

# --- Data + schema search paths ------------------------------------------------
# XDG_DATA_DIRS: our install prefix first (nautilus gresources, ontology,
# app icon), then Homebrew's share (Adwaita/hicolor icon themes,
# gsettings-desktop-schemas, shared-mime-info).
export XDG_DATA_DIRS="$INSTALL_PREFIX/share:$BREW_PREFIX/share"

# GSETTINGS_SCHEMA_DIR: the compiled schema cache. Our install script already
# runs glib-compile-schemas here (bundles org.gnome.nautilus.* plus copies of
# the gtk4 / gsettings-desktop-schemas it depends on via install). If the
# compiled cache is missing, GLib falls back to XDG_DATA_DIRS/glib-2.0/schemas.
export GSETTINGS_SCHEMA_DIR="$INSTALL_PREFIX/share/glib-2.0/schemas"

# --- Session D-Bus (dev) -------------------------------------------------------
# GLib finds the launchd session bus via DBUS_LAUNCHD_SESSION_BUS_SOCKET.
# The app tolerates a missing bus (degrades to non-unique), but with the bus
# present the CLI verbs (--new-window/--select/--quit) route to the single
# running instance.
if [[ "${NAUTILUS_NO_DBUS:-0}" == "1" ]]; then
    unset DBUS_LAUNCHD_SESSION_BUS_SOCKET DBUS_SESSION_BUS_ADDRESS
else
    if [[ -z "${DBUS_LAUNCHD_SESSION_BUS_SOCKET:-}" ]]; then
        sock="$(launchctl getenv DBUS_LAUNCHD_SESSION_BUS_SOCKET 2>/dev/null || true)"
        if [[ -n "$sock" ]]; then
            export DBUS_LAUNCHD_SESSION_BUS_SOCKET="$sock"
        fi
        # If no dev bus is registered, that's fine — the app handles it.
        # To start one: launchctl bootstrap gui/$(id -u) \
        #   "$BREW_PREFIX/opt/dbus/org.freedesktop.dbus-session.plist"
    fi
    # Homebrew GLib is built without launchd support, so it ignores
    # DBUS_LAUNCHD_SESSION_BUS_SOCKET and only honors DBUS_SESSION_BUS_ADDRESS.
    # Derive the address form so GApplication actually finds the bus.
    if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" && -n "${DBUS_LAUNCHD_SESSION_BUS_SOCKET:-}" ]]; then
        export DBUS_SESSION_BUS_ADDRESS="unix:path=$DBUS_LAUNCHD_SESSION_BUS_SOCKET"
    fi
fi

# Run in the foreground: GTK's macOS (quartz) backend wants a real foreground
# process to become a proper NSApplication and show its window.
exec "$NAUTILUS_BIN" "$@"
