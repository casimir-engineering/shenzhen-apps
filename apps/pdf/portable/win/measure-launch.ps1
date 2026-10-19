<#
.SYNOPSIS
  Time ShenzhenPDF's launch: process creation -> window visible -> first page
  pixels -> settled, N runs, median, from OUTSIDE the process and from the
  process's own SPDF-LAUNCH timeline.

.DESCRIPTION
  The number a reader feels is launch -> first PAGE pixels, and until this
  script nothing on Windows measured it. Two independent clocks are used and
  both are reported, because each has failed on its own in this repo:

    EXTERNAL. The host polls (never Start-Process -Wait: that cmdlet adds ~1 s
    of pipe teardown to every run -- portable/docs/windows-native-observations.md
    sec 4.8) for a visible top-level window, then samples PrintWindow captures
    of the CLIENT area until one is no longer blank. Every external timestamp
    is expressed relative to the process's own kernel creation time
    ($proc.StartTime), so it shares an origin with the in-process marks.

    IN-PROCESS. SPDF_WIN_LAUNCH_PROFILE=<file> makes the app append one
    `SPDF-LAUNCH <ms> <phase>` line per phase (portable/win/src/
    spdf_win_launch_profile.h), from process creation, through QPC. Read back
    per run; the first occurrence of each phase is reported.

  WHY THE EARLIER SAMPLER SAW BLANK FRAMES. Three things, all needed at once:
  PrintWindow must be given PW_RENDERFULLCONTENT (0x2) or a Direct2D client
  area comes back black; the host must be per-monitor DPI aware or every rect
  it reads is virtualised and the capture is a crop (sec 5.1); and until the
  first WM_PAINT has completed the client area IS blank -- the window is
  visible before it has content, which is precisely the interval this script
  exists to measure. A blank frame is data, not a failure: the first non-blank
  one is "first page pixels".

  SESSION SAFETY. %APPDATA%\ShenzhenPDF\session.yaml is the user's LIVE state
  and the app rewrites it on exit. This script backs it up once, removes it
  before every run (or writes the -RestoreTabs fixture), and after each run
  puts the backup back -- but only when the file on disk is the one the
  launched app wrote (its window id carries the app's pid, or the fixture id),
  so a save by the user's own instance is never overwritten.

  COLD. -Cold copies the exe to a fresh name under -OutDir before every run,
  written unbuffered/write-through so the copy is not left in the file cache,
  which defeats both the SmartScreen/Defender first-run cache and the
  standby-list warmth of the image. It approximates a first launch after a
  build; it cannot evict the system DLLs (d2d1, dwrite, the GPU driver), which
  every desktop already has resident.

.PARAMETER Exe          ShenzhenPDF.exe to measure.
.PARAMETER Pdf          Document to open. Empty = bare launch (session restore).
.PARAMETER AppArgs      Extra app arguments (--dark, --light, --page N).
.PARAMETER Runs         How many launches; the median is what matters.
.PARAMETER Cold         Fresh, uncached copy of the exe per run.
.PARAMETER RestoreTabs  Write a session.yaml with this many tabs of -Pdf (copied
                        N times so the paths differ) and launch bare.
.PARAMETER OutDir       Where per-run marker files, the JSON summary and cold
                        copies go. Default: %TEMP%\spdf-launch.
.PARAMETER Label        Free text carried into the JSON and the table header.
.PARAMETER SettleMs     How long after first pixels to let the post-paint burst
                        run before reading CPU/IO counters and closing.
.PARAMETER WindowBudgetMs / FirstPageBudgetMs
                        When > 0, the median must be under it or the script
                        exits 1. This is how the suite's launch.budget case
                        uses it.
.PARAMETER Json         Print the summary as JSON instead of a table.

.OUTPUTS
  0  measured (and within budget when one was given)
  1  a budget was exceeded
  64 bad usage / missing input
  65 the process exited before a window appeared
  66 no window within the timeout
  68 the workstation is locked / not composited -- BLOCKED, not a failure
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Exe,
  [string]$Pdf = '',
  [string[]]$AppArgs = @(),
  [int]$Runs = 7,
  [switch]$Cold,
  [int]$RestoreTabs = 0,
  [string]$OutDir = '',
  [string]$Label = '',
  [int]$SettleMs = 700,
  [int]$TimeoutMs = 15000,
  [int]$SamplerTimeoutMs = 2500,
  [int]$WindowBudgetMs = 0,
  [int]$FirstPageBudgetMs = 0,
  [switch]$Json
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Exe)) { Write-Output "error=no-exe path=$Exe"; exit 64 }
if ($Pdf -ne '' -and -not (Test-Path -LiteralPath $Pdf)) { Write-Output "error=no-pdf path=$Pdf"; exit 64 }
if ($RestoreTabs -gt 0 -and $Pdf -eq '') { Write-Output "error=RestoreTabs-needs-Pdf"; exit 64 }
if ($Runs -lt 1) { $Runs = 1 }
if ($OutDir -eq '') { $OutDir = Join-Path $env:TEMP 'spdf-launch' }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

