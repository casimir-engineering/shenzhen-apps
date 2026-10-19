<#
.SYNOPSIS
  Drive ShenzhenPDF's MODAL windows -- task dialogs, message boxes, the
  annotation and Properties dialogs -- through UI Automation, and capture them.

.DESCRIPTION
  portable/win/drive-window.ps1 posts synthetic mouse and keyboard messages at
  client coordinates. That is the right tool for the app's own canvas and
  chrome, which it paints itself, and the wrong one for a MODAL DIALOG:

    - a TaskDialog's command links, a MessageBoxW's buttons and a dialog's edit
      fields are real child HWNDs whose positions this repo does not own, so
      clicking them by coordinate means hard-coding pixel offsets into a layout
      Windows is free to change with a font, a language or a DPI;
    - a modal dialog runs its OWN message loop, so the app's window stops
      answering and drive-window.ps1's "is it alive" checks stop meaning
      anything;
    - and PostMessage carries no modifier state, so a dialog that wants Alt+F
      cannot be driven that way at all.

  UI Automation asks the dialog what it contains and invokes the control by
  NAME, which is what portable/docs/windows-feature-matrix.md gap 16 ("modal
  windows verified live") needs: an assertion about "the button that says
  Install", not about the pixel it happens to occupy.

  IT NEVER MOVES THE USER'S CURSOR. UIA's InvokePattern and ValuePattern act on
  the control directly, exactly as PostMessage does and unlike SendInput, which
  would take over the mouse of the person sitting at this machine (agents.md).

  IT DOES NOT SUPPRESS THE FIRST-RUN QUESTION, and that is the one thing it
  does differently from drive-window.ps1, which sets SPDF_WIN_SETUP_NO_PROMPT
  for every launch. Here the modal dialog is the POINT, so the environment is
  left exactly as the caller set it. A caller that does not want the question
  must set SPDF_WIN_SETUP_NO_PROMPT (or pass --state-dir) itself --
  portable/win/src/spdf_win_setup.h lists every suppressor.

.PARAMETER Exe      ShenzhenPDF.exe to launch.
.PARAMETER AppArgs  Arguments passed through verbatim (each array element is one
                    argument, quoted here only when it contains whitespace).
.PARAMETER OutDir   Where `shot:` writes its PNGs.
.PARAMETER Steps    See the grammar below.
.PARAMETER TimeoutMs How long any single wait step may take.

  STEPS
    wait-dialog[:CLASS]  wait for a top-level window of this process that is
                         NOT the main ShenzhenPDFWindow (default), or whose
                         class name contains CLASS, and make it the target
    wait-main            wait for the ShenzhenPDFWindow, and make it the target
    tree                 print the target's UIA subtree (control type, name,
                         automation id, enabled, and whether it is invokable)
    invoke:TEXT          invoke the first Button/Hyperlink/MenuItem whose name
                         contains TEXT (case-insensitive). Fails the run if
                         there is no such element
    settext:TEXT         SetValue on the target's first Edit / Document element
    focusclick:TEXT      SetFocus then Invoke, for controls that want focus
                         first
    childtext:ID=TEXT    WM_SETTEXT the target's child control ID (see the note
                         at the step: UIA sees no Edit or Button in this app's
                         own dialogs, so an id is the only stable handle)
    childclick:ID        WM_COMMAND/BN_CLICKED for the target's child control ID
    shot:NAME            PrintWindow the TARGET window to OutDir\NAME.png
    shot-main:NAME       PrintWindow the MAIN window (even while a dialog is up)
    cmd:ID               post the main window WM_COMMAND for spdf_win_command ID
    click:X,Y            post a left click at MAIN-window client X,Y (a
                         precondition step: Add Comment with no selection puts
                         its note at the last clicked point)
    type:TEXT            post one WM_CHAR per character to the MAIN window, for
                         the app's self-drawn fields (find, page, filter)
    key:VK               post WM_KEYDOWN/UP for a virtual key to the target
    size:WxH             MoveWindow the MAIN window to 80,80 at this client size
    sleep:MS
    expect-no-dialog:MS  assert that NO non-main window appears within MS
    expect-exit:CODE     wait for the process to exit and assert its code
    kill                 TerminateProcess: the app takes no exit path, so
                         nothing it would write on the way out is written

