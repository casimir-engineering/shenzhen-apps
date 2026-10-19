<#
.SYNOPSIS
  Launch ShenzhenPDF.exe, wait for its window, capture it to a PNG, close it.

.DESCRIPTION
  The Windows port was built entirely from a macOS host driving a Parallels VM
  through `prlctl exec`, which runs as `nt authority\system` and therefore has
  NO INTERACTIVE DESKTOP. Every visual claim in this repo before 2026-09-01 was
  a build, an exit code, or an offscreen render -- nobody had ever seen the
  window. See portable/docs/windows-port-handoff.md sec 0.

  This script exists so that "look at the window" is a repeatable command
  rather than a human favour, and so a screenshot can be diffed against
  docs/images/portable/macos-main-window.webp.

  It captures with PrintWindow(hwnd, dc, PW_RENDERFULLCONTENT), not a
  screen-region grab, so the result is the window's own pixels: no desktop
  wallpaper bleeding in, no other window overlapping it, and it works when the
  window is not foreground. PW_RENDERFULLCONTENT (0x2) is required for a window
  drawing through Direct2D/DirectComposition -- without it a hardware-composed
  client area comes back blank, which would look exactly like "the app painted
  nothing" and send you hunting a bug that is not there.

  It always tries to close the app it started. A stray ShenzhenPDF.exe, a stray
  message box, or a maximised window left behind is the Windows equivalent of
  the repo rule "do not launch the macOS app" -- the user has this machine in
  front of them while agents work (agents.md).

.PARAMETER Exe
  Path to ShenzhenPDF.exe.

.PARAMETER Pdf
  Document to open. Prefer portable/win/tests/fixtures/golden.pdf or another
  fixture over anything of the user's -- a screenshot ends up in a report.

.PARAMETER Out
  Destination PNG path.

.PARAMETER AppArgs
  Extra arguments passed through to the app, e.g. --dark.

.PARAMETER Width / Height
  Optional client-area size to force via MoveWindow before capturing, so two
  runs are comparable. Omit to accept whatever the app chose (which is itself
  worth capturing at least once -- the default size is a parity question).

.PARAMETER SettleMs
  How long to let the app render after its window appears. The canvas renders
  pages on a worker pool, so an immediate capture can catch placeholder paper
  instead of a page -- which would be a false "the page did not render" report.

.OUTPUTS
  Writes the PNG and prints one `key=value` line per fact for a caller to
  parse. Exit codes are distinct so a harness can tell the failures apart, and
  nothing is decided by piping this through grep (a repo rule -- see
  portable/docs/windows-port-handoff.md sec 5):
    0  captured
    64 bad usage / missing input
    65 process exited before a window appeared
    66 timed out waiting for a window
    67 capture itself failed
    68 the capture came back blank because the desktop is not composited --
       almost always a LOCKED workstation. This is a BLOCKED, not a failure:
       nothing has been shown about the app. See DistinctColors below.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Exe,
  [Parameter(Mandatory = $true)][string]$Pdf,
  [Parameter(Mandatory = $true)][string]$Out,
  [string[]]$AppArgs = @(),
  [int]$Width = 0,
  [int]$Height = 0,
  [int]$SettleMs = 1500,
  [int]$TimeoutMs = 20000,
  # Passed to the app as --state-dir: where it reads and writes settings.yaml
  # and session.yaml instead of %APPDATA%\ShenzhenPDF. A capture that restores
  # the reader's own session shows the page they left, not the one asked for,
  # and a capture must never write into their files. A parameter of its own
  # because a nested `powershell -File` cannot hand -AppArgs an array.
  [string]$StateDir = ''
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Exe)) { Write-Output "error=no-exe path=$Exe"; exit 64 }
if (-not (Test-Path -LiteralPath $Pdf)) { Write-Output "error=no-pdf path=$Pdf"; exit 64 }

