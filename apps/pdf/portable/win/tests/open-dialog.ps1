param(
  [Parameter(Mandatory = $true)][string]$Exe,
  [Parameter(Mandatory = $true)][string]$StateDir,
  [Parameter(Mandatory = $true)][string]$OutDir,
  [string]$Pdf = "",
  [int]$SettleMs = 3000
)
# open-dialog.ps1 -- DOES THE OPEN DIALOG ACTUALLY HAVE ANYTHING IN IT?
#
# WHY THIS CASE EXISTS. "When you click open pdf, then everything freezes."
# Measured: the shell's Open dialog came up with its title bar and its dark
# navigation pane painted and EVERYTHING ELSE a white rectangle -- the file list,
# the File name box, the file-type combo, the Open and Cancel buttons -- and
# stayed that way. Nothing already in the suite could see it: the window was
# there, the process answered SendMessageTimeout in 0 ms, IsHungAppWindow was
# false, and launch.health only ever looks at a launch with no dialog in it. The
# cause was a WM_MOUSELEAVE loop in this app's own window proc that starved
# WM_PAINT (portable/docs/windows-native-observations.md, section 20), so the
# only honest witness is the dialog's own pixels.
#
# WHAT IT ASSERTS, in the order it can fail:
#
#   1. a bare launch shows the empty state with its accent "Open a PDF..."
#      button. The button is found BY COLOUR -- the only accent capsule on an
#      empty dark canvas -- so a changed layout constant cannot make the case
#      click somewhere harmless and pass;
#   2. clicking it brings up a `#32770` in THIS process;
#   3. after $SettleMs its CLIENT area has CONTENT: enough distinct colours and
#      little enough flat white, measured over the whole client and again over
#      the bottom band on its own, because the bottom band (the File name row and
#      the two buttons) is where the defect was most visible and it is only 15% of
#      the pixels, so a whole-client threshold alone could pass with it blank.
#      This is the same shape of assertion screenshot-window.ps1 uses for
#      "capture-not-composited";
#   4. the process is not SPINNING: the CPU it burns while the dialog just sits
#      there is a small fraction of wall-clock time. The defect ran the UI thread
#      flat out, which is what starved the paint, so this is the cause measured
#      directly rather than only its symptom;
#   5. and, when -Pdf names a file, the whole flow END TO END: the path is typed
#      into the dialog, Enter opens it, and the window's title and pixels change.
#
# BLOCKED (68), NOT FAILED, when the desktop cannot be used: this drives real
# SendInput at a real window and captures the screen, so a locked workstation,
# the screen saver's desktop or a session that refuses our window the foreground
# all mean the question cannot be asked. 65 = no window, 66 = no accent button,
# 67 = no dialog.
#
# It closes only the process it started, by the handle Start-Process gave it.

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Drawing

. (Join-Path $PSScriptRoot '..\desktop-available.ps1')
$reason = Spdf-DesktopUnavailable
if ($reason) {
  Write-Output "error=desktop-unavailable detail=$reason"
  exit 68
}

