<#
.SYNOPSIS
  Does the window ANSWER? Launch ShenzhenPDF on a fixture, drive it with real
  SendInput (a toolbar click, PageDown, Ctrl+F and typing), assert the window
  repainted after each, then read back the launch-health.log the app wrote about
  itself and assert what it says.

.DESCRIPTION
  WHY THIS EXISTS. "The app was never responsive to any user input and not even
  focusable." Every test was green. They were green because none of them sent
  input: the headless compose renders a frame with no window, measure-launch.ps1
  watches a window appear and measures its first pixels, and screenshot-window.ps1
  captures one. A window can pass all three while ignoring every click.

  So this one clicks. Real SendInput, and a PrintWindow(PW_RENDERFULLCONTENT)
  capture before and after each action -- window-relative, so where the window
  sits is irrelevant. Then it reads the app's OWN launch-health.log back from
  the private --state-dir it handed it, and asserts what the 1 s and 5 s lines
  say. The full account, including the field guide for that log and the three
  design points worth keeping, is section 17 of
  portable/docs/windows-native-observations.md.

  BLOCKED, NOT FAILED, when the desktop cannot answer the question: a locked
  workstation is not composited (PrintWindow returns a flat client, so no
  capture can differ), and real input goes to whoever is in FRONT, so a desktop
  this cannot come to the front of must not be typed into. Both exit 68, which
  run-tests-native.sh maps to BLOCKED. The lock test is measure-launch.ps1's:
  LogonUI running always means locked, LockApp only when it is not merely
  suspended (a suspended LockApp lingers for hours after an unlock and blocked
  a whole run on a live desktop on 2026-09-05).

  THE READER'S STATE IS NEVER TOUCHED. -StateDir is mandatory and must not be
  %APPDATA%\ShenzhenPDF; SPDF_WIN_SETUP_NO_PROMPT=1 keeps the first-run
  TaskDialog from appearing in front of the window.

.OUTPUTS
  0  the window answered every action and its own log agrees
  1  it did not
  64 bad usage / missing input
  65 the process exited before a window appeared
  66 no window within the timeout
  68 BLOCKED: workstation locked, or the app could not be brought to the front
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Exe,
  [Parameter(Mandatory = $true)][string]$Pdf,
  [Parameter(Mandatory = $true)][string]$StateDir,
  [string]$OutDir = '',
  # THE DEFAULTS ARE CHOSEN SO EVERY KEYSTROKE LANDS BEFORE THE 5 s LINE. The
  # app writes that line five seconds after it shows the window, and the
  # assertion below is that its input counters have moved by then; with a 2 s
  # settle-in and 900 ms per step the last WM_CHAR arrived at 4.94 s and the
  # counter read 1 of 3 by luck. 1.5 s + 4 x 800 ms puts the typing at ~4.1 s.
  # (A run that still loses the race falls back to the 30 s line rather than
  # failing -- see the counter block.)
  [int]$WaitMs = 1500,
  [int]$SettleMs = 800,
  [int]$TimeoutMs = 15000,
  [double]$MinChangedPct = 1.0
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Exe)) { Write-Output "error=no-exe path=$Exe"; exit 64 }
if (-not (Test-Path -LiteralPath $Pdf)) { Write-Output "error=no-pdf path=$Pdf"; exit 64 }
if ($StateDir -eq '' -or $StateDir -eq (Join-Path $env:APPDATA 'ShenzhenPDF')) {
  Write-Output "error=StateDir-must-be-private"; exit 64
}
if ($OutDir -eq '') { $OutDir = Join-Path $env:TEMP 'spdf-launch-health' }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
Remove-Item -Recurse -Force $StateDir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $StateDir -Force | Out-Null

# measure-launch.ps1's lock test. See the .DESCRIPTION note.
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'desktop-available.ps1')
$unavailable = Spdf-DesktopUnavailable
if ($unavailable) { Write-Output ("error=desktop-unavailable detail=" + $unavailable); exit 68 }

