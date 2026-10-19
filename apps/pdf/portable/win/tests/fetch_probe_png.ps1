# Bring a guest-rendered PNG back to the Mac as base64 on stdout, and REMOVE it
# from the guest once it has been read.
#
#   fetch_probe_png.ps1 [name] [-Keep]
#
# `name` is a bare file name inside C:\spdf-build, defaulting to probe-page.png
# so an invocation with no arguments still means what it always meant.
#
# WHY NOT JUST COPY IT TO THE SHARE. That is what this used to do, and it broke:
# sync-to-vm.sh runs rsync with --delete-excluded, so the staging tree's
# portable/win/build/ directory -- the obvious drop box -- is deleted on every
# sync, including the one vm-build.sh performs moments before the probe runs.
# Any transport that depends on the staging tree depends on another track's
# rsync flags, and will break again the next time those change.
#
# stdout has no such coupling. A page render is tens of kilobytes, base64 is
# about a third larger, and prlctl carries it fine.
#
# Emitted in fixed-width chunks rather than as one enormous line so nothing in
# the console/pipe path is tempted to wrap it at a width we did not choose; the
# Mac side strips all whitespace before decoding, so the chunking is invisible.
#
# WHY THE READ IS DESTRUCTIVE. This file is a transport buffer, not an artifact:
# the durable copy is the one on the Mac. Leaving it behind in the guest is what
# once let the harness grade a stale image and call it byte-identical -- a
# Windows render that failed exited 0, and this script cheerfully handed back the
# PREVIOUS run's pixels. probe-cases.sh now clears the path before each run and
# the probe clears its own output before writing, so this is the third of three
# independent guards; but it is the one that holds even for a caller that forgets
# the other two, because after a successful fetch there is simply nothing left to
# serve twice. A second fetch with no intervening render fails loudly, which is
# the correct answer to a question that has no fresh data behind it.
#
# Pass -Keep to leave the file in place when you need to inspect it by hand.
param(
    [string] $Name = 'probe-page.png',
    [switch] $Keep
)

$ErrorActionPreference = 'Stop'

if ($Name -match '[\\/:]') {
    [Console]::Error.WriteLine("fetch_probe_png: '$Name' must be a bare file name")
    exit 2
}

$src = Join-Path 'C:\spdf-build' $Name
if (-not (Test-Path $src)) {
    [Console]::Error.WriteLine("fetch_probe_png: missing $src")
    [Console]::Error.WriteLine("fetch_probe_png: nothing rendered it this run, or it was already fetched")
    exit 1
}
$bytes = [IO.File]::ReadAllBytes($src)
$b64 = [Convert]::ToBase64String($bytes)
for ($i = 0; $i -lt $b64.Length; $i += 76) {
    $n = [Math]::Min(76, $b64.Length - $i)
    [Console]::Out.WriteLine($b64.Substring($i, $n))
}
# Only after the bytes are safely on stdout.
if (-not $Keep) {
    Remove-Item -LiteralPath $src -Force
}
exit 0
