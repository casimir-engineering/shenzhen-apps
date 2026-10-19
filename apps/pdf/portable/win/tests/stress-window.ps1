<#
.SYNOPSIS
  Flood a REAL ShenzhenPDF window with input for ~20 s, while the document it
  has open is rewritten under it, and prove the UI thread never stopped
  answering -- then prove it still turns a page.

.DESCRIPTION
  "The app was never responsive to any user input and not even focusable."
  Every test was green when that was reported, twice, because nothing in the
  suite ever drove the window the way a person does: a launch check looks for
  a window and a first frame and closes it within a second or two. A UI thread
  that pumps for two seconds and then waits on something it does not control
  -- a worker's lock, another process's file lock, a hung window's reply --
  looks perfect to that check. This harness is the check that would have
  caught it.

  WHAT IT DOES. Launches the freshly built exe on a PRIVATE copy of the outline
  fixture with a PRIVATE --state-dir (never the reader's %APPDATA%), makes the
  window foreground, and for DurationMs drives it through SendInput -- the real
  input path, not PostMessage: wheel scrolling, PageDown/PageUp, Home/End,
  Ctrl+plus / Ctrl+minus, Ctrl+F and typing, Escape, the sidebar toggle
  button, and window resizes -- while every RewriteEveryMs the opened file is
  rewritten in place or atomically replaced, so the watcher's debounce, the
  canvas teardown (which joins the render workers), the reopen and the
  thumbnail and search rebuilds all run under load.

  WHAT IT ASSERTS, every PingEveryMs: SendMessageTimeout(WM_NULL,
  SMTO_ABORTIFHUNG | SMTO_BLOCK, PingTimeoutMs) answers, and no window of the
  process is IsHungAppWindow. WM_NULL is the message the shell itself uses to
  ask "are you alive"; a thread parked in a wait never answers it. At the end:
  a Home then a PageDown still change the client pixels (PrintWindow with
  PW_RENDERFULLCONTENT, the only form that sees a Direct2D client -- see
  measure-launch.ps1), and WM_CLOSE exits the process within CloseTimeoutMs,
  which is the exit path's own joins under the same load.

  WHY THE HARNESS NEVER SENDS A SYNCHRONOUS MESSAGE OF ITS OWN. MoveWindow and
  a plain SetWindowPos deliver WM_WINDOWPOSCHANGING to the target thread and
  WAIT for it, so a harness that resized with them would hang on exactly the
  defect it is measuring and report nothing. Resizes go through SetWindowPos
  with SWP_ASYNCWINDOWPOS (posted, not sent); the only synchronous call is the
  ping, and its timeout is the assertion.

  BLOCKED, NOT FAILED (exit 68 / 69), when the desktop cannot take the input:
  a locked workstation is not composited and SendInput goes nowhere, and a
  desktop that refuses the launched window the foreground (Windows grants it
  only to the process that had the last input) cannot receive keystrokes.
  Both are the host's state, not the app's, and the suite records them as
  BLOCKED so the run exits 2 rather than pretending.

.PARAMETER Exe            ShenzhenPDF.exe to drive.
.PARAMETER Pdf            The fixture; a copy under OutDir is what is opened
                          and rewritten, the original is never touched.
.PARAMETER OutDir         Private state dir, the working copy, captures, JSON.
.PARAMETER DurationMs     How long to flood. Default 20 s.
.PARAMETER PingEveryMs    Liveness cadence. Default 250 ms.
.PARAMETER PingTimeoutMs  How long an unanswered WM_NULL is a failure. 500 ms.
.PARAMETER RewriteEveryMs How often the open file is rewritten under the app.
.PARAMETER CloseTimeoutMs How long WM_CLOSE may take to end the process.
.PARAMETER Json           Print the summary as JSON instead of a table.

.OUTPUTS
  0  every ping answered, no hung window, PageDown still repaints, exit clean
  1  a ping timed out, a window hung, the page did not turn, or exit hung
  64 bad usage / missing input
  65 the process exited before a window appeared (or during the flood)
  66 no window within the timeout
  67 the harness itself could not capture
  68 the workstation is locked / not composited -- BLOCKED
  69 the desktop refused the window the foreground -- BLOCKED
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Exe,
  [Parameter(Mandatory = $true)][string]$Pdf,
  [string]$OutDir = '',
  [int]$DurationMs = 20000,
  [int]$PingEveryMs = 250,
  [int]$PingTimeoutMs = 500,
  [int]$RewriteEveryMs = 2000,
  [int]$CloseTimeoutMs = 10000,
  [int]$WindowTimeoutMs = 15000,
  [switch]$Json
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Exe)) { Write-Output "error=no-exe path=$Exe"; exit 64 }
if (-not (Test-Path -LiteralPath $Pdf)) { Write-Output "error=no-pdf path=$Pdf"; exit 64 }
if ($OutDir -eq '') { $OutDir = Join-Path $env:TEMP 'spdf-stress' }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