# A locked workstation is not composited: PrintWindow returns a flat client for
# a Direct2D window and the "first pixels" sampler can never fire. LockApp.exe is
# the Windows 11 lock screen and is the indicator that was actually present when
# this was hit; LogonUI is the older one screenshot-window.ps1 checks.
#
# The IN-PROCESS timeline does not need a composited desktop (EndDraw still
# returns), so without a budget the run proceeds and only the sampler is
# reported BLOCKED. With a budget, the answer would describe a desktop nobody
# is looking at, so the whole run is BLOCKED (68), as the suite expects.
# A SUSPENDED LockApp lingers long after an unlock, so its mere presence is a
# false positive -- it blocked launch.budget for a whole run on a live,
# composited desktop (2026-09-05), whose screenshots prove it was awake.
# LogonUI running always means locked; LockApp only when it is scheduled.
. (Join-Path $PSScriptRoot 'desktop-available.ps1')
# Only the states that stop a window being SHOWN: this case measures painting,
# not input, and it stays valid while the screen saver owns the input desktop.
$unavailable = Spdf-DesktopNotComposited
$locked = [bool]$unavailable
if ($locked -and ($WindowBudgetMs -gt 0 -or $FirstPageBudgetMs -gt 0)) {
  Write-Output ("error=desktop-unavailable detail=" + $unavailable)
  exit 68
}
$samplerState = if ($locked) { 'BLOCKED: ' + $unavailable } else { 'active' }

