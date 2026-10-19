# Runs on Windows (tauri-vm-package.sh copies it into the VM): builds the NSIS installer and the MSI with Friends from
# the tree in -Dir, checks both carry the helper beside the app, the animal set and the helper's acknowledgements
# (helper-notices.mjs), then checks ADR 0015 § 14 with the NSIS installer: an older helper runs (as an app would
# have started it, in a temporary Friends home), the installer installs silently for this user with no restart, its
# hook asks that helper to hand over, and it leaves.
# The install goes to a folder under -Dir and is uninstalled again; the MSI is only unpacked (msiexec /a).
param(
    [Parameter(Mandatory)] [string] $Dir,
    [Parameter(Mandatory)] [string] $CliModules,
    [Parameter(Mandatory)] [string] $Version,
    [Parameter(Mandatory)] [string] $Build,
    [Parameter(Mandatory)] [string] $Node,
    [string] $Target = "aarch64-pc-windows-msvc"
)
# Native tools write progress to stderr, which Windows PowerShell would raise as errors: their exit codes decide.
$ErrorActionPreference = "Continue"
$cargo = Join-Path $env:USERPROFILE ".cargo\bin\cargo.exe"
$env:PATH = "$(Split-Path $cargo);$env:PATH"  # the Tauri CLI runs cargo by name
$env:SZFRIENDS_HELPER_VERSION = $Version
$env:SZFRIENDS_HELPER_BUILD = $Build
function Fail($why) { Write-Output "not ok $why"; exit 1 }

New-Item -ItemType Directory -Force "$Dir\3d\node_modules\@tauri-apps" | Out-Null
Copy-Item -Recurse "$CliModules\@tauri-apps\cli" "$Dir\3d\node_modules\@tauri-apps\"
Get-ChildItem "$CliModules\@tauri-apps" -Filter "cli-win32-*" |
    Copy-Item -Recurse -Destination "$Dir\3d\node_modules\@tauri-apps\"

Push-Location "$Dir\friends\core-rs"
$env:CARGO_TARGET_DIR = "$Dir\target-core"
& $cargo build --release --target $Target -p szfriends-helper --bin szfriends-helper --example restamp 2>&1 |
    ForEach-Object { "$_" } | Select-Object -Last 1
if ($LASTEXITCODE -ne 0) { Fail "the helper did not build" }
Pop-Location
$helper = "$Dir\target-core\$Target\release\szfriends-helper.exe"
New-Item -ItemType Directory -Force "$Dir\3d\src-tauri\friends\bin" | Out-Null
Copy-Item $helper "$Dir\3d\src-tauri\friends\bin\szfriends-helper-$Target.exe"
Copy-Item -Recurse "$Dir\friends\avatars\animals" "$Dir\3d\src-tauri\friends\animals"
Remove-Item -Recurse -Force "$Dir\3d\src-tauri\friends\animals\pdf" -ErrorAction SilentlyContinue
& $Node "$Dir\3d\scripts\friends\helper-notices.mjs" $helper "$Dir\friends" `
    "$Dir\3d\src-tauri\friends\Acknowledgements.txt"
if ($LASTEXITCODE -ne 0) { Fail "the helper's acknowledgements were not written" }
'{"build": {"beforeBuildCommand": ""}}' | Set-Content -Encoding ascii "$Dir\no-frontend-build.json"

Push-Location "$Dir\3d"
$env:CARGO_TARGET_DIR = "$Dir\target-app"
$plugin = ("$Dir\friends\tauri" -replace '\\', '/')
& $Node node_modules\@tauri-apps\cli\tauri.js build --target $Target --features friends `
    --config src-tauri\friends\tauri.conf.json --config "$Dir\no-frontend-build.json" --bundles nsis,msi -- `
    --config "patch.szfriends-pinned.tauri-plugin-szfriends.path='$plugin'" 2>&1 | ForEach-Object { "$_" } |
    Select-Object -Last 6
if ($LASTEXITCODE -ne 0) { Fail "the installers did not build" }
Pop-Location
$bundle = "$Dir\target-app\$Target\release\bundle"
$setup = (Get-ChildItem "$bundle\nsis\*.exe" | Select-Object -First 1).FullName
$msi = (Get-ChildItem "$bundle\msi\*.msi" | Select-Object -First 1).FullName
if (-not $setup -or -not $msi) { Fail "the bundles were not built" }

# The MSI, unpacked without installing.
$unpacked = "$Dir\msi-unpacked"
Start-Process msiexec.exe -Wait -ArgumentList "/a", "`"$msi`"", "/qn", "TARGETDIR=`"$unpacked`"" | Out-Null
$inMsi = Get-ChildItem -Recurse $unpacked
if (($inMsi | Where-Object Name -eq "szfriends-helper.exe") -and
    ($inMsi | Where-Object { $_.FullName -like "*friends\animals\manifest.json" }) -and
    ($inMsi | Where-Object { $_.FullName -like "*friends\Acknowledgements.txt" })) {
    Write-Output "ok MSI carries the helper, the animal set and the acknowledgements"
} else { Fail "the MSI lacks the helper, the animal set or the acknowledgements" }

