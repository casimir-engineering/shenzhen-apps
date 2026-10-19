# The guest side of windows-pipe-plan.sh, one case per run (`-Case 1` to `4`; `20` is case 2's SYSTEM side), in the directory the
# script prepared. Each case runs in one PowerShell process: the guest's own background processes (CreateProcess),
# never two `prlctl exec` calls of one user at once, which the guest tools may run one after the other.
param([int]$Case, [string]$Dir, [string]$Bin)

$ErrorActionPreference = 'Stop'
$probe = Join-Path $Bin 'examples\pipe-probe.exe'
$low = Join-Path $Dir 'pipe-probe-low.exe'

function Probe([string]$exe, [string[]]$arguments) { (& $exe @arguments 2>&1 | Out-String).Trim() }
function WaitFor([string]$file, [string]$pattern, [int]$seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path $file) -and ((Get-Content $file -Raw) -match $pattern)) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}
function Sent([string]$report) {
    if (WaitFor $report 'bytes \d+' 15) { return ((Get-Content $report -Raw) -replace '(?s).*bytes (\d+).*', '$1') }
    return 'none'
}
# Started with CreateProcess, not the shell: ShellExecute can wait on the shell's checks of a freshly labelled file.
function Launch([string]$exe, [string[]]$arguments) {
    $info = New-Object System.Diagnostics.ProcessStartInfo $exe
    $info.Arguments = ($arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    return [System.Diagnostics.Process]::Start($info)
}
function Squat([string]$exe, [string]$state, [string]$sddl, [string]$report) {
    $name = Probe $probe @('name', $state)
    Launch $exe @('squat', $name, $sddl, $report) | Out-Null
    return $name
}

$sid = Probe $probe @('sid')
switch ($Case) {
    1 {
        # The other account's squatter was started by SYSTEM and wrote its pid and name.
        if (-not (WaitFor "$Dir\squat1.txt" '^\d+ ' 30)) { 'squatter: none'; break }
        $squatter = (Get-Content "$Dir\squat1.txt" -First 1).Split(' ')[0]
        $name = Get-Content "$Dir\name1.txt" -First 1
        Probe $probe @('advertise', "$Dir\state1", $name, $squatter) | Out-Null
        'verdict: ' + (Probe $probe @('connect', "$Dir\state1"))
        'sent: ' + (Sent "$Dir\squat1.txt")
    }
    2 {
        $name = Squat $probe "$Dir\state2" "O:${sid}D:P(A;;GA;;;${sid})" "$Dir\squat2.txt"
        if (-not (WaitFor "$Dir\squat2.txt" '^\d+ \d+' 30)) { 'squatter: none'; break }
        # SYSTEM changes the pipe's owner and leaves this file.
        if (-not (WaitFor "$Dir\owner2.txt" 'owner set' 60)) { 'owner: ' + (Get-Content "$Dir\owner2.txt" -Raw); break }
        'owner: owner set'
        $squatter = (Get-Content "$Dir\squat2.txt" -First 1).Split(' ')[0]
        Probe $probe @('advertise', "$Dir\state2", $name, $squatter) | Out-Null
        'verdict: ' + (Probe $probe @('connect', "$Dir\state2"))
        'sent: ' + (Sent "$Dir\squat2.txt")
    }
    20 {
        # Case 2's other account (run as SYSTEM, started first): once the squatter has written its pid and handle,
        # make SYSTEM the owner of its pipe.
        if (WaitFor "$Dir\squat2.txt" '^\d+ \d+' 60) {
            $pid2, $handle = (Get-Content "$Dir\squat2.txt" -First 1).Split(' ')
            Probe $probe @('set-owner', $pid2, $handle, 'S-1-5-18') | Set-Content "$Dir\owner2.txt"
        }
    }
    3 {
        # A low-integrity copy writes only where the label allows: its report goes to a directory labelled low.
        Copy-Item $probe $low -Force
        New-Item -ItemType Directory "$Dir\low" -Force | Out-Null
        icacls $low /setintegritylevel low | Out-Null
        icacls "$Dir\low" /setintegritylevel '(OI)(CI)low' | Out-Null
        $name = Squat $low "$Dir\state3" "D:P(A;;GA;;;${sid})S:(ML;;NW;;;LW)" "$Dir\low\squat3.txt"
        if (-not (WaitFor "$Dir\low\squat3.txt" '^\d+ ' 30)) { 'squatter: none'; break }
        $squatter = (Get-Content "$Dir\low\squat3.txt" -First 1).Split(' ')[0]
        Probe $probe @('advertise', "$Dir\state3", $name, $squatter) | Out-Null
        'verdict: ' + (Probe $probe @('connect', "$Dir\state3"))
        'sent: ' + (Sent "$Dir\low\squat3.txt")
    }
    4 {
        $env:SZFRIENDS_STATE_DIR = "$Dir\state4"
        $helper = Launch (Join-Path $Bin 'szfriends-helper.exe') @()
        $verdict = 'none'
        for ($i = 0; $i -lt 100 -and $verdict -ne 'connected'; $i++) {
            $verdict = Probe $probe @('connect', "$Dir\state4")
            Start-Sleep -Milliseconds 100
        }
        'helper: ' + $verdict
        'low client: ' + (Probe $low @('connect', "$Dir\state4"))
        $refusals = Get-Content "$Dir\state4\helper.log" | Where-Object { $_ -match 'refused' }
        $refusals | ForEach-Object { 'helper log: ' + $_ }
        $helper.WaitForExit(60000) | Out-Null
        'helper exited: ' + $helper.HasExited
    }
}