if (-not ('SpdfLaunch' -as [type])) {
  # /unsafe for the LockBits pointer walk in SampleClientColors; the references
  # must then travel in the same CompilerParameters (Add-Type refuses both
  # -ReferencedAssemblies and -CompilerParameters at once).
  $cp = New-Object CodeDom.Compiler.CompilerParameters
  $cp.CompilerOptions = '/unsafe'
  [void]$cp.ReferencedAssemblies.Add('System.dll')
  [void]$cp.ReferencedAssemblies.Add('System.Core.dll')
  [void]$cp.ReferencedAssemblies.Add('System.Drawing.dll')
  Add-Type -Language CSharp -CompilerParameters $cp -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class SpdfLaunch {
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr GetDesktopWindow();
    [DllImport("kernel32.dll")] public static extern void GetSystemTimePreciseAsFileTime(out long ft);
    [DllImport("kernel32.dll")] public static extern bool GetProcessIoCounters(IntPtr p, out IO_COUNTERS c);
    [DllImport("psapi.dll")] public static extern bool GetProcessMemoryInfo(IntPtr p, out PMC c, uint cb);
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct IO_COUNTERS {
        public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes; }
    [StructLayout(LayoutKind.Sequential)] public struct PMC {
        public uint cb, PageFaultCount; public UIntPtr PeakWS, WS, QPeakPaged, QPaged, QPeakNonPaged, QNonPaged, PagefileUsage, PeakPagefileUsage; }

    public static bool BecomeDpiAware() {
        try { return SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch (EntryPointNotFoundException) { return false; }
    }

    // Wall clock with QPC precision, as a FILETIME, so it can be subtracted
    // from the process's kernel creation time.
    public static long NowFileTime() { long ft; GetSystemTimePreciseAsFileTime(out ft); return ft; }

    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool IsHungAppWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetTopWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);

    // THE HEALTH OF A LAUNCHED WINDOW, as a person experiences it. Two defects
    // shipped with every test green because nothing asked these questions
    // (windows-native-observations.md section 11): a window that came up
    // BEHIND the window that launched it, and a hidden helper window whose
    // thread never pumped -- a hung window to the whole desktop. Both are
    // invisible to a headless compose and to a PrintWindow capture.
    //
    // ZIndex: position among visible top-level windows larger than 200 px
    // (the same band the shell's Alt+Tab list draws from), 0 = in front.
    public static int ZIndex(IntPtr target) {
        IntPtr h = GetTopWindow(IntPtr.Zero); int i = 0;
        while (h != IntPtr.Zero) {
            if (IsWindowVisible(h)) {
                RECT r;
                if (GetWindowRect(h, out r) && (r.Right - r.Left) > 200 && (r.Bottom - r.Top) > 200) {
                    if (h == target) return i;
                    i++;
                }
            }
            h = GetWindow(h, 2 /* GW_HWNDNEXT */);
        }
        return -1;
    }

    // Every window of the process, visible or not, whose thread has stopped
    // answering -- IsHungAppWindow is the same test the shell uses before it
    // ghosts a window, and it is true of an invisible window just the same.
    public static int HungWindows(uint pid) {
        int hung = 0;
        EnumWindows(delegate(IntPtr h, IntPtr p) {
            uint owner; GetWindowThreadProcessId(h, out owner);
            if (owner == pid && IsHungAppWindow(h)) hung++;
            return true;
        }, IntPtr.Zero);
        return hung;
    }

    public static IntPtr FirstVisibleWindow(uint pid) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr p) {
            if (!IsWindowVisible(h)) return true;
            uint owner; GetWindowThreadProcessId(h, out owner);
            if (owner != pid) return true;
            RECT r;
            if (GetWindowRect(h, out r) && (r.Right - r.Left) > 32 && (r.Bottom - r.Top) > 32) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }

    // PW_RENDERFULLCONTENT alone, on the WHOLE window, then crop to the client
    // rectangle. Measured on this machine: PW_CLIENTONLY | PW_RENDERFULLCONTENT
    // returns a blank client for this window on every sample, forever -- which
    // is exactly the "blank frames" the first ad-hoc sampler reported. The
    // whole-window form is the one screenshot-window.ps1 has always used.
    const uint PW_RENDERFULLCONTENT = 2;

    // Reused across samples so the sampler allocates nothing per frame.
    static Bitmap sampleBmp;

    // Distinct colours on a 48x48 grid of the client area, or -1 when the
    // capture failed. A blank (never painted, or non-composited) client is one
    // or two colours; a painted ShenzhenPDF window is dozens.
    public static int SampleClientColors(IntPtr hwnd) {
        RECT wr, cr; POINT o = new POINT();
        if (!GetWindowRect(hwnd, out wr) || !GetClientRect(hwnd, out cr) || !ClientToScreen(hwnd, ref o)) return -1;
        int w = wr.Right - wr.Left, h = wr.Bottom - wr.Top;
        if (w <= 0 || h <= 0) return -1;
        if (sampleBmp == null || sampleBmp.Width != w || sampleBmp.Height != h) {
            if (sampleBmp != null) sampleBmp.Dispose();
            sampleBmp = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        }
        using (Graphics g = Graphics.FromImage(sampleBmp)) {
            IntPtr dc = g.GetHdc();
            bool ok;
            try { ok = PrintWindow(hwnd, dc, PW_RENDERFULLCONTENT); } finally { g.ReleaseHdc(dc); }
            if (!ok) return -1;
        }
        int cx = o.X - wr.Left, cy = o.Y - wr.Top, cw = cr.Right - cr.Left, ch = cr.Bottom - cr.Top;
        if (cx < 0) cx = 0; if (cy < 0) cy = 0;
        if (cx + cw > w) cw = w - cx; if (cy + ch > h) ch = h - cy;
        if (cw <= 0 || ch <= 0) return -1;
        var seen = new System.Collections.Generic.HashSet<int>();
        BitmapData d = sampleBmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try {
            int stepX = Math.Max(1, cw / 48), stepY = Math.Max(1, ch / 48);
            unsafe {
                byte* base_ = (byte*)d.Scan0;
                for (int y = cy; y < cy + ch; y += stepY) {
                    int* row = (int*)(base_ + y * d.Stride);
                    for (int x = cx; x < cx + cw; x += stepX) seen.Add(row[x] | unchecked((int)0xFF000000));
                }
            }
        } finally { sampleBmp.UnlockBits(d); }
        return seen.Count;
    }

    public static void SaveSample(string path) { if (sampleBmp != null) sampleBmp.Save(path, ImageFormat.Png); }

    public static void Close(IntPtr hwnd) { PostMessageW(hwnd, 0x0010 /* WM_CLOSE */, IntPtr.Zero, IntPtr.Zero); }

    public static string Counters(IntPtr process) {
        IO_COUNTERS io; PMC pmc;
        GetProcessIoCounters(process, out io);
        GetProcessMemoryInfo(process, out pmc, (uint)Marshal.SizeOf(typeof(PMC)));
        return io.ReadOps + "," + io.ReadBytes + "," + pmc.PageFaultCount + "," + (ulong)pmc.WS + "," + (ulong)pmc.PeakWS;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool WriteFile(IntPtr h, byte[] buf, uint n, out uint written, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr h);

    // An unbuffered, write-through copy: the destination's pages are not left
    // in the standby list, so the next open of it reads from disk. Written in
    // sector-aligned chunks as FILE_FLAG_NO_BUFFERING demands, then the exact
    // length is restored with a plain (buffered) truncate of the padding.
    public static void ColdCopy(string src, string dst) {
        const uint GENERIC_WRITE = 0x40000000, CREATE_ALWAYS = 2;
        const uint FILE_FLAG_NO_BUFFERING = 0x20000000, FILE_FLAG_WRITE_THROUGH = 0x80000000;
        byte[] data = System.IO.File.ReadAllBytes(src);
        int aligned = (data.Length + 4095) & ~4095;
        byte[] padded = new byte[aligned];
        Buffer.BlockCopy(data, 0, padded, 0, data.Length);
        IntPtr h = CreateFileW(dst, GENERIC_WRITE, 0, IntPtr.Zero, CREATE_ALWAYS, FILE_FLAG_NO_BUFFERING | FILE_FLAG_WRITE_THROUGH, IntPtr.Zero);
        if (h == new IntPtr(-1)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "CreateFileW " + dst);
        try {
            uint written;
            if (!WriteFile(h, padded, (uint)aligned, out written, IntPtr.Zero) || written != aligned)
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "WriteFile " + dst);
        } finally { CloseHandle(h); }
        if (!System.IO.File.Exists(dst))
            throw new System.IO.IOException("ColdCopy: " + dst + " is missing right after an unbuffered write of " + aligned + " bytes");
        using (var fs = new System.IO.FileStream(dst, System.IO.FileMode.Open, System.IO.FileAccess.Write, System.IO.FileShare.None)) {
            fs.SetLength(data.Length);
        }
    }
}
'@
}

