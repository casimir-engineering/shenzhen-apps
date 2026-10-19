# launch-invariant.ps1 -- after a launch, is there exactly one window to use?
#
# THE INVARIANT (windows-native-observations.md, section 13): after any launch,
# every window of the app is enabled, not hung and REACHABLE -- at least 80 x 80
# of it inside a monitor's work area with its top edge, the tab strip that is
# its title bar, inside that work area -- and the window the session says the
# reader left focused is the topmost of the app's windows, so a sibling that
# was told to show behind never leaves the front window unshown. The foreground
# itself is reported, not judged: Windows grants it only to a process launched
# by the foreground process, which a harness under a shell under an editor is
# not (measure-launch.ps1 says the same).
#
# THE SCENARIOS are the launches that broke it, each from a session.yaml this
# script writes into a private --state-dir on the LIVE display geometry, so the
# frames are off this desktop's screen and not some other machine's:
#
#   behind   two saved windows, the second focused; the launch restores it and
#            spawns the first as a --behind sibling. Then a THIRD process is
#            started as a late --behind sibling of the first window, after the
#            focused window is up and has claimed the foreground. Before the
#            fix it came up at z-index 0 over the focused window, at its exact
#            frame; the focused window kept the keyboard underneath it.
#   sliver   one window whose saved frame leaves a 60 x 28 corner in the work
#            area, on its own attached display. Came back as that corner.
#   strip    one window whose saved frame puts its top edge 1100 px above the
#            display, leaving a strip at the top. Came back as that strip, with
#            nothing to drag.
#   gone     one window on a display that is not attached, wholly off screen.
#            (Always parked centred; here so the rule's third branch is run.)
#
# The parked scenarios also assert what the session remembers on exit: the
# frame the reader left, not where the window was parked (spdf_win_placement.h,
# rule 2).
#
# EXIT CODES, the whole verdict for run-tests-native.launch.sh:
#   0  every scenario holds
#   1  a scenario failed (the log says which assertion)
#   65 a launch produced no window inside the timeout
#   68 the workstation is locked -- BLOCKED, not a failure (see measure-launch.ps1)
#
# Never run bare: SPDF_WIN_SETUP_NO_PROMPT=1 is set here, and every launch gets
# a --state-dir under -OutDir, so the reader's own session is never read or
# written. Only processes running THIS exe with THIS state dir on their command
# line are closed at the end.
param(
  [Parameter(Mandatory = $true)][string]$Exe,
  [Parameter(Mandatory = $true)][string]$Pdf,
  [Parameter(Mandatory = $true)][string]$Pdf2,
  [string]$OutDir = '',
  [string[]]$Scenarios = @('behind', 'sliver', 'strip', 'gone'),
  [int]$WindowTimeoutMs = 15000
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Exe)) { Write-Output "error=no-exe $Exe"; exit 64 }
if (-not (Test-Path $Pdf)) { Write-Output "error=no-pdf $Pdf"; exit 64 }
if (-not (Test-Path $Pdf2)) { Write-Output "error=no-pdf2 $Pdf2"; exit 64 }
if ($OutDir -eq '') { $OutDir = Join-Path $env:TEMP 'spdf-launch-invariant' }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$env:SPDF_WIN_SETUP_NO_PROMPT = '1'

# LogonUI running always means locked; LockApp only when it is scheduled (a
# suspended LockApp lingers after an unlock). Same test as measure-launch.ps1.
$locked = (@(Get-Process LogonUI -ErrorAction SilentlyContinue).Count +
           @(Get-Process LockApp -ErrorAction SilentlyContinue |
             Where-Object { $_.Threads[0].WaitReason -ne 'Suspended' }).Count) -gt 0
if ($locked) { Write-Output "error=workstation-locked"; exit 68 }