# A LOCKED WORKSTATION CANNOT BE SCREENSHOTTED, AND SAYING SO UP FRONT SAVES AN
# INVESTIGATION.
#
# Windows does not composite a locked session. The DWM-drawn title bar still
# appears in a capture, because DWM has it cached, but a Direct2D client area
# backed by a GPU surface does not: PrintWindow returns black or stale garbage,
# and CopyFromScreen returns pure black for the entire screen.
#
# The failure is convincing in the worst way. It looks exactly like the app
# painting nothing -- and it REPRODUCES, including from a clean build of a
# known-good commit, which is how one investigation concluded the window had
# regressed when it had not. The offscreen compose of the very same binary was
# perfect throughout, which is the tell: spdf_win_paint() needs no desktop.
#
# So this is checked BEFORE the app is launched (no point starting it) and
# reported as its own exit code, so a harness records BLOCKED rather than FAIL.
# Nothing has been learned about the app either way.
# A SUSPENDED LockApp lingers long after an unlock, so its mere presence is
# a false positive -- it blocked launch.budget for a whole run on a live,
# composited desktop (2026-09-05), whose screenshots prove it was awake.
# LogonUI running always means locked; LockApp only when it is scheduled.
if ((@(Get-Process LogonUI -ErrorAction SilentlyContinue).Count +
           @(Get-Process LockApp -ErrorAction SilentlyContinue |
             Where-Object { $_.Threads[0].WaitReason -ne 'Suspended' }).Count) -gt 0) {
  Write-Output "error=workstation-locked"
  Write-Output ("detail=LogonUI or LockApp (the Windows 11 lock screen) is running, so this session is locked and Windows is not compositing it. " +
                "PrintWindow returns black or stale pixels for a Direct2D client area and CopyFromScreen " +
                "returns black for the whole screen, which presents as 'the app rendered nothing'. " +
                "Unlock the machine and re-run. The offscreen path (--render-window-png, optionally --chrome) " +
                "needs no desktop at all and is unaffected.")
  exit 68
}

$outDir = Split-Path -Parent $Out
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
  New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