# Can this desktop take synthetic input at all? Not only the lock screen: the
# SCREEN SAVER switches the input desktop too, and on that desktop
# GetForegroundWindow answers NULL and SendInput reaches nothing -- which is
# how this case first failed, reporting a refused foreground instead of the
# reason. desktop-available.ps1 asks Windows directly.
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'desktop-available.ps1')
$unavailable = Spdf-DesktopUnavailable
if ($unavailable) { Write-Output ("error=desktop-unavailable detail=" + $unavailable); exit 68 }

if (-not ('SpdfStress' -as [type])) {
  Add-Type -ReferencedAssemblies System.Drawing -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;

public static class SpdfStress {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsHungAppWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);

    // Is the screen point on OUR window (or a child of it)? Another process's
    // window can land on top of the one under test -- this desktop is shared
    // with whoever else is launching things -- and a click there would drive
    // the wrong program and prove nothing about this one.
    public static bool PointIsOurs(IntPtr h, int x, int y) {
        POINT p; p.X = x; p.Y = y;
        IntPtr under = WindowFromPoint(p);
        if (under == IntPtr.Zero) return false;
        return under == h || GetAncestor(under, 2 /* GA_ROOT */) == h;
    }
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint tid, ref GUITHREADINFO g);
    [StructLayout(LayoutKind.Sequential)] public struct GUITHREADINFO { public int cbSize; public uint flags; public IntPtr hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret; public RECT rcCaret; }
    [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr SendMessageTimeoutW(IntPtr h, uint m, IntPtr w, IntPtr l, uint flags, uint ms, out IntPtr res);
    [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint n, INPUT[] inputs, int size);

    [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit)] public struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public INPUTUNION u; }

    public static bool BecomeDpiAware() {
        try { return SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch (EntryPointNotFoundException) { return false; }
    }

    public static string ClassOf(IntPtr h) { var s = new StringBuilder(256); GetClassNameW(h, s, 256); return s.ToString(); }

    // Who has the foreground and where the app thread's keyboard focus is:
    // the two facts to read first when input goes nowhere.
    public static string Describe(IntPtr app) {
        IntPtr fg = GetForegroundWindow();
        uint fgPid; GetWindowThreadProcessId(fg, out fgPid);
        uint appPid; uint tid = GetWindowThreadProcessId(app, out appPid);
        var g = new GUITHREADINFO(); g.cbSize = Marshal.SizeOf(g);
        string focus = GetGUIThreadInfo(tid, ref g) ? (g.hwndFocus == IntPtr.Zero ? "none" : ClassOf(g.hwndFocus)) : "?";
        return "foreground=" + (fg == app ? "app" : ClassOf(fg) + "/pid" + fgPid) + " app_focus=" + focus;
    }

    // The app's own main window class, visible: not the watcher's message-only
    // window, not the updater's sink, not a dialog.
    public static IntPtr MainWindow(uint pid) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr p) {
            uint owner; GetWindowThreadProcessId(h, out owner);
            if (owner != pid || !IsWindowVisible(h)) return true;
            if (ClassOf(h) != "ShenzhenPDFWindow") return true;
            found = h; return false;
        }, IntPtr.Zero);
        return found;
    }

    // Every window of the process, visible or not, whose thread has stopped
    // answering -- the shell's own test before it ghosts a window.
    public static int HungWindows(uint pid) {
        int hung = 0;
        EnumWindows(delegate(IntPtr h, IntPtr p) {
            uint owner; GetWindowThreadProcessId(h, out owner);
            if (owner == pid && IsHungAppWindow(h)) hung++;
            return true;
        }, IntPtr.Zero);
        return hung;
    }

    // Visible top-level windows of the process other than `main`: a dialog the
    // flood provoked, which a reader would have to dismiss.
    public static int OtherVisibleWindows(uint pid, IntPtr main) {
        int n = 0;
        EnumWindows(delegate(IntPtr h, IntPtr p) {
            uint owner; GetWindowThreadProcessId(h, out owner);
            if (owner == pid && h != main && IsWindowVisible(h)) {
                RECT r;
                if (GetWindowRect(h, out r) && (r.Right - r.Left) > 32 && (r.Bottom - r.Top) > 32) n++;
            }
            return true;
        }, IntPtr.Zero);
        return n;
    }

    // WM_NULL with SMTO_ABORTIFHUNG | SMTO_BLOCK: the round trip in ms, or -1
    // when the thread did not answer within `timeoutMs`.
    public static double Ping(IntPtr h, uint timeoutMs) {
        IntPtr res;
        var sw = Stopwatch.StartNew();
        IntPtr ok = SendMessageTimeoutW(h, 0x0000, IntPtr.Zero, IntPtr.Zero, 0x0002 | 0x0001, timeoutMs, out res);
        sw.Stop();
        return ok == IntPtr.Zero ? -1.0 : sw.Elapsed.TotalMilliseconds;
    }

    // Posted, never sent: SWP_ASYNCWINDOWPOS (0x4000) so this call cannot itself
    // block on the window it is testing. SWP_NOZORDER | SWP_NOACTIVATE too.
    public static bool MoveAsync(IntPtr h, int x, int y, int w, int hgt) {
        return SetWindowPos(h, IntPtr.Zero, x, y, w, hgt, 0x0004 | 0x0010 | 0x4000);
    }

    static int Size() { return Marshal.SizeOf(typeof(INPUT)); }

    static INPUT KeyDown(ushort vk) { var i = new INPUT(); i.type = 1; i.u.ki.wVk = vk; return i; }
    static INPUT KeyUp(ushort vk) { var i = new INPUT(); i.type = 1; i.u.ki.wVk = vk; i.u.ki.dwFlags = 2; return i; }

    public static uint Key(ushort vk, bool ctrl, bool shift) {
        var l = new List<INPUT>();
        if (ctrl) l.Add(KeyDown(0x11));
        if (shift) l.Add(KeyDown(0x10));
        l.Add(KeyDown(vk)); l.Add(KeyUp(vk));
        if (shift) l.Add(KeyUp(0x10));
        if (ctrl) l.Add(KeyUp(0x11));
        return SendInput((uint)l.Count, l.ToArray(), Size());
    }

    public static uint Text(string s) {
        var l = new List<INPUT>();
        foreach (char c in s) {
            var k = new INPUT(); k.type = 1; k.u.ki.wScan = c; k.u.ki.dwFlags = 4; l.Add(k);
            var u = k; u.u.ki.dwFlags = 4 | 2; l.Add(u);
        }
        return SendInput((uint)l.Count, l.ToArray(), Size());
    }

    public static uint Click(int x, int y) {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(30);
        var a = new INPUT[2];
        a[0].type = 0; a[0].u.mi.dwFlags = 0x0002;
        a[1].type = 0; a[1].u.mi.dwFlags = 0x0004;
        return SendInput(2, a, Size());
    }

    public static uint Wheel(int x, int y, int delta) {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(10);
        var a = new INPUT[1];
        a[0].type = 0; a[0].u.mi.dwFlags = 0x0800; a[0].u.mi.mouseData = unchecked((uint)delta);
        return SendInput(1, a, Size());
    }

    // A process may set the foreground only if it received the last input.
    // Sending itself an Alt press makes that true of this harness, after which
    // SetForegroundWindow on the app's window is honoured -- the documented
    // way for an automation host to hand focus to what it launched.
    public static bool ForceForeground(IntPtr h) {
        for (int attempt = 0; attempt < 6; attempt++) {
            if (GetForegroundWindow() == h) return true;
            var a = new INPUT[2];
            a[0] = KeyDown(0x12); a[1] = KeyUp(0x12);
            SendInput(2, a, Size());
            SetForegroundWindow(h);
            System.Threading.Thread.Sleep(150);
        }
        return GetForegroundWindow() == h;
    }

    public static Bitmap Capture(IntPtr h) {
        RECT r; if (!GetWindowRect(h, out r)) return null;
        int w = r.Right - r.Left, hgt = r.Bottom - r.Top;
        if (w <= 0 || hgt <= 0) return null;
        var bmp = new Bitmap(w, hgt, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bmp)) {
            IntPtr dc = g.GetHdc();
            bool ok;
            try { ok = PrintWindow(h, dc, 2 /* PW_RENDERFULLCONTENT */); } finally { g.ReleaseHdc(dc); }
            if (!ok) { bmp.Dispose(); return null; }
        }
        return bmp;
    }

    static int[] Pixels(Bitmap a) {
        var d = a.LockBits(new Rectangle(0, 0, a.Width, a.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        var px = new int[a.Width * a.Height];
        try {
            for (int y = 0; y < a.Height; y++)
                Marshal.Copy(new IntPtr(d.Scan0.ToInt64() + (long)y * d.Stride), px, y * a.Width, a.Width);
        } finally { a.UnlockBits(d); }
        return px;
    }

    public static long Diff(Bitmap a, Bitmap b) {
        if (a == null || b == null || a.Width != b.Width || a.Height != b.Height) return -1;
        var pa = Pixels(a); var pb = Pixels(b); long n = 0;
        for (int i = 0; i < pa.Length; i++) if ((pa[i] & 0xffffff) != (pb[i] & 0xffffff)) n++;
        return n;
    }

    public static int Colors(Bitmap a) {
        if (a == null) return -1;
        var seen = new HashSet<int>(); var pa = Pixels(a);
        for (int i = 0; i < pa.Length; i += 7) seen.Add(pa[i] & 0xffffff);
        return seen.Count;
    }

    public static void Close(IntPtr h) { PostMessageW(h, 0x0010 /* WM_CLOSE */, IntPtr.Zero, IntPtr.Zero); }
}
'@
}

