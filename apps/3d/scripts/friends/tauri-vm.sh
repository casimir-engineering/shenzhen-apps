#!/bin/bash
# Runs the Tauri Friends checks inside a running Parallels VM, from a Mac: copies this checkout's Tauri shell and
# frontend build (dist/, from npm run build) and the Friends sources of a shenzhen-pdf checkout, with the online
# stack's libraries from its ext/, into a fresh temporary directory in the guest, works there, and removes the
# directory. Nothing is shared or mounted; the guest fetches crates itself.
#
#   scripts/friends/tauri-vm.sh smoke|package|installers|check windows-vm|linux-vm <shenzhen-pdf checkout> [VM name]
#
#   smoke     builds the Rust helper, the befriend tool and the app with the friends-smoke feature, and runs
#             tauri-smoke.mjs: the app against two real helpers in temporary homes.
#   package   builds the installers with Friends (NSIS and MSI, or deb, rpm and AppImage) and runs
#             tauri-package-check.ps1 or .sh: what they carry, and the handover and per-user copy of ADR 0015 § 14.
#             With $SZF_VM_KEEP (a directory on the Mac), a passing run copies the installers there, under
#             windows-<target>/ or linux-<arch>/.
#   installers  Windows only: builds the NSIS installer and the MSI with Friends, as package does, through cmd.exe
#             alone (no PowerShell, which can hang in a guest that otherwise answers) and without package's checks,
#             and copies them to $SZF_VM_KEEP/windows-<target>/. tools/release.sh builds the release's installers so.
#   check     cargo check of the Tauri shell with and without the `friends` feature for $SZF_VM_TARGETS (default
#             x86_64-pc-windows-msvc aarch64-pc-windows-msvc, or the guest's own Linux target).
#
#   windows-vm  default VM "Windows 11"; runs as the signed-in user with %USERPROFILE%\.cargo\bin and the MSVC
#               build tools; $SZF_VM_NODE is the guest's node.exe, $SZF_VM_TAURI_CLI a guest node_modules holding
#               @tauri-apps/cli (package), $SZF_VM_TARGET the Rust target (default aarch64-pc-windows-msvc).
#   linux-vm    default VM "Ubuntu 24.04 (with Rosetta)"; $SZF_VM_ENV is a guest script that puts cargo and node on
#               PATH (sourced), $SZF_VM_TAURI_CLI as above; as root when SZF_VM_AS_ROOT=1 (for a toolchain only
#               root can read). The app runs under xvfb-run. $SZF_VM_VENDOR, a `cargo vendor` directory on the Mac
#               (the plugin's tools/host-build.sh vendor makes one, docs/FRIENDS.md § Locked builds), goes along
#               and the guest builds from it instead of fetching crates (a guest whose clock has run off fails
#               crates.io's certificate).
# Starts, resumes and suspends nothing: the VM must already be running. A run cut short (Ctrl-C, a failed copy) still
# removes its directory in the guest and, on Linux, stops what it started there.
#
#   SZF_VM_PERSIST  a directory in the guest kept between runs instead of a temporary one (tools/release.sh sets it:
#               /var/tmp/szf3d-release, C:\szf3d-release): the tree is synced into <dir>/src by vm-sync.py, which sends
#               only the files whose sha256 changed, then copied to a fresh <dir>/run, where the build runs; cargo's
#               output (<dir>/target-core, <dir>/target-app) and, on Linux, its home stay, so the next build compiles
#               only what changed. A path without spaces, under /var/tmp/szf3d- or C:\szf3d-.
set -euo pipefail
guest_cleanup=()
cleanup_guest() {
    [ ${#guest_cleanup[@]} -eq 0 ] || "${guest_cleanup[@]}" >/dev/null 2>&1 || true
    guest_cleanup=()
}
trap cleanup_guest EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
here=$(cd "$(dirname "$0")/../.." && pwd)
mode=${1:?usage: tauri-vm.sh smoke|package|installers|check windows-vm|linux-vm <shenzhen-pdf checkout> [VM]}
platform=${2:?usage: tauri-vm.sh smoke|package|installers|check windows-vm|linux-vm <shenzhen-pdf checkout> [VM]}
friends_root=$(cd "${3:?the shenzhen-pdf checkout with portable/friends/tauri}" && pwd)
friends="$friends_root/portable/friends"
[ -f "$here/dist/index.html" ] || { echo "dist/ is missing: npm run build first" >&2; exit 1; }
[ -f "$friends/tauri/Cargo.toml" ] || { echo "$friends has no tauri plugin" >&2; exit 1; }

payload_tree() { # the directory to fill: the tree the guest builds from
    local stage=$1
    mkdir -p "$stage/3d" "$stage/friends/service/identity" "$stage/ext"
    COPYFILE_DISABLE=1 tar --no-xattrs -cf - --exclude 'src-tauri/target' --exclude 'src-tauri/gen' \
        --exclude 'src-tauri/friends/bin' --exclude 'src-tauri/friends/animals' --exclude '.DS_Store' \
        -C "$here" .cargo package.json src-tauri dist scripts/friends/tauri-smoke.mjs scripts/friends/tauri-smoke-page.js \
        scripts/friends/tauri-package-check.sh scripts/friends/tauri-package-check.ps1 \
        scripts/friends/helper-notices.mjs scripts/friends/clock-shift.c \
        tests/fixtures/formats/triangle.stl tests/fixtures/formats/drawing.svg |
        tar -xf - -C "$stage/3d"
    COPYFILE_DISABLE=1 tar --no-xattrs -cf - --exclude 'core-rs/target' --exclude 'core-rs/fuzz' \
        --exclude 'tauri/target' --exclude '.DS_Store' -C "$friends" core-rs tauri service/identity/wordlist \
        avatars/animals ACKNOWLEDGEMENTS.txt | tar -xf - -C "$stage/friends"
    # The online stack's C and C++ sources, which szfriends-datachannel-sys finds in an ext/ above the crate.
    COPYFILE_DISABLE=1 tar --no-xattrs -cf - --exclude '.git' --exclude '.DS_Store' -C "$friends_root/ext" \
        libdatachannel libjuice usrsctp plog mbedtls | tar -xf - -C "$stage/ext"
    if [ -n "${SZF_VM_VENDOR:-}" ]; then
        mkdir "$stage/vendor"
        COPYFILE_DISABLE=1 tar --no-xattrs -cf - -C "$SZF_VM_VENDOR" . | tar -xf - -C "$stage/vendor"
    fi
}
# The staging directory, removed (by its path from mktemp, never a pattern).
remove_stage() { python3 -I -c 'import shutil, sys; shutil.rmtree(sys.argv[1])' "$1"; }

payload() {
    local stage
    stage=$(mktemp -d "${TMPDIR:-/tmp}/szf3d-vm-payload.XXXXXX")
    payload_tree "$stage"
    local vendor=()
    [ -d "$stage/vendor" ] && vendor=(vendor)
    COPYFILE_DISABLE=1 tar --no-xattrs -czf - -C "$stage" 3d friends ext ${vendor[@]+"${vendor[@]}"} | base64
    remove_stage "$stage"
}

# SZF_VM_PERSIST: the tree synced into <root>/src (vm-sync.py), for the caller to copy to <root>/run.
sync_persistent() { # linux|windows, VM name, guest root, extra vm-sync.py arguments
    local platform=$1 vm=$2 root=$3 stage status=0
    shift 3
    stage=$(mktemp -d "${TMPDIR:-/tmp}/szf3d-vm-payload.XXXXXX")
    payload_tree "$stage"
    python3 -I "$here/scripts/friends/vm-sync.py" "$platform" "$vm" "$root" "$stage" "$@" || status=$?
    remove_stage "$stage"
    return "$status"
}

# The installers with Friends, as tauri-package-check.ps1 builds them, by a batch file cmd.exe runs: the Rust helper
# for the target, the animal set, the acknowledgements, then NSIS and MSI. The bundles come back as base64 that
# certutil writes and cmd's type prints.
windows_installers() { # guest dir, Rust target, guest node.exe; uses $vm's exec array from run_windows
    local dir=$1 target=$2 node=$3
    local cli=${SZF_VM_TAURI_CLI:?set SZF_VM_TAURI_CLI to a guest node_modules holding @tauri-apps/cli}
    local keep=${SZF_VM_KEEP:?set SZF_VM_KEEP to the Mac directory the installers go to}
    local plugin="${dir//\\//}/friends/tauri" batch
    batch=$(mktemp "${TMPDIR:-/tmp}/szf3d-installers.XXXXXX")
    {
        printf '%s\r\n' '@echo off' 'setlocal' \
            'set PATH=%USERPROFILE%\.cargo\bin;%PATH%' \
            "set SZFRIENDS_HELPER_VERSION=$helper_version" "set SZFRIENDS_HELPER_BUILD=$helper_build" \
            "mkdir $dir\3d\node_modules\@tauri-apps" \
            "xcopy /e /i /q $cli\@tauri-apps\cli $dir\3d\node_modules\@tauri-apps\cli >nul || (echo failed at step 11 & exit /b 11)" \
            "for /d %%d in ($cli\@tauri-apps\cli-win32-*) do xcopy /e /i /q %%d $dir\3d\node_modules\@tauri-apps\%%~nxd >nul" \
            "cd /d $dir\friends\core-rs || (echo failed at step 12 & exit /b 12)" \
            "set CARGO_TARGET_DIR=$dir\target-core" \
            "cargo build --release --target $target -p szfriends-helper --bin szfriends-helper || (echo failed at step 13 & exit /b 13)" \
            "mkdir $dir\3d\src-tauri\friends\bin" \
            "copy /b $dir\target-core\\$target\release\szfriends-helper.exe $dir\3d\src-tauri\friends\bin\szfriends-helper-$target.exe >nul || (echo failed at step 14 & exit /b 14)" \
            "xcopy /e /i /q $dir\friends\avatars\animals $dir\3d\src-tauri\friends\animals >nul || (echo failed at step 15 & exit /b 15)" \
            "if exist $dir\3d\src-tauri\friends\animals\pdf rmdir /s /q $dir\3d\src-tauri\friends\animals\pdf" \
            "$node $dir\3d\scripts\friends\helper-notices.mjs $dir\target-core\\$target\release\szfriends-helper.exe $dir\friends $dir\3d\src-tauri\friends\Acknowledgements.txt || (echo failed at step 16 & exit /b 16)" \
            "echo {\"build\": {\"beforeBuildCommand\": \"\"}}> $dir\no-frontend-build.json" \
            "cd /d $dir\3d || (echo failed at step 17 & exit /b 17)" \
            "set CARGO_TARGET_DIR=$dir\target-app" \
            "$node node_modules\@tauri-apps\cli\tauri.js build --target $target --features friends --config src-tauri\friends\tauri.conf.json --config $dir\no-frontend-build.json --bundles nsis,msi -- --config patch.szfriends-pinned.tauri-plugin-szfriends.path='$plugin' || (echo failed at step 18 & exit /b 18)" \
            "cd /d $dir\target-app\\$target\release\bundle || (echo failed at step 19 & exit /b 19)" \
            "tar -cf $dir\bundles.tar nsis msi || (echo failed at step 20 & exit /b 20)" \
            "certutil -f -encode $dir\bundles.tar $dir\bundles.b64 >nul || (echo failed at step 21 & exit /b 21)" \
            'echo installers built'
    } >"$batch"
    base64 -b 76 <"$batch" | "${exec[@]}" cmd /c "findstr /v /c:# > $dir\\build.b64"
    rm -f "$batch"
    "${exec[@]}" cmd /c "certutil -f -decode $dir\\build.b64 $dir\\build.cmd >nul && del $dir\\build.b64" >/dev/null
    # The build's output goes to a log in the guest, whose last lines come back. Only a batch that reached its end
    # writes "installers built" (cmd expands %ERRORLEVEL% before the line runs, so it cannot say).
    "${exec[@]}" cmd /c "$dir\\build.cmd > $dir\\build.log 2>&1" >/dev/null 2>&1 || true
    local log
    log=$("${exec[@]}" cmd /c "type $dir\\build.log" | tr -d '\r')
    printf '%s\n' "$log" | tail -40
    printf '%s\n' "$log" | grep -q '^installers built' ||
        { echo "windows-vm: the installers did not build" >&2; return 1; }
    mkdir -p "$keep/windows-$target"
    "${exec[@]}" cmd /c "type $dir\\bundles.b64" | tr -d '\r' | grep -v -- '-----' | base64 -d |
        tar -xf - -C "$keep/windows-$target"
    ls "$keep/windows-$target"/nsis/*.exe "$keep/windows-$target"/msi/*.msi
}

run_windows() { # VM name
    local vm=$1 dir status=0
    local exec=(prlctl exec "$vm" --current-user)
    local node=${SZF_VM_NODE:?set SZF_VM_NODE to the guest node.exe}
    local target=${SZF_VM_TARGET:-aarch64-pc-windows-msvc}
    # cmd.exe only to set up: PowerShell can hang in a guest that otherwise answers. The payload goes over in lines
    # findstr copies unchanged ('#' is not in base64), and certutil decodes it.
    if [ -n "${SZF_VM_PERSIST:-}" ]; then
        local root=$SZF_VM_PERSIST
        case "$root" in
        'C:\szf3d-'*) ;;
        *) echo "windows-vm: SZF_VM_PERSIST must start with C:\\szf3d-" >&2; return 1 ;;
        esac
        case "$root" in *' '* | *'&'* | *'%'*) echo "windows-vm: no usable directory ($root)" >&2; return 1 ;; esac
        sync_persistent windows "$vm" "$root" || return 1
        # A fresh copy of the tree each run (robocopy /MIR removes what the last run added) at the same path, with
        # cargo's output kept beside it and joined in: the same paths every run, so cargo reuses what did not change.
        dir="$root\\run"
        "${exec[@]}" cmd /c "(for %t in (target-core target-app) do if not exist $root\\%t mkdir $root\\%t) & \
robocopy $root\\src $dir /MIR /XD $dir\\target-core $dir\\target-app /NFL /NDL /NJH /NJS /NP >nul & \
(for %t in (target-core target-app) do if not exist $dir\\%t mklink /J $dir\\%t $root\\%t >nul) & \
if exist $root\\target-app\\$target\\release\\bundle rmdir /s /q $root\\target-app\\$target\\release\\bundle"
        "${exec[@]}" cmd /c "if not exist $dir\\3d\\package.json exit 1" ||
            { echo "windows-vm: $dir was not made from $root\\src" >&2; return 1; }
    else
        dir="$("${exec[@]}" cmd /c "echo %TEMP%" | tr -d '\r\n')\\szf3d-tauri-$(openssl rand -hex 8)"
        case "$dir" in *' '* | %*) echo "windows-vm: no usable temporary directory ($dir)" >&2; return 1 ;; esac
        "${exec[@]}" cmd /c "mkdir $dir" || { echo "windows-vm: no temporary directory ($dir)" >&2; return 1; }
        guest_cleanup=("${exec[@]}" cmd /c "rmdir /s /q $dir")
        payload | base64 -d | base64 -b 76 | "${exec[@]}" cmd /c "findstr /v /c:# > $dir\\tree.b64"
        "${exec[@]}" cmd /c "certutil -decode $dir\\tree.b64 $dir\\tree.tgz > nul && del $dir\\tree.b64"
        "${exec[@]}" cmd /c "tar -xzf $dir\\tree.tgz -C $dir"
    fi
    if [ "$mode" = check ]; then
        local cargo='%USERPROFILE%\.cargo\bin\cargo.exe' features
        local plugin="${dir//\\//}/friends/tauri"
        for target in ${SZF_VM_TARGETS:-x86_64-pc-windows-msvc aarch64-pc-windows-msvc}; do
            for features in tauri/custom-protocol friends,tauri/custom-protocol; do
                echo "cargo check --target $target --features $features"
                "${exec[@]}" cmd /c "cd /d $dir\\3d\\src-tauri && $cargo check --target $target --features \
$features --config patch.szfriends-pinned.tauri-plugin-szfriends.path='$plugin' --target-dir $dir\\target-check \
2>&1" | tr -d '\r' | tail -1 || status=$?
            done
        done
    elif [ "$mode" = installers ]; then
        windows_installers "$dir" "$target" "$node" || status=$?
    elif [ "$mode" = package ]; then
        local cli=${SZF_VM_TAURI_CLI:?set SZF_VM_TAURI_CLI to a guest node_modules holding @tauri-apps/cli}
        local check="$dir\\3d\\scripts\\friends\\tauri-package-check.ps1"
        "${exec[@]}" powershell -NoProfile -ExecutionPolicy Bypass -File "$check" -Dir "$dir" -CliModules "$cli" \
            -Version "$helper_version" -Build "$helper_build" -Node "$node" -Target "$target" 2>&1 |
            tr -d '\r' || status=$?
        if [ "$status" = 0 ] && [ -n "${SZF_VM_KEEP:-}" ]; then
            mkdir -p "$SZF_VM_KEEP/windows-$target"
            "${exec[@]}" cmd /c "cd /d $dir\\target-app\\$target\\release\\bundle && tar -cf $dir\\bundles.tar nsis msi"
            "${exec[@]}" powershell -NoProfile -Command \
                "[Convert]::ToBase64String([IO.File]::ReadAllBytes('$dir\\bundles.tar'))" | tr -d '\r\n' |
                base64 -d | tar -xf - -C "$SZF_VM_KEEP/windows-$target"
        fi
    else
        local cargo='%USERPROFILE%\.cargo\bin\cargo.exe'
        local plugin="${dir//\\//}/friends/tauri"
        "${exec[@]}" cmd /c "cd /d $dir\\friends\\core-rs && $cargo build --release --target $target \
-p szfriends-helper --bin szfriends-helper --example befriend --target-dir $dir\\target-core 2>&1" | tr -d '\r' |
            tail -3 || status=$?
        # No double quotes: Windows' command-line parsing would strip them. The temporary path has no spaces.
        "${exec[@]}" cmd /c "cd /d $dir\\3d\\src-tauri && $cargo build --release --target $target --features \
friends-smoke,tauri/custom-protocol --config patch.szfriends-pinned.tauri-plugin-szfriends.path='$plugin' \
--target-dir $dir\\target-app 2>&1" | tr -d '\r' | tail -3 || status=$?
        local core="$dir\\target-core\\$target\\release"
        "${exec[@]}" cmd /c "cd /d $dir\\3d && $node scripts\\friends\\tauri-smoke.mjs --app \
$dir\\target-app\\$target\\release\\shenzhen-3d.exe --helper $core\\szfriends-helper.exe \
--befriend $core\\examples\\befriend.exe 2>&1" | tr -d '\r' || status=$?
    fi
    cleanup_guest
    return "$status"
}

run_linux() { # VM name
    local vm=$1 dir status=0
    local exec=(prlctl exec "$vm")
    [ "${SZF_VM_AS_ROOT:-0}" = 1 ] || exec+=(--current-user)
    local setup=${SZF_VM_ENV:+. $SZF_VM_ENV &&}
    if [ -n "${SZF_VM_PERSIST:-}" ]; then
        local root=$SZF_VM_PERSIST
        case "$root" in
        /var/tmp/szf3d-*) ;;
        *) echo "linux-vm: SZF_VM_PERSIST must start with /var/tmp/szf3d-" >&2; return 1 ;;
        esac
        case "$root" in *' '* | *"'"* | *'"'*) echo "linux-vm: no usable directory ($root)" >&2; return 1 ;; esac
        local as_root=()
        [ "${SZF_VM_AS_ROOT:-0}" = 1 ] && as_root=(--as-root)
        sync_persistent linux "$vm" "$root" ${as_root[@]+"${as_root[@]}"} || return 1
        # A fresh copy of the tree each run (rsync --delete removes what the last run added) at the same path, with
        # cargo's output and home kept beside it and linked in: the same paths every run, so cargo reuses what did not
        # change. The installers of the last run go first, so none is taken for this one's.
        dir=$root/run
        "${exec[@]}" "mkdir -p $root/target-core $root/target-app $root/cargo-home $dir && \
rsync -a --delete --exclude=/target-core --exclude=/target-app --exclude=/cargo-home $root/src/ $dir/ && \
for t in target-core target-app cargo-home; do ln -sfn $root/\$t $dir/\$t; done && \
rm -rf $root/target-app/release/bundle && test -f $dir/3d/package.json"
        # What the last run started there stops with this one; the directory stays. The bracket keeps the pattern from
        # matching the shell that runs it.
        guest_cleanup=("${exec[@]}" "for pid in \$(pgrep -f '${dir%?}[${dir: -1}]/'); do kill -9 \$pid; done")
    else
        dir=$("${exec[@]}" "mktemp -d /tmp/szf3d-tauri.XXXXXX")
        case "$dir" in /tmp/szf3d-tauri.*) ;; *) echo "linux-vm: no temporary directory ($dir)" >&2; return 1 ;; esac
        # The bracket keeps the pattern from matching the shell that runs it.
        guest_cleanup=("${exec[@]}" "for pid in \$(pgrep -f '/tmp/[s]${dir#/tmp/s}/'); do kill -9 \$pid; done; rm -rf $dir")
        payload | "${exec[@]}" "base64 -d | tar -xzf - -C $dir"
    fi
    if [ -n "${SZF_VM_VENDOR:-}" ]; then
        "${exec[@]}" "mkdir -p $dir/cargo-home && printf '%s\\n' '[source.crates-io]' 'replace-with = \"vendored\"' \
'[source.vendored]' 'directory = \"$dir/vendor\"' > $dir/cargo-home/config.toml"
    fi
    if [ "$mode" = check ]; then
        local patch="patch.szfriends-pinned.tauri-plugin-szfriends.path=\\\"$dir/friends/tauri\\\"" features
        for features in tauri/custom-protocol friends,tauri/custom-protocol; do
            echo "cargo check --features $features"
            "${exec[@]}" "$setup export CARGO_HOME=$dir/cargo-home CARGO_TARGET_DIR=$dir/target-check; \
cd $dir/3d/src-tauri && cargo check --features $features --config \"$patch\" 2>&1 | tail -1" || status=$?
        done
    elif [ "$mode" = package ]; then
        local cli=${SZF_VM_TAURI_CLI:?set SZF_VM_TAURI_CLI to a guest node_modules holding @tauri-apps/cli}
        # A guest clock that has run off confuses incremental builds' timestamps: never incremental here.
        "${exec[@]}" "$setup export CARGO_HOME=$dir/cargo-home CARGO_INCREMENTAL=0 ${SZF_VM_VENDOR:+CARGO_NET_OFFLINE=true}; \
bash $dir/3d/scripts/friends/tauri-package-check.sh \
$dir $cli $helper_version $helper_build 2>&1" || status=$?
        if [ "$status" = 0 ] && [ -n "${SZF_VM_KEEP:-}" ]; then
            local arch
            arch=$("${exec[@]}" "uname -m")
            mkdir -p "$SZF_VM_KEEP/linux-$arch"
            "${exec[@]}" "cd $dir/target-app/release/bundle && tar -cf - deb/*.deb rpm/*.rpm appimage/*.AppImage |
base64" | base64 -d | tar -xf - -C "$SZF_VM_KEEP/linux-$arch"
        fi
    else
        local env="$setup export CARGO_HOME=$dir/cargo-home CARGO_TARGET_DIR="
        "${exec[@]}" "$env$dir/target-core; cd $dir/friends/core-rs && cargo build --release -p szfriends-helper \
--bin szfriends-helper --example befriend 2>&1 | tail -3" || status=$?
        local patch="patch.szfriends-pinned.tauri-plugin-szfriends.path=\\\"$dir/friends/tauri\\\""
        "${exec[@]}" "$env$dir/target-app; cd $dir/3d/src-tauri && cargo build --release --features \
'friends-smoke tauri/custom-protocol' --config \"$patch\" 2>&1 | tail -3" || status=$?
        # A session bus of the run's own: a second launch reaches the running app over D-Bus.
        "${exec[@]}" "$setup cd $dir/3d && dbus-run-session -- xvfb-run -a node scripts/friends/tauri-smoke.mjs \
--app $dir/target-app/release/shenzhen-3d --helper $dir/target-core/release/szfriends-helper \
--befriend $dir/target-core/release/examples/befriend 2>&1" || status=$?
    fi
    cleanup_guest
    return "$status"
}

# The stamp the packaged helper carries: the helper version and build number friends-lock.sh reads (friends.lock,
# or apps/pdf's in the Shenzhen repository).
# shellcheck source=friends-lock.sh
. "$here/scripts/friends/friends-lock.sh"
friends_lock_read "$here"
helper_build=$FRIENDS_BUILD_NUMBER
helper_version=$FRIENDS_SHORT_VERSION

case "$mode" in smoke | package | installers | check) ;; *) echo "unknown mode: $mode" >&2; exit 2 ;; esac
case "$platform" in
windows-vm) run_windows "${4:-Windows 11}" ;;
linux-vm) run_linux "${4:-Ubuntu 24.04 (with Rosetta)}" ;;
*) echo "unknown platform: $platform" >&2; exit 2 ;;
esac
