<#
.SYNOPSIS
  Check Phase 1's five done-criteria against a real ShenzhenPDF window.

.DESCRIPTION
  portable/docs/windows-port-plan.md states Phase 1's done-bar as: the window
  opens, the page is visible and correctly scaled to the client area, resizing
  repaints, DPI scaling is correct on a 2x display, closing exits 0.

  Every one of those five was UNOBSERVED until 2026-09-01. The port was built
  from a macOS host driving a Parallels VM over `prlctl exec`, which runs as
  `nt authority\system` with no interactive desktop, so nobody had ever seen the
  window (portable/docs/windows-port-handoff.md sec 0). This script is how the
  five stop being claims.

  HOW "CORRECTLY SCALED" IS DECIDED, AND WHY IT IS THE STRONG CHECK.
  The app can compose the same canvas without a window at all:
  `--render-window-png <pdf> <page> <w> <h> <out.png>` runs spdf_win_paint over
  a WIC target and prints the geometry it used. So this script captures the real
  window's CLIENT AREA and compares it to a headless render at exactly the
  client size, at zero tolerance. That is a much stronger statement than "the
  page looks about right": it says the windowed path and the offscreen path
  produce identical pixels, which is what makes every offscreen pixel test in
  this port actual evidence about the window. spdf_win_d2d.h's rule that
  spdf_win_paint must never require an HWND is what allows the comparison, and
  this is the first check that exercises it.

  THE HOST MUST BE DPI-AWARE. See screenshot-window.ps1's BecomeDpiAware
  comment: a DPI-unaware caller gets virtualised rects, and the resulting
  capture is a top-left crop that mimics "the app renders at the wrong scale"
  convincingly enough to send you debugging the app instead of the harness.

  Judged by exit code, never by grepping this output (a repo rule):
    0  all selected criteria passed
    1  at least one criterion FAILED
    2  at least one criterion was BLOCKED (a prerequisite was missing)
   64  bad usage
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Exe,
  [Parameter(Mandatory = $true)][string]$Pdf,
  [string]$OutDir = "",
  [switch]$Dark
)

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$shot = Join-Path $here 'screenshot-window.ps1'

if (-not (Test-Path -LiteralPath $Exe)) { Write-Output "BLOCKED no-exe $Exe"; exit 64 }
if (-not (Test-Path -LiteralPath $Pdf)) { Write-Output "BLOCKED no-pdf $Pdf"; exit 64 }
if (-not (Test-Path -LiteralPath $shot)) { Write-Output "BLOCKED no-screenshot-script $shot"; exit 64 }
if (-not $OutDir) { $OutDir = Join-Path $env:TEMP ("spdf-phase1-" + $PID) }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$script:results = @()
function Record([string]$name, [string]$status, [string]$detail) {
  $script:results += [pscustomobject]@{ Name = $name; Status = $status; Detail = $detail }
  Write-Output ("{0,-28} {1,-8} {2}" -f $name, $status, $detail)
}

# Parse the `key=value` lines screenshot-window.ps1 emits into a hashtable.
function Capture([string]$png, [int]$w, [int]$h, [string[]]$appArgs) {
  # -StateDir: A PRIVATE STATE DIRECTORY, so the run neither reads nor writes
  # the reader's own %APPDATA%\ShenzhenPDF. This is what used to make the check
  # sensitive to a saved session (windows-native-observations.md 4.5: "delete
  # session.yaml first or it remembers a page"): the window restored the page an
  # earlier click had left while the headless reference rendered page 0. With
  # its own directory the window has no session and no settings to restore, and
  # the reader's files are never touched by a test. A parameter of its own
  # rather than two more entries in -AppArgs, because a nested powershell -File
  # cannot be handed an array (the elements arrive joined into one string).
  $a = @('-Exe', $Exe, '-Pdf', $Pdf, '-Out', $png, '-SettleMs', '2500', '-StateDir', (Join-Path $OutDir 'state'))
  if ($w -gt 0) { $a += @('-Width', $w, '-Height', $h) }
  if ($appArgs -and $appArgs.Count) { $a += @('-AppArgs'); $a += (, $appArgs) }
  $raw = & powershell -NoProfile -ExecutionPolicy Bypass -File $shot @a 2>&1
  $rc = $LASTEXITCODE
  $map = @{}
  foreach ($line in $raw) {
    $t = [string]$line
    $i = $t.IndexOf('=')
    if ($i -gt 0) { $map[$t.Substring(0, $i)] = $t.Substring($i + 1) }
  }
  $map['__rc'] = $rc
  $map['__raw'] = ($raw -join "`n")
  return $map
}