$dpiAware = [SpdfStress]::BecomeDpiAware()

# --- the private world -----------------------------------------------------

$stateDir = Join-Path $OutDir 'state'
if (Test-Path -LiteralPath $stateDir) { Remove-Item -LiteralPath $stateDir -Recurse -Force }
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
$work = Join-Path $OutDir 'stress.pdf'
$fixtureBytes = [IO.File]::ReadAllBytes($Pdf)
[IO.File]::WriteAllBytes($work, $fixtureBytes)

# The open file, changed under the app. In place on even turns (LAST_WRITE /
# SIZE notifications); through a temp file and MoveFileEx on odd turns, which
# is what an editor's atomic save looks like (REMOVED / RENAMED). Both paths of
# spdf_win_watcher.cpp get exercised. A sharing violation is not a failure of
# the app: the render workers may hold the file for a moment, so it is
# reported and the next turn tries again.
function Rewrite-Work([int]$turn) {
  try {
    if ($turn % 2 -eq 0) {
      [IO.File]::WriteAllBytes($work, $fixtureBytes)
    } else {
      $tmp = "$work.tmp"
      [IO.File]::WriteAllBytes($tmp, $fixtureBytes)
      [IO.File]::Copy($tmp, $work, $true)
      Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
    return $true
  } catch { return $false }
}

# --- launch ----------------------------------------------------------------

$psi = New-Object Diagnostics.ProcessStartInfo
$psi.FileName = $Exe
$psi.UseShellExecute = $false
# The first-run question is modal and appears before the window: never in a
# harness (spdf_win_setup.h). --state-dir alone would also suppress it, but
# the intent is worth spelling out.
$psi.EnvironmentVariables['SPDF_WIN_SETUP_NO_PROMPT'] = '1'
$psi.Arguments = ('--state-dir "{0}" "{1}"' -f $stateDir, $work)

$result = [ordered]@{
  exe = $Exe; pdf = $work; state_dir = $stateDir; duration_ms = $DurationMs; ping_every_ms = $PingEveryMs
  ping_timeout_ms = $PingTimeoutMs; host_dpi_aware = $dpiAware
  window_ms = $null; first_paint_ms = $null; pings = 0; ping_timeouts = 0; ping_max_ms = 0.0; ping_mean_ms = 0.0
  hung_samples = 0; actions = 0; obstructed = 0; rewrites = 0; rewrite_failures = 0; foreground_lost = 0; foreground_notes = @(); other_windows = 0
  final_state = ''
  final_home_pagedown_diff_px = $null; final_client_px = $null; final_ping_ms = $null
  close_to_exit_ms = $null; exit_code = $null; verdict = ''; failures = @()
}

$proc = [Diagnostics.Process]::Start($psi)
$script:hwnd = [IntPtr]::Zero
$script:rc = 0
$script:sizeAt = 0
$script:actionIndex = 0

# The body is a function so that `return` on a BLOCKED or broken run lands in
# the summary below rather than ending the script before it is written.
function Run-Flood {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.ElapsedMilliseconds -lt $WindowTimeoutMs) {
    if ($proc.HasExited) { Write-Output ("error=exited-before-window exit={0}" -f $proc.ExitCode); exit 65 }
    $h = [SpdfStress]::MainWindow([uint32]$proc.Id)
    if ($h -ne [IntPtr]::Zero) { $script:hwnd = $h; break }
    Start-Sleep -Milliseconds 20
  }
  if ($hwnd -eq [IntPtr]::Zero) { Write-Output "error=no-window"; exit 66 }
  $result.window_ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)

  # First paint, so the flood starts on a window that has content to change.
  $paintDeadline = $sw.ElapsedMilliseconds + 3000
  while ($sw.ElapsedMilliseconds -lt $paintDeadline) {
    $bmp = [SpdfStress]::Capture($hwnd)
    $colors = [SpdfStress]::Colors($bmp)
    if ($bmp) { $bmp.Dispose() }
    if ($colors -gt 3) { $result.first_paint_ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 1); break }
    Start-Sleep -Milliseconds 30
  }

  # A known place and size, so every coordinate below is on screen. Posted.
  [void][SpdfStress]::MoveAsync($hwnd, 40, 40, 1400, 900)
  Start-Sleep -Milliseconds 400

  if (-not [SpdfStress]::ForceForeground($hwnd)) {
    $fg = [SpdfStress]::GetForegroundWindow()
    # A screen saver can start DURING the run, so ask again before blaming the
    # app: an unavailable desktop is this machine's state, not a defect.
    $late = Spdf-DesktopUnavailable
    if ($late) { Write-Output ("error=desktop-unavailable detail=" + $late); $script:rc = 68; return }
    Write-Output ("error=foreground-refused foreground_class={0} hung_windows={1}" -f [SpdfStress]::ClassOf($fg), [SpdfStress]::HungWindows([uint32]$proc.Id))
    $script:rc = 69
    return
  }

  function Geometry {
    $r = New-Object SpdfStress+RECT; [void][SpdfStress]::GetWindowRect($hwnd, [ref]$r)
    $c = New-Object SpdfStress+RECT; [void][SpdfStress]::GetClientRect($hwnd, [ref]$c)
    $o = New-Object SpdfStress+POINT; [void][SpdfStress]::ClientToScreen($hwnd, [ref]$o)
    # The toolbar row is 42 pt below the 42 pt tab strip
    # and the sidebar toggle is the first 112 pt control after a 6 pt inset
    # (spdf_win_chrome.h, spdf_win_chrome_toolbar.h). The ratio of the window
    # rect's width to what was asked for stands in for the DPI, so this needs
    # no GetDpiForWindow import and is right on a 96 dpi display too.
    $scale = [math]::Max(1.0, ($r.Right - $r.Left) / 1400.0)
    return @{ rect = $r; client = $c; origin = $o; scale = $scale
              toggleX = $o.X + [int](62 * $scale); toggleY = $o.Y + [int](63 * $scale)
              canvasX = $o.X + [int](($c.Right - $c.Left) * 0.6); canvasY = $o.Y + [int](($c.Bottom - $c.Top) * 0.6) }
  }
  $g = Geometry

  # --- the flood -----------------------------------------------------------

  $pingSum = 0.0
  $sizes = @(@(1400, 900), @(900, 700), @(1600, 1000), @(1100, 800))
  # A pointer action only when the point is on our window; a keyboard action
  # only while we hold the foreground. Anything else is another window's
  # business and is counted as obstructed rather than sent into it.
  function Pointer([int]$x, [int]$y, [scriptblock]$do) {
    if ([SpdfStress]::PointIsOurs($hwnd, $x, $y)) { & $do } else { $result.obstructed++ }
  }
  function Keys([scriptblock]$do) {
    if ([SpdfStress]::GetForegroundWindow() -eq $hwnd) { & $do } else { $result.obstructed++ }
  }
  $actions = @(
    { Pointer $g.canvasX $g.canvasY { [void][SpdfStress]::Wheel($g.canvasX, $g.canvasY, -360) } },
    { Keys { [void][SpdfStress]::Key(0x22, $false, $false) } },                     # PageDown
    { Pointer $g.canvasX $g.canvasY { [void][SpdfStress]::Wheel($g.canvasX, $g.canvasY, -120) } },
    { Keys { [void][SpdfStress]::Key(0xBB, $true, $false) } },                      # Ctrl +
    { Pointer $g.canvasX $g.canvasY { [void][SpdfStress]::Wheel($g.canvasX, $g.canvasY, 240) } },
    { Keys { [void][SpdfStress]::Key(0x21, $false, $false) } },                     # PageUp
    { Keys { [void][SpdfStress]::Key(0x46, $true, $false); Start-Sleep -Milliseconds 60; [void][SpdfStress]::Text('line') } },  # Ctrl+F, type
    { Keys { [void][SpdfStress]::Key(0x1B, $false, $false) } },                     # Escape
    { Pointer $g.toggleX $g.toggleY { [void][SpdfStress]::Click($g.toggleX, $g.toggleY) } },   # sidebar off
    { Keys { [void][SpdfStress]::Key(0xBD, $true, $false) } },                      # Ctrl -
    { Keys { [void][SpdfStress]::Key(0x23, $false, $false) } },                     # End
    { $s = $sizes[$script:sizeAt % $sizes.Count]; $script:sizeAt++; [void][SpdfStress]::MoveAsync($hwnd, 40, 40, $s[0], $s[1]) },
    { Pointer $g.toggleX $g.toggleY { [void][SpdfStress]::Click($g.toggleX, $g.toggleY) } },   # sidebar on
    { Keys { [void][SpdfStress]::Key(0x24, $false, $false) } },                     # Home
    { Pointer $g.canvasX $g.canvasY { [void][SpdfStress]::Wheel($g.canvasX, $g.canvasY, -600) } },
    { Keys { [void][SpdfStress]::Key(0x22, $false, $false) } }
  )

  $flood = [Diagnostics.Stopwatch]::StartNew()
  $nextPing = $PingEveryMs
  $nextRewrite = $RewriteEveryMs
  $rewriteTurn = 0
  while ($flood.ElapsedMilliseconds -lt $DurationMs) {
    if ($proc.HasExited) {
      $result.failures += ('the process exited during the flood (exit {0})' -f $proc.ExitCode)
      $script:rc = 65
      return
    }
    # The comma binds tighter than % in PowerShell, so the index is computed
    # on its own line before it goes into a format list.
    $lastAction = ($script:actionIndex - 1) % $actions.Count
    if ([SpdfStress]::GetForegroundWindow() -ne $hwnd) {
      $result.foreground_lost++
      $result.foreground_notes += ('at {0} ms after action {1}: {2}' -f $flood.ElapsedMilliseconds, $lastAction, [SpdfStress]::Describe($hwnd))
      [void][SpdfStress]::ForceForeground($hwnd)
    }
    $g = Geometry
    & $actions[$script:actionIndex % $actions.Count]
    $script:actionIndex++
    $result.actions++

    if ($flood.ElapsedMilliseconds -ge $nextRewrite) {
      if (Rewrite-Work $rewriteTurn) { $result.rewrites++ } else { $result.rewrite_failures++ }
      $rewriteTurn++
      $nextRewrite += $RewriteEveryMs
    }

    $wait = $nextPing - $flood.ElapsedMilliseconds
    if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }
    $nextPing += $PingEveryMs
    $ms = [SpdfStress]::Ping($hwnd, [uint32]$PingTimeoutMs)
    $result.pings++
    if ($ms -lt 0) {
      $result.ping_timeouts++
      $lastAction = ($script:actionIndex - 1) % $actions.Count
      $result.failures += ('ping {0} at {1} ms: WM_NULL unanswered within {2} ms (after action {3})' -f $result.pings, $flood.ElapsedMilliseconds, $PingTimeoutMs, $lastAction)
    } else {
      $pingSum += $ms
      if ($ms -gt $result.ping_max_ms) { $result.ping_max_ms = [math]::Round($ms, 2) }
    }
    if ([SpdfStress]::HungWindows([uint32]$proc.Id) -gt 0) {
      $result.hung_samples++
      $result.failures += ('a window of the process was hung at {0} ms' -f $flood.ElapsedMilliseconds)
    }
  }
  if ($result.pings - $result.ping_timeouts -gt 0) { $result.ping_mean_ms = [math]::Round($pingSum / ($result.pings - $result.ping_timeouts), 2) }

  # --- still a document viewer? --------------------------------------------

  Start-Sleep -Milliseconds 900  # the last reload lands
  [void][SpdfStress]::MoveAsync($hwnd, 40, 40, 1400, 900)
  Start-Sleep -Milliseconds 400
  if (-not [SpdfStress]::ForceForeground($hwnd)) {
    Write-Output ("error=foreground-refused-at-end {0}" -f [SpdfStress]::Describe($hwnd))
    $script:rc = 69
    return
  }
  $g = Geometry
  $result.final_client_px = ($g.client.Right - $g.client.Left) * ($g.client.Bottom - $g.client.Top)
  $result.final_state = [SpdfStress]::Describe($hwnd)
  $best = -1
  for ($attempt = 0; $attempt -lt 3 -and $best -lt ($result.final_client_px * 0.02); $attempt++) {
    if (-not [SpdfStress]::ForceForeground($hwnd)) { continue }
    [void][SpdfStress]::Key(0x1B, $false, $false)  # any field loses the keyboard
    [void][SpdfStress]::Key(0x24, $false, $false)  # Home
    Start-Sleep -Milliseconds 700
    $a = [SpdfStress]::Capture($hwnd)
    [void][SpdfStress]::Key(0x22, $false, $false)  # PageDown
    Start-Sleep -Milliseconds 700
    $b = [SpdfStress]::Capture($hwnd)
    if ($a -eq $null -or $b -eq $null) { Write-Output "error=capture-failed"; $script:rc = 67; return }
    $d = [SpdfStress]::Diff($a, $b)
    if ($d -gt $best) { $best = $d }
    if ($attempt -eq 0) { $a.Save((Join-Path $OutDir 'final-home.png')); $b.Save((Join-Path $OutDir 'final-pagedown.png')) }
    $a.Dispose(); $b.Dispose()
  }
  $result.final_home_pagedown_diff_px = $best
  if ($best -lt ($result.final_client_px * 0.02)) {
    $result.failures += ('after the flood a PageDown changed {0} px of {1} (less than 2 %): the window no longer turns pages ({2})' -f $best, $result.final_client_px, $result.final_state)
  }
  $result.final_ping_ms = [SpdfStress]::Ping($hwnd, [uint32]$PingTimeoutMs)
  if ($result.final_ping_ms -lt 0) { $result.failures += 'the final WM_NULL went unanswered' }
  $result.other_windows = [SpdfStress]::OtherVisibleWindows([uint32]$proc.Id, $hwnd)

  # --- the exit path, under the same load ----------------------------------

  $tClose = [Diagnostics.Stopwatch]::StartNew()
  [SpdfStress]::Close($hwnd)
  if ($proc.WaitForExit($CloseTimeoutMs)) {
    $result.close_to_exit_ms = [math]::Round($tClose.Elapsed.TotalMilliseconds, 1)
    $result.exit_code = $proc.ExitCode
  } else {
    $result.failures += ('WM_CLOSE did not end the process within {0} ms' -f $CloseTimeoutMs)
  }
}

