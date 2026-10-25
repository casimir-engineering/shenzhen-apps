#!/usr/bin/env bash
#
# make-app.sh — assemble a relocatable dist/Nautilus.app from the installed
# prefix at <repo>/install (PLAN.md §5 Phase 5 task 1).
#
# What goes where:
#   Contents/MacOS/nautilus            real meson-built binary (from install/bin)
#   Contents/MacOS/nautilus-launcher   tiny compiled exec-wrapper (CFBundleExecutable);
#                                      exports XDG_DATA_DIRS / GSETTINGS_SCHEMA_DIR /
#                                      GDK_PIXBUF_MODULE_FILE / GIO_MODULE_DIR /
#                                      FONTCONFIG_FILE relative to the bundle, then
#                                      execs the real binary (see nautilus-launcher.c)
#   Contents/Frameworks/               libnautilus-extension + (later) the full dylib
#                                      closure written by bundle-dylibs.sh
#   Contents/Resources/share/          nautilus data + ontology + icons + COMPILED
#                                      gsettings schemas + adwaita/hicolor themes with
#                                      regenerated icon caches + shared-mime-info db +
#                                      gtk-4.0 data (emoji) + trimmed locales
#   Contents/Resources/lib/            gdk-pixbuf loaders (regenerated relocatable
#                                      loaders.cache) + GIO modules (giomodule.cache)
#   Contents/Resources/etc/fonts/      minimal fontconfig config (safety net only;
#                                      GTK4 on macOS uses CoreText)
#   Contents/Helpers/Shenzhen Friends.app  the Shenzhen Friends helper, built by
#                                      tools/setup-friends.sh from the shenzhen-pdf
#                                      commit in friends.lock
#   Contents/Resources/Friends/        its animal set and Acknowledgements.txt
#
# Run order for a full package:
#   tools/setup-friends.sh -> make-app.sh -> bundle-dylibs.sh -> make-dmg.sh
#
# Usage: ./package/make-app.sh [app-path]  (default: <repo>/dist/Shenzhen Files.app)
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

BREW="${HOMEBREW_PREFIX:-/opt/homebrew}"
INSTALL="$repo_root/install"
APP="${1:-$repo_root/dist/Shenzhen Files.app}"

# Identity stamped into Info.plist. Shenzhen-product conventions (mirrors
# shenzhen-pdf): bundle id com.intuition.<product>, date-based user version,
# a globally increasing numeric CFBundleVersion for LaunchServices/App Store
# cache semantics, and an explicit YY.M.DD-BUILD release tag for GitHub.
BUNDLE_ID="com.intuition.shenzhenfiles"
SHORT_VERSION="26.10.25"
RELEASE_BUILD="1"
BUNDLE_VERSION="26102501"
# tools/release.sh builds a candidate of another version (a dry run of a throwaway one) with
# SZF_RELEASE_VERSION=<YY.M.D>-<N>; publishing refuses a version other than the one written above.
if [[ -n "${SZF_RELEASE_VERSION:-}" ]]; then
  [[ "$SZF_RELEASE_VERSION" =~ ^([0-9]{2})\.([1-9][0-9]?)\.([1-9][0-9]?)-([1-9][0-9]?)$ ]] ||
    { echo "error: SZF_RELEASE_VERSION must read YY.M.D-N, not $SZF_RELEASE_VERSION" >&2; exit 2; }
  SHORT_VERSION="${SZF_RELEASE_VERSION%-*}"
  RELEASE_BUILD="${SZF_RELEASE_VERSION##*-}"
  BUNDLE_VERSION="$(printf '%02d%02d%02d%02d' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" \
    "${BASH_REMATCH[4]}")"
fi
RELEASE_TAG="$SHORT_VERSION-$RELEASE_BUILD"

# Locales kept in the bundle (nautilus ships ~120; trim to a reasonable set).
LOCALES=(ar ca cs da de el en_GB es eu fi fr gl he hi hu id it ja ko nb nl pl
         pt pt_BR ro ru sk sv th tr uk vi zh_CN zh_TW)