$dpiAware = [SpdfLaunch]::BecomeDpiAware()

# --- the session file ------------------------------------------------------

$sessionDir = Join-Path $env:APPDATA 'ShenzhenPDF'
$sessionFile = Join-Path $sessionDir 'session.yaml'
$backup = $null
if (Test-Path -LiteralPath $sessionFile) {
  $backup = Join-Path $OutDir ('session.yaml.backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $PID)
  Copy-Item -LiteralPath $sessionFile -Destination $backup
}
$fixtureId = 'win-launch-harness-' + $PID

function Write-RestoreSession([string]$pdf, [int]$tabs) {
  $tabDir = Join-Path $OutDir 'restore-tabs'
  New-Item -ItemType Directory -Path $tabDir -Force | Out-Null
  $sb = New-Object Text.StringBuilder
  [void]$sb.Append("# ShenzhenPDF session (launch harness fixture)`nversion: 2`nwindows:`n  - id: `"$fixtureId`"`n    selectedTab: $($tabs - 1)`n    tabs:`n")
  for ($t = 1; $t -le $tabs; $t++) {
    $copy = Join-Path $tabDir ("tab-$t" + [IO.Path]::GetExtension($pdf))
    if (-not (Test-Path -LiteralPath $copy)) { Copy-Item -LiteralPath $pdf -Destination $copy }
    $esc = $copy.Replace('\', '\\')
    [void]$sb.Append("      - path: `"$esc`"`n        title: `"tab-$t`"`n        page: 0`n        zoom: 1.0000`n        customZoom: 1.0000`n        fitMode: 2`n        scrollX: 0.0000`n        scrollY: 0.0000`n        hasScrollOrigin: false`n        viewMode: 1`n")
  }
  New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
  [IO.File]::WriteAllText($sessionFile, $sb.ToString(), (New-Object Text.UTF8Encoding $false))
}

# Put the user's file back only if what is on disk was written by OUR launch.
function Restore-Session([int]$appPid) {
  if (-not (Test-Path -LiteralPath $sessionFile)) {
    if ($backup) { Copy-Item -LiteralPath $backup -Destination $sessionFile }
    return
  }
  $text = [IO.File]::ReadAllText($sessionFile)
  # Ours if it carries the launched app's window id, the fixture id, or is the
  # EMPTY session a bare launch writes on exit (a window with no tabs is
  # removed from the file, so nothing in it names a pid). The file was deleted
  # before this run, so anything else present was written by the user's own
  # instance in the meantime and is left alone.
  $ours = $text.Contains("win-$appPid-") -or $text.Contains($fixtureId) -or ($text -match 'windows:\s*\[\s*\]')
  if (-not $ours) { return }
  if ($backup) { Copy-Item -LiteralPath $backup -Destination $sessionFile -Force }
  else { Remove-Item -LiteralPath $sessionFile -Force }
}

# --- one run ----------------------------------------------------------------

function Median($values) {
  $v = @($values | Where-Object { $_ -ne $null } | Sort-Object)
  if ($v.Count -eq 0) { return $null }
  if ($v.Count % 2 -eq 1) { return $v[[int](($v.Count - 1) / 2)] }
  return ($v[$v.Count / 2 - 1] + $v[$v.Count / 2]) / 2
}

function Invoke-Run([int]$i) {
  $r = @{ run = $i; exit_code = $null; error = $null; marks = @{}; samples = @() }
  $launchExe = $Exe
  if ($Cold) {
    $coldDir = Join-Path $OutDir 'cold'
    New-Item -ItemType Directory -Path $coldDir -Force | Out-Null
    $launchExe = Join-Path $coldDir ("ShenzhenPDF-cold-$i-" + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.exe')
    [SpdfLaunch]::ColdCopy($Exe, $launchExe)
  }
  $markFile = Join-Path $OutDir ("run-$i.launch.txt")
  if (Test-Path -LiteralPath $markFile) { Remove-Item -LiteralPath $markFile -Force }

  if (Test-Path -LiteralPath $sessionFile) { Remove-Item -LiteralPath $sessionFile -Force }
  if ($RestoreTabs -gt 0) { Write-RestoreSession $Pdf $RestoreTabs }

  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $launchExe
  $psi.UseShellExecute = $false
  $psi.EnvironmentVariables['SPDF_WIN_LAUNCH_PROFILE'] = $markFile
  # NO FIRST-RUN DIALOG. This script launches against the REAL %APPDATA% on
  # purpose (measuring session restore is the point), so it cannot use
  # --state-dir to suppress the "Install, or just run it?" question the way
  # screenshot-window.ps1 does -- and that question is MODAL and appears before
  # the window, so the poll below would wait for a window that never comes.
  # SPDF_WIN_LAUNCH_PROFILE above already suppresses it (a timed launch must not
  # be timed with a human in it); this is the explicit form, so a reader sees
  # the intent rather than a side effect. spdf_win_setup.h documents both.
  $psi.EnvironmentVariables['SPDF_WIN_SETUP_NO_PROMPT'] = '1'
  $args = @()
  foreach ($a in $AppArgs) { if ($a -ne '') { $args += $a } }
  if ($Pdf -ne '' -and $RestoreTabs -le 0) { $args += $Pdf }
  $psi.Arguments = ($args | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '

  $hostBefore = [SpdfLaunch]::NowFileTime()
  $proc = [Diagnostics.Process]::Start($psi)
  $hostAfterStart = [SpdfLaunch]::NowFileTime()
  $hwnd = [IntPtr]::Zero
  $created = $null
  try {
    # The kernel's creation timestamp is the origin for everything below.
    $created = $proc.StartTime.ToFileTimeUtc()
    $r.spawn_ms = [math]::Round(($hostAfterStart - $created) / 10000.0, 1)
    $r.host_before_create_ms = [math]::Round(($created - $hostBefore) / 10000.0, 1)

    $deadline = $created + [long]$TimeoutMs * 10000
    while ([SpdfLaunch]::NowFileTime() -lt $deadline) {
      if ($proc.HasExited) { $r.error = 'exited-before-window'; $r.exit_code = $proc.ExitCode; return $r }
      $h = [SpdfLaunch]::FirstVisibleWindow([uint32]$proc.Id)
      if ($h -ne [IntPtr]::Zero) { $hwnd = $h; break }
      [Threading.Thread]::Sleep(0)
    }
    if ($hwnd -eq [IntPtr]::Zero) { $r.error = 'no-window'; return $r }
    $r.window_ms = [math]::Round(([SpdfLaunch]::NowFileTime() - $created) / 10000.0, 1)

    # Sample the client area until it is no longer blank -- for at most
    # SamplerTimeoutMs after the window appeared: a first paint later than that
    # is not a launch, and a desktop that is not composited never paints.
    $firstPixels = $null
    $lastColors = -1
    $sampleUntil = [SpdfLaunch]::NowFileTime() + [long]$SamplerTimeoutMs * 10000
    while (-not $locked -and [SpdfLaunch]::NowFileTime() -lt $sampleUntil) {
      $t = [SpdfLaunch]::NowFileTime()
      $colors = [SpdfLaunch]::SampleClientColors($hwnd)
      $t2 = [SpdfLaunch]::NowFileTime()
      $ms = [math]::Round(($t - $created) / 10000.0, 1)
      $r.samples += @{ at_ms = $ms; colors = $colors; cost_ms = [math]::Round(($t2 - $t) / 10000.0, 1) }
      $lastColors = $colors
      if ($colors -gt 3) { $firstPixels = [math]::Round(($t2 - $created) / 10000.0, 1); break }
      if ($proc.HasExited) { $r.error = 'exited-before-paint'; $r.exit_code = $proc.ExitCode; return $r }
    }
    $r.first_pixels_ms = $firstPixels
    $r.first_sample_colors = $lastColors
    if ($i -eq 1 -and -not $locked) { [SpdfLaunch]::SaveSample((Join-Path $OutDir 'first-frame.png')) }

    $proc.Refresh()
    $r.cpu_at_pixels_ms = [math]::Round($proc.TotalProcessorTime.TotalMilliseconds, 1)
    $r.counters_at_pixels = [SpdfLaunch]::Counters($proc.Handle)
    Start-Sleep -Milliseconds $SettleMs
    $proc.Refresh()
    $r.cpu_settled_ms = [math]::Round($proc.TotalProcessorTime.TotalMilliseconds, 1)
    $r.counters_settled = [SpdfLaunch]::Counters($proc.Handle)
    $r.threads_settled = $proc.Threads.Count
    # Health, taken while the window is up and idle (see SpdfLaunch.ZIndex).
    $r.foreground = ([SpdfLaunch]::GetForegroundWindow() -eq $hwnd)
    $r.zindex = [SpdfLaunch]::ZIndex($hwnd)
    $r.hung_windows = [SpdfLaunch]::HungWindows([uint32]$proc.Id)

    $tClose = [SpdfLaunch]::NowFileTime()
    [SpdfLaunch]::Close($hwnd)
    if (-not $proc.WaitForExit(5000)) { $proc.Kill(); $proc.WaitForExit(2000) | Out-Null; $r.error = 'killed' }
    $r.close_to_exit_ms = [math]::Round(([SpdfLaunch]::NowFileTime() - $tClose) / 10000.0, 1)
    $r.exit_code = $proc.ExitCode
  } finally {
    if (-not $proc.HasExited) { try { $proc.Kill() } catch {} ; $proc.WaitForExit(2000) | Out-Null }
    Restore-Session $proc.Id
    if ($Cold -and (Test-Path -LiteralPath $launchExe)) { Remove-Item -LiteralPath $launchExe -Force -ErrorAction SilentlyContinue }
  }
  # In-process marks: first occurrence of each phase wins.
  if (Test-Path -LiteralPath $markFile) {
    foreach ($line in Get-Content -LiteralPath $markFile) {
      if ($line -match '^SPDF-LAUNCH\s+([\d.]+)ms\s+(\S+)(.*)$') {
        $phase = $Matches[2]
        if (-not $r.marks.ContainsKey($phase)) { $r.marks[$phase] = [double]$Matches[1] }
        if ($Matches[3].Trim() -ne '' -and -not $r.ContainsKey("mark_detail_$phase")) { $r["mark_detail_$phase"] = $Matches[3].Trim() }
      }
    }
  }
  return $r
}

if (-not $locked) { [void][SpdfLaunch]::SampleClientColors([SpdfLaunch]::GetDesktopWindow()) }

$results = @()
try {
  for ($i = 1; $i -le $Runs; $i++) { $results += Invoke-Run $i }
} finally {
  # Belt and braces: whatever happened, the user's file is not left as our fixture.
  if (Test-Path -LiteralPath $sessionFile) {
    $text = [IO.File]::ReadAllText($sessionFile)
    if ($text.Contains($fixtureId)) {
      if ($backup) { Copy-Item -LiteralPath $backup -Destination $sessionFile -Force } else { Remove-Item -LiteralPath $sessionFile -Force }
    }
  }
}

# --- summary ----------------------------------------------------------------

$ok = @($results | Where-Object { $_.error -eq $null })
$phaseNames = @{}
foreach ($r in $ok) { foreach ($k in $r.marks.Keys) { $phaseNames[$k] = $true } }
$phases = @()
foreach ($k in $phaseNames.Keys) { $phases += @{ name = $k; median = Median(@($ok | ForEach-Object { $_.marks[$k] })) } }
$phases = @($phases | Sort-Object { $_.median })

$summary = [ordered]@{
  label = $Label; exe = $Exe; pdf = $Pdf; args = ($AppArgs -join ' '); cold = [bool]$Cold; restore_tabs = $RestoreTabs
  runs = $Runs; ok_runs = $ok.Count; host_dpi_aware = $dpiAware; sampler = $samplerState
  health = @{
    runs = $ok.Count
    foreground_runs = @($ok | Where-Object { $_.foreground }).Count
    front_runs = @($ok | Where-Object { $_.zindex -eq 0 }).Count
    hung_runs = @($ok | Where-Object { $_.hung_windows -gt 0 }).Count
  }
  window_ms = @{ median = Median(@($ok | % { $_.window_ms })); min = ($ok | % { $_.window_ms } | Measure-Object -Minimum).Minimum; max = ($ok | % { $_.window_ms } | Measure-Object -Maximum).Maximum }
  first_pixels_ms = @{ median = Median(@($ok | % { $_.first_pixels_ms })); min = ($ok | % { $_.first_pixels_ms } | Measure-Object -Minimum).Minimum; max = ($ok | % { $_.first_pixels_ms } | Measure-Object -Maximum).Maximum }
  spawn_ms = Median(@($ok | % { $_.spawn_ms }))
  close_to_exit_ms = Median(@($ok | % { $_.close_to_exit_ms }))
  cpu_at_pixels_ms = Median(@($ok | % { $_.cpu_at_pixels_ms }))
  cpu_settled_ms = Median(@($ok | % { $_.cpu_settled_ms }))
  threads_settled = Median(@($ok | % { $_.threads_settled }))
  sample_cost_ms = Median(@($ok | % { $_.samples | % { $_.cost_ms } }))
  phases = $phases
  runs_detail = $results
}
$jsonPath = Join-Path $OutDir 'summary.json'
($summary | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $jsonPath -Encoding UTF8

if ($Json) {
  Get-Content -LiteralPath $jsonPath
} else {
  $title = if ($Label) { $Label } else { [IO.Path]::GetFileName($Pdf) }
  Write-Output ("== launch: {0}  ({1} runs{2}{3}; host_dpi_aware={4})" -f $title, $Runs, $(if ($Cold) { ', cold' } else { '' }), $(if ($RestoreTabs) { ", restore $RestoreTabs tabs" } else { '' }), $dpiAware)
  Write-Output ("  exe: {0}" -f $Exe)
  if ($ok.Count -lt $Runs) {
    foreach ($r in $results | Where-Object { $_.error }) { Write-Output ("  run {0}: {1} (exit {2})" -f $r.run, $r.error, $r.exit_code) }
  }
  Write-Output ("  {0,-34} {1,9} {2,9} {3,9}" -f 'external (from process creation)', 'median', 'min', 'max')
  Write-Output ("  {0,-34} {1,9:n1} {2,9:n1} {3,9:n1}" -f 'window visible', $summary.window_ms.median, $summary.window_ms.min, $summary.window_ms.max)
  if ($summary.first_pixels_ms.median -ne $null) {
    Write-Output ("  {0,-34} {1,9:n1} {2,9:n1} {3,9:n1}" -f 'first client pixels (sampler)', $summary.first_pixels_ms.median, $summary.first_pixels_ms.min, $summary.first_pixels_ms.max)
  } else {
    Write-Output ("  {0,-34} {1}" -f 'first client pixels (sampler)', $(if ($locked) { $samplerState } else { 'never non-blank within SamplerTimeoutMs' }))
  }
  Write-Output ("  {0,-34} {1,9:n1}" -f 'Process.Start returned', $summary.spawn_ms)
  Write-Output ("  {0,-34} {1,9:n1}" -f 'WM_CLOSE -> exit', $summary.close_to_exit_ms)
  Write-Output ("  {0,-34} {1,9:n1} {2,9:n1}" -f 'cpu ms at pixels / settled', $summary.cpu_at_pixels_ms, $summary.cpu_settled_ms)
  Write-Output ("  {0,-34} {1,9:n1}" -f 'sampler cost per frame', $summary.sample_cost_ms)
  Write-Output ("  {0,-34} {1,9}" -f 'threads when settled', $summary.threads_settled)
  Write-Output ("  {0,-34} {1}/{2} runs foreground, {3}/{2} in front, {4}/{2} with a hung window" -f 'health', $summary.health.foreground_runs, $summary.health.runs, $summary.health.front_runs, $summary.health.hung_runs)
  if ($phases.Count -gt 0) {
    Write-Output ("  {0,-34} {1,9}   {2}" -f 'in-process (SPDF-LAUNCH)', 'median', 'delta')
    $prev = 0.0
    foreach ($p in $phases) {
      Write-Output ("  {0,-34} {1,9:n1}   {2,7:n1}" -f $p.name, $p.median, ($p.median - $prev))
      $prev = $p.median
    }
  } else {
    Write-Output "  (no SPDF-LAUNCH marks: this exe was built without spdf_win_launch_profile.h markers)"
  }
  Write-Output ("  json: {0}" -f $jsonPath)
}

$rc = 0
if ($ok.Count -eq 0) {
  $first = $results | Select-Object -First 1
  if ($first.error -eq 'exited-before-window') { exit 65 }
  if ($first.error -eq 'no-window') { exit 66 }
  exit 67
}
# No sampler hit and no in-process mark in any run: nothing here says when the
# page appeared. An unlocked desktop that never composites is the backstop case
# screenshot-window.ps1 also reports as 68.
if ($summary.first_pixels_ms.median -eq $null -and $phases.Count -eq 0) {
  Write-Output "error=no-first-page-signal (sampler blank and no SPDF-LAUNCH marks)"
  exit 68
}
if ($WindowBudgetMs -gt 0 -and $summary.window_ms.median -gt $WindowBudgetMs) {
  Write-Output ("budget=FAIL window visible median {0} ms > {1} ms" -f $summary.window_ms.median, $WindowBudgetMs); $rc = 1
}
if ($FirstPageBudgetMs -gt 0) {
  $fp = $null
  foreach ($p in $phases) { if ($p.name -eq 'first-compose-end') { $fp = $p.median } }
  if ($fp -eq $null) { $fp = $summary.first_pixels_ms.median }
  if ($fp -gt $FirstPageBudgetMs) { Write-Output ("budget=FAIL first page median {0} ms > {1} ms" -f $fp, $FirstPageBudgetMs); $rc = 1 }
}
if ($WindowBudgetMs -gt 0 -or $FirstPageBudgetMs -gt 0) {
  $hl = $summary.health
  if ($hl.hung_runs -gt 0) { Write-Output ("health=FAIL a window of the process was hung in {0} of {1} runs" -f $hl.hung_runs, $hl.runs); $rc = 1 }
  # Foreground is reported, not judged: Windows grants the foreground only to a
  # process launched BY the foreground process, and this harness never is one
  # (it runs under a shell, under an editor whose own window is at z-index 0
  # while a session is open), so the app is refused, correctly, and flashes its
  # taskbar button instead. Measured 0 of 5 here on a desktop where a hand
  # launch is foreground every time.
  #
  # AND Z-ORDER CANNOT BE JUDGED WHEN THE FOREGROUND WAS REFUSED, which an
  # earlier version of this block got wrong: it claimed the two were
  # independent, and then failed the case 0/5 on a machine where the window was
  # healthy, because a window that may not take the foreground also may not be
  # raised above the window holding it. The z-order defect worth catching is the
  # narrower one that was actually seen (section 11): activation GRANTED and the
  # window still not raised. So z-order is judged only over the runs that got
  # the foreground, and reported for the rest.
  if ($hl.foreground_runs * 2 -ge $hl.runs -and $hl.front_runs * 2 -lt $hl.runs) {
    Write-Output ("health=FAIL the window took the foreground in {0} of {1} runs but was in front (z-index 0) in only {2}" -f $hl.foreground_runs, $hl.runs, $hl.front_runs)
    $rc = 1
  }
  if ($rc -eq 0) { Write-Output "health=OK" }
}
if ($rc -eq 0 -and ($WindowBudgetMs -gt 0 -or $FirstPageBudgetMs -gt 0)) { Write-Output "budget=OK" }
exit $rc
