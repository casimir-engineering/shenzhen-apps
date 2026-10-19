# desktop-available.ps1 -- CAN THIS MACHINE RECEIVE SYNTHETIC INPUT RIGHT NOW?
#
# Dot-source it and call Spdf-DesktopUnavailable. It answers a reason string
# when a desktop test cannot run, and $null when the desktop is usable.
#
# WHY IT IS NOT JUST A PROCESS CHECK. The three scripts that needed this each
# grew the same test -- LogonUI running, or a LockApp that is not merely a
# suspended leftover -- and that test names two of the ways a desktop stops
# accepting input. It misses the one that actually stopped a suite run here on
# 2026-09-07: the SCREEN SAVER. Windows switches the input desktop to
# "Screen-saver" while it runs, and on that desktop GetForegroundWindow()
# answers NULL, SetForegroundWindow cannot be honoured for any window, and
# SendInput reaches nothing. The window.stress case reported that as
# "the desktop refused the launched window the foreground", which is true and
# tells the reader nothing about what to do (unlock the screen, or move the
# mouse, and run it again).
#
# So ask the question directly, the way Windows itself answers it:
# OpenInputDesktop + UOI_NAME is the desktop that owns the input queue. Only
# "Default" is the interactive one. "Winlogon" is the secure desktop (the lock
# screen, a UAC prompt, Ctrl+Alt+Del), "Screen-saver" is the screen saver, and
# OpenInputDesktop failing outright means this process is not on the input
# desktop at all -- a service, or a disconnected session. The process check is
# KEPT as a second opinion, because it names the lock screen more precisely
# than the desktop does while LockApp is still coming up.

Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public class SpdfDesktop {
  [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
  [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr h);
  [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool GetUserObjectInformationW(IntPtr h, int index, IntPtr buf, int len, out int need);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  // The input desktop's name, or "" when this process cannot open it (which is
  // itself an answer: something else owns the input).
  public static string InputDesktop() {
    IntPtr d = OpenInputDesktop(0, false, 0x0001 /* DESKTOP_READOBJECTS */);
    if (d == IntPtr.Zero) return "";
    IntPtr buf = Marshal.AllocHGlobal(512);
    string name = "";
    try { int need; if (GetUserObjectInformationW(d, 2 /* UOI_NAME */, buf, 512, out need)) name = Marshal.PtrToStringUni(buf); }
    finally { Marshal.FreeHGlobal(buf); CloseDesktop(d); }
    return name;
  }
}
"@ -ErrorAction SilentlyContinue

# TWO DIFFERENT QUESTIONS, and the screen saver answers them differently.
#
#   Spdf-DesktopNotComposited -- can a window of ours be SHOWN and captured?
#   Only the lock screen and the secure desktop stop that: while the screen
#   saver runs, the Default desktop is still there and DWM still composites the
#   windows on it, so a launch measurement remains valid.
#
#   Spdf-DesktopUnavailable -- can synthetic INPUT reach it? The screen saver
#   takes the input desktop, so it stops this even though the window is fine.
#
# A case that only measures painting must use the first; anything that calls
# SendInput must use the second. Blocking a paint-only case on the screen saver
# would throw away coverage on a machine that can perfectly well provide it.

function Spdf-LockScreenUp {
    # LogonUI running always means locked. A LockApp lingers SUSPENDED long
    # after an unlock, so it only counts while one of its threads is scheduled.
    return (@(Get-Process LogonUI -ErrorAction SilentlyContinue).Count +
            @(Get-Process LockApp -ErrorAction SilentlyContinue |
              Where-Object { $_.Threads[0].WaitReason -ne 'Suspended' }).Count) -gt 0
}

function Spdf-DesktopNotComposited {
    if (Spdf-LockScreenUp) {
        return 'the Windows lock screen is up (LogonUI or a running LockApp), so no window of ours is shown or composited; unlock the session and run this again'
    }
    $desk = [SpdfDesktop]::InputDesktop()
    if ($desk -eq 'Winlogon') {
        return 'the secure desktop is up (a UAC prompt, or Ctrl+Alt+Del), so no window of ours is composited; dismiss it and run this again'
    }
    return $null
}

function Spdf-DesktopUnavailable {
    $blind = Spdf-DesktopNotComposited
    if ($blind) { return $blind }
    $desk = [SpdfDesktop]::InputDesktop()
    if ($desk -eq '') {
        return 'this process is not on the input desktop (a service session, or a disconnected one), so SendInput reaches nothing'
    }
    if ($desk -ne 'Default') {
        return ("the input desktop is '" + $desk + "', not 'Default' -- the screen saver or the secure desktop owns the input, GetForegroundWindow answers NULL and SendInput reaches nothing; dismiss it and run this again")
    }
    return $null
}