Add-Type -AssemblyName System.Drawing
if (-not ('SpdfInput' -as [type])) {
  Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System; using System.Text; using System.Drawing; using System.Drawing.Imaging;
using System.Runtime.InteropServices; using System.Collections.Generic;
public static class SpdfInput {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr p);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint from, uint to, bool attach);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", SetLastError=true)] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Explicit)] public struct UNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public UNION u; }

    // The app's own window: class name, not title and not MainWindowHandle --
    // the class is registered by this app and by nothing else, and the hidden
    // helper windows of the process do not carry it.
    public static IntPtr MainWindow(uint pid) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr p) {
            uint owner; GetWindowThreadProcessId(h, out owner);
            if (owner != pid || !IsWindowVisible(h)) return true;
            var s = new StringBuilder(64); GetClassNameW(h, s, 64);
            if (s.ToString() == "ShenzhenPDFWindow") { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // REAL INPUT NEEDS THE REAL FOREGROUND. Windows refuses SetForegroundWindow
    // to a process that does not already own the foreground, and this harness
    // runs under a shell under an editor, so it never does. Attaching to the
    // current foreground thread's input queue is the documented way a tool asks
    // anyway; when even that is refused the caller must NOT send input, because
    // it would land in whatever window is actually in front.
    public static bool Raise(IntPtr h) {
        if (GetForegroundWindow() == h) return true;
        SetForegroundWindow(h); BringWindowToTop(h);
        if (GetForegroundWindow() == h) return true;
        uint fgPid;
        uint fgThread = GetWindowThreadProcessId(GetForegroundWindow(), out fgPid);
        uint me = GetCurrentThreadId();
        if (fgThread == 0 || fgThread == me) return false;
        AttachThreadInput(me, fgThread, true);
        SetForegroundWindow(h); BringWindowToTop(h);
        AttachThreadInput(me, fgThread, false);
        return GetForegroundWindow() == h;
    }

    // WHOSE WINDOW IS ACTUALLY UNDER THAT POINT. Being the foreground window is
    // not the same as being ON TOP of it -- a foreground window sitting below
    // another in the z-order is a state this port has actually observed
    // (spdf_win_window_lifecycle.h) -- and a click lands on whatever is drawn
    // there, not on whoever has the focus. So the click is only sent when the
    // pixel it aims at belongs to the process being tested.
    public static bool OwnsPoint(uint pid, int x, int y) {
        POINT p; p.X = x; p.Y = y;
        IntPtr h = WindowFromPoint(p);
        if (h == IntPtr.Zero) return false;
        uint owner; GetWindowThreadProcessId(h, out owner);
        return owner == pid;
    }

    public static string Click(int x, int y) {
        SetCursorPos(x, y); System.Threading.Thread.Sleep(80);
        var a = new INPUT[2];
        a[0].type = 0; a[0].u.mi.dwFlags = 0x0002; // LEFTDOWN
        a[1].type = 0; a[1].u.mi.dwFlags = 0x0004; // LEFTUP
        return "click@" + x + "," + y + " sent=" + SendInput(2, a, Marshal.SizeOf(typeof(INPUT)));
    }

    public static string Key(ushort vk, bool ctrl) {
        var l = new List<INPUT>();
        if (ctrl) { var d = new INPUT(); d.type = 1; d.u.ki.wVk = 0x11; l.Add(d); }
        var k = new INPUT(); k.type = 1; k.u.ki.wVk = vk; l.Add(k);
        var ku = new INPUT(); ku.type = 1; ku.u.ki.wVk = vk; ku.u.ki.dwFlags = 2; l.Add(ku);
        if (ctrl) { var u = new INPUT(); u.type = 1; u.u.ki.wVk = 0x11; u.u.ki.dwFlags = 2; l.Add(u); }
        return "key sent=" + SendInput((uint)l.Count, l.ToArray(), Marshal.SizeOf(typeof(INPUT)));
    }

    // KEYEVENTF_UNICODE, so the characters arrive as WM_CHAR whatever keyboard
    // layout the machine has.
    public static string Text(string s) {
        var l = new List<INPUT>();
        foreach (char c in s) {
            var k = new INPUT(); k.type = 1; k.u.ki.wScan = c; k.u.ki.dwFlags = 4; l.Add(k);
            var u = k; u.u.ki.dwFlags = 4 | 2; l.Add(u);
        }
        return "text sent=" + SendInput((uint)l.Count, l.ToArray(), Marshal.SizeOf(typeof(INPUT)));
    }

    // PW_RENDERFULLCONTENT on the WHOLE window: a Direct2D client comes back
    // black without it, and PW_CLIENTONLY comes back blank for this window on
    // this machine every time (measure-launch.ps1 records the measurement).
    public static Bitmap Capture(IntPtr h) {
        RECT r; if (!GetWindowRect(h, out r)) return null;
        int w = r.R - r.L, ht = r.B - r.T;
        if (w <= 0 || ht <= 0) return null;
        var bmp = new Bitmap(w, ht, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bmp)) {
            IntPtr dc = g.GetHdc();
            bool ok; try { ok = PrintWindow(h, dc, 2); } finally { g.ReleaseHdc(dc); }
            if (!ok) { bmp.Dispose(); return null; }
        }
        return bmp;
    }

    static int[] Pixels(Bitmap a) {
        var d = a.LockBits(new Rectangle(0, 0, a.Width, a.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        var px = new int[a.Width * a.Height];
        for (int y = 0; y < a.Height; y++)
            Marshal.Copy(new IntPtr(d.Scan0.ToInt64() + (long)y * d.Stride), px, y * a.Width, a.Width);
        a.UnlockBits(d); return px;
    }

    // Percent of pixels whose RGB differs. -1 when the two cannot be compared
    // (a resize between captures), which the caller reports rather than passes.
    public static double DiffPct(Bitmap a, Bitmap b) {
        if (a == null || b == null || a.Width != b.Width || a.Height != b.Height) return -1;
        var pa = Pixels(a); var pb = Pixels(b); long n = 0;
        for (int i = 0; i < pa.Length; i++) if ((pa[i] & 0xffffff) != (pb[i] & 0xffffff)) n++;
        return pa.Length == 0 ? -1 : (100.0 * n / pa.Length);
    }

    public static void Close(IntPtr h) { PostMessageW(h, 0x0010, IntPtr.Zero, IntPtr.Zero); }
}
'@
}
[void][SpdfInput]::SetProcessDpiAwarenessContext([IntPtr](-4))  # PER_MONITOR_AWARE_V2

$fails = @()
function Fail($m) { $script:fails += $m; Write-Output ("FAIL " + $m) }

# The app's own --diagnose, run while the window under test is STILL UP, and
# printed whenever this case is about to report a failure. It is the same
# report a reader is asked to paste, and here it is captured at the moment the
# window misbehaved rather than reconstructed afterwards -- which is the whole
# point of the switch existing. Redirected explicitly, for the reason the
# --print-layout call below states.
function Diagnose($exe, $stateDir) {
  try {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = ('--diagnose --state-dir "{0}"' -f $stateDir)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $p = [Diagnostics.Process]::Start($psi)
    $text = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    Write-Output "-- --diagnose --"
    $text.Split("`n") | ForEach-Object { Write-Output ("   " + $_.TrimEnd("`r")) }
  } catch { Write-Output ("-- --diagnose failed: " + $_.Exception.Message) }
}

# --- launch -----------------------------------------------------------------

$psi = New-Object Diagnostics.ProcessStartInfo
$psi.FileName = $Exe
$psi.UseShellExecute = $false
$psi.EnvironmentVariables['SPDF_WIN_SETUP_NO_PROMPT'] = '1'
$psi.Arguments = ('--state-dir "{0}" "{1}"' -f $StateDir, $Pdf)
$proc = [Diagnostics.Process]::Start($psi)
$hwnd = [IntPtr]::Zero
try {
  $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
  while ([DateTime]::UtcNow -lt $deadline) {
    if ($proc.HasExited) { Write-Output ("error=exited-before-window rc=" + $proc.ExitCode); exit 65 }
    $h = [SpdfInput]::MainWindow([uint32]$proc.Id)
    if ($h -ne [IntPtr]::Zero) { $hwnd = $h; break }
    Start-Sleep -Milliseconds 25
  }
  if ($hwnd -eq [IntPtr]::Zero) { Write-Output "error=no-window"; exit 66 }

  # THE FOREGROUND IS ASKED FOR IMMEDIATELY, BEFORE THE 1 s LINE IS WRITTEN.
  # Windows grants the foreground to a process launched BY the foreground
  # process, and this harness -- a shell under an editor -- never is one, so the
  # app's own SetForegroundWindow is correctly refused and it flashes its taskbar
  # button instead (measure-launch.ps1 measures 0/5 here against 5/5 for a hand
  # launch, and reports foreground without judging it). Asking on its behalf here
  # turns the 1 s line's fg= and zindex= into an assertion worth making: not
  # "was the app granted the foreground", which is the system's decision, but
  # "given it, does the window HOLD it and stay on top" -- which is precisely
  # what the field report said it did not.
  if (-not [SpdfInput]::Raise($hwnd)) {
    Write-Output "error=not-foreground (refusing to send input into another application's window)"
    [SpdfInput]::Close($hwnd); exit 68
  }
  Start-Sleep -Milliseconds $WaitMs

  $cr = New-Object SpdfInput+RECT; [void][SpdfInput]::GetClientRect($hwnd, [ref]$cr)
  $o = New-Object SpdfInput+POINT; [void][SpdfInput]::ClientToScreen($hwnd, [ref]$o)
  $dpi = [SpdfInput]::GetDpiForWindow($hwnd); if ($dpi -le 0) { $dpi = 96 }
  $scale = $dpi / 96.0
  Write-Output ("window hwnd={0} client={1}x{2} origin={3},{4} dpi={5} scale={6:n3}" -f $hwnd, $cr.R, $cr.B, $o.X, $o.Y, $dpi, $scale)

  # WHERE THE BUTTONS ARE, ASKED OF THE APP (spdf_win_layout_print.h).
  #
  # THROUGH AN EXPLICITLY REDIRECTED PIPE, not `& $Exe ... 2>&1`. ShenzhenPDF.exe
  # is /SUBSYSTEM:WINDOWS and therefore has no console of its own: what it writes
  # goes to whatever standard output handle it INHERITED, and a nested
  # `powershell -File` does not reliably give a native child one (measured: the
  # same call captures 1184 characters from an interactive prompt and 0 from
  # inside a script). RedirectStandardOutput hands it a real pipe, which is the
  # one arrangement that works everywhere.
  $layout = @{}
  $lpsi = New-Object Diagnostics.ProcessStartInfo
  $lpsi.FileName = $Exe
  $lpsi.Arguments = ('--print-layout {0} {1} {2}' -f $cr.R, $cr.B,
                     [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.0000}', $scale))
  $lpsi.UseShellExecute = $false
  $lpsi.RedirectStandardOutput = $true
  $lproc = [Diagnostics.Process]::Start($lpsi)
  $layoutText = $lproc.StandardOutput.ReadToEnd()
  $lproc.WaitForExit()
  foreach ($line in $layoutText.Split("`n")) {
    $line = $line.TrimEnd("`r")
    if ($line -match '^(item|action|band)\s+(\S+)\s+(-?\d+)\s+(-?\d+)\s+(\d+)\s+(\d+)$') {
      $layout[$Matches[1] + ':' + $Matches[2]] = @{ x = [int]$Matches[3]; y = [int]$Matches[4]; w = [int]$Matches[5]; h = [int]$Matches[6] }
    }
  }
  if (-not $layout.ContainsKey('action:next-page')) {
    Write-Output "error=no-layout (--print-layout printed no next-page action)"
    Write-Output $layoutText
    [SpdfInput]::Close($hwnd); exit 1
  }
  $btn = $layout['action:next-page']
  $bx = $o.X + $btn.x + [int]($btn.w / 2)
  $by = $o.Y + $btn.y + [int]($btn.h / 2)
  Write-Output ("next-page button: client {0},{1} {2}x{3} -> screen {4},{5}" -f $btn.x, $btn.y, $btn.w, $btn.h, $bx, $by)

  # --- drive ----------------------------------------------------------------

  # PARK THE POINTER OVER THE CANVAS BEFORE ANYTHING ELSE. Left where the last
  # run put it, the cursor can sit over the tab strip, which arms the strip's
  # hover preview -- an owned, always-on-top window of this same process. A
  # click aimed at the toolbar then lands on the tooltip, which swallows it,
  # and the case fails for a reason that has nothing to do with the app's input
  # handling. (Observed: the runs that failed this way are exactly the ones
  # whose 1 s line says owned=1.) The canvas has no hover chrome.
  [void][SpdfInput]::SetCursorPos($o.X + [int]($cr.R / 2), $o.Y + [int]($cr.B * 3 / 4))
  Start-Sleep -Milliseconds 200

  $prev = [SpdfInput]::Capture($hwnd)
  if ($prev -eq $null) { Write-Output "error=no-capture"; [SpdfInput]::Close($hwnd); exit 68 }
  $prev.Save((Join-Path $OutDir '00-initial.png'))
  $step = 1
  $blocked = ''
  function Step($name, $floor, $act) {
    if ($script:blocked) { return }
    # BEFORE EVERY ACTION, not just before the first. Another application can
    # take the foreground at any moment (a notification, a build finishing, the
    # editor this harness runs under), and from then on every keystroke this
    # script sends lands in ITS window. That is not a failure of the app and it
    # must never be typed anyway: the run stops and reports BLOCKED.
    if (-not [SpdfInput]::Raise($hwnd)) {
      $script:blocked = "the app lost the foreground before $name"
      return
    }
    if (-not $script:proc.HasExited -and -not [SpdfInput]::OwnsPoint([uint32]$script:proc.Id, $script:bx, $script:by)) {
      $script:blocked = "another window is drawn over the app's toolbar before $name"
      return
    }
    $sent = & $act
    Start-Sleep -Milliseconds $SettleMs
    $cur = [SpdfInput]::Capture($hwnd)
    $pct = [SpdfInput]::DiffPct($script:prev, $cur)
    if ($cur -ne $null) { $cur.Save((Join-Path $OutDir ("{0:d2}-{1}.png" -f $script:step, $name))) }
    Write-Output ("{0:d2} {1,-16} {2,-30} changed={3:n2}% floor={4:n2}%" -f $script:step, $name, $sent, $pct, $floor)
    if ($floor -gt 0 -and $pct -lt $floor) {
      Fail ("{0}: the window did not repaint ({1:n2}% of pixels changed, need > {2:n2}%)" -f $name, $pct, $floor)
    }
    # A step with no floor is an observation, not an assertion, and it does NOT
    # become the next baseline: the assertion that follows is then about the
    # whole sequence rather than about its last keystroke alone.
    if ($floor -gt 0 -and $cur -ne $null) { $script:prev = $cur }
    $script:step++
  }
  # THE TWO FLOORS. A page turn and a PageDown redraw the canvas, which is most
  # of the window, so 1% is a floor nothing but a real repaint clears. Ctrl+F on
  # its own may only light the search field and its caret -- a few thousand
  # pixels in a two-megapixel window -- so it is recorded and not judged, and
  # the assertion is on the pair (Ctrl+F then a query typed into it), which also
  # moves the match counter and the sidebar's Search section. $MinFindPct is
  # still an order of magnitude above capture noise.
  $MinFindPct = 0.1
  Step 'pagedown'        $MinChangedPct { [SpdfInput]::Key(0x22, $false) }
  Step 'click-next-page' $MinChangedPct { [SpdfInput]::Click($bx, $by) }
  Step 'ctrl-f'          0              { [SpdfInput]::Key(0x46, $true) }
  Step 'ctrl-f-type-the' $MinFindPct    { [SpdfInput]::Text('the') }

  if ($proc.HasExited) {
    Write-Output ("error=exited-during-input rc=" + $proc.ExitCode)
    exit 1
  }
  if ($blocked) {
    Write-Output ("error=lost-the-desktop ({0}); refusing to send input into another application's window" -f $blocked)
    [SpdfInput]::Close($hwnd)
    exit 68
  }

  # --- what the app says about itself ---------------------------------------

  # The 5 s line is written by a timer 5 s after the window was shown; the
  # driving above takes about that long, so wait for it rather than assume.
  $log = Join-Path $StateDir 'launch-health.log'
  $wait = [DateTime]::UtcNow.AddSeconds(12)
  $lines = @()
  while ([DateTime]::UtcNow -lt $wait) {
    if (Test-Path -LiteralPath $log) {
      $lines = @(Get-Content -LiteralPath $log)
      if (@($lines | Where-Object { $_ -match ' phase=5s ' }).Count -gt 0) { break }
    }
    Start-Sleep -Milliseconds 250
  }
  Write-Output "-- launch-health.log --"
  $lines | ForEach-Object { Write-Output ("   " + $_) }

  $one = @($lines | Where-Object { $_ -match ' phase=1s ' }) | Select-Object -First 1
  if (-not $one) {
    Fail "the app wrote no 1 s line to $log"
  } else {
    foreach ($want in @('fg=1', 'enabled=1', 'visible=1', 'iconic=0', 'hung=0', 'zindex=0', 'onscreen=1', 'modal=0')) {
      if ($one -notmatch [regex]::Escape(' ' + $want + ' ')) { Fail ("1 s line does not say $want" ) }
    }
    if ($one -match ' monitor=(\S+) ') {
      if ($Matches[1] -eq 'none') { Fail "1 s line found no monitor for the window" }
    } else { Fail "1 s line has no monitor field" }
  }

  $counterRe = ' msg=lbdown:(\d+),keydown:(\d+),char:(\d+),mousemove:(\d+),wheel:(\d+),activate:(\d+),setfocus:(\d+),killfocus:(\d+) '
  function Counters($line) {
    if (-not $line -or $line -notmatch $counterRe) { return $null }
    return @{ lbdown = [int]$Matches[1]; keydown = [int]$Matches[2]; char = [int]$Matches[3]; mousemove = [int]$Matches[4] }
  }
  $five = @($lines | Where-Object { $_ -match ' phase=5s ' }) | Select-Object -First 1
  $counts = Counters $five
  if (-not $five) {
    Fail "the app wrote no 5 s line to $log (the UI thread's timer never fired)"
  } elseif (-not $counts) {
    Fail "the 5 s line has no msg= counters"
  } else {
    Write-Output ("counters at 5 s: lbdown={0} keydown={1} char={2} mousemove={3}" -f $counts.lbdown, $counts.keydown, $counts.char, $counts.mousemove)
    # THE ONE RACE THIS TEST CANNOT DESIGN AWAY. The 5 s line is written by a
    # timer, not by us, so on a slow machine the last keystroke can land just
    # after it. That is a scheduling accident and not a defect, so the 30 s line
    # -- which the app writes anyway -- settles it rather than a red result.
    if ($counts.char -le 0) {
      Write-Output "   (no WM_CHAR by the 5 s line; waiting for the 30 s line to settle it)"
      $wait = [DateTime]::UtcNow.AddSeconds(32)
      while ([DateTime]::UtcNow -lt $wait) {
        $lines = @(Get-Content -LiteralPath $log)
        $late = @($lines | Where-Object { $_ -match ' phase=30s ' }) | Select-Object -First 1
        if ($late) { $counts = Counters $late; Write-Output ("   counters at 30 s: char=" + $counts.char); break }
        Start-Sleep -Milliseconds 500
      }
    }
    foreach ($k in @('lbdown', 'keydown', 'char', 'mousemove')) {
      if ($counts[$k] -le 0) { Fail ("the app counted no $k message -- that input never reached the window") }
    }
    if ($five -match ' paints=(\d+) ' -and [int]$Matches[1] -le 0) { Fail "the app completed no paint by 5 s" }
  }

  if (@($lines | Where-Object { $_ -match ' phase=stall ' }).Count -gt 0) {
    Fail "the watchdog recorded a stall: the UI thread stopped pumping for more than 3 s"
  }

  # WHILE THE WINDOW IS STILL UP. Anything that goes wrong here is something
  # nobody has yet reproduced twice, so the evidence is collected now rather
  # than inferred later from an exit code.
  if ($fails.Count -gt 0) {
    Write-Output ("process alive=" + (-not $proc.HasExited) + " responding=" + $(if ($proc.HasExited) { 'n/a' } else { $proc.Responding }))
    Diagnose $Exe $StateDir
  }
} finally {
  if ($hwnd -ne [IntPtr]::Zero) { [SpdfInput]::Close($hwnd) }
  if (-not $proc.WaitForExit(5000)) { try { $proc.Kill() } catch {} }
}

if ($fails.Count -gt 0) { Write-Output ("health=FAIL " + $fails.Count + " assertion(s)"); exit 1 }
Write-Output "health=OK the window answered every action and its own log agrees"
exit 0