# P/Invoke surface. PrintWindow + a DIB section, because a Graphics.CopyFromScreen
# would capture whatever is on top of the window instead of the window.
if (-not ('SpdfShot' -as [type])) {
  Add-Type -Language CSharp -ReferencedAssemblies 'System.Drawing' -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class SpdfShot {
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);

    // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4.
    //
    // THIS IS LOAD-BEARING AND IT COST AN INVESTIGATION. The host process
    // (powershell.exe) is not per-monitor DPI aware. When a DPI-unaware process
    // calls GetWindowRect/GetClientRect on a window owned by a per-monitor-aware
    // process, Windows VIRTUALISES the answer: on this 144-dpi display it
    // reported a 1680x1200 window as 1120x800. Allocating a bitmap of that
    // virtualised size and calling PrintWindow then captures only the window's
    // top-left 1120x800 PHYSICAL pixels -- a crop at true scale, which looks
    // exactly like "the app renders 1.5x too large and clips the page".
    //
    // It is a convincing false positive: it survives being reproduced, and the
    // ratio equals the DPI scale, so it points straight at the app's DPI
    // handling. The app was right the whole time. Becoming DPI-aware here is
    // what makes the numbers mean what they say.
    public static bool BecomeDpiAware() {
        try { return SetProcessDpiAwarenessContext(new IntPtr(-4)); }
        catch (EntryPointNotFoundException) { return false; }
    }

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }

    // The client area's origin expressed in the captured bitmap's own
    // coordinates. PrintWindow renders the WHOLE window including the frame, so
    // comparing a capture against a headless render of the client area needs
    // this offset -- otherwise the frame's border shifts everything and the
    // comparison reports a difference that is really an alignment error.
    public static string ClientOffset(IntPtr h) {
        RECT wr; POINT p = new POINT();
        if (!GetWindowRect(h, out wr)) return null;
        if (!ClientToScreen(h, ref p)) return null;
        RECT cr;
        if (!GetClientRect(h, out cr)) return null;
        return (p.X - wr.Left) + "," + (p.Y - wr.Top) + "," + (cr.Right - cr.Left) + "," + (cr.Bottom - cr.Top);
    }

    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    public delegate bool EnumProc(IntPtr h, IntPtr p);

    // Finding the window by MainWindowHandle alone is not enough: a process
    // whose first window is not its main one, or one that has not pumped a
    // message yet, reports IntPtr.Zero, and a launcher-style exe (several
    // in-box Windows apps are now packaged that way) owns no window at all.
    // Enumerating every visible top-level window against a set of process ids
    // is the version that does not depend on the app's startup order.
    public static IntPtr FirstVisibleWindow(uint[] pids) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr p) {
            if (!IsWindowVisible(h)) return true;
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            for (int i = 0; i < pids.Length; i++) {
                if (pids[i] == pid) {
                    RECT r;
                    // Skip 0-area helper windows some frameworks keep around.
                    if (GetWindowRect(h, out r) && (r.Right - r.Left) > 32 && (r.Bottom - r.Top) > 32) {
                        found = h;
                        return false;
                    }
                }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int t, bool repaint);
    [DllImport("user32.dll")] public static extern IntPtr GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder s, int n);

    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

    // PW_RENDERFULLCONTENT = 2. Mandatory for a D2D/DirectComposition client area.
    const uint PW_RENDERFULLCONTENT = 2;

    // How many DISTINCT colours a capture contains, sampled on a grid.
    //
    // WHY THIS IS HERE AND NOT IN THE CALLER. A capture taken while the
    // workstation is LOCKED comes back black -- all of it, including the
    // DWM-drawn title bar, which the app does not paint. Windows does not
    // composite a locked session, so both PrintWindow and CopyFromScreen return
    // nothing, and there is no reliable lock flag to test first: with the app in
    // the user's own session, OpenInputDesktop still reports "Default" and
    // GetForegroundWindow merely returns 0.
    //
    // So the harness asks the question it actually cares about -- is this
    // capture meaningful? -- instead of trying to divine why it might not be.
    // That distinction matters more than it sounds: a black capture presents as
    // the app rendering nothing, and it cost one investigation already, in which
    // a clean build of a known-good commit "reproduced" a window regression that
    // did not exist. The port's whole history is people unable to see the
    // window; being able to see it now includes noticing when you cannot.
    public static int DistinctColors(Bitmap bmp, int maxSamples) {
        return DistinctColorsIn(bmp, 0, 0, bmp.Width, bmp.Height, maxSamples);
    }

    // Same, over a sub-rectangle. The CLIENT area is the one that matters: DWM
    // keeps compositing the title bar when a Direct2D client area does not, so a
    // whole-window count stays healthy while the only interesting part is blank.
    // Measured during the locked-session investigation: whole window 7 distinct
    // colours, client area 2.
    public static int DistinctColorsIn(Bitmap bmp, int x0, int y0, int w, int h, int maxSamples) {
        if (w <= 0 || h <= 0) return -1;
        if (x0 < 0) x0 = 0;
        if (y0 < 0) y0 = 0;
        if (x0 + w > bmp.Width) w = bmp.Width - x0;
        if (y0 + h > bmp.Height) h = bmp.Height - y0;
        if (w <= 0 || h <= 0) return -1;
        var seen = new System.Collections.Generic.HashSet<int>();
        int stepX = Math.Max(1, w / 40), stepY = Math.Max(1, h / 40);
        int n = 0;
        for (int y = y0; y < y0 + h && n < maxSamples; y += stepY)
            for (int x = x0; x < x0 + w && n < maxSamples; x += stepX, n++)
                seen.Add(bmp.GetPixel(x, y).ToArgb());
        return seen.Count;
    }

    public static int LastCaptureColors = -1;
    public static int LastClientColors = -1;

    public static string Capture(IntPtr hwnd, string path) {
        RECT wr;
        if (!GetWindowRect(hwnd, out wr)) return "GetWindowRect failed";
        int w = wr.Right - wr.Left, h = wr.Bottom - wr.Top;
        if (w <= 0 || h <= 0) return "window rect is empty (" + w + "x" + h + ")";
        using (Bitmap bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb))
        using (Graphics g = Graphics.FromImage(bmp)) {
            IntPtr dc = g.GetHdc();
            bool ok;
            try { ok = PrintWindow(hwnd, dc, PW_RENDERFULLCONTENT); }
            finally { g.ReleaseHdc(dc); }
            if (!ok) return "PrintWindow failed (win32 " + Marshal.GetLastWin32Error() + ")";
            LastCaptureColors = DistinctColors(bmp, 1600);
            // The client area within the captured (whole-window) bitmap.
            RECT cr; POINT o = new POINT();
            if (GetClientRect(hwnd, out cr) && ClientToScreen(hwnd, ref o)) {
                LastClientColors = DistinctColorsIn(bmp, o.X - wr.Left, o.Y - wr.Top,
                                                    cr.Right - cr.Left, cr.Bottom - cr.Top, 1600);
            } else {
                LastClientColors = -1;
            }
            bmp.Save(path, ImageFormat.Png);
        }
        return null;
    }

    public static string ClassOf(IntPtr h) {
        var sb = new System.Text.StringBuilder(256);
        GetClassNameW(h, sb, sb.Capacity);
        return sb.ToString();
    }

    public static string TitleOf(IntPtr h) {
        var sb = new System.Text.StringBuilder(1024);
        GetWindowTextW(h, sb, sb.Capacity);
        return sb.ToString();
    }
}
'@
}