# gettext domains pulled from Homebrew's share/locale for the bundled libs.
BREW_DOMAINS=(glib20 gtk40 libadwaita gdk-pixbuf gsettings-desktop-schemas
              shared-mime-info json-glib-1.0 glib-networking tinysparql3)

for f in "$INSTALL/bin/nautilus" "$INSTALL/lib/libnautilus-extension.4.dylib" \
         "$script_dir/Info.plist.template" "$script_dir/AppIcon.icns" \
         "$script_dir/nautilus-launcher.c"; do
  [[ -e "$f" ]] || { echo "error: missing input: $f" >&2; exit 1; }
done

# Shenzhen Friends: the checkout and the helper built from it must be the ones
# friends.lock pins; --check says what to run when they are not.
# shellcheck source-path=SCRIPTDIR source=../tools/friends-lock.sh
. "$repo_root/tools/friends-lock.sh"
friends_lock_read "$repo_root"
"$repo_root/tools/setup-friends.sh" --check

echo "==> assembling $APP"
rm -rf "$APP"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"
FRAMEWORKS="$APP/Contents/Frameworks"
mkdir -p "$MACOS" "$RES" "$FRAMEWORKS"

# --- executables ---------------------------------------------------------------
cp "$INSTALL/bin/nautilus" "$MACOS/nautilus"
cc -O2 -Wall -Wextra -o "$MACOS/nautilus-launcher" "$script_dir/nautilus-launcher.c"
cp "$INSTALL/lib/libnautilus-extension.4.dylib" "$FRAMEWORKS/"
chmod -R u+w "$MACOS" "$FRAMEWORKS"

# --- Shenzhen Friends --------------------------------------------------------------
# The helper goes where the Friends host adapter starts it. The animal set ships
# once, in Resources/Friends/, where the views look and where the embedded helper
# looks from Contents/Helpers/ (shenzhen-pdf avatars/SZFriendsAnimalSet.m), so the
# helper's own copy is dropped. Its version keys come from friends.lock, never from
# this app's version: ShenzhenPDF embeds the same helper, and the running one hands
# over to the embedded helper with the higher build number (PROTOCOL.md § Lifecycle),
# so the number has to say which Friends code it is. They are stamped again here,
# as ShenzhenPDF does for its copy, so the shipped keys come from the lock itself
# and not from whichever run built the bundle. Stamping breaks the helper's
# signature until bundle-dylibs.sh signs it.
HELPERS="$APP/Contents/Helpers"
FRIENDS_RES="$RES/Friends"
FRIENDS_HELPER="$HELPERS/$FRIENDS_HELPER_NAME.app"
mkdir -p "$HELPERS" "$FRIENDS_RES/animals/svg" "$FRIENDS_RES/animals/pdf"
cp -R "$FRIENDS_HELPER_BUILT" "$HELPERS/"
rm -rf "$FRIENDS_HELPER/Contents/Resources/Friends"
xattr -cr "$FRIENDS_HELPER"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleShortVersionString $FRIENDS_SHORT_VERSION" \
  -c "Set :CFBundleVersion $FRIENDS_BUILD_NUMBER" \
  -c "Set :SZFriendsBuildNumber $FRIENDS_BUILD_NUMBER" \
  "$FRIENDS_HELPER/Contents/Info.plist"
cp "$FRIENDS_ANIMALS/manifest.json" "$FRIENDS_RES/animals/"
cp "$FRIENDS_ANIMALS/svg/"*.svg "$FRIENDS_RES/animals/svg/"
cp "$FRIENDS_ANIMALS/pdf/"*.pdf "$FRIENDS_RES/animals/pdf/"
cp "$FRIENDS_ACKNOWLEDGEMENTS" "$FRIENDS_RES/Acknowledgements.txt"

