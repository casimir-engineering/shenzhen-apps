<#
  Scratch harness: launch ShenzhenPDF, POST synthetic mouse messages at given
  CLIENT coordinates, capture a PNG after each step, close the app.

  PostMessage rather than SendInput deliberately: the user is sitting at this
  machine, and SendInput would move their real cursor. PostMessage delivers
  WM_LBUTTONDOWN/UP/WM_MOUSEMOVE to the window's own queue with the coordinates
  we choose and touches nothing else on the desktop.

  Steps are strings:  move:X,Y | click:X,Y | mclick:X,Y | rclick:X,Y | drag:X1,Y1>X2,Y2 | shot:NAME
                      key:VK (a virtual-key code, e.g. key:27 for Escape, key:116 for F5)
                      cmd:ID (a spdf_win_command id, posted as the menu's WM_COMMAND)
                      sleep:MS | alive (prints alive=True/False without failing)
                      rect (prints window=X,Y,WxH: the outer frame, screen pixels)

  KEYS ARE POSTED UNMODIFIED. A WM_KEYDOWN carries no modifier state -- the app
  reads GetKeyState(VK_CONTROL), the REAL keyboard -- so Ctrl+W cannot be posted
  without pressing the user's Ctrl key, which SendInput would do and this script
  never will. Post the COMMAND instead (cmd:3 is Close Tab); it takes the same
  route an accelerator takes after the keymap has resolved it.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Exe,
  # Optional since the app launches bare (restoring its session, or opening an
  # empty window): an empty -Pdf launches it that way.
  [string]$Pdf = '',
  [Parameter(Mandatory=$true)][string]$OutDir,
  [string[]]$AppArgs = @(),
  [Parameter(Mandatory=$true)][string[]]$Steps,
  [int]$Width = 1120,
  [int]$Height = 800,
  [int]$SettleMs = 900,
  # Leave the window where the app put it, instead of moving it to 80,80 at
  # Width x Height: what a check of the session's restored frame needs.
  [switch]$NoMove
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

if (-not ('SpdfDrive' -as [type])) {
  Add-Type -Language CSharp -ReferencedAssemblies 'System.Drawing' -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public static class SpdfDrive {
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr c);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint f);
    [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int t, bool r);
    [DllImport("user32.dll")] public static extern IntPtr GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

    public static bool Dpi() { try { return SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch { return false; } }

    public static IntPtr Find(uint[] pids) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr p) {
            if (!IsWindowVisible(h)) return true;
            uint pid; GetWindowThreadProcessId(h, out pid);
            for (int i = 0; i < pids.Length; i++) if (pids[i] == pid) {
                RECT r;
                if (GetWindowRect(h, out r) && (r.Right-r.Left) > 32 && (r.Bottom-r.Top) > 32) { found = h; return false; }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    static IntPtr LP(int x, int y) { return new IntPtr((y << 16) | (x & 0xFFFF)); }
    const uint WM_MOUSEMOVE = 0x0200, WM_LBUTTONDOWN = 0x0201, WM_LBUTTONUP = 0x0202;
    const uint WM_MBUTTONDOWN = 0x0207, WM_MBUTTONUP = 0x0208;
    const int MK_LBUTTON = 0x0001, MK_MBUTTON = 0x0010;

    public static void Move(IntPtr h, int x, int y, int keys) { PostMessageW(h, WM_MOUSEMOVE, new IntPtr(keys), LP(x,y)); }
    public static void Click(IntPtr h, int x, int y) {
        PostMessageW(h, WM_MOUSEMOVE, IntPtr.Zero, LP(x,y));
        PostMessageW(h, WM_LBUTTONDOWN, new IntPtr(MK_LBUTTON), LP(x,y));
        PostMessageW(h, WM_LBUTTONUP, IntPtr.Zero, LP(x,y));
    }
    public static void MClick(IntPtr h, int x, int y) {
        PostMessageW(h, WM_MOUSEMOVE, IntPtr.Zero, LP(x,y));
        PostMessageW(h, WM_MBUTTONDOWN, new IntPtr(MK_MBUTTON), LP(x,y));
        PostMessageW(h, WM_MBUTTONUP, IntPtr.Zero, LP(x,y));
    }
    const uint WM_RBUTTONDOWN = 0x0204, WM_RBUTTONUP = 0x0205, WM_KEYDOWN = 0x0100, WM_KEYUP = 0x0101, WM_COMMAND = 0x0111;
    const int MK_RBUTTON = 0x0002;
    public static void RClick(IntPtr h, int x, int y) {
        PostMessageW(h, WM_MOUSEMOVE, IntPtr.Zero, LP(x,y));
        PostMessageW(h, WM_RBUTTONDOWN, new IntPtr(MK_RBUTTON), LP(x,y));
        PostMessageW(h, WM_RBUTTONUP, IntPtr.Zero, LP(x,y));
    }
    public static void Key(IntPtr h, int vk) {
        PostMessageW(h, WM_KEYDOWN, new IntPtr(vk), IntPtr.Zero);
        PostMessageW(h, WM_KEYUP, new IntPtr(vk), new IntPtr(unchecked((int)0xC0000000)));
    }
    // SPDF_WIN_MENU_ID_BASE (spdf_win_menu.h) + the command, lParam 0: exactly the
    // message a menu pick produces, which the window turns into SPDF_WIN_INPUT_COMMAND.
    public static void Command(IntPtr h, int id) { PostMessageW(h, WM_COMMAND, new IntPtr(0x400 + id), IntPtr.Zero); }
    // WM_MOUSEWHEEL carries SCREEN coordinates, so the client point is converted
    // here -- the same conversion spdf_win_window.cpp's on_wheel does.
    public static void Wheel(IntPtr h, int x, int y, int notches, bool ctrl) {
        POINT p = new POINT(); p.X = x; p.Y = y; ClientToScreen(h, ref p);
        int keys = ctrl ? 0x0008 : 0;
        IntPtr w = new IntPtr((notches * 120) << 16 | keys);
        PostMessageW(h, 0x020A, w, new IntPtr((p.Y << 16) | (p.X & 0xFFFF)));
    }

    public static void Drag(IntPtr h, int x1, int y1, int x2, int y2) {
        PostMessageW(h, WM_MOUSEMOVE, IntPtr.Zero, LP(x1,y1));
        PostMessageW(h, WM_LBUTTONDOWN, new IntPtr(MK_LBUTTON), LP(x1,y1));
        for (int i = 1; i <= 8; i++) {
            int x = x1 + (x2-x1)*i/8, y = y1 + (y2-y1)*i/8;
            PostMessageW(h, WM_MOUSEMOVE, new IntPtr(MK_LBUTTON), LP(x,y));
        }
        PostMessageW(h, WM_LBUTTONUP, IntPtr.Zero, LP(x2,y2));
    }

    public static string Capture(IntPtr hwnd, string path) {
        RECT wr; if (!GetWindowRect(hwnd, out wr)) return "GetWindowRect failed";
        int w = wr.Right-wr.Left, h = wr.Bottom-wr.Top;
        if (w <= 0 || h <= 0) return "empty rect";
        using (Bitmap b = new Bitmap(w, h, PixelFormat.Format32bppArgb))
        using (Graphics g = Graphics.FromImage(b)) {
            IntPtr dc = g.GetHdc(); bool ok;
            try { ok = PrintWindow(hwnd, dc, 2); } finally { g.ReleaseHdc(dc); }
            if (!ok) return "PrintWindow failed " + Marshal.GetLastWin32Error();
            b.Save(path, ImageFormat.Png);
        }
        return null;
    }
}
'@
}

Write-Output ("host_dpi_aware=" + [SpdfDrive]::Dpi())
$argList = @()
foreach ($a in @($AppArgs) + @($Pdf)) {
  if ($null -eq $a -or $a -eq '') { continue }
  if ($a -match '\s' -and $a -notmatch '^".*"$') { $argList += ('"' + $a + '"') } else { $argList += $a }
}
# NO FIRST-RUN DIALOG, whatever -AppArgs a caller passed. The "Install, or just
# run it?" question (spdf_win_setup.h) is MODAL and appears before the window,
# so without this the window poll below would wait 20 s for a window that is
# behind a dialog nobody is there to answer. Callers that pass --state-dir are
# already covered; this covers the ones that do not. Inherited by Start-Process.
$env:SPDF_WIN_SETUP_NO_PROMPT = '1'
$proc = Start-Process -FilePath $Exe -ArgumentList $argList -PassThru
$hwnd = [IntPtr]::Zero
$sw = [Diagnostics.Stopwatch]::StartNew()
try {
  while ($sw.ElapsedMilliseconds -lt 20000) {
    if ($proc.HasExited) { Write-Output "error=exited exitcode=$($proc.ExitCode)"; exit 65 }
    $pids = New-Object System.Collections.Generic.List[uint32]
    $pids.Add([uint32]$proc.Id)
    $h = [SpdfDrive]::Find($pids.ToArray())
    if ($h -ne [IntPtr]::Zero) { $hwnd = $h; break }
    Start-Sleep -Milliseconds 100
  }
  if ($hwnd -eq [IntPtr]::Zero) { Write-Output "error=no-window"; exit 66 }
  if (-not $NoMove) { [void][SpdfDrive]::MoveWindow($hwnd, 80, 80, $Width, $Height, $true) }
  Start-Sleep -Milliseconds 600
  $cr = New-Object SpdfDrive+RECT
  [void][SpdfDrive]::GetClientRect($hwnd, [ref]$cr)
  Write-Output ("dpi=" + [SpdfDrive]::GetDpiForWindow($hwnd))
  Write-Output ("client=" + ($cr.Right-$cr.Left) + "x" + ($cr.Bottom-$cr.Top))
  Start-Sleep -Milliseconds $SettleMs

  foreach ($s in $Steps) {
    if ($s -match '^shot:(.+)$') {
      Start-Sleep -Milliseconds $SettleMs
      $p = Join-Path $OutDir ($Matches[1] + '.png')
      $e = [SpdfDrive]::Capture($hwnd, $p)
      if ($e) { Write-Output ("error=capture detail=" + $e); exit 67 }
      Write-Output ("shot=" + $p)
      continue
    }
    if ($s -match '^click:(-?\d+),(-?\d+)$')  { [SpdfDrive]::Click($hwnd,  [int]$Matches[1], [int]$Matches[2]); Write-Output ("step=" + $s); Start-Sleep -Milliseconds 350; continue }
    if ($s -match '^mclick:(-?\d+),(-?\d+)$') { [SpdfDrive]::MClick($hwnd, [int]$Matches[1], [int]$Matches[2]); Write-Output ("step=" + $s); Start-Sleep -Milliseconds 350; continue }
    if ($s -match '^move:(-?\d+),(-?\d+)$')   { [SpdfDrive]::Move($hwnd,   [int]$Matches[1], [int]$Matches[2], 0); Write-Output ("step=" + $s); Start-Sleep -Milliseconds 250; continue }
    if ($s -match '^wheel:(-?\d+),(-?\d+),(-?\d+),(ctrl|plain)$') { [SpdfDrive]::Wheel($hwnd, [int]$Matches[1], [int]$Matches[2], [int]$Matches[3], ($Matches[4] -eq 'ctrl')); Write-Output ("step=" + $s); Start-Sleep -Milliseconds 400; continue }
    if ($s -match '^drag:(-?\d+),(-?\d+)>(-?\d+),(-?\d+)$') { [SpdfDrive]::Drag($hwnd, [int]$Matches[1], [int]$Matches[2], [int]$Matches[3], [int]$Matches[4]); Write-Output ("step=" + $s); Start-Sleep -Milliseconds 400; continue }
    if ($s -match '^rclick:(-?\d+),(-?\d+)$') { [SpdfDrive]::RClick($hwnd, [int]$Matches[1], [int]$Matches[2]); Write-Output ("step=" + $s); Start-Sleep -Milliseconds 350; continue }
    if ($s -match '^key:(\d+)$')             { [SpdfDrive]::Key($hwnd, [int]$Matches[1]); Write-Output ("step=" + $s); Start-Sleep -Milliseconds 400; continue }
    if ($s -match '^cmd:(\d+)$')             { [SpdfDrive]::Command($hwnd, [int]$Matches[1]); Write-Output ("step=" + $s); Start-Sleep -Milliseconds 600; continue }
    if ($s -match '^sleep:(\d+)$')           { Start-Sleep -Milliseconds ([int]$Matches[1]); Write-Output ("step=" + $s); continue }
    if ($s -eq 'alive') {
      # Whether the process is still there, and whether its window is: the two
      # differ while a WM_CLOSE is being processed. Never a failure by itself.
      $proc.Refresh()
      Write-Output ("alive=" + (-not $proc.HasExited) + " window=" + [SpdfDrive]::IsWindowVisible($hwnd))
      continue
    }
    if ($s -eq 'rect') {
      $wr = New-Object SpdfDrive+RECT
      [void][SpdfDrive]::GetWindowRect($hwnd, [ref]$wr)
      Write-Output ("window=" + $wr.Left + "," + $wr.Top + "," + ($wr.Right - $wr.Left) + "x" + ($wr.Bottom - $wr.Top))
      continue
    }
    Write-Output ("error=bad-step step=" + $s); exit 64
  }
  Write-Output "status=done"
  exit 0
}
finally {
  if ($proc -and -not $proc.HasExited) {
    [void]$proc.CloseMainWindow()
    if (-not $proc.WaitForExit(4000)) { $proc.Kill(); [void]$proc.WaitForExit(2000) }
  }
  if ($proc) { Write-Output ("app_exitcode=" + $proc.ExitCode) }
}
