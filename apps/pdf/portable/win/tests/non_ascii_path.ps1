# Guest-side half of run-tests.sh's harness.non-ascii-path case.
#
# Creates a directory whose name contains a non-ASCII character, copies the
# golden fixture into it, and runs narrow_path_probe.exe against it. Exits with
# the probe's own exit code, so the whole thing is judged by status on the Mac.
#
# WHY THIS IS A SCRIPT AND NOT A ONE-LINER. Two separate reasons, both learned
# the hard way:
#   1. `prlctl exec` strips quotes out of an inline -Command argument, so a
#      script passed that way loses every string literal and fails in a way that
#      looks like a PowerShell syntax error rather than a quoting problem.
#   2. The character itself is written as [char]0xE9 rather than as a literal
#      e-acute so that this FILE stays pure ASCII. A non-ASCII source file would
#      have to survive git, rsync, a Parallels share and robocopy -- and on
#      macOS it would also be at risk of NFC/NFD normalisation, which would make
#      the test's own input depend on which machine checked the repo out.
#
# The guest's ANSI code page is 1252, not UTF-8. Windows narrows the real UTF-16
# command line to that code page on the way into `char** argv`, and `fopen`
# widens it back the same way, so e-acute arrives as the single byte 0xE9 and
# round-trips. A harness that handed the guest a UTF-8 path would send C3 A9 and
# be looking for a file that does not exist.
$ErrorActionPreference = 'Stop'

$dir = 'C:\spdf-build\t4-' + [char]0xE9 + 'dir'
$src = 'C:\spdf\portable\win\tests\fixtures\golden.pdf'
$exe = 'C:\spdf-build\narrow_path_probe.exe'

New-Item -ItemType Directory -Force -Path $dir | Out-Null
$target = Join-Path $dir 'golden.pdf'
Copy-Item $src $target -Force

& $exe $target
exit $LASTEXITCODE