# --- Info.plist + icon -----------------------------------------------------------
cp "$script_dir/Info.plist.template" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleIdentifier $BUNDLE_ID" \
  -c "Set :CFBundleShortVersionString $SHORT_VERSION" \
  -c "Set :CFBundleVersion $BUNDLE_VERSION" \
  -c "Set :SZFReleaseTag $RELEASE_TAG" \
  "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$script_dir/AppIcon.icns" "$RES/AppIcon.icns"

# --- share payload ---------------------------------------------------------------
mkdir -p "$RES/share"

# Nautilus data (ontology is required by the tag manager / starring).
cp -R "$INSTALL/share/nautilus" "$RES/share/nautilus"

# Locales: nautilus's own domain (trimmed) + Homebrew domains for bundled libs.
for loc in "${LOCALES[@]}"; do
  src="$INSTALL/share/locale/$loc"
  [[ -d "$src" ]] || continue
  mkdir -p "$RES/share/locale/$loc/LC_MESSAGES"
  cp "$src/LC_MESSAGES/nautilus.mo" "$RES/share/locale/$loc/LC_MESSAGES/" 2>/dev/null || true
  for dom in "${BREW_DOMAINS[@]}"; do
    mo="$BREW/share/locale/$loc/LC_MESSAGES/$dom.mo"
    [[ -f "$mo" ]] && cp -L "$mo" "$RES/share/locale/$loc/LC_MESSAGES/"
  done
done

# GSettings schemas: nautilus + gtk4 + gsettings-desktop-schemas, compiled into
# ONE cache inside the bundle (TRAP: gschemas.compiled must be regenerated here —
# a copied cache from install/ or brew would carry that machine's paths/mix).
mkdir -p "$RES/share/glib-2.0/schemas"
cp "$INSTALL/share/glib-2.0/schemas/"*.xml "$RES/share/glib-2.0/schemas/"
cp -L "$BREW/share/glib-2.0/schemas/"*.xml "$RES/share/glib-2.0/schemas/"
"$BREW/bin/glib-compile-schemas" "$RES/share/glib-2.0/schemas"

# Icon themes: Adwaita + hicolor (brew) merged with nautilus's own hicolor icons.
# TRAP: icon-theme.cache staleness — regenerate caches after merging.
mkdir -p "$RES/share/icons"
cp -RL "$BREW/share/icons/Adwaita" "$RES/share/icons/Adwaita"
cp -RL "$BREW/share/icons/hicolor" "$RES/share/icons/hicolor"
ditto "$INSTALL/share/icons/hicolor" "$RES/share/icons/hicolor"
chmod -R u+w "$RES/share/icons"
rm -f "$RES/share/icons/Adwaita/icon-theme.cache" "$RES/share/icons/hicolor/icon-theme.cache"
"$BREW/bin/gtk4-update-icon-cache" -q -t -f "$RES/share/icons/Adwaita"
"$BREW/bin/gtk4-update-icon-cache" -q -t -f "$RES/share/icons/hicolor"

# shared-mime-info: ship the XML source and regenerate the binary db in place.
mkdir -p "$RES/share/mime/packages"
cp -L "$BREW/share/mime/packages/freedesktop.org.xml" "$RES/share/mime/packages/"
"$BREW/bin/update-mime-database" "$RES/share/mime" 2>/dev/null

# GTK4's own share data. GTK4's css/media are compiled-in gresources; on this
# brew install share/gtk-4.0 holds only the emoji data + builder schema (there is
# no /opt/homebrew/lib/gtk-4.0 module dir at all — nothing else to bundle).
mkdir -p "$RES/share/gtk-4.0"
cp -RL "$BREW/share/gtk-4.0/emoji" "$RES/share/gtk-4.0/emoji"
cp -L "$BREW/share/gtk-4.0/gtk4builder.rng" "$RES/share/gtk-4.0/" 2>/dev/null || true

# Minimal fontconfig config (see launcher comment; normally unused on macOS).
mkdir -p "$RES/etc/fonts"
cat > "$RES/etc/fonts/fonts.conf" <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <dir>/System/Library/Fonts</dir>
  <dir>/Library/Fonts</dir>
  <dir>~/Library/Fonts</dir>
  <cachedir prefix="xdg">fontconfig</cachedir>
