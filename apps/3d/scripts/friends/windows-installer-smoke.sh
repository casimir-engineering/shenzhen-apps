#!/bin/bash
# Runs windows-installer-smoke.mjs inside a running Parallels Windows VM, from a Mac: the Setup.exe the release (or
# tauri-vm.sh installers) built, installed silently into a temporary folder in the guest and opened in Friends homes
# of the run's own (see the .mjs for what it checks). Through cmd.exe only, as tauri-vm.sh does: PowerShell can hang
# in a guest that otherwise answers. The guest's node.exe is $SZF_VM_NODE (the one tools/release/app_3d.py names for
# the Windows VM). Screenshots of the panel are copied to $SZF_VM_KEEP when set.
#
#   scripts/friends/windows-installer-smoke.sh <Setup.exe> [VM name, default "Windows 11"]
#
# Starts, resumes and suspends nothing: the VM must already be running, signed in, with Shenzhen 3D closed in it.
# Like any Shenzhen 3D Setup, the install first removes a Shenzhen 3D already installed in the VM; the run uninstalls
# its own at the end and puts back the folder the next install goes to.
# The helpers the run started leave on their own once idle; the next run removes the folders they leave.
set -euo pipefail
here=$(cd "$(dirname "$0")/../.." && pwd)
setup=${1:?usage: windows-installer-smoke.sh <Setup.exe> [VM]}
vm=${2:-Windows 11}
node=${SZF_VM_NODE:-'C:\Shenzhen3D-build-0.1.9-4f7dbf54\tools\node-v24.22.0-win-arm64\node.exe'}
exec=(prlctl exec "$vm" --current-user)

temp=$("${exec[@]}" cmd /c "echo %TEMP%" | tr -d '\r\n')
case "$temp" in *' '* | %*) echo "windows-installer-smoke: no usable temporary directory ($temp)" >&2; exit 1 ;; esac
# Earlier runs' folders, once their helpers have left.
"${exec[@]}" cmd /c "for /d %d in ($temp\\szf3d-winsmoke-*) do rmdir /s /q %d" >/dev/null 2>&1 || true
dir="$temp\\szf3d-winsmoke-$(openssl rand -hex 6)"
"${exec[@]}" cmd /c "mkdir $dir" >/dev/null

put() { # Mac file, guest path: base64 lines findstr copies unchanged, which certutil decodes
    base64 -b 76 <"$1" | "${exec[@]}" cmd /c "findstr /v /c:# > $2.b64"
    "${exec[@]}" cmd /c "certutil -f -decode $2.b64 $2 >nul && del $2.b64"
}
put "$setup" "$dir\\Setup.exe"
put "$here/scripts/friends/windows-installer-smoke.mjs" "$dir\\smoke.mjs"

status=0
"${exec[@]}" cmd /c "$node $dir\\smoke.mjs --setup $dir\\Setup.exe --work $dir\\run 2>&1" | tr -d '\r' || status=$?
if [ -n "${SZF_VM_KEEP:-}" ]; then
    mkdir -p "$SZF_VM_KEEP"
    for shot in fresh quarantined broken; do
        "${exec[@]}" cmd /c "certutil -f -encode $dir\\run\\$shot.png $dir\\$shot.b64 >nul && type $dir\\$shot.b64" |
            tr -d '\r' | grep -v -- '-----' | base64 -d >"$SZF_VM_KEEP/windows-smoke-$shot.png" 2>/dev/null || true
    done
fi
exit "$status"