# PIN THE THEME EXPLICITLY, both ways.
#
# A window follows the SYSTEM theme now (spdf_win_system_prefers_dark), so on a
# machine set to dark, launching with no flag gives a dark window while the
# headless reference below renders light -- and the comparison fails for a reason
# that is not a defect. --light exists precisely so a test can pin either.
$appArgs = if ($Dark) { @('--dark') } else { @('--light') }
$variant = if ($Dark) { 'dark' } else { 'light' }

# Snapshot of instances that are NOT ours, for the cleanup criterion at the end.
$exeName = [IO.Path]::GetFileNameWithoutExtension($Exe)
$preexisting = @(Get-Process -Name $exeName -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })

# ---- 1. the window opens ------------------------------------------------
$c1 = Capture (Join-Path $OutDir "01-open-$variant.png") 1120 800 $appArgs

# 68 from screenshot-window.ps1 means the desktop is not composited -- almost
# always a locked workstation. Every criterion below is about what the window
# LOOKS like, and none of them can be evaluated through a black capture, so this
# is BLOCKED for the whole run rather than five failures.
#
# It is worth being emphatic about, because the failure is a convincing liar: a
# locked session reproduces "the window paints nothing" from a clean build of a
# known-good commit, which is exactly how a phantom regression gets reported. The
# tell is that the offscreen compose of the same binary is perfect -- and that
# path needs no desktop, which is why it is unaffected.
if ($c1['__rc'] -eq 68) {
  Record 'window.opens'              'BLOCKED' ($c1['detail'])
  Record 'host.dpi_aware'            'BLOCKED' 'not reached'
  Record 'page.correctly_scaled'     'BLOCKED' 'the screen cannot be read while the session is not composited'
  Record 'dpi.scaling'               'BLOCKED' 'the screen cannot be read while the session is not composited'
  Record 'resize.repaints'           'BLOCKED' 'the screen cannot be read while the session is not composited'
  Record 'close.exits_zero'          'BLOCKED' 'not reached'
  Record 'cleanup.no_stray_process'  'BLOCKED' 'not reached'
  Write-Output ''
  Write-Output "phase1[$variant]: 0 passed, 0 failed, 7 blocked  -- unlock the workstation and re-run"
  exit 2
}

if ($c1['__rc'] -ne 0) {
  Record 'window.opens' 'FAIL' ("screenshot-window exited $($c1['__rc']): " + ($c1['__raw'] -replace "`n", ' | '))
} else {
  Record 'window.opens' 'PASS' ("class=$($c1['class']) title='$($c1['title'])' in $($c1['window_ms'])ms")
}

# The host being DPI-aware is a prerequisite for criteria 2 and 4, not a
# criterion. If it is false, say so loudly rather than reporting a scale bug.
if ($c1['host_dpi_aware'] -ne 'True') {
  Record 'host.dpi_aware' 'BLOCKED' 'the capture host is not per-monitor DPI aware; every rect below would be virtualised'
} else {
  Record 'host.dpi_aware' 'PASS' 'per-monitor-v2'
}