if (-not ('SpdfInv' -as [type])) {
Add-Type -TypeDefinition @"
using System; using System.Text; using System.Runtime.InteropServices; using System.Collections.Generic;
public class SpdfInv {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct MONITORINFOEX { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string szDevice; }
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr p);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsHungAppWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
  [DllImport("user32.dll")] public static extern IntPtr GetTopWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
  [DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(POINT p, uint flags);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool GetMonitorInfoW(IntPtr mon, ref MONITORINFOEX mi);
  public static string Cls(IntPtr h) { var s = new StringBuilder(256); GetClassNameW(h, s, 256); return s.ToString(); }
  public static string Title(IntPtr h) { var s = new StringBuilder(512); GetWindowTextW(h, s, 512); return s.ToString(); }
  // Visible windows of the class, in z-order from the top, restricted to the given pids.
  public static List<IntPtr> AppWindowsTopDown(string cls, HashSet<uint> pids) {
    var l = new List<IntPtr>();
    for (IntPtr h = GetTopWindow(IntPtr.Zero); h != IntPtr.Zero; h = GetWindow(h, 2)) {
      if (!IsWindowVisible(h) || Cls(h) != cls) continue;
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (pids.Contains(pid)) l.Add(h);
    }
    return l;
  }
  public static MONITORINFOEX Primary() {
    var p = new POINT(); var mi = new MONITORINFOEX(); mi.cbSize = Marshal.SizeOf(mi);
    GetMonitorInfoW(MonitorFromPoint(p, 1), ref mi); return mi;
  }
  // "reachable": >= 80 x 80 inside the work area of the monitor the window is on, top edge inside it.
  public static string Reach(IntPtr h) {
    RECT r; GetWindowRect(h, out r);
    IntPtr mon = MonitorFromWindow(h, 0);
    if (mon == IntPtr.Zero) return "OFF every monitor rect=" + r.L + "," + r.T + "-" + r.R + "," + r.B;
    var mi = new MONITORINFOEX(); mi.cbSize = Marshal.SizeOf(mi); GetMonitorInfoW(mon, ref mi);
    int l = Math.Max(r.L, mi.rcWork.L), t = Math.Max(r.T, mi.rcWork.T), rr = Math.Min(r.R, mi.rcWork.R), b = Math.Min(r.B, mi.rcWork.B);
    int ow = rr > l ? rr - l : 0, oh = b > t ? b - t : 0;
    bool top = r.T >= mi.rcWork.T && r.T < mi.rcWork.B;
    return ((ow >= 80 && oh >= 80 && top) ? "reachable" : "UNREACHABLE") + " rect=" + r.L + "," + r.T + "-" + r.R + "," + r.B + " overlap=" + ow + "x" + oh + " topInWork=" + top + " " + mi.szDevice;
  }
}
"@
}
[void][SpdfInv]::SetProcessDPIAware()
$cls = 'ShenzhenPDFWindow'
$mi = [SpdfInv]::Primary()
$work = $mi.rcWork; $mon = $mi.rcMonitor
Write-Output ("primary " + $mi.szDevice + " monitor=" + $mon.L + "," + $mon.T + "-" + $mon.R + "," + $mon.B + " work=" + $work.L + "," + $work.T + "-" + $work.R + "," + $work.B)
$W = 1702; $H = 1211
if ($W -gt ($work.R - $work.L)) { $W = $work.R - $work.L - 100 }
if ($H -gt ($work.B - $work.T)) { $H = $work.B - $work.T - 100 }