</fontconfig>
EOF

# --- loadable modules ------------------------------------------------------------
# gdk-pixbuf loaders. TRAP: loaders.cache is generated with absolute paths; a
# cache copied from brew would point at /opt/homebrew. Also, query-loaders can't
# run against the raw bundled copies (their @rpath deps, e.g. the SVG loader's
# librsvg, aren't rewritten until bundle-dylibs.sh) — so generate the cache from
# a staging dir of symlinks into Homebrew (where deps still resolve), then
# rewrite the paths to @executable_path (dlopen resolves it relative to
# Contents/MacOS/nautilus — verified to work on this host).
PIXBUF_DIR="$RES/lib/gdk-pixbuf-2.0/2.10.0"
mkdir -p "$PIXBUF_DIR/loaders"
# .so only: brew also ships libpixbufloader_svg.dylib as a duplicate of the .so.
cp -L "$BREW/lib/gdk-pixbuf-2.0/2.10.0/loaders/"*.so "$PIXBUF_DIR/loaders/"
chmod -R u+w "$PIXBUF_DIR"
stage="$(mktemp -d /tmp/nautilus-loaders.XXXXXX)"
for f in "$BREW/lib/gdk-pixbuf-2.0/2.10.0/loaders/"*.so; do
  ln -s "$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$f")" \
        "$stage/$(basename "$f")"
done
GDK_PIXBUF_MODULEDIR="$stage" \
  "$BREW/opt/gdk-pixbuf/bin/gdk-pixbuf-query-loaders" > "$PIXBUF_DIR/loaders.cache"
rm -rf "$stage"
sed -i '' "s|\"$stage/|\"@executable_path/../Resources/lib/gdk-pixbuf-2.0/2.10.0/loaders/|g" \
  "$PIXBUF_DIR/loaders.cache"
if grep -qE '^"/.*\.(so|dylib)"' "$PIXBUF_DIR/loaders.cache"; then
  echo "error: absolute paths left in loaders.cache" >&2
  exit 1
fi

# tinysparql (tracker) parser module. TRAP: libtinysparql loads its
# collation/parser module (libtracker-parser-libicu.so) via g_module_open()
# from a HARD-CODED absolute path baked at compile time
# (PRIVATE_LIBDIR = <brew>/Cellar/tinysparql/<ver>/lib/tinysparql-3.0), with
# no env override. That path only exists on a machine with Homebrew's
# tinysparql, so the tag DB (starring) crashes on any clean Mac; and under
# the hardened runtime + Developer ID signing, Library Validation refuses to
# load the ad-hoc-signed Homebrew module even where the path DOES exist —
# g_module_open returns NULL and libtinysparql g_assert()s → SIGABRT at
# startup (nautilus_tag_manager_init). Fix: bundle the module here, then
# bundle-dylibs.sh (a) re-signs it with our identity so Library Validation
# accepts it and (b) binary-patches the baked path in the bundled
# libtinysparql to @executable_path/../Resources/lib/tinysparql-3.0.
TSPARQL_MODDIR="$RES/lib/tinysparql-3.0"
mkdir -p "$TSPARQL_MODDIR"
cp -L "$BREW/lib/tinysparql-3.0/libtracker-parser-libicu.so" "$TSPARQL_MODDIR/"
chmod -R u+w "$TSPARQL_MODDIR"

# GIO modules (TLS backend). TRAP: giomodule.cache — regenerate in the bundle;
# entries are basenames, so the cache itself is relocatable.
GIO_DIR="$RES/lib/gio/modules"
mkdir -p "$GIO_DIR"
cp -L "$BREW/lib/gio/modules/"*.so "$GIO_DIR/"
chmod -R u+w "$GIO_DIR"
"$BREW/bin/gio-querymodules" "$GIO_DIR"

"$script_dir/check-friends-bundle.sh" "$APP"

echo "==> app assembled: $APP"
echo "    next: ./package/bundle-dylibs.sh \"$APP\""