# ---- 2 + 4. correctly scaled, and DPI correct --------------------------
# One comparison settles both: if the windowed compose matched the headless one
# at a non-96 DPI, the scale is right AND the DPI plumbing is right.
function CompareClientToHeadless([hashtable]$cap, [string]$tag) {
  if ($cap['__rc'] -ne 0 -or -not $cap['client_offset']) { return @{ ok = $false; why = 'no capture' } }
  $parts = $cap['client_offset'].Split(',')
  $cw = [int]$parts[2]; $ch = [int]$parts[3]
  $headless = Join-Path $OutDir "headless-$tag.png"

  # The headless render MUST be given the window's own DPI scale.
  #
  # Page LAYOUT is dpi-independent here -- spdf_win_canvas's fit maths work in
  # device pixels and dpi_scale only reaches the LRU key and "actual size" -- so
  # for a while a 1.0 headless render matched a 1.5 window exactly and this
  # looked unnecessary. But CHROME is dpi-scaled on purpose: the page shade band
  # is 2*s / 3*s and the dark page border is s wide (spdf_win_d2d.cpp
  # draw_canvas_page). Comparing a 1.5 window against a 1.0 headless render
  # therefore reports a real difference in the border as if it were a defect,
  # and in LIGHT mode it silently does not, because the shade band falls outside
  # the visible page rect on a tall page. That asymmetry is what makes this easy
  # to get wrong: the flawed comparison passes in one theme and fails in the
  # other, which reads like a dark-theme bug.
  $scale = 1.0
  if ($cap['dpi']) { $scale = [double]$cap['dpi'] / 96.0 }
  # --chrome so the headless frame contains the same furniture the window does.
  # Without it the comparison is a chrome-less canvas against a full window and
  # reports ~57% of pixels differing, which is not a defect, just the wrong
  # question.
  $argv = @('--render-window-png', '--chrome', '--dpi', ("{0}" -f $scale))
  if ($Dark) { $argv += '--dark' }
  $argv += @($Pdf, '0', "$cw", "$ch", $headless)

  # Start-Process -Wait with a redirect, NOT `& $Exe`, and this is load-bearing.
  #
  # The app is linked /SUBSYSTEM:WINDOWS so that launching it does not open a
  # terminal window. PowerShell's native-command operator only WAITS for console
  # subsystem processes; for a GUI one it returns immediately, so `& $Exe` came
  # back with $geom empty and $LASTEXITCODE stale. The visible symptom was not an
  # error: the `chrome canvas=` line was simply never seen, this function
  # silently fell back to comparing the WHOLE CLIENT, and the tab strip -- which
  # legitimately differs, because the window restores a session and this
  # invocation has no tabs -- then failed three criteria at 16% of pixels.
  #
  # A harness must not depend on the subsystem of the thing it measures. Bash
  # pipes were unaffected, which is why run-tests-native.sh stayed green and only
  # this script broke -- a good reminder that "the suite passes" is not the same
  # as "everything passes".
  $stdout = Join-Path $OutDir "geom-$tag.txt"
  # Start-Process joins -ArgumentList with plain spaces and quotes nothing, so a
  # document path containing a space arrives as several arguments and the app
  # exits 64. Same trap as screenshot-window.ps1's launch.
  $argvQ = @()
  foreach ($t in $argv) {
    if ($t -match '\s' -and $t -notmatch '^".*"$') { $argvQ += ('"' + $t + '"') } else { $argvQ += $t }
  }
  $proc = Start-Process -FilePath $Exe -ArgumentList $argvQ -NoNewWindow -Wait -PassThru `
                        -RedirectStandardOutput $stdout
  $geomRc = $proc.ExitCode
  $geom = if (Test-Path -LiteralPath $stdout) { Get-Content -LiteralPath $stdout } else { @() }

  # The CANVAS region is what this criterion is about, and it is the region the
  # two paths can be expected to match in. The chrome cannot match: the window
  # restores a session and draws its real tabs, while this invocation opened one
  # document and has none, so the tab strip legitimately differs. Comparing the
  # canvas rect the app itself printed keeps the check exact and honest instead
  # of loosening a tolerance until the whole window passes.
  $canvasRect = $null
  foreach ($line in @($geom)) {
    if ([string]$line -match 'chrome canvas=(\d+),(\d+),(\d+),(\d+)') {
      $canvasRect = @([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], [int]$Matches[4])
      break
    }
  }
  if ($geomRc -ne 0) { return @{ ok = $false; why = "headless render exited $geomRc" } }
  if (-not $canvasRect) {
    # Never fall back silently: a whole-client comparison answers a different
    # question and fails for reasons that are not defects.
    return @{ ok = $false; why = 'the headless render printed no `chrome canvas=` line, so there is no canvas rect to compare' }
  }

  $crop = Join-Path $OutDir "client-$tag.png"
  $py = Join-Path $OutDir 'cmp_client.py'
  # TOLERANCE, AND WHY IT IS NOT ZERO. All measured on this machine 2026-09-01.
  #
  # The window's canvas region is BYTE-IDENTICAL to the headless compose at most
  # client sizes (1098x744, 900x700, 1300x900: 0 differing pixels). It diverges
  # where DrawBitmap has to resample the page bitmap hard, and the divergence
  # grows with the scale factor:
  #
  #     bitmap 1426 px into a 1425.6 px slot   ->  0.76% differ, maxdelta 2
  #     bitmap ~1000 px into a 208 px slot     ->  11.2% differ, maxdelta 43,
  #                                                MAE 0.60, 99.9th pct 27
  #
  # It is neither flakiness nor a repaint bug, and that was established rather
  # than assumed: two runs of the same WINDOW are byte-identical to each other,
  # two runs of the HEADLESS path are byte-identical to each other, and every
  # differing pixel lies inside the page bitmap -- the gutter above the page
  # matches exactly, 0 of 2704 px. The window paints into an HWND target created
  # with D2D1_RENDER_TARGET_TYPE_DEFAULT (GPU); spdf_win_render_scene_to_png
  # deliberately uses D2D1_RENDER_TARGET_TYPE_SOFTWARE. The two rasterisers'
  # bilinear filters simply do not agree bit-for-bit, and disagree more the
  # further the scale is from 1:1.
  #
  # This matters beyond this script: the port's zero-tolerance pixel cases all
  # run SOFTWARE on both sides (probe versus --render-window-png), so they are
  # unaffected. What they do NOT certify is the GPU window's resampled pixels.
  #
  # So the criterion is MAE plus a ceiling, not bit-equality. MAE <= 1.0 is two
  # orders of magnitude below anything a real fault produces: a wrong zoom,
  # origin, fit mode, theme colour or a stale texture moves the mean by tens.
  # The maxdelta ceiling of 64 still catches a single grossly wrong region.
  @'
import sys
from PIL import Image, ImageChops
win, off, head, out = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
MAX_DELTA = 64
MAX_MAE = 1.0
x, y, w, h = [int(v) for v in off.split(',')]
a = Image.open(win).convert('RGB').crop((x, y, x + w, y + h))
a.save(out)
b = Image.open(head).convert('RGB')
if a.size != b.size:
    print('SIZE_MISMATCH %s %s' % (a.size, b.size)); sys.exit(3)
# Optional 5th arg: crop both to "cx,cy,cw,ch" (the canvas rect the app printed).
if len(sys.argv) > 5 and sys.argv[5]:
    cx, cy, cw2, ch2 = [int(v) for v in sys.argv[5].split(',')]
    box = (cx, cy, cx + cw2, cy + ch2)
    a = a.crop(box)
    b = b.crop(box)
    a.save(out)
w, h = a.size
hist = ImageChops.difference(a, b).convert('L').histogram()
total = sum(hist)
n = sum(hist[1:])
worst = max(i for i, c in enumerate(hist) if c > 0)
mae = sum(i * c for i, c in enumerate(hist)) / float(total)
if n == 0:
    print('IDENTICAL %d px' % (w * h)); sys.exit(0)
print('DIFF %d of %d (%.3f%%) maxdelta %d mae %.3f' % (n, w * h, 100.0 * n / (w * h), worst, mae))
sys.exit(0 if (worst <= MAX_DELTA and mae <= MAX_MAE) else 1)
'@ | Out-File -FilePath $py -Encoding utf8
  $canvasArg = ''
  if ($canvasRect) { $canvasArg = ($canvasRect -join ',') }
  $out = & python $py $cap['png'] $cap['client_offset'] $headless $crop $canvasArg 2>&1
  $prc = $LASTEXITCODE
  $region = if ($canvasRect) { "canvas region $canvasArg" } else { 'whole client area' }
  return @{ ok = ($prc -eq 0); why = ($out -join ' '); region = $region
            geom = (($geom | Where-Object { $_ -match 'frame ' } | Select-Object -First 2) -join ' ') }
}

$cmp = CompareClientToHeadless $c1 "open-$variant"
if ($cmp.ok) {
  Record 'page.correctly_scaled' 'PASS' ("$($cmp.region) matches the headless compose; " + $cmp.geom)
} else {
  Record 'page.correctly_scaled' 'FAIL' ([string]$cmp.why)
}

$dpi = [int]($c1['dpi'])
if ($dpi -eq 96) {
  Record 'dpi.scaling' 'BLOCKED' 'this display is at 96 dpi (100%); a scaled display is needed to exercise DPI'
} elseif ($cmp.ok) {
  Record 'dpi.scaling' 'PASS' ("correct at $dpi dpi (" + [math]::Round($dpi / 96.0, 2) + "x): " + $cmp.region + " matches the headless compose")
} else {
  Record 'dpi.scaling' 'FAIL' ("mismatch at $dpi dpi")
}

# ---- 3. resizing repaints ---------------------------------------------
# Three sizes, each compared against its own headless render. A window that
# repainted the old content into a new size, or did not repaint at all, fails
# because the geometry it should have used is size-dependent.
$sizes = @(@(900, 700), @(1300, 900), @(700, 520))
$resizeOk = $true
$resizeDetail = @()
foreach ($sz in $sizes) {
  $tag = "resize-$($sz[0])x$($sz[1])-$variant"
  $c = Capture (Join-Path $OutDir "$tag.png") $sz[0] $sz[1] $appArgs
  if ($c['__rc'] -ne 0) { $resizeOk = $false; $resizeDetail += "$($sz[0])x$($sz[1]):capture-failed"; continue }
  $r = CompareClientToHeadless $c $tag
  if ($r.ok) { $resizeDetail += "$($sz[0])x$($sz[1]):ok" } else { $resizeOk = $false; $resizeDetail += "$($sz[0])x$($sz[1]):$($r.why)" }
}
if ($resizeOk) {
  Record 'resize.repaints' 'PASS' ($resizeDetail -join ' ')
} else {
  Record 'resize.repaints' 'FAIL' ($resizeDetail -join ' ')
}

# ---- 5. closing exits 0 ----------------------------------------------
# screenshot-window.ps1 closes via WM_CLOSE (CloseMainWindow) and reports the
# app's own exit code, so criterion 5 is already measured by every capture
# above; assert it explicitly rather than inferring it.
if ($c1['app_exitcode'] -eq '0') {
  Record 'close.exits_zero' 'PASS' 'WM_CLOSE then exit 0'
} else {
  Record 'close.exits_zero' 'FAIL' ("app exited " + $c1['app_exitcode'])
}

# Nothing WE started may be left running. This is the Windows form of agents.md's
# "do not launch the macOS app": the user is at this machine while agents work.
#
# Judged by PID against the snapshot taken before the first launch, NOT by
# process name. The user may -- and right now does -- have their own instance
# open while this runs, and a name-based count reported that as a leak: one
# false failure in both themes, on a run that had cleaned up perfectly. A
# harness must not fail because the person it serves is using the product.
$after = @(Get-Process -Name $exeName -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
$stray = @($after | Where-Object { $preexisting -notcontains $_ })
if ($stray.Count -eq 0) {
  $note = if ($preexisting.Count -gt 0) { " ($($preexisting.Count) pre-existing instance(s) left alone)" } else { '' }
  Record 'cleanup.no_stray_process' 'PASS' ("no process started by this run left behind" + $note)
} else {
  Record 'cleanup.no_stray_process' 'FAIL' ("started by this run and still running: pid " + ($stray -join ', '))
}

Write-Output ''
$pass = @($script:results | Where-Object { $_.Status -eq 'PASS' }).Count
$fail = @($script:results | Where-Object { $_.Status -eq 'FAIL' }).Count
$blocked = @($script:results | Where-Object { $_.Status -eq 'BLOCKED' }).Count
Write-Output ("phase1[$variant]: $pass passed, $fail failed, $blocked blocked  (artefacts in $OutDir)")

if ($fail -gt 0) { exit 1 }
if ($blocked -gt 0) { exit 2 }
exit 0