.OUTPUTS
  One `key=value` or `step=` line per fact, judged by exit code:
    0  every step ran and every assertion held
   64  bad usage / bad step
   65  the process exited when a step still needed it
   66  a wait step timed out
   67  a capture failed
   68  a capture came back as 1-3 flat colours: the desktop is not being
       composited (a locked or disconnected session). BLOCKED, not a failure --
       windows-native-observations.md 4.6
   69  an assertion failed (invoke found nothing, an exit code differed, a
       dialog appeared where none was expected)
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Exe,
  [Parameter(Mandatory = $true)][string]$OutDir,
  [Parameter(Mandatory = $true)][string[]]$Steps,
  [string[]]$AppArgs = @(),
  # A second exe this run may legitimately have started -- the copy an
  # "Install and run" relaunches. Only $Exe and this path are ever closed by the
  # cleanup below, and only for a pid that did not exist before the launch.
  [string]$ChildExe = '',
  [int]$TimeoutMs = 15000,
  [int]$SettleMs = 700
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Exe)) { Write-Output "error=no-exe path=$Exe"; exit 64 }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# Every pid on the machine before the launch. The cleanup in `finally` may only
# touch a pid that is NOT in here: the reader is at this machine and other
# tracks build on it, so their processes must be invisible to this script.
$preexisting = @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
$script:stepRc = 0

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

if (-not ('SpdfUia' -as [type])) {
  Add-Type -Language CSharp -ReferencedAssemblies 'System.Drawing' -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class SpdfUia {
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr c);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint f);
    [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int t, bool r);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, string l);
    [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr h, int id);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder s, int n);
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }

    // Per-monitor-v2, for the same reason screenshot-window.ps1 does it: a
    // DPI-unaware caller gets VIRTUALISED rects from a per-monitor-aware
    // window, and the capture is then a top-left crop that mimics a scale bug.
    public static bool BecomeDpiAware() {
        try { return SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch (EntryPointNotFoundException) { return false; }
    }

    public static string ClassOf(IntPtr h) {
        var sb = new System.Text.StringBuilder(256); GetClassNameW(h, sb, sb.Capacity); return sb.ToString();
    }
    public static string TitleOf(IntPtr h) {
        var sb = new System.Text.StringBuilder(1024); GetWindowTextW(h, sb, sb.Capacity); return sb.ToString();
    }

    // Every visible top-level window owned by these pids, largest first, so a
    // caller can pick "the main one" or "anything but the main one".
    public static IntPtr[] Windows(uint[] pids) {
        var found = new List<IntPtr>();
        EnumWindows(delegate(IntPtr h, IntPtr p) {
            if (!IsWindowVisible(h)) return true;
            uint pid; GetWindowThreadProcessId(h, out pid);
            for (int i = 0; i < pids.Length; i++) {
                if (pids[i] != pid) continue;
                RECT r;
                // 0-area helper windows some frameworks keep around are not
                // dialogs and are not the app.
                if (GetWindowRect(h, out r) && (r.Right - r.Left) > 32 && (r.Bottom - r.Top) > 32) found.Add(h);
            }
            return true;
        }, IntPtr.Zero);
        return found.ToArray();
    }

    // Distinct colours on a 40x40 grid of the whole captured window. A dialog
    // has text and a button in it, so it is never 1-3 flat colours; a
    // non-composited desktop returns exactly that. See screenshot-window.ps1.
    public static int LastColors = -1;

    public static string Capture(IntPtr hwnd, string path) {
        RECT wr;
        if (!GetWindowRect(hwnd, out wr)) return "GetWindowRect failed";
        int w = wr.Right - wr.Left, h = wr.Bottom - wr.Top;
        if (w <= 0 || h <= 0) return "window rect is empty (" + w + "x" + h + ")";
        using (Bitmap bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb))
        using (Graphics g = Graphics.FromImage(bmp)) {
            IntPtr dc = g.GetHdc();
            bool ok;
            // PW_RENDERFULLCONTENT (2): mandatory for a Direct2D /
            // DirectComposition client area, and harmless for a plain dialog.
            try { ok = PrintWindow(hwnd, dc, 2); } finally { g.ReleaseHdc(dc); }
            if (!ok) return "PrintWindow failed (win32 " + Marshal.GetLastWin32Error() + ")";
            var seen = new HashSet<int>();
            int sx = Math.Max(1, w / 40), sy = Math.Max(1, h / 40);
            for (int y = 0; y < h; y += sy) for (int x = 0; x < w; x += sx) seen.Add(bmp.GetPixel(x, y).ToArgb());
            LastColors = seen.Count;
            bmp.Save(path, ImageFormat.Png);
        }
        return null;
    }
}
'@
}

