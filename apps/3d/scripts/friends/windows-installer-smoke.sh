#!/bin/bash
# Runs windows-installer-smoke.mjs inside a running Parallels Windows VM, from a Mac: the Setup.exe the release (or
# tauri-vm.sh installers) built, installed silently into a temporary folder in the guest and opened in Friends homes
# of the run's own (see the .mjs for what it checks). Through cmd.exe only, as tauri-vm.sh does: PowerShell can hang
# in a guest that otherwise answers. The guest's node.exe is $SZF_VM_NODE (the one tools/release/app_3d.py names for
# the Windows VM). Screenshots of the panel are copied to $SZF_VM_KEEP when set.
#
#   scripts/friends/windows-installer-smoke.sh <Setup.exe> [VM name, default "Windows 11"]
#
# $SZF_VM_HOME (a guest folder used as %LOCALAPPDATA%, with a Friends profile made earlier) runs the scenarios that
# reach the Friends host in that profile, so a run makes no new Friends ID (the host allows an address only a few a
# day). $SZF_VM_FIREWALL=1 also runs the firewall scenarios: as the guest's administrator (prlctl exec without
# --current-user) the run removes Friends' rule, sets the network Private or Public and adds Friends' rule or a Block
# rule between them, then puts the network category back and removes what it added.
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
admin=(prlctl exec "$vm")

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

home=()
[ -n "${SZF_VM_HOME:-}" ] && home=(--home "$SZF_VM_HOME")
smoke() { # arguments for smoke.mjs; output to stdout; returns its status
    "${exec[@]}" cmd /c "$node $dir\\smoke.mjs --setup $dir\\Setup.exe --work $dir\\run ${home[*]+${home[*]}} $* 2>&1" | tr -d '\r'
}

# Friends' rule, as the installer adds it (szfriends-core nearby/firewall.rs rule_arguments).
rule='name="Shenzhen Friends (people nearby)"'
add_rule="netsh advfirewall firewall add rule $rule dir=in action=allow protocol=TCP localport=48250-48257 remoteip=localsubnet profile=private,domain"
block='name="szf-smoke-block"'
add_block="netsh advfirewall firewall add rule $block dir=in action=block protocol=TCP localport=48250-48257 profile=any"
as_admin() { "${admin[@]}" cmd /c "$*" >/dev/null 2>&1 || true; }
category() { # Private or Public, for every connected network
    "${admin[@]}" cmd /c "powershell -NoProfile -NonInteractive -Command \"Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory $1\"" >/dev/null 2>&1 || true
}

status=0
shots=(fresh quarantined broken lingering wedged)
if [ "${SZF_VM_FIREWALL:-}" = 1 ]; then
    was=$("${admin[@]}" cmd /c "powershell -NoProfile -NonInteractive -Command \"(Get-NetConnectionProfile | Select-Object -First 1).NetworkCategory\"" | tr -d '\r\n ')
    smoke --keep || status=$?
    installed="--installed $dir\\run\\installed"
    as_admin "netsh advfirewall firewall delete rule $rule"
    category Private
    smoke "$installed" --scenarios declined || status=$?
    as_admin "$add_rule"
    category Public
    smoke "$installed" --scenarios public || status=$?
    category Private
    smoke "$installed" --scenarios allowed || status=$?
    as_admin "$add_block"
    smoke "$installed" --scenarios blocked || status=$?
    as_admin "netsh advfirewall firewall delete rule $block"
    as_admin "netsh advfirewall firewall delete rule $rule"
    category "${was:-Public}"
    smoke "$installed" --uninstall || status=$?
    shots+=(declined public allowed blocked friends-list)
else
    smoke || status=$?
fi
if [ -n "${SZF_VM_KEEP:-}" ]; then
    mkdir -p "$SZF_VM_KEEP"
    for shot in "${shots[@]}"; do
        "${exec[@]}" cmd /c "certutil -f -encode $dir\\run\\$shot.png $dir\\$shot.b64 >nul && type $dir\\$shot.b64" |
            tr -d '\r' | grep -v -- '-----' | base64 -d >"$SZF_VM_KEEP/windows-smoke-$shot.png" 2>/dev/null || true
    done
fi
exit "$status"
