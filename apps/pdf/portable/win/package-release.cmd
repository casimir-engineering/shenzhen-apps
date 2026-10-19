@echo off
rem Package a built ShenzhenPDF.exe as a release asset. THERE IS NO ZIP AND
rem THERE IS NO INSTALLER: the download IS the exe.
rem
rem   portable\win\package-release.cmd <built ShenzhenPDF.exe> [dist dir]
rem
rem It produces exactly the two files the updater already looks for
rem (portable\win\src\spdf_win_updater.h:32, _feed.c, _verify.cpp):
rem
rem   dist\ShenzhenPDF-win-x64.exe
rem   dist\ShenzhenPDF-win-x64.exe.sha256      "<64 lowercase hex>  <name>"
rem
rem and prints the exe's ProductVersion, so whoever cuts the release can check
rem it against the tag before uploading. The tag is "<version>-<build>", e.g.
rem 26.9.2-1, and the updater compares all four numeric fields against
rem GitHub's tag_name -- a mismatch there means the app either offers a build
rem the user already runs or refuses the one it should take.
rem
rem THE EXE IS ITS OWN INSTALLER (portable\win\src\spdf_win_setup.h): the asset
rem below runs as a portable app on download, and `--install` is the optional
rem per-user step. That is why no second artefact is built here.
rem
rem SIGNING IS NOT DONE HERE. The updater verifies Authenticode plus a pinned
rem certificate thumbprint; signtool runs on the machine that holds the
rem certificate, on the copy this script produces, BEFORE the sidecar is
rem meaningful -- so re-run this script after signing, never before.
rem
rem CONTRACT: any failure exits non-zero. A release script that swallows an
rem error produces a sidecar that does not match the asset, and every updater
rem that reads it then refuses the update with a hash mismatch nobody can
rem explain. Infrastructure failures use codes 64-70, matching
rem portable\win\build-native.cmd's habit of keeping them distinguishable.
rem
rem Delayed expansion is deliberately OFF, as in build-native.cmd: a `!` in a
rem path would be eaten, and nothing here needs it -- the hash is normalised by
rem sequential `set` statements, not inside a parenthesised block.
setlocal EnableExtensions DisableDelayedExpansion

for %%I in ("%~dp0..\..") do set "REPO=%%~fI"

set "ASSET=ShenzhenPDF-win-x64.exe"
set "SRC=%~1"
set "DIST=%~2"
if not defined DIST set "DIST=%REPO%\dist"

if not defined SRC goto usage
if /i "%SRC%"=="--help" goto usage
if /i "%SRC%"=="-h" goto usage

if not exist "%SRC%" (
  echo [package-release] no such file: "%SRC%"
  exit /b 64
)

rem ---- 1. The ProductVersion, read from the binary itself ------------------
rem From VERSIONINFO, which rc.exe compiled in from
rem portable\win\src\spdf_win_about_version.h -- so this is the version the
rem About box and the updater's compare will report, not a number typed here.
set "PRODVER="
for /f "usebackq tokens=*" %%V in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "(Get-Item -LiteralPath '%SRC%').VersionInfo.ProductVersion" 2^>nul`) do if not defined PRODVER set "PRODVER=%%V"
if not defined PRODVER (
  echo [package-release] could not read the ProductVersion from "%SRC%"
  echo                   -- is it a ShenzhenPDF.exe built with its resources?
  exit /b 65
)

rem ---- 2. Copy ------------------------------------------------------------
if not exist "%DIST%" mkdir "%DIST%"
if not exist "%DIST%" (
  echo [package-release] cannot create "%DIST%"
  exit /b 66
)
copy /y "%SRC%" "%DIST%\%ASSET%" >nul
if errorlevel 1 (
  echo [package-release] could not copy "%SRC%" to "%DIST%\%ASSET%"
  exit /b 67
)

rem ---- 3. The SHA-256 sidecar ---------------------------------------------
rem certutil's second line is the digest. Older builds print it in space-
rem separated groups and newer ones as one run, and either may be upper case,
rem so both are normalised rather than assumed -- and the result is then
rem CHECKED, because a sidecar with a malformed digest fails every update with
rem a hash mismatch that reads like a corrupted download.
set "HASH="
for /f "usebackq skip=1 tokens=*" %%H in (`certutil -hashfile "%DIST%\%ASSET%" SHA256`) do if not defined HASH set "HASH=%%H"
if not defined HASH (
  echo [package-release] certutil produced no digest for "%DIST%\%ASSET%"
  exit /b 68
)
set "HASH=%HASH: =%"
set "HASH=%HASH:A=a%"
set "HASH=%HASH:B=b%"
set "HASH=%HASH:C=c%"
set "HASH=%HASH:D=d%"
set "HASH=%HASH:E=e%"
set "HASH=%HASH:F=f%"

rem Exactly 64 characters: character 64 exists and character 65 does not.
if "%HASH:~63,1%"=="" goto bad_hash
if not "%HASH:~64,1%"=="" goto bad_hash
rem ... and all of them hex. Whatever survives removing 0-9a-f is not.
set "REST=%HASH%"
for %%C in (0 1 2 3 4 5 6 7 8 9 a b c d e f) do call :strip "%%C"
if not "%REST%"=="" goto bad_hash

rem Two spaces between digest and name: the sha256sum format the updater's
rem parser reads (spdf_win_updater_parse_sha256_sidecar).
>"%DIST%\%ASSET%.sha256" echo %HASH%  %ASSET%
if errorlevel 1 (
  echo [package-release] could not write "%DIST%\%ASSET%.sha256"
  exit /b 69
)
if not exist "%DIST%\%ASSET%.sha256" (
  echo [package-release] "%DIST%\%ASSET%.sha256" was not created
  exit /b 69
)

rem ---- 4. Say what was produced -------------------------------------------
for %%S in ("%DIST%\%ASSET%") do set "BYTES=%%~zS"
echo [package-release] %DIST%\%ASSET%
echo [package-release]   ProductVersion  %PRODVER%
echo [package-release]   bytes           %BYTES%
echo [package-release]   sha256          %HASH%
echo [package-release] %DIST%\%ASSET%.sha256
echo [package-release] the release tag is version-build, e.g. 26.9.2-1, and must agree
echo [package-release] with the ProductVersion above -- the updater compares all four fields.
exit /b 0

:strip
rem `call set` so the substitution's %REST% expands at run time rather than at
rem parse time -- the same delayed-expansion trap build-native.cmd:298 warns
rem about, avoided the same way: in a subroutine, not a block.
call set "REST=%%REST:%~1=%%"
exit /b 0

:bad_hash
echo [package-release] certutil's digest is not 64 hex characters: "%HASH%"
exit /b 70

:usage
echo Package a built ShenzhenPDF.exe as a release asset. The download IS the exe.
echo.
echo   package-release.cmd ^<built ShenzhenPDF.exe^> [dist dir]
echo.
echo Produces ^<dist^>\%ASSET% and its .sha256 sidecar, and prints the
echo ProductVersion so the release can be checked against its tag.
echo Default dist dir: %REPO%\dist
echo.
echo Exit codes: 0 ok / 64 no such source / 65 no ProductVersion / 66 dist dir /
echo 67 copy failed / 68 certutil produced nothing / 69 sidecar write failed /
echo 70 malformed digest.
exit /b 64