$UIA = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]

Write-Output ("host_dpi_aware=" + [SpdfUia]::BecomeDpiAware())

$argList = @()
foreach ($a in $AppArgs) {
  if ($null -eq $a -or $a -eq '') { continue }
  if ($a -match '\s' -and $a -notmatch '^".*"$') { $argList += ('"' + $a + '"') } else { $argList += $a }
}
Write-Output ("launch=" + $Exe)
Write-Output ("args=" + ($argList -join ' '))

# Start-Process, not the call operator: the app is linked /SUBSYSTEM:WINDOWS and
# PowerShell's `&` does not wait for -- or reliably report -- a GUI process.
$proc = if ($argList.Count) { Start-Process -FilePath $Exe -ArgumentList $argList -PassThru }
        else { Start-Process -FilePath $Exe -PassThru }

$script:target = [IntPtr]::Zero
$script:main = [IntPtr]::Zero
$script:rc = 0

$script:childPids = @()
$script:childrenAt = [Diagnostics.Stopwatch]::StartNew()

function AppPids {
  $pids = New-Object System.Collections.Generic.List[uint32]
  $pids.Add([uint32]$proc.Id)
  # A relaunched installed copy is a CHILD, and it is the window that matters
  # for "Install and run" -- so children are polled, but only every 500 ms.
  # Get-CimInstance costs 200-400 ms per call here, and calling it on every
  # 100 ms poll turned a 15 s wait into a WMI hammer that starved the very
  # window it was waiting for.
  if ($script:childrenAt.ElapsedMilliseconds -gt 500 -or $script:childPids.Count -eq 0) {
    $script:childPids = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $($proc.Id)" -ErrorAction SilentlyContinue |
                          ForEach-Object { [uint32]$_.ProcessId })
    $script:childrenAt.Restart()
  }
  foreach ($c in $script:childPids) { $pids.Add($c) }
  return $pids.ToArray()
}

# $wantMain: the ShenzhenPDFWindow. Otherwise: anything that is not it, which is
# what a modal dialog is -- matched by class substring when one is given, because
# a TaskDialog and a MessageBoxW are both "#32770" and neither has a stable name.
function WaitWindow([bool]$wantMain, [string]$classLike, [int]$ms) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.ElapsedMilliseconds -lt $ms) {
    if ($proc.HasExited -and $wantMain) { return [IntPtr]::Zero }
    foreach ($h in [SpdfUia]::Windows((AppPids))) {
      $cls = [SpdfUia]::ClassOf($h)
      $isMain = ($cls -eq 'ShenzhenPDFWindow')
      if ($wantMain) { if ($isMain) { $script:main = $h; return $h } ; continue }
      if ($isMain) { $script:main = $h; continue }
      if ($classLike -and $cls -notlike "*$classLike*") { continue }
      return $h
    }
    Start-Sleep -Milliseconds 100
  }
  return [IntPtr]::Zero
}

function TargetElement {
  if ($script:target -eq [IntPtr]::Zero) { return $null }
  try { return $UIA::FromHandle($script:target) } catch { return $null }
}

function DumpTree($el, [int]$depth) {
  if (-not $el -or $depth -gt 6) { return }
  $c = $el.Current
  # TryGetCurrentPattern, never GetCurrentPattern: the latter THROWS
  # "Unsupported Pattern" for an element that does not have it, which in a tree
  # dump means the first static-text child aborts the whole walk.
  $p = $null
  $inv = $el.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$p)
  $name = ($c.Name -replace "`r?`n", ' | ')
  Write-Output ("  " * $depth + ("uia type={0} name='{1}' id='{2}' enabled={3} invokable={4}" -f
    $c.ControlType.ProgrammaticName.Replace('ControlType.', ''), $name, $c.AutomationId, $c.IsEnabled, $inv))
  foreach ($k in $el.FindAll($TS::Children, [System.Windows.Automation.Condition]::TrueCondition)) {
    DumpTree $k ($depth + 1)
  }
}

