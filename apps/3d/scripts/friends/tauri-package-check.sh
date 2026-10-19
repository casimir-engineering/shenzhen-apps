#!/bin/bash
# Runs on Linux (tauri-vm.sh copies it into the VM): builds the deb, rpm and AppImage with Friends from the tree in
# $1, checks each carries the helper beside the app, the animal set and the acknowledgements (naming libdbus, which
# the helper links for Bluetooth), then checks ADR 0015 § 14 with the AppImage: started while an older helper runs,
# the app asks it to hand over and starts the helper from a per-user copy; that helper outlives the app and its mount
# once the app quits, then exits on its own. Everything happens under $1, in a temporary Friends home; nothing is
# installed.
#
#   tauri-package-check.sh <dir> <node_modules holding @tauri-apps/cli> <helper version> <helper build>
set -euo pipefail
dir=$1 cli_modules=$2 version=$3 build=$4
# Whatever ends the check, a failure or an interruption included: the AppImage, xvfb-run and its Xvfb, and the helpers
# the check started stop with it, so nothing of the run keeps going in the guest (tauri-vm.sh then removes $dir).
older_pid= xvfb_pid= home=
stop_started() {
    local pids=() pid
    [ -n "$older_pid" ] && pids+=("$older_pid")
    # The AppImage's runtime, and the app it starts from its mount.
    if [ -s "$dir/app.pid" ]; then
        pid=$(cat "$dir/app.pid")
        pids+=("$pid")
        for pid in $(pgrep -P "$pid" || true); do pids+=("$pid"); done
    fi
    if [ -n "$xvfb_pid" ]; then
        pids+=("$xvfb_pid")
        for pid in $(pgrep -P "$xvfb_pid" || true); do pids+=("$pid"); done
    fi
    # The per-user copies of the helper, which outlive the app by design.
    if [ -n "$home" ]; then
        for pid in $(pgrep -f "$home/helper/" || true); do pids+=("$pid"); done
    fi
    [ ${#pids[@]} -gt 0 ] || return 0
    kill "${pids[@]}" 2>/dev/null || true
    sleep 1
    kill -9 "${pids[@]}" 2>/dev/null || true
}
trap 'status=$?; trap - EXIT; stop_started; exit $status' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
target=$(rustc -vV | sed -n 's/^host: //p')
export SZFRIENDS_HELPER_VERSION=$version SZFRIENDS_HELPER_BUILD=$build
mkdir -p "$dir/3d/node_modules/@tauri-apps"
cp -a "$cli_modules/@tauri-apps/cli" "$cli_modules"/@tauri-apps/cli-linux-* "$dir/3d/node_modules/@tauri-apps/"

(cd "$dir/friends/core-rs" && CARGO_TARGET_DIR="$dir/target-core" cargo build --release -p szfriends-helper \
    --bin szfriends-helper --example restamp 2>&1 | tail -1)
helper="$dir/target-core/release/szfriends-helper"
mkdir -p "$dir/3d/src-tauri/friends/bin"
cp "$helper" "$dir/3d/src-tauri/friends/bin/szfriends-helper-$target"
cp -a "$dir/friends/avatars/animals" "$dir/3d/src-tauri/friends/animals"
rm -rf "$dir/3d/src-tauri/friends/animals/pdf"
node "$dir/3d/scripts/friends/helper-notices.mjs" "$helper" "$dir/friends" \
    "$dir/3d/src-tauri/friends/Acknowledgements.txt"
printf '{"build": {"beforeBuildCommand": ""}}\n' > "$dir/no-frontend-build.json"
bundles() { # bundle types, then a command prefix for the bundler
    local types=$1
    shift
    (cd "$dir/3d" && CARGO_TARGET_DIR="$dir/target-app" "$@" node node_modules/@tauri-apps/cli/tauri.js build \
        --features friends --config src-tauri/friends/tauri.conf.json --config "$dir/no-frontend-build.json" \
        --bundles "$types" -- \
        --config "patch.szfriends-pinned.tauri-plugin-szfriends.path=\"$dir/friends/tauri\"" 2>&1 | tail -6)
}
# The AppImage's runtime comes from the linuxdeploy the bundler already keeps (a type-2 AppImage starts with one),
# so the check fetches nothing.
linuxdeploy=$(ls "$HOME"/.cache/tauri/linuxdeploy-*-"$(uname -m)".AppImage 2>/dev/null | head -1 || true)
if [ -n "$linuxdeploy" ] && [ -z "${LDAI_RUNTIME_FILE:-}" ]; then
    head -c "$(APPIMAGE_EXTRACT_AND_RUN=1 "$linuxdeploy" --appimage-offset)" "$linuxdeploy" > "$dir/appimage-runtime"
    export LDAI_RUNTIME_FILE="$dir/appimage-runtime"
fi
# An rpm's times are 32-bit: a guest whose clock has run past 2106 cannot write one. The guest's clock stays as it is;
# the rpm is then bundled on its own, the bundler reading times moved back to the day this check was written
# (clock-shift.c, preloaded).
if [ "$(date +%Y)" -gt 2105 ]; then
    bundles deb,appimage env
    cc -shared -fPIC -o "$dir/clock-shift.so" "$dir/3d/scripts/friends/clock-shift.c" -ldl
    echo "the guest's clock reads $(date +%Y); the rpm's bundler reads times moved back to 2026-10-19"
    bundles rpm env LD_PRELOAD="$dir/clock-shift.so" SZF_CLOCK_SHIFT=$(($(date +%s) - $(date -d 2026-10-19 +%s)))
else
    bundles deb,rpm,appimage env
fi

bundle="$dir/target-app/release/bundle"
deb=$(ls "$bundle"/deb/*.deb) rpm=$(ls "$bundle"/rpm/*.rpm) appimage=$(ls "$bundle"/appimage/*.AppImage)
check() { # name, listing
    local listing=$2
    if grep -q '/szfriends-helper$' <<<"$listing" && grep -q 'friends/animals/manifest.json$' <<<"$listing" &&
        grep -q 'friends/Acknowledgements.txt$' <<<"$listing"; then
        echo "ok $1 carries the helper, the animal set and the acknowledgements"
    else
        echo "not ok $1 lacks the helper, the animal set or the acknowledgements"
        exit 1
    fi
}
notice() { # name, the acknowledgements file it carries
    if grep -q '^libdbus 1\.' "$2" && grep -q 'Academic Free License' "$2" &&
        grep -q 'GNU GENERAL PUBLIC LICENSE' "$2"; then
        echo "ok $1's acknowledgements name libdbus with its licences (AFL-2.1 or GPL-2.0-or-later)"
    else
        echo "not ok $1's acknowledgements do not name libdbus, which the helper links for Bluetooth"
        exit 1
    fi
}
check deb "$(dpkg-deb -c "$deb" | awk '{print $NF}')"
mkdir -p "$dir/deb-files"
dpkg-deb -x "$deb" "$dir/deb-files"
notice deb "$(find "$dir/deb-files" -path '*friends/Acknowledgements.txt' | head -1)"
check rpm "$(rpm -qlp "$rpm" 2>/dev/null)"
mkdir -p "$dir/extract"
(cd "$dir/extract" && "$appimage" --appimage-extract >/dev/null)
check AppImage "$(cd "$dir/extract" && find squashfs-root)"
notice AppImage "$(find "$dir/extract/squashfs-root" -path '*friends/Acknowledgements.txt' | head -1)"
echo "deb $(dpkg-deb -c "$deb" | grep szfriends-helper | awk '{print $NF}')"

# An older helper runs, as an app would have started it from its per-user copy, in the Friends home the packaged app
# uses: a release build serves the person's own, here under the run's own data directory.
export XDG_DATA_HOME="$dir/xdg/data" XDG_CONFIG_HOME="$dir/xdg/config" XDG_CACHE_HOME="$dir/xdg/cache"
home="$XDG_DATA_HOME/shenzhen-friends"
mkdir -p "$home" "$dir/older"
export SZFRIENDS_STATE_DIR=$home
socket="$home/ipc/helper.sock"
older="$dir/older/szfriends-helper"
"$dir/target-core/release/examples/restamp" "$helper" "$older" $((build - 1))
chmod +x "$older"
chmod 700 "$home"
"$older" >"$dir/older.log" 2>&1 &
older_pid=$!
for _ in $(seq 1 80); do [ -S "$socket" ] && break; sleep 0.25; done
if ! [ -S "$socket" ]; then
    echo "not ok the older helper did not start"
    tail -n 5 "$dir/older.log" "$home/helper.log"
    exit 1
fi
echo "ok an older helper runs (build $((build - 1)))"
# The app's own helper leaves after a shorter wait than usual once the app has quit, so the run ends promptly.
export SZFRIENDS_HELPER_TIME_SCALE=0.5

# The AppImage starts Friends after its first paint and asks the older helper to hand over; quitting it unmounts the
# image, and the helper runs on from its per-user copy until its own grace period ends.
xvfb-run -a sh -c "\"$appimage\" & echo \$! > \"$dir/app.pid\"; wait" >/dev/null 2>&1 &
xvfb_pid=$!
copy=
for _ in $(seq 1 120); do
    copy=$(ls -d "$home"/helper/*/szfriends-helper 2>/dev/null | head -1 || true)
    [ -n "$copy" ] && pgrep -f "$copy" >/dev/null && [ -S "$socket" ] && break
    sleep 0.5
done
[ -n "$copy" ] && pgrep -f "$copy" >/dev/null || { echo "not ok the AppImage never started its helper"; exit 1; }
for _ in $(seq 1 40); do kill -0 "$older_pid" 2>/dev/null || break; sleep 0.25; done
if kill -0 "$older_pid" 2>/dev/null || ! grep -q "handing over to build $build" "$home/helper.log"; then
    echo "not ok the older helper did not hand over to build $build"
    exit 1
fi
echo "ok the AppImage asks the older helper to hand over to build $build, and it leaves"
echo "ok the AppImage started the helper from its per-user copy ($(basename "$(dirname "$copy")"))"
kill "$(cat "$dir/app.pid")"
for _ in $(seq 1 40); do kill -0 "$(cat "$dir/app.pid")" 2>/dev/null || break; sleep 0.25; done
sleep 1
if [ -S "$socket" ] && pgrep -f "$copy" >/dev/null; then
    echo "ok the helper outlives the AppImage that started it"
else
    echo "not ok the helper went with the AppImage"
    exit 1
fi
for _ in $(seq 1 60); do [ -S "$socket" ] || break; sleep 0.5; done
[ -S "$socket" ] && { echo "not ok the helper did not exit on its own"; exit 1; }
grep -q "exiting: " "$home/helper.log" || { echo "not ok the helper's log does not say why it left"; exit 1; }
reason=$(grep "exiting: " "$home/helper.log" | tail -1 | cut -d' ' -f3-)
echo "ok the helper exits on its own after its last app ($reason)"
wait
