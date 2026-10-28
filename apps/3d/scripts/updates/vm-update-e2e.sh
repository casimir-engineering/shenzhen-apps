#!/bin/bash
# Updating from an older version on Windows and Linux, in a running Parallels VM, from a Mac (docs/UPDATES.md
# § Testing): builds two test versions of the Tauri app (feature updates-test-api) in the guest, an old one and the
# candidate, signs the candidate's installers on this Mac with the updater key (release-updates.mjs, as a release
# does), and runs update-e2e-guest.mjs in the guest for each way the app is installed:
#
#   windows  NSIS: the published 0.2.0 Setup (if --published), then the old test version over it, which updates
#            itself to the candidate (a changed download refused first). MSI: the same with the MSIs, as the
#            signed-in user with administrator rights (a scheduled task: an MSI installs for all users).
#   linux    AppImage: the old test version in a folder of its own updates itself (a changed download refused
#            first; the file then holds the candidate's bytes). deb: the old test package offers Download and
#            opens the candidate's package.
#
#   scripts/updates/vm-update-e2e.sh windows|linux <work dir> [--published <dir of the 0.2.0 release files>]
#       [--old 0.2.2] [--new 0.2.9] [--vm <name>]
#
# Needs dist/ (npm run build). Windows: $SZF_VM_NODE (the guest's node.exe) and $SZF_VM_TAURI_CLI (a guest
# node_modules holding @tauri-apps/cli and its Windows binary); the guest fetches crates. Linux: $SZF_VM_ENV (a guest
# script, read as root, putting cargo, rustup and node on PATH) and $SZF_VM_TAURI_CLI; the guest's clock may be wrong,
# so crates come from a `cargo vendor` of this app made here ($SZF_VM_VENDOR), and the AppImage runtime from the
# linuxdeploy the guest already keeps. Commands go through cmd.exe (Windows) or bash; nothing is shared or mounted;
# test apps run in the guest only (Linux under Xvfb). The guest's work directory is removed at the end; logs are
# copied to <work dir>.
set -euo pipefail
here=$(cd "$(dirname "$0")/../.." && pwd)
platform=${1:?usage: vm-update-e2e.sh windows|linux <work dir> [options]}
work=$(mkdir -p "${2:?work dir}" && cd "$2" && pwd)
shift 2
published="" old=0.2.2 new=0.2.9 vm=""
while [ $# -gt 0 ]; do
    case $1 in
    --published) published=$(cd "$2" && pwd); shift 2 ;;
    --old) old=$2; shift 2 ;;
    --new) new=$2; shift 2 ;;
    --vm) vm=$2; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
    esac
done
[ -f "$here/dist/index.html" ] || { echo "dist/ is missing: npm run build first" >&2; exit 1; }
tag=preview-$new
mkdir -p "$work/bundles" "$work/release" "$work/logs"
printf '{"version":"%s"}' "$old" >"$work/old.json"
printf '{"version":"%s"}' "$new" >"$work/new.json"
printf '{"build": {"beforeBuildCommand": ""}}' >"$work/no-frontend-build.json"
COPYFILE_DISABLE=1 tar --no-xattrs -czf "$work/payload.tgz" --exclude 'src-tauri/target' --exclude 'src-tauri/gen' \
    --exclude 'src-tauri/friends/bin' --exclude '.DS_Store' -C "$here" package.json .cargo src-tauri dist \
    scripts/updates tests/updates
status=0
step() { echo "== $*"; }

# The candidate's release, as a release makes it: the installers under their release names, signed here.
release() {
    printf '# Shenzhen 3D %s (update test build)\n' "$new" >"$work/release/README.md"
    node "$here/scripts/updates/release-updates.mjs" --dir "$work/release" --tag "$tag" --collect "$work/bundles"
}