# Depth-first by NAME SUBSTRING, over every descendant. FindAll(Descendants)
# alone would do, but a TaskDialog's command links are grandchildren of a
# grouping element on some Windows builds and children on others, so the search
# must not depend on the level.
function FindByName($el, [string]$text, [string[]]$types) {
  if (-not $el) { return $null }
  foreach ($d in $el.FindAll($TS::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) {
    $t = $d.Current.ControlType.ProgrammaticName.Replace('ControlType.', '')
    if ($types -and $types -notcontains $t) { continue }
    if ($d.Current.Name -and $d.Current.Name.ToLower().Contains($text.ToLower())) { return $d }
  }
  return $null
}

# The result travels in $script:stepRc, NOT as a return value. A PowerShell
# function returns everything that reached the output stream, so a `return 0`
# after three Write-Output lines hands the caller a four-element array -- which
# `if ($rc)` reads as true and `exit $rc` cannot use. That cost one silent
# mid-run abort with no error text and a stale exit code.
function Shot([IntPtr]$h, [string]$name) {
  $script:stepRc = 0
  if ($h -eq [IntPtr]::Zero) { Write-Output "error=no-window-to-capture name=$name"; $script:stepRc = 66; return }
  $p = Join-Path $OutDir ($name + '.png')
  $e = [SpdfUia]::Capture($h, $p)
  if ($e) { Write-Output ("error=capture-failed detail=" + $e); $script:stepRc = 67; return }
  Write-Output ("shot=" + $p + " colors=" + [SpdfUia]::LastColors +
                " class=" + [SpdfUia]::ClassOf($h) + " title='" + [SpdfUia]::TitleOf($h) + "'")
  if ([SpdfUia]::LastColors -le 3) {
    Write-Output ("error=capture-not-composited colors=" + [SpdfUia]::LastColors +
                  " detail=the window came back as flat colour(s); the desktop is not being composited " +
                  "(locked, disconnected or asleep). BLOCKED, not a failure.")
    $script:stepRc = 68
  }
}

try {
  # ONE wait for "the app has put something on screen", preferring the main
  # window but accepting a dialog -- not a full main-window timeout followed by
  # a short dialog one. A launch whose first and ONLY window is modal (the
  # first-run TaskDialog, or --install's completion box) has no main window at
  # all, and spending the whole -TimeoutMs looking for one before glancing at
  # the dialog made the box arrive and be missed.
  $sw0 = [Diagnostics.Stopwatch]::StartNew()
  while ($sw0.ElapsedMilliseconds -lt $TimeoutMs) {
    $h = WaitWindow $true '' 250
    if ($h -ne [IntPtr]::Zero) { $script:target = $h; break }
    $h = WaitWindow $false '' 250
    if ($h -ne [IntPtr]::Zero) { $script:target = $h; break }
    if ($proc.HasExited) { break }
  }
  if ($script:target -ne [IntPtr]::Zero) {
    Write-Output ("target=0x" + $script:target.ToString('x') + " class=" + [SpdfUia]::ClassOf($script:target) +
                  " title='" + [SpdfUia]::TitleOf($script:target) + "'")
  } else {
    Write-Output 'target=none'
  }
  Start-Sleep -Milliseconds $SettleMs

  foreach ($s in $Steps) {
    if ($s -match '^sleep:(\d+)$') { Start-Sleep -Milliseconds ([int]$Matches[1]); Write-Output "step=$s"; continue }

    if ($s -match '^wait-main$') {
      $h = WaitWindow $true '' $TimeoutMs
      if ($h -eq [IntPtr]::Zero) { Write-Output "error=no-main-window step=$s"; exit 66 }
      $script:target = $h
      Write-Output ("step=$s target=0x" + $h.ToString('x') + " title='" + [SpdfUia]::TitleOf($h) + "'")
      Start-Sleep -Milliseconds $SettleMs; continue
    }

    if ($s -match '^wait-dialog(?::(.+))?$') {
      $h = WaitWindow $false $Matches[1] $TimeoutMs
      if ($h -eq [IntPtr]::Zero) { Write-Output "error=no-dialog step=$s"; exit 66 }
      $script:target = $h
      Write-Output ("step=$s target=0x" + $h.ToString('x') + " class=" + [SpdfUia]::ClassOf($h) +
                    " title='" + [SpdfUia]::TitleOf($h) + "'")
      Start-Sleep -Milliseconds $SettleMs; continue
    }

    if ($s -match '^expect-no-dialog:(\d+)$') {
      $h = WaitWindow $false '' ([int]$Matches[1])
      if ($h -ne [IntPtr]::Zero) {
        Write-Output ("assert=FAIL step=$s a dialog appeared: class=" + [SpdfUia]::ClassOf($h) +
                      " title='" + [SpdfUia]::TitleOf($h) + "'")
        exit 69
      }
      Write-Output "step=$s assert=OK no non-main window appeared"; continue
    }

    if ($s -eq 'tree') {
      $el = TargetElement
      if (-not $el) { Write-Output "error=no-target step=tree"; exit 66 }
      Write-Output "step=tree"
      DumpTree $el 1
      continue
    }

    if ($s -match '^(invoke|focusclick):(.+)$') {
      $el = TargetElement
      if (-not $el) { Write-Output "error=no-target step=$s"; exit 66 }
      $hit = FindByName $el $Matches[2] @('Button', 'Hyperlink', 'MenuItem', 'ListItem', 'CheckBox', 'TabItem')
      if (-not $hit) { Write-Output ("assert=FAIL step=$s no invokable element whose name contains it"); exit 69 }
      Write-Output ("step=$s matched='" + ($hit.Current.Name -replace "`r?`n", ' | ') + "' enabled=" + $hit.Current.IsEnabled)
      if ($Matches[1] -eq 'focusclick') { try { $hit.SetFocus() } catch {} ; Start-Sleep -Milliseconds 200 }
      $pat = $null
      if (-not $hit.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pat)) {
        Write-Output ("assert=FAIL step=$s the match supports no InvokePattern"); exit 69
      }
      $pat.Invoke()
      Start-Sleep -Milliseconds $SettleMs
      continue
    }

    if ($s -match '^settext:(.*)$') {
      $el = TargetElement
      if (-not $el) { Write-Output "error=no-target step=$s"; exit 66 }
      $edit = $null
      foreach ($d in $el.FindAll($TS::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) {
        $t = $d.Current.ControlType.ProgrammaticName
        if ($t -eq 'ControlType.Edit' -or $t -eq 'ControlType.Document') { $edit = $d; break }
      }
      if (-not $edit) { Write-Output "assert=FAIL step=$s no Edit in the target"; exit 69 }
      try { $edit.SetFocus() } catch {}
      $vp = $null
      if (-not $edit.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp)) {
        Write-Output ("assert=FAIL step=$s the Edit supports no ValuePattern"); exit 69
      }
      $vp.SetValue($Matches[1])
      Write-Output ("step=$s value='" + $vp.Current.Value + "'")
      Start-Sleep -Milliseconds 250
      continue
    }

    # BY CONTROL ID, because UIA CANNOT PRESS THESE ON THIS BOX -- and the
    # reason is the CLIENT, not the app, which is worth spelling out because the
    # symptom looks damning. Every child of every dialog comes back as
    # ControlType.Pane with its control id as the AutomationId, its window text
    # as the Name, and NO InvokePattern or ValuePattern, so `invoke:` and
    # `settext:` find nothing to act on.
    #
    # That is NOT an accessibility defect in ShenzhenPDF's dialogs. Measured
    # here: a stock MessageBoxW raised by `--install` reports its OK button --
    # a plain L"BUTTON" in a plain #32770, the most accessible control in
    # Windows -- as `type=Pane name='OK' id='2' invokable=False` too. When the
    # OS's own message box comes back that way, the missing piece is the
    # standard-control proxy providers on the System.Windows.Automation client
    # side, not the provider. Do not report the app's dialogs as inaccessible on
    # this evidence; test with a UIA client that resolves MessageBox before
    # making that claim.
    #
    # So these two steps address the child through GetDlgItem instead. The
    # control id is the stable handle and the source names it
    # (spdf_win_annot_dialog.cpp:19-22 for the annotation dialog; IDOK is 1 and
    # a MessageBoxW OK is 2). `tree` still prints what UIA can see, which is how
    # the limitation was found.
    if ($s -match '^childtext:(\d+)=(.*)$') {
      $h = [SpdfUia]::GetDlgItem($script:target, [int]$Matches[1])
      if ($h -eq [IntPtr]::Zero) { Write-Output "assert=FAIL step=$s no such control id"; exit 69 }
      [void][SpdfUia]::SendMessageW($h, 0x000C, [IntPtr]::Zero, [string]$Matches[2])  # WM_SETTEXT
      Write-Output ("step=$s text='" + [SpdfUia]::TitleOf($h) + "'")
      Start-Sleep -Milliseconds 200; continue
    }
    if ($s -match '^childclick:(\d+)$') {
      $h = [SpdfUia]::GetDlgItem($script:target, [int]$Matches[1])
      if ($h -eq [IntPtr]::Zero) { Write-Output "assert=FAIL step=$s no such control id"; exit 69 }
      # WM_COMMAND with BN_CLICKED (0) in the high word, exactly what a real
      # button press sends to its parent.
      [void][SpdfUia]::PostMessageW($script:target, 0x0111, [IntPtr][int]$Matches[1], $h)
      Write-Output ("step=$s label='" + [SpdfUia]::TitleOf($h) + "'")
      Start-Sleep -Milliseconds $SettleMs; continue
    }

    if ($s -match '^shot:(.+)$') { Shot $script:target $Matches[1]; if ($script:stepRc) { exit $script:stepRc }; continue }
    if ($s -match '^shot-main:(.+)$') {
      if ($script:main -eq [IntPtr]::Zero) { [void](WaitWindow $true '' 1000) }
      Shot $script:main $Matches[1]; if ($script:stepRc) { exit $script:stepRc }; continue
    }

    if ($s -match '^size:(\d+)x(\d+)$') {
      if ($script:main -eq [IntPtr]::Zero) { [void](WaitWindow $true '' 2000) }
      [void][SpdfUia]::MoveWindow($script:main, 80, 80, [int]$Matches[1], [int]$Matches[2], $true)
      Start-Sleep -Milliseconds 500; Write-Output "step=$s"; continue
    }

    # SPDF_WIN_MENU_ID_BASE (0x400) + the command, exactly as a menu pick
    # produces it. drive-window.ps1 documents why a COMMAND is posted rather
    # than an accelerator: WM_KEYDOWN carries no modifier state.
    if ($s -match '^cmd:(\d+)$') {
      if ($script:main -eq [IntPtr]::Zero) { [void](WaitWindow $true '' 2000) }
      [void][SpdfUia]::PostMessageW($script:main, 0x0111, [IntPtr](0x400 + [int]$Matches[1]), [IntPtr]::Zero)
      Start-Sleep -Milliseconds $SettleMs; Write-Output "step=$s"; continue
    }

    # A click in the MAIN window's client area, by PostMessage, so the user's
    # real cursor never moves (drive-window.ps1 says why). Here it is only ever
    # a PRECONDITION: Add Comment with no selection puts its note at the last
    # clicked point, so a dialog step that needs one takes it from here.
    if ($s -match '^click:(-?\d+),(-?\d+)$') {
      if ($script:main -eq [IntPtr]::Zero) { [void](WaitWindow $true '' 2000) }
      $lp = [IntPtr](([int]$Matches[2] -shl 16) -bor ([int]$Matches[1] -band 0xFFFF))
      [void][SpdfUia]::PostMessageW($script:main, 0x0200, [IntPtr]::Zero, $lp)
      [void][SpdfUia]::PostMessageW($script:main, 0x0201, [IntPtr]1, $lp)
      [void][SpdfUia]::PostMessageW($script:main, 0x0202, [IntPtr]::Zero, $lp)
      Start-Sleep -Milliseconds 350; Write-Output "step=$s"; continue
    }

    # WM_CHAR per character, to the MAIN window. The app's own fields -- the
    # find field, the page field, the sidebar filter -- are CHROME it draws
    # itself, not child controls, so they take text through WM_CHAR
    # (spdf_win_window.cpp:294 -> SPDF_WIN_INPUT_CHAR) and nothing about them can
    # be reached by control id. Focus one first with the command that focuses it
    # (cmd:26 is Find).
    if ($s -match '^type:(.*)$') {
      if ($script:main -eq [IntPtr]::Zero) { [void](WaitWindow $true '' 2000) }
      foreach ($ch in [char[]]$Matches[1]) {
        [void][SpdfUia]::PostMessageW($script:main, 0x0102, [IntPtr][int][char]$ch, [IntPtr]1)
        Start-Sleep -Milliseconds 60
      }
      Write-Output "step=$s"; Start-Sleep -Milliseconds $SettleMs; continue
    }

    if ($s -match '^key:(\d+)$') {
      $h = if ($script:target -ne [IntPtr]::Zero) { $script:target } else { $script:main }
      [void][SpdfUia]::PostMessageW($h, 0x0100, [IntPtr][int]$Matches[1], [IntPtr]::Zero)
      # WM_KEYUP's lParam: 0xC0000000 (transition + previous-state bits) as a
      # SIGNED int32. `unchecked(...)` is C#, not PowerShell, and PowerShell
      # would read 0xC0000000 as a positive Int64 that [IntPtr] then rejects on
      # a 32-bit cast, so the constant is written out already signed.
      [void][SpdfUia]::PostMessageW($h, 0x0101, [IntPtr][int]$Matches[1], [IntPtr](-1073741824))
      Start-Sleep -Milliseconds 400; Write-Output "step=$s"; continue
    }

    if ($s -match '^expect-exit:(\d+)$') {
      if (-not $proc.WaitForExit($TimeoutMs)) { Write-Output "assert=FAIL step=$s still running"; exit 69 }
      if ($proc.ExitCode -ne [int]$Matches[1]) {
        Write-Output ("assert=FAIL step=$s exit " + $proc.ExitCode); exit 69
      }
      Write-Output "step=$s assert=OK"; continue
    }

    if ($s -eq 'kill') {
      # TerminateProcess: the app runs no exit path, so nothing it would write on
      # the way out (session.yaml, recents) is written. This is how a dialog can
      # be SHOWN without its answer being carried out.
      try { $proc.Kill(); [void]$proc.WaitForExit(4000) } catch {}
      Write-Output ("step=kill exited=" + $proc.HasExited); continue
    }

    if ($s -eq 'alive') { $proc.Refresh(); Write-Output ("alive=" + (-not $proc.HasExited)); continue }

    Write-Output "error=bad-step step=$s"; exit 64
  }
  Write-Output 'status=done'
  exit 0
}
finally {
  if ($proc -and -not $proc.HasExited) {
    [void]$proc.CloseMainWindow()
    if (-not $proc.WaitForExit(4000)) { try { $proc.Kill() } catch {} ; [void]$proc.WaitForExit(2000) }
  }
  if ($proc) { Write-Output ("app_exitcode=" + $proc.ExitCode) }
  # Never leave a child the app relaunched running either -- an installed copy
  # started by "Install and run" is a stray window on the user's desktop.
  #
  # BY PID AGAINST A PRE-LAUNCH SNAPSHOT, NEVER BY IMAGE NAME. This is the trap
  # windows-native-observations.md 4.7 records for verify-phase1.ps1, and it bit
  # again here in a worse form: a name-based sweep found and CLOSED a
  # ShenzhenPDF.exe belonging to another build tree -- another agent's instance,
  # or the reader's own. A harness may only close what it started, so a process
  # must be absent from $preexisting AND live under a path this run launched
  # before it is touched.
  $allowed = @([IO.Path]::GetFullPath($Exe))
  if ($ChildExe) { $allowed += [IO.Path]::GetFullPath($ChildExe) }
  foreach ($p in @(Get-Process -ErrorAction SilentlyContinue |
                   Where-Object { $preexisting -notcontains $_.Id -and $_.Id -ne $proc.Id })) {
    $path = $null
    try { $path = $p.Path } catch { continue }
    if (-not $path) { continue }
    if ($allowed -notcontains [IO.Path]::GetFullPath($path)) { continue }
    try {
      Write-Output ("cleanup=child pid=" + $p.Id + " path=" + $path)
      [void]$p.CloseMainWindow()
      if (-not $p.WaitForExit(3000)) { $p.Kill(); [void]$p.WaitForExit(2000) }
    } catch {}
  }
}