# A private state directory is not optional: the app writes settings, session and
# launch-health.log there, and the reader's own must never be what a test drives.
if ($StateDir -notmatch 'spdf|test|scratch|Temp') {
  Write-Output "error=state-dir-refused detail=$StateDir does not look like a scratch directory"
  exit 64
}
New-Item -ItemType Directory -Force $StateDir | Out-Null
New-Item -ItemType Directory -Force $OutDir | Out-Null

Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @"
using System; using System.Text; using System.Runtime.InteropServices; using System.Collections.Generic; using System.Drawing;
public class OD {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct PT { public int X, Y; }
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr c);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr p);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref PT p);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint from, uint to, bool attach);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", SetLastError=true)] static extern uint SendInput(uint n, INPUT[] i, int sz);
  [StructLayout(LayoutKind.Sequential)] public struct MI { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr extra; }
  [StructLayout(LayoutKind.Sequential)] public struct KI { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr extra; }
  [StructLayout(LayoutKind.Explicit)] public struct U { [FieldOffset(0)] public MI mi; [FieldOffset(0)] public KI ki; }
  [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public U u; }

  // ASK FOR THE FOREGROUND ON THE APP'S BEHALF, the same way
  // launch-health.ps1's Raise() does and for the same reason: Windows grants
  // SetForegroundWindow only to a process that already owns the foreground, and
  // this harness runs under a shell under an editor, so it never does.
  // Attaching to the current foreground thread's input queue is the documented
  // way a tool asks anyway; when even that is refused the caller must NOT send
  // input, because it would land in whatever window is actually in front.
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

  public static List<IntPtr> W(uint pid) { var l = new List<IntPtr>(); EnumWindows(delegate(IntPtr h, IntPtr p) { uint o; GetWindowThreadProcessId(h, out o); if (o == pid) l.Add(h); return true; }, IntPtr.Zero); return l; }
  public static string Cls(IntPtr h) { var s = new StringBuilder(256); GetClassNameW(h, s, 256); return s.ToString(); }
  public static string Ttl(IntPtr h) { var s = new StringBuilder(512); GetWindowTextW(h, s, 512); return s.ToString(); }
  public static void Click(int x, int y) { SetCursorPos(x, y); System.Threading.Thread.Sleep(120); var a = new INPUT[2]; a[0].type = 0; a[0].u.mi.dwFlags = 0x0002; a[1].type = 0; a[1].u.mi.dwFlags = 0x0004; SendInput(2, a, Marshal.SizeOf(typeof(INPUT))); }
  public static void Tap(ushort vk) { var a = new INPUT[2]; a[0].type = 1; a[0].u.ki.wVk = vk; a[1] = a[0]; a[1].u.ki.dwFlags = 2; SendInput(2, a, Marshal.SizeOf(typeof(INPUT))); }
  public static void TypeText(string s) {
    foreach (char c in s) {
      var a = new INPUT[2];
      a[0].type = 1; a[0].u.ki.wScan = (ushort)c; a[0].u.ki.dwFlags = 4 /* KEYEVENTF_UNICODE */;
      a[1] = a[0]; a[1].u.ki.dwFlags = 4 | 2;
      SendInput(2, a, Marshal.SizeOf(typeof(INPUT)));
      System.Threading.Thread.Sleep(6);
    }
  }

  static Bitmap ShotWindow(IntPtr h) { RECT r; if (!GetWindowRect(h, out r)) return null; int w = r.R - r.L, ht = r.B - r.T; if (w < 1 || ht < 1) return null; var b = new Bitmap(w, ht); using (var g = Graphics.FromImage(b)) g.CopyFromScreen(r.L, r.T, 0, 0, new Size(w, ht)); return b; }
  static Bitmap ShotClient(IntPtr h) { RECT c; if (!GetClientRect(h, out c)) return null; PT o = new PT(); if (!ClientToScreen(h, ref o)) return null; int w = c.R - c.L, ht = c.B - c.T; if (w < 40 || ht < 40) return null; var b = new Bitmap(w, ht); using (var g = Graphics.FromImage(b)) g.CopyFromScreen(o.X, o.Y, 0, 0, new Size(w, ht)); return b; }
  public static bool SaveWindow(IntPtr h, string path) { Bitmap b = ShotWindow(h); if (b == null) return false; b.Save(path); return true; }

  // distinct colours and near-white percentage over a horizontal band of the
  // client area, given as fractions of its height. -1,-1 when it cannot capture.
  public static int[] Band(IntPtr h, double from, double to) {
    Bitmap b = ShotClient(h); if (b == null) return new int[]{-1,-1};
    int y0 = (int)(b.Height * from), y1 = (int)(b.Height * to);
    if (y1 - y0 < 4) return new int[]{-1,-1};
    var seen = new HashSet<int>(); long white = 0, total = 0;
    var ra = b.LockBits(new Rectangle(0, 0, b.Width, b.Height), System.Drawing.Imaging.ImageLockMode.ReadOnly, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
    var row = new int[b.Width];
    for (int y = y0; y < y1; y += 2) {
      Marshal.Copy(new IntPtr(ra.Scan0.ToInt64() + (long)y * ra.Stride), row, 0, b.Width);
      for (int x = 0; x < b.Width; x += 2) {
        int p = row[x]; seen.Add(p); total++;
        int r = (p >> 16) & 0xff, g = (p >> 8) & 0xff, bl = p & 0xff;
        if (r > 245 && g > 245 && bl > 245) white++;
      }
    }
    b.UnlockBits(ra);
    return new int[]{ seen.Count, (int)(100 * white / total) };
  }

  // The accent capsule's centroid in WINDOW coordinates, or -1,-1: the only
  // accent blue on an empty dark canvas, so it cannot drift with a constant.
  public static int[] AccentOf(IntPtr h) {
    Bitmap b = ShotWindow(h); if (b == null) return new int[]{-1,-1};
    long sx = 0, sy = 0, n = 0;
    var ra = b.LockBits(new Rectangle(0, 0, b.Width, b.Height), System.Drawing.Imaging.ImageLockMode.ReadOnly, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
    var row = new int[b.Width];
    for (int y = 0; y < b.Height; y++) {
      Marshal.Copy(new IntPtr(ra.Scan0.ToInt64() + (long)y * ra.Stride), row, 0, b.Width);
      for (int x = 0; x < b.Width; x++) { int p = row[x]; int r = (p >> 16) & 0xff, g = (p >> 8) & 0xff, bl = p & 0xff; if (bl > 190 && g > 140 && r < 150 && bl > r + 60) { sx += x; sy += y; n++; } }
    }
    b.UnlockBits(ra);
    if (n < 200) return new int[]{-1,-1};
    return new int[]{(int)(sx / n), (int)(sy / n)};
  }

  // How many pixels of a window's capture differ from an earlier one, as a
  // percentage -- the same "did anything change?" measure launch-health.ps1 uses.
  public static int Differs(IntPtr h, string before, string after) {
    Bitmap a = ShotWindow(h); if (a == null) return -1;
    if (after != "") a.Save(after);
    if (before == "" || !System.IO.File.Exists(before)) return -1;
    using (Bitmap b0 = new Bitmap(before)) {
      if (b0.Width != a.Width || b0.Height != a.Height) return 100;
      long diff = 0, total = 0;
      for (int y = 0; y < a.Height; y += 4) for (int x = 0; x < a.Width; x += 4) { total++; if (a.GetPixel(x, y).ToArgb() != b0.GetPixel(x, y).ToArgb()) diff++; }
      return total == 0 ? -1 : (int)(100 * diff / total);
    }
  }
}
"@

# PerMonitorV2 in THIS process too, or every rect we read is scaled and the click
# lands somewhere else on a 150% display.
[void][OD]::SetProcessDpiAwarenessContext([IntPtr](-4))

$fail = 0
function Check($name, $ok, $detail) {
  if ($ok) { Write-Output ("ok   $name  $detail") } else { Write-Output ("FAIL $name  $detail"); $script:fail = 1 }
}

$env:SPDF_WIN_SETUP_NO_PROMPT = '1'
$proc = Start-Process -FilePath $Exe -ArgumentList @('--state-dir', $StateDir) -PassThru
$code = 0
try {
  Start-Sleep -Seconds 5
  $proc.Refresh()
  if ($proc.HasExited) { Write-Output ("error=exited detail=rc=" + $proc.ExitCode); exit 65 }
  $main = [IntPtr]::Zero
  foreach ($h in [OD]::W([uint32]$proc.Id)) { if ([OD]::IsWindowVisible($h) -and [OD]::Cls($h) -eq 'ShenzhenPDFWindow') { $main = $h } }
  if ($main -eq [IntPtr]::Zero) { Write-Output 'error=no-window'; exit 65 }
  if (-not [OD]::Raise($main)) {
    Write-Output 'error=desktop-unavailable detail=the desktop refused the launched window the foreground (refusing to send input into another application''s window)'
    exit 68
  }
  Start-Sleep -Milliseconds 700
  [void][OD]::SaveWindow($main, (Join-Path $OutDir 'empty-state.png'))

  $c = [OD]::AccentOf($main)
  if ($c[0] -lt 0) { Write-Output 'error=no-accent-button detail=no accent capsule in the empty state capture'; exit 66 }
  $wr = New-Object OD+RECT; [void][OD]::GetWindowRect($main, [ref]$wr)
  Write-Output ("01 clicking the accent button at window " + $c[0] + "," + $c[1])
  [OD]::Click(($wr.L + $c[0]), ($wr.T + $c[1]))

  # The dialog, then time to settle: the shell lays the item dialog out in
  # several passes and a measurement taken mid-layout says nothing.
  $dlg = [IntPtr]::Zero
  $waited = 0
  while ($waited -lt 8000 -and $dlg -eq [IntPtr]::Zero) {
    Start-Sleep -Milliseconds 250; $waited += 250
    foreach ($h in [OD]::W([uint32]$proc.Id)) { if ([OD]::IsWindowVisible($h) -and [OD]::Cls($h) -eq '#32770') { $dlg = $h } }
  }
  if ($dlg -eq [IntPtr]::Zero) { Write-Output 'error=no-dialog detail=no #32770 appeared within 8 s of the click'; exit 67 }
  Start-Sleep -Milliseconds $SettleMs
  [void][OD]::SaveWindow($dlg, (Join-Path $OutDir 'open-dialog.png'))

  # 3. CONTENT. Whole client, then the bottom band on its own.
  $all = [OD]::Band($dlg, 0.0, 1.0)
  $bottom = [OD]::Band($dlg, 0.85, 1.0)
  Write-Output ("02 dialog '" + [OD]::Ttl($dlg) + "' client distinct=" + $all[0] + " near_white=" + $all[1] + "%; bottom band distinct=" + $bottom[0] + " near_white=" + $bottom[1] + "%")
  Check 'dialog.client-has-content' ($all[0] -ge 100 -and $all[1] -le 20) ("distinct=" + $all[0] + " (want >= 100), near_white=" + $all[1] + "% (want <= 20)")
  Check 'dialog.bottom-band-has-content' ($bottom[0] -ge 20 -and $bottom[1] -le 40) ("distinct=" + $bottom[0] + " (want >= 20), near_white=" + $bottom[1] + "% (want <= 40)")

  # 4. NOT SPINNING. The UI thread ran flat out in the defect; with the dialog
  # merely sitting there the process should be all but idle.
  $proc.Refresh(); $cpu0 = $proc.TotalProcessorTime
  $sw = [Diagnostics.Stopwatch]::StartNew()
  Start-Sleep -Milliseconds 1500
  $sw.Stop(); $proc.Refresh()
  $cpuMs = [int](($proc.TotalProcessorTime - $cpu0).TotalMilliseconds)
  $wallMs = [int]$sw.Elapsed.TotalMilliseconds
  Write-Output ("03 cpu while the dialog sits idle: " + $cpuMs + " ms over " + $wallMs + " ms of wall clock")
  Check 'dialog.not-spinning' ($cpuMs -lt ($wallMs / 4)) ("cpu=" + $cpuMs + " ms (want < " + [int]($wallMs / 4) + ")")

  # 5. END TO END.
  if ($Pdf -ne "" -and (Test-Path $Pdf)) {
    $titleBefore = [OD]::Ttl($main)
    [void][OD]::SaveWindow($main, (Join-Path $OutDir 'before-open.png'))
    [OD]::TypeText((Resolve-Path $Pdf).Path)
    Start-Sleep -Milliseconds 400
    [OD]::Tap(0x0D)  # Enter
    Start-Sleep -Seconds 4
    $gone = $true
    foreach ($h in [OD]::W([uint32]$proc.Id)) { if ([OD]::IsWindowVisible($h) -and [OD]::Cls($h) -eq '#32770') { $gone = $false } }
    $titleAfter = [OD]::Ttl($main)
    $changed = [OD]::Differs($main, (Join-Path $OutDir 'before-open.png'), (Join-Path $OutDir 'after-open.png'))
    Write-Output ("04 dialog_closed=" + $gone + " title '" + $titleBefore + "' -> '" + $titleAfter + "' pixels changed=" + $changed + "%")
    Check 'dialog.opens-the-document' ($gone -and $titleAfter -ne $titleBefore -and $changed -ge 5) ("closed=" + $gone + " title_changed=" + ($titleAfter -ne $titleBefore) + " changed=" + $changed + "%")
  } else {
    Write-Output "04 skipped: no -Pdf given"
    if ($dlg -ne [IntPtr]::Zero) { [void][OD]::PostMessageW($dlg, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) }
  }

  $log = Join-Path $StateDir 'launch-health.log'
  if (Test-Path $log) {
    $stalls = @(Select-String -Path $log -Pattern 'phase=stall' -SimpleMatch).Count
    $modals = @(Select-String -Path $log -Pattern 'phase=modal' -SimpleMatch).Count
    Write-Output ("05 launch-health.log: stall lines=" + $stalls + " modal lines=" + $modals)
    Check 'dialog.no-false-stall' ($stalls -eq 0) ("a modal dialog must be logged as phase=modal, not phase=stall (stall=" + $stalls + ", modal=" + $modals + ")")
  }
  $code = $fail
} finally {
  $proc.Refresh()
  if (-not $proc.HasExited) { $proc.CloseMainWindow() | Out-Null; Start-Sleep -Seconds 2; $proc.Refresh() }
  if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
}
exit $code