windows() {
    vm=${vm:-Windows 11}
    local node=${SZF_VM_NODE:?set SZF_VM_NODE to the guest node.exe}
    local cli=${SZF_VM_TAURI_CLI:?set SZF_VM_TAURI_CLI to a guest node_modules holding @tauri-apps/cli}
    wexec() { prlctl exec "$vm" --current-user cmd /c "$*" 2>&1 | tr -d '\r'; }
    wsys() { prlctl exec "$vm" cmd /c "$*" 2>&1 | tr -d '\r'; }
    wput() { base64 -b 76 <"$1" | prlctl exec "$vm" --current-user cmd /c "findstr /v /c:# > $2.b64" &&
        wexec "certutil -f -decode $2.b64 $2 >nul && del $2.b64" >/dev/null; }
    wget() { wexec "certutil -f -encode \"$1\" $dir\\get.b64 >nul" >/dev/null
        prlctl exec "$vm" --current-user cmd /c "type $dir\\get.b64" | tr -d '\r' | grep -v -- '-----' | base64 -d >"$2"
        wexec "del $dir\\get.b64" >/dev/null; }
    # As the signed-in user with administrator rights, without a prompt: a scheduled task made by the system.
    welevated() { # name, command line; waits for it
        printf '@echo off\r\n%s > %s\\%s.out 2>&1\r\necho done %%ERRORLEVEL%% >> %s\\%s.out\r\n' "$2" "$dir" "$1" "$dir" "$1" \
            >"$work/$1.cmd"
        wput "$work/$1.cmd" "$dir\\$1.cmd"
        local user
        user=$(wexec "echo %USERNAME%" | tr -d '\n')
        wsys "schtasks /create /tn szupd-$1 /tr $dir\\$1.cmd /sc once /st 23:59 /ru $user /rl HIGHEST /it /f >nul && schtasks /run /tn szupd-$1 >nul"
        until wexec "type $dir\\$1.out 2>nul" | grep -q '^done'; do sleep 5; done
        wsys "schtasks /delete /tn szupd-$1 /f >nul"
        wexec "type $dir\\$1.out"
    }
    dir="$(wexec "echo %TEMP%" | tr -d '\n')\\szupd-$(openssl rand -hex 6)"
    case "$dir" in *' '* | %*) echo "no usable guest directory ($dir)" >&2; return 1 ;; esac
    wexec "mkdir $dir" >/dev/null
    trap 'wexec "rmdir /s /q $dir" >/dev/null || true' EXIT
    step "payload into $dir"
    wput "$work/payload.tgz" "$dir\\payload.tgz"
    wexec "cd /d $dir && tar -xzf payload.tgz && mkdir node_modules\\@tauri-apps && xcopy /e /i /q $cli\\@tauri-apps\\cli node_modules\\@tauri-apps\\cli >nul && for /d %d in ($cli\\@tauri-apps\\cli-win32-*) do xcopy /e /i /q %d node_modules\\@tauri-apps\\%~nxd >nul" >/dev/null
    for f in old new no-frontend-build; do wput "$work/$f.json" "$dir\\$f.json"; done
    local bundle="$dir\\target\\x86_64-pc-windows-msvc\\release\\bundle"
    for v in old new; do
        local ver
        ver=$([ $v = old ] && echo "$old" || echo "$new")
        step "build the $v test version ($ver, NSIS and MSI, x64)"
        wexec "cd /d $dir && set CARGO_TARGET_DIR=$dir\\target&& set PATH=%USERPROFILE%\\.cargo\\bin;%PATH%&& $node node_modules\\@tauri-apps\\cli\\tauri.js build --target x86_64-pc-windows-msvc --bundles nsis,msi --features updates-test-api --config src-tauri\\updates-test.conf.json --config $dir\\$v.json --config $dir\\no-frontend-build.json -- --locked > $dir\\build-$v.log 2>&1 & echo exit %ERRORLEVEL%" | tail -1
        # By name and /b: a wildcard makes copy join text files.
        wexec "mkdir $dir\\$v & copy /b \"$bundle\\nsis\\Shenzhen 3D_${ver}_x64-setup.exe\" $dir\\$v\\setup.exe >nul & copy /b \"$bundle\\msi\\Shenzhen 3D_${ver}_x64_en-US.msi\" $dir\\$v\\installer.msi >nul & dir $dir\\$v | findstr setup.exe"
    done
    mkdir -p "$work/bundles/nsis" "$work/bundles/msi"
    wget "$dir\\new\\setup.exe" "$work/bundles/nsis/Shenzhen 3D_${new}_x64-setup.exe"
    wget "$dir\\new\\installer.msi" "$work/bundles/msi/Shenzhen 3D_${new}_x64_en-US.msi"
    step "the candidate's release, signed here"
    release
    wexec "mkdir $dir\\release $dir\\published" >/dev/null
    for f in "$work/release"/*; do
        case $f in *.sig) continue ;; esac
        wput "$f" "$dir\\release\\$(basename "$f")"
    done
    local setup=Shenzhen-3D-$new-Windows-x64-Setup.exe msi=Shenzhen-3D-$new-Windows-x64.msi
    local uninstall='HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\Shenzhen 3D'
    local guest="$node scripts\\updates\\update-e2e-guest.mjs --release $dir\\release --tag $tag --timeout 300"

    step "NSIS: published 0.2.0, then $old, which updates itself to $new"
    if [ -n "$published" ]; then
        wput "$published/Shenzhen-3D-0.2.0-Windows-x64-Setup.exe" "$dir\\published\\setup.exe"
        wput "$published/Shenzhen-3D-0.2.0-Windows-x64.msi" "$dir\\published\\installer.msi"
        wexec "start /wait \"\" $dir\\published\\setup.exe /S /D=$dir\\installed & reg query \"$uninstall\" /v DisplayVersion | findstr DisplayVersion"
    fi
    wexec "start /wait \"\" $dir\\old\\setup.exe /S /D=$dir\\installed & reg query \"$uninstall\" /v DisplayVersion | findstr DisplayVersion"
    wexec "cd /d $dir && $guest --app $dir\\installed\\shenzhen-3d.exe --work $dir\\e2e-nsis --tamper $setup" |
        tee "$work/logs/nsis.out" | grep -E '^(ok|not ok|PASSED|FAILED)' || status=1
    wexec "reg query \"$uninstall\" /v DisplayVersion | findstr DisplayVersion" | tee -a "$work/logs/nsis.out"
    grep -q "REG_SZ    $new" "$work/logs/nsis.out" || { echo "not ok the NSIS install is not $new"; status=1; }
    # The uninstaller goes on from a copy of itself, and gives up while the app is still closing: run it until the
    # installation is gone.
    local tries
    for tries in 1 2 3 4 5 6; do
        wexec "start /wait \"\" $dir\\installed\\uninstall.exe /S" >/dev/null
        sleep 5
        wexec "reg query \"$uninstall\"" | grep -q DisplayVersion || break
    done
    # The installers remember the folder in the user's registry; the test's folder goes with it.
    wexec "reg delete \"HKCU\\Software\\shenzhen3d\\Shenzhen 3D\" /f" >/dev/null || true
    wexec "type $dir\\e2e-nsis\\app.log" >"$work/logs/nsis-app.log"
    wexec "type $dir\\e2e-nsis\\mock.log" >"$work/logs/nsis-mock.log"

    step "MSI: published 0.2.0, then $old, which updates itself to $new (with administrator rights)"
    [ -z "$published" ] || welevated msi-published "msiexec /i $dir\\published\\installer.msi /qn"
    welevated msi-old "msiexec /i $dir\\old\\installer.msi /qn"
    welevated msi-e2e "cd /d $dir && $guest --app \"C:\\Program Files\\Shenzhen 3D\\shenzhen-3d.exe\" --work $dir\\e2e-msi --tamper $msi" |
        tee "$work/logs/msi.out" | grep -E '^(ok|not ok|PASSED|FAILED)' || status=1
    grep -q '^PASSED' "$work/logs/msi.out" || status=1
    local keys key
    keys=$(wsys "reg query HKLM\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall /s /f \"Shenzhen 3D\" /d" | grep -E '^HKEY' || true)
    for key in $keys; do
        wsys "reg query \"$key\" /v DisplayVersion" </dev/null | grep DisplayVersion | tee -a "$work/logs/msi.out"
        welevated msi-remove "msiexec /x ${key##*\\} /qn" </dev/null >/dev/null
    done
    grep -q "REG_SZ    $new" "$work/logs/msi.out" || { echo "not ok the MSI install is not $new"; status=1; }
    wexec "reg delete \"HKCU\\Software\\shenzhen3d\\Shenzhen 3D\" /f" >/dev/null || true
    wexec "type $dir\\e2e-msi\\app.log" >"$work/logs/msi-app.log"
    wexec "type $dir\\e2e-msi\\mock.log" >"$work/logs/msi-mock.log"
}

linux() {
    vm=${vm:-Ubuntu 24.04 (with Rosetta)}
    local env=${SZF_VM_ENV:?set SZF_VM_ENV to a guest script that puts cargo and node on PATH}
    local cli=${SZF_VM_TAURI_CLI:?set SZF_VM_TAURI_CLI to a guest node_modules holding @tauri-apps/cli}
    local vendor=${SZF_VM_VENDOR:?set SZF_VM_VENDOR to a cargo vendor directory of src-tauri}
    lexec() { prlctl exec "$vm" "$*"; }
    luser() { prlctl exec "$vm" --current-user "$*"; }
    dir=$(lexec "mktemp -d /tmp/szupd.XXXXXX" | tr -d '\r\n')
    case "$dir" in /tmp/szupd.*) ;; *) echo "no guest directory ($dir)" >&2; return 1 ;; esac
    trap 'lexec "rm -rf $dir" || true' EXIT
    step "payload and vendored crates into $dir"
    lexec "chmod 755 $dir && mkdir $dir/app $dir/vendor $dir/cargo-home $dir/user $dir/release"
    base64 <"$work/payload.tgz" | lexec "base64 -d | tar -xzf - -C $dir/app"
    COPYFILE_DISABLE=1 tar --no-xattrs -czf - -C "$vendor" . | base64 | lexec "base64 -d | tar -xzf - -C $dir/vendor"
    lexec "printf '%s\n' '[source.crates-io]' 'replace-with = \"vendored\"' '[source.vendored]' 'directory = \"$dir/vendor\"' > $dir/cargo-home/config.toml"
    lexec "mkdir -p $dir/app/node_modules/@tauri-apps && cp -a $cli/@tauri-apps/cli $cli/@tauri-apps/cli-linux-* $dir/app/node_modules/@tauri-apps/ && chmod -R a+rX $dir/app"
    for f in old new no-frontend-build; do lexec "cat > $dir/$f.json" <"$work/$f.json"; done
    # As root (the toolchain is root's); offline; the AppImage runtime from the linuxdeploy the guest keeps.
    cat >"$work/build.sh" <<EOF
set -u
. $env
export CARGO_HOME=$dir/cargo-home CARGO_TARGET_DIR=$dir/target CARGO_INCREMENTAL=0 CARGO_NET_OFFLINE=true
linuxdeploy=\$(ls "\$HOME"/.cache/tauri/linuxdeploy-*-"\$(uname -m)".AppImage | head -1)
head -c "\$(APPIMAGE_EXTRACT_AND_RUN=1 "\$linuxdeploy" --appimage-offset)" "\$linuxdeploy" > $dir/appimage-runtime
export LDAI_RUNTIME_FILE=$dir/appimage-runtime APPIMAGE_EXTRACT_AND_RUN=1
cd $dir/app && node node_modules/@tauri-apps/cli/tauri.js build --bundles deb,appimage --features updates-test-api \
  --config src-tauri/updates-test.conf.json --config $dir/\$1.json --config $dir/no-frontend-build.json -- --locked \
  > $dir/build-\$1.log 2>&1
echo "exit \$?"
mkdir -p $dir/\$1 && mv $dir/target/release/bundle/deb/*.deb $dir/\$1/package.deb && mv $dir/target/release/bundle/appimage/*.AppImage $dir/\$1/app.AppImage
EOF
    lexec "cat > $dir/build.sh" <"$work/build.sh"
    for v in old new; do
        step "build the $v test version (AppImage and deb)"
        lexec "bash $dir/build.sh $v" | tail -1
    done
    lexec "cp \$(. $env; command -v node) $dir/node && chmod 755 $dir/node"
    local arch
    arch=$(lexec "uname -m" | tr -d '\r\n')
    local debarch
    debarch=$([ "$arch" = aarch64 ] && echo arm64 || echo amd64)
    mkdir -p "$work/bundles/appimage" "$work/bundles/deb"
    lexec "base64 -w0 $dir/new/app.AppImage" | base64 -d >"$work/bundles/appimage/Shenzhen 3D_${new}_${arch}.AppImage"
    lexec "base64 -w0 $dir/new/package.deb" | base64 -d >"$work/bundles/deb/Shenzhen 3D_${new}_${debarch}.deb"
    step "the candidate's release, signed here"
    release
    for f in "$work/release"/*; do
        case $f in *.sig) continue ;; esac
        base64 <"$f" | lexec "base64 -d > $dir/release/$(basename "$f")"
    done
    lexec "chmod -R a+rX $dir/release && cp $dir/old/app.AppImage $dir/user/Shenzhen-3D.AppImage && chown -R \$(id -un 1000) $dir/user && chmod 755 $dir/user/Shenzhen-3D.AppImage"
    local appimage
    appimage=$(cd "$work/release" && ls Shenzhen-3D-"$new"-Linux-*.AppImage)
    local hash
    hash=$(shasum -a 256 "$work/release/$appimage" | cut -d' ' -f1)
    local session="export XDG_CONFIG_HOME=$dir/user/xdg/config XDG_DATA_HOME=$dir/user/xdg/data XDG_CACHE_HOME=$dir/user/xdg/cache; cd $dir/app && dbus-run-session -- xvfb-run -a $dir/node scripts/updates/update-e2e-guest.mjs --release $dir/release --tag $tag --timeout 300"

    step "AppImage: $old updates itself to $new"
    luser "$session --app $dir/user/Shenzhen-3D.AppImage --work $dir/user/e2e-appimage --tamper $appimage --replaced $dir/user/Shenzhen-3D.AppImage --sha256 $hash 2>&1" |
        tee "$work/logs/appimage.out" | grep -E '^(ok|not ok|PASSED|FAILED)' || status=1
    grep -q '^PASSED' "$work/logs/appimage.out" || status=1
    lexec "cat $dir/user/e2e-appimage/app.log" >"$work/logs/appimage-app.log"

    step "deb: $old offers $new's package"
    lexec "dpkg -i $dir/old/package.deb >/dev/null 2>&1; dpkg-query -W shenzhen-3d"
    luser "$session --app /usr/bin/shenzhen-3d --work $dir/user/e2e-deb --expect download 2>&1" |
        tee "$work/logs/deb.out" | grep -E '^(ok|not ok|PASSED|FAILED)' || status=1
    grep -q '^PASSED' "$work/logs/deb.out" || status=1
    lexec "dpkg -r shenzhen-3d >/dev/null 2>&1; cat $dir/user/e2e-deb/app.log" >"$work/logs/deb-app.log"
}

case "$platform" in
windows) windows ;;
linux) linux ;;
*) echo "unknown platform: $platform" >&2; exit 2 ;;
esac
echo "$([ $status = 0 ] && echo PASSED || echo FAILED) ($platform; logs in $work/logs)"
exit $status