# Quote every argument that contains whitespace. Start-Process joins
# -ArgumentList with plain spaces and does NOT quote for you, so an unquoted
# "C:\...\what made apollo a success.pdf" reaches the app as five arguments and
# it exits 64 (usage) -- which reads exactly like "the app cannot open this
# file". Measured here, and the same class of bug as passing an unquoted
# --installPath to a Windows installer.
# Must happen before any window/DPI query below. See BecomeDpiAware's comment:
# without it every rect this script reports is silently virtualised.
$dpiAware = [SpdfShot]::BecomeDpiAware()
Write-Output ("host_dpi_aware=" + $dpiAware)

$argList = @()
$launchArgs = @($AppArgs)
if ($StateDir) {
  New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
  $launchArgs += @('--state-dir', $StateDir)
}
foreach ($a in $launchArgs + @($Pdf)) {
  if ($null -eq $a -or $a -eq '') { continue }
  if ($a -match '\s' -and $a -notmatch '^".*"$') { $argList += ('"' + $a + '"') } else { $argList += $a }
}

Write-Output ("launch=" + $Exe)
Write-Output ("args=" + ($argList -join ' '))

$proc = Start-Process -FilePath $Exe -ArgumentList $argList -PassThru
$hwnd = [IntPtr]::Zero
$sw = [Diagnostics.Stopwatch]::StartNew()