try {
  Run-Flood
} finally {
  if ($proc -and -not $proc.HasExited) { try { $proc.Kill() } catch {} ; $proc.WaitForExit(2000) | Out-Null }
}

$rc = $script:rc
if ($rc -eq 0) { $rc = if ($result.failures.Count -gt 0) { 1 } else { 0 } }
$result.verdict = if ($rc -eq 0) { 'OK' } else { 'FAIL' }
$jsonPath = Join-Path $OutDir 'summary.json'
($result | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $jsonPath -Encoding UTF8

if ($Json) {
  Get-Content -LiteralPath $jsonPath
} else {
  Write-Output ("== stress: {0} for {1} ms, ping every {2} ms (timeout {3} ms); host_dpi_aware={4}" -f [IO.Path]::GetFileName($Exe), $DurationMs, $PingEveryMs, $PingTimeoutMs, $dpiAware)
  Write-Output ("  window at {0} ms, first paint at {1} ms" -f $result.window_ms, $result.first_paint_ms)
  Write-Output ("  actions={0} (obstructed {1}) rewrites={2} (failed {3}) foreground_lost={4}" -f $result.actions, $result.obstructed, $result.rewrites, $result.rewrite_failures, $result.foreground_lost)
  Write-Output ("  pings={0} timeouts={1} max_ms={2} mean_ms={3} hung_samples={4}" -f $result.pings, $result.ping_timeouts, $result.ping_max_ms, $result.ping_mean_ms, $result.hung_samples)
  Write-Output ("  final: home->pagedown changed {0} px of {1}; final ping {2} ms; other visible windows {3}; {4}" -f $result.final_home_pagedown_diff_px, $result.final_client_px, $result.final_ping_ms, $result.other_windows, $result.final_state)
  foreach ($n in $result.foreground_notes) { Write-Output ("  foreground lost {0}" -f $n) }
  Write-Output ("  WM_CLOSE -> exit {0} ms (exit code {1})" -f $result.close_to_exit_ms, $result.exit_code)
  foreach ($f in $result.failures) { Write-Output ("  FAIL: {0}" -f $f) }
  Write-Output ("  json: {0}" -f $jsonPath)
  Write-Output ("verdict={0}" -f $result.verdict)
}
exit $rc