# An older helper runs in a test home, as an app would have started it from its per-user copy.
$friendsHome = "$Dir\home"
New-Item -ItemType Directory -Force $friendsHome | Out-Null
$older = "$Dir\older\szfriends-helper.exe"
New-Item -ItemType Directory -Force (Split-Path $older) | Out-Null
& "$Dir\target-core\$Target\release\examples\restamp.exe" $helper $older ([int64]$Build - 1)
if ($LASTEXITCODE -ne 0) { Fail "no older helper" }
$env:SZFRIENDS_STATE_DIR = $friendsHome
$running = Start-Process $older -PassThru -WindowStyle Hidden
for ($i = 0; $i -lt 80 -and -not (Test-Path "$friendsHome\ipc\helper.pipe"); $i++) { Start-Sleep -Milliseconds 250 }
if (-not (Test-Path "$friendsHome\ipc\helper.pipe")) { Fail "the older helper did not start" }
Write-Output "ok an older helper runs (build $([int64]$Build - 1), process $($running.Id))"

# The installer, silently, for this user, into a folder of the test's own; its hook runs the new helper's --handover.
$installed = "$Dir\installed"
$install = Start-Process $setup -Wait -PassThru -ArgumentList "/S", "/D=$installed"
if ($install.ExitCode -ne 0) { Fail "the installer exited with $($install.ExitCode)" }
$app = Get-ChildItem "$installed" -Filter *.exe |
    Where-Object { $_.Name -notin "szfriends-helper.exe", "uninstall.exe" }
if (-not (Test-Path "$installed\szfriends-helper.exe") -or -not $app) {
    Fail "the installer did not put the app and its helper in place"
}
$animals = Get-ChildItem -Recurse "$installed" -Filter manifest.json |
    Where-Object { $_.FullName -like "*friends\animals*" }
if (-not $animals) {
    Fail "the installed app lacks the animal set"
}
if (-not (Get-ChildItem -Recurse "$installed" -Filter Acknowledgements.txt |
        Where-Object { $_.FullName -like "*friends\Acknowledgements.txt" })) {
    Fail "the installed app lacks the acknowledgements"
}
Write-Output "ok the installer installs silently over a running helper, without a restart"
$left = $false
for ($i = 0; $i -lt 60; $i++) {
    if (-not (Get-Process -Id $running.Id -ErrorAction SilentlyContinue)) { $left = $true; break }
    Start-Sleep -Milliseconds 250
}
$handed = Select-String -Path "$friendsHome\helper.log" -Pattern "handing over to build $Build" -Quiet
if (-not $left -or -not $handed) { Fail "the older helper did not hand over to build $Build" }
Write-Output "ok the installer's hook asks the older helper to hand over to build $Build, and it leaves"

$uninstaller = "$installed\uninstall.exe"
if (Test-Path $uninstaller) {
    Start-Process $uninstaller -Wait -ArgumentList "/S" | Out-Null
    for ($i = 0; $i -lt 40 -and (Test-Path $app[0].FullName); $i++) { Start-Sleep -Milliseconds 250 }
    Write-Output "ok uninstalled again"
}
Remove-Item Env:\SZFRIENDS_STATE_DIR