try {
  # Wait for a visible top-level window on the process. MainWindowHandle is not
  # populated at once and is not refreshed on a cached object, hence Refresh().
  while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
    if ($proc.HasExited) {
      Write-Output "error=process-exited-before-window exitcode=$($proc.ExitCode) after_ms=$($sw.ElapsedMilliseconds)"
      exit 65
    }
    $proc.Refresh()
    # MainWindowHandle reads back as $null once the process has exited, and
    # passing that to IsWindowVisible throws a cast error that buries the real
    # story (the app's own exit code). Normalise first.
    $h = $proc.MainWindowHandle
    if ($null -eq $h) { $h = [IntPtr]::Zero }
    if ($h -ne [IntPtr]::Zero -and [SpdfShot]::IsWindowVisible($h)) { $hwnd = $h; break }

    # Fall back to enumerating windows owned by this process or any child it
    # spawned. Collected fresh each round: a child can appear at any time.
    $pids = New-Object System.Collections.Generic.List[uint32]
    $pids.Add([uint32]$proc.Id)
    foreach ($c in Get-CimInstance Win32_Process -Filter "ParentProcessId = $($proc.Id)" -ErrorAction SilentlyContinue) {
      $pids.Add([uint32]$c.ProcessId)
    }
    $h = [SpdfShot]::FirstVisibleWindow($pids.ToArray())
    if ($h -ne [IntPtr]::Zero) { $hwnd = $h; break }

    Start-Sleep -Milliseconds 100
  }

  if ($hwnd -eq [IntPtr]::Zero) {
    Write-Output "error=no-window-within-timeout timeout_ms=$TimeoutMs"
    exit 66
  }

  Write-Output ("window_ms=" + $sw.ElapsedMilliseconds)
  Write-Output ("hwnd=0x" + $hwnd.ToString('x'))
  Write-Output ("class=" + [SpdfShot]::ClassOf($hwnd))
  Write-Output ("title=" + [SpdfShot]::TitleOf($hwnd))

  $dpi = [SpdfShot]::GetDpiForWindow($hwnd)
  Write-Output ("dpi=" + $dpi)

  if ($Width -gt 0 -and $Height -gt 0) {
    [void][SpdfShot]::MoveWindow($hwnd, 80, 80, $Width, $Height, $true)
    Start-Sleep -Milliseconds 400
  }

  $cr = New-Object SpdfShot+RECT
  if ([SpdfShot]::GetClientRect($hwnd, [ref]$cr)) {
    Write-Output ("client=" + ($cr.Right - $cr.Left) + "x" + ($cr.Bottom - $cr.Top))
  }
  $wr = New-Object SpdfShot+RECT
  if ([SpdfShot]::GetWindowRect($hwnd, [ref]$wr)) {
    Write-Output ("frame=" + ($wr.Right - $wr.Left) + "x" + ($wr.Bottom - $wr.Top))
  }
  # x,y,w,h of the client area inside the captured bitmap. Lets a caller crop
  # the capture to exactly what spdf_win_paint drew, which is what
  # --render-window-png produces headlessly.
  $co = [SpdfShot]::ClientOffset($hwnd)
  if ($co) { Write-Output ("client_offset=" + $co) }

  Start-Sleep -Milliseconds $SettleMs

  $err = [SpdfShot]::Capture($hwnd, $Out)
  if ($err) { Write-Output ("error=capture-failed detail=" + $err); exit 67 }

  Write-Output ("png=" + $Out)
  Write-Output ("bytes=" + (Get-Item -LiteralPath $Out).Length)
  Write-Output ("colors=" + [SpdfShot]::LastCaptureColors + " client_colors=" + [SpdfShot]::LastClientColors)

  # A real ShenzhenPDF window has a document, chrome and a title bar in it, so
  # it is never one or two flat colours. One is a black rectangle. Reported as a
  # DISTINCT exit code rather than as success-with-a-bad-png, so a harness can
  # record BLOCKED instead of FAIL: the app has not been shown to be wrong, the
  # screen simply could not be read.
  # Backstop for the non-composited cases the LogonUI check up front does not
  # name -- a disconnected RDP session, a blanked display, a GPU reset. Judged on
  # the CLIENT area, not the framed window: DWM keeps compositing the title bar
  # when the Direct2D client does not, so a whole-window count stays healthy
  # while the only part that matters is blank. Measured during the locked-session
  # investigation: whole window 7 distinct colours, client area 2.
  if ([SpdfShot]::LastClientColors -ge 0 -and [SpdfShot]::LastClientColors -le 3) {
    Write-Output ("error=capture-not-composited client_colors=" + [SpdfShot]::LastClientColors)
    Write-Output ("detail=the client area came back as " + [SpdfShot]::LastClientColors +
                  ' flat colour(s), which no real document window is. The desktop is probably not being ' +
                  'composited (locked, disconnected, or the display is asleep). This is BLOCKED, not a failure: ' +
                  'nothing has been shown about the app. The offscreen path needs no desktop and is unaffected.')
    exit 68
  }

  Write-Output "status=captured"
  exit 0
}
finally {
  # Always clean up: no stray window, no stray process. CloseMainWindow first so
  # the app takes its own exit path (which is what writes session.yaml); Kill
  # only if it will not go.
  if ($proc -and -not $proc.HasExited) {
    [void]$proc.CloseMainWindow()
    if (-not $proc.WaitForExit(4000)) { $proc.Kill(); [void]$proc.WaitForExit(2000) }
    Write-Output ("app_exitcode=" + $proc.ExitCode)
  } elseif ($proc) {
    Write-Output ("app_exitcode=" + $proc.ExitCode)
  }
}