function Y($s) { return '"' + $s.Replace('\', '\\') + '"' }
function WindowYaml($id, $frame, $display, $focusedAt, $path) {
  $o = @()
  if ($display) { $o += "  - display:"; $o += "      height: $($display[4])"; $o += "      name: $(Y $display[0])"; $o += "      width: $($display[3])"; $o += "      x: $($display[1])"; $o += "      y: $($display[2])"; $o += "    focusedAt: $focusedAt" }
  else { $o += "  - focusedAt: $focusedAt" }
  $o += "    frame:"; $o += "      height: $($frame[3])"; $o += "      width: $($frame[2])"; $o += "      x: $($frame[0])"; $o += "      y: $($frame[1])"
  $o += "    id: $(Y $id)"; $o += "    selectedTab: 0"; $o += "    tabs:"
  $o += "      - path: $(Y $path)"; $o += "        title: $(Y ([IO.Path]::GetFileName($path)))"; $o += "        preservesImageColors: true"; $o += "        viewMode: 1"
  return $o
}
function WriteSession($dir, $windows) {
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  Remove-Item (Join-Path $dir '*') -Force -ErrorAction SilentlyContinue
  $lines = @("version: 2", "windows:") + $windows
  [IO.File]::WriteAllText((Join-Path $dir 'session.yaml'), (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
}
$primaryDisplay = @($mi.szDevice, $mon.L, $mon.T, ($mon.R - $mon.L), ($mon.B - $mon.T))

# Processes running this exe whose command line names this state dir: the ones
# a scenario started (the launch and the siblings it spawned), and only those.
$exeName = [IO.Path]::GetFileName($Exe)
function MyProcs($dir) {
  $ids = New-Object 'System.Collections.Generic.HashSet[uint32]'
  Get-CimInstance Win32_Process -Filter "Name='$exeName'" -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.ExecutablePath -eq $Exe -and $_.CommandLine -and $_.CommandLine.Contains($dir)) { [void]$ids.Add([uint32]$_.ProcessId) }
  }
  return $ids
}
function WaitWindows($dir, $count) {
  $deadline = (Get-Date).AddMilliseconds($WindowTimeoutMs)
  do {
    $pids = MyProcs $dir
    $w = [SpdfInv]::AppWindowsTopDown($cls, $pids)
    if ($w.Count -ge $count) { Start-Sleep -Milliseconds 700; return [SpdfInv]::AppWindowsTopDown($cls, (MyProcs $dir)) }
    Start-Sleep -Milliseconds 100
  } while ((Get-Date) -lt $deadline)
  return $null
}
function CloseAll($dir) {
  $pids = MyProcs $dir
  foreach ($h in [SpdfInv]::AppWindowsTopDown($cls, $pids)) { [void][SpdfInv]::PostMessageW($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) }
  $deadline = (Get-Date).AddSeconds(5)
  do { Start-Sleep -Milliseconds 200; $left = MyProcs $dir } while ($left.Count -gt 0 -and (Get-Date) -lt $deadline)
  foreach ($id in $left) { Write-Output ("  pid $id did not exit on WM_CLOSE; terminating"); Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
}
function Describe($wins) {
  $fg = [SpdfInv]::GetForegroundWindow()
  $z = 0
  foreach ($h in $wins) {
    Write-Output ("  z$z hwnd=$h '" + [SpdfInv]::Title($h) + "' enabled=" + [SpdfInv]::IsWindowEnabled($h) + " hung=" + [SpdfInv]::IsHungAppWindow($h) + " foreground=" + ($h -eq $fg) + " " + [SpdfInv]::Reach($h))
    $z++
  }
}
# The assertions every scenario shares: prints each failure, returns how many.
# Through $script:failed rather than a return value, because a PowerShell
# function's return is its whole output stream and the messages would ride
# along with the count.
function Common($wins) {
  foreach ($h in $wins) {
    if (-not [SpdfInv]::IsWindowEnabled($h)) { Write-Output "  FAIL window $h is disabled"; $script:failed++ }
    if ([SpdfInv]::IsHungAppWindow($h)) { Write-Output "  FAIL window $h is hung"; $script:failed++ }
    if (-not ([SpdfInv]::Reach($h)).StartsWith('reachable')) { Write-Output "  FAIL window $h is not reachable"; $script:failed++ }
  }
}
function SavedFrame($dir) {
  $y = Get-Content (Join-Path $dir 'session.yaml') -Raw
  $m = [regex]::Match($y, 'frame:\s+height: (-?\d+)\s+width: (-?\d+)\s+x: (-?\d+)\s+y: (-?\d+)')
  if (-not $m.Success) { return $null }
  return @([int]$m.Groups[3].Value, [int]$m.Groups[4].Value, [int]$m.Groups[2].Value, [int]$m.Groups[1].Value)
}

$failed = 0
foreach ($s in $Scenarios) {
  $dir = Join-Path $OutDir ("state-" + $s)
  Write-Output "== scenario $s"
  $wins = $null
  switch ($s) {
    'behind' {
      $f1 = @(($work.L + 228), ($work.T + 228), $W, $H)
      WriteSession $dir ((WindowYaml 'win-old' $f1 $primaryDisplay 100.0 $Pdf) + (WindowYaml 'win-new' $f1 $primaryDisplay 200.0 $Pdf2))
      $p = Start-Process -FilePath $Exe -ArgumentList @('--state-dir', $dir) -PassThru
      $wins = WaitWindows $dir 2
      if (-not $wins) { Write-Output "error=no-window"; CloseAll $dir; exit 65 }
      Write-Output "  after the launch (focused window and its spawned sibling):"; Describe $wins
      $p3 = Start-Process -FilePath $Exe -ArgumentList @('--window', 'win-old', '--behind', '--state-dir', $dir) -PassThru
      $wins = WaitWindows $dir 3
      if (-not $wins) { Write-Output "error=no-window (late sibling)"; CloseAll $dir; exit 65 }
      Write-Output "  after the late --behind sibling:"; Describe $wins
      Common $wins
      $topTitle = [SpdfInv]::Title($wins[0])
      if (-not $topTitle.StartsWith([IO.Path]::GetFileName($Pdf2))) { Write-Output "  FAIL the topmost app window is '$topTitle', not the focused window's document"; $failed++ }
      $fg = [SpdfInv]::GetForegroundWindow()
      if ($wins.Contains($fg) -and $fg -ne $wins[0]) { Write-Output "  FAIL the foreground window is not the topmost app window"; $failed++ }
      if (-not $wins.Contains($fg)) { Write-Output "  (foreground not granted to the harness's launch -- reported, not judged)" }
    }
    'sliver' {
      $f = @(($work.R - 60), ($work.B - 28), $W, $H)
      WriteSession $dir (WindowYaml 'win-1' $f $primaryDisplay 100.0 $Pdf)
      $p = Start-Process -FilePath $Exe -ArgumentList @('--state-dir', $dir) -PassThru
      $wins = WaitWindows $dir 1
      if (-not $wins) { Write-Output "error=no-window"; CloseAll $dir; exit 65 }
      Describe $wins; Common $wins
    }
    'strip' {
      $f = @(($work.L + 228), ($work.T - 1100), $W, $H)
      WriteSession $dir (WindowYaml 'win-1' $f $primaryDisplay 100.0 $Pdf)
      $p = Start-Process -FilePath $Exe -ArgumentList @('--state-dir', $dir) -PassThru
      $wins = WaitWindows $dir 1
      if (-not $wins) { Write-Output "error=no-window"; CloseAll $dir; exit 65 }
      Describe $wins; Common $wins
    }
    'gone' {
      $f = @(($mon.R + 120), 100, $W, $H)
      WriteSession $dir (WindowYaml 'win-1' $f @('\\.\DISPLAY77', $mon.R, 0, 3440, 1440) 100.0 $Pdf)
      $p = Start-Process -FilePath $Exe -ArgumentList @('--state-dir', $dir) -PassThru
      $wins = WaitWindows $dir 1
      if (-not $wins) { Write-Output "error=no-window"; CloseAll $dir; exit 65 }
      Describe $wins; Common $wins
    }
    default { Write-Output "error=unknown-scenario $s"; exit 64 }
  }
  CloseAll $dir
  if ($s -eq 'sliver' -or $s -eq 'strip' -or $s -eq 'gone') {
    # Parked is not saved: the frame in the file is still the one the reader left.
    $saved = SavedFrame $dir
    if (-not $saved) { Write-Output "  FAIL no frame saved"; $failed++ }
    elseif ($saved[0] -ne $f[0] -or $saved[1] -ne $f[1]) { Write-Output ("  FAIL the parked position was saved: " + ($saved -join ',') + " for saved frame " + ($f -join ',')); $failed++ }
    else { Write-Output ("  remembered frame after exit: " + ($saved -join ',') + " (as saved, not as parked)") }
  }
}
if ($failed -gt 0) { Write-Output "verdict=FAIL ($failed assertion(s))"; exit 1 }
Write-Output "verdict=PASS"
exit 0
