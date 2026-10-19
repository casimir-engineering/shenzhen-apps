@echo off
rem Guest-side MuPDF build. Runs INSIDE the Parallels VM; normally invoked by
rem portable/win/mupdf-build.sh as
rem   prlctl exec "Windows 11" cmd.exe /c "\\Mac\Home\Documents\spdf-win\portable\win\mupdf-build.cmd [ninja args...]"
rem
rem Produces, in C:\spdf-build\mupdf:
rem   libmupdf.lib        MuPDF proper + the 182 embedded font/hyphenation blobs
rem   libmupdf-third.lib  freetype, harfbuzz, libjpeg, lcms2, zlib, jbig2dec,
rem                       openjpeg, mujs, gumbo, extract
rem both ARM64, both /MT.
rem
rem The build description is C:\spdf\mupdf-win\build.ninja, generated on the Mac
rem by portable/win/mupdf-gen-ninja.sh from mupdf/Makefile's OWN macOS recipe --
rem see that script for why it is not mupdf.sln.
rem
rem Contract, same as guest-build.cmd: this script's exit code is ninja's exit
rem code. Infrastructure failures use 90+ so they can never be mistaken for a
rem compile error. Every conditional is a parenthesised block on purpose; the
rem one-liner "if errorlevel N echo x & exit /b y" runs the exit unconditionally.
setlocal EnableExtensions

set "SPDF_SRC=\\Mac\Home\Documents\spdf-win"
set "SPDF_DST=C:\spdf"
set "SPDF_OUT=C:\spdf-build"
set "MUPDF_OUT=%SPDF_OUT%\mupdf"

rem ---- 1. Refresh the local copy from the share --------------------------
rem MuPDF is ~4000 files the compiler opens repeatedly; over the Parallels share
rem that is roughly 9x slower than a local disk, so mirror first and build local.
rem MUPDF_OUT lives under SPDF_OUT, deliberately OUTSIDE SPDF_DST, so /MIR can
rem never delete 646 freshly built object files.
if not exist "%MUPDF_OUT%" mkdir "%MUPDF_OUT%"
echo [guest] mirroring %SPDF_SRC% -^> %SPDF_DST% ...
robocopy "%SPDF_SRC%" "%SPDF_DST%" /MIR /NFL /NDL /NJH /NJS /NP /R:1 /W:1 >nul
rem robocopy's exit code is a bit field; only >=8 is a real failure.
if errorlevel 8 (
  echo [guest] robocopy failed with %ERRORLEVEL%
  exit /b 90
)

if not exist "%SPDF_DST%\mupdf-win\build.ninja" (
  echo [guest] no build.ninja at %SPDF_DST%\mupdf-win -- run mupdf-gen-ninja.sh on the Mac
  exit /b 93
)

rem ---- 2. Enter the MSVC environment -------------------------------------
set "VCVARS=C:\BuildTools\VC\Auxiliary\Build\vcvarsall.bat"
if not exist "%VCVARS%" call :find_vcvars
if not exist "%VCVARS%" (
  echo [guest] no vcvarsall.bat found
  exit /b 91
)
rem "arm64" = host ARM64, target ARM64. Native, not emulated. It also puts the
rem bundled ninja.exe (VC.CMake.Project component) on PATH -- it is not a global
rem install and is NOT on PATH before this line.
call "%VCVARS%" arm64 >nul
if errorlevel 1 (
  echo [guest] vcvarsall failed
  exit /b 92
)

where ninja >nul 2>&1
if errorlevel 1 (
  echo [guest] ninja not on PATH after vcvarsall
  exit /b 94
)

rem ---- 3. Build ----------------------------------------------------------
rem ninja runs from the OUTPUT directory: build.ninja names its objects with
rem paths relative to here and its sources absolutely under C:\spdf\mupdf.
cd /d "%MUPDF_OUT%"
if errorlevel 1 (
  echo [guest] cannot cd to %MUPDF_OUT%
  exit /b 95
)
rem -k 0 keeps going after a failure so one bad file reports every OTHER bad file
rem in the same round trip instead of hiding behind it. ninja still exits
rem non-zero, which is the only thing the Mac side judges by.
ninja -k 0 -f "%SPDF_DST%\mupdf-win\build.ninja" %*
set "NINJA_RC=%ERRORLEVEL%"
if not "%NINJA_RC%"=="0" echo [guest] ninja exited %NINJA_RC%
exit /b %NINJA_RC%

:find_vcvars
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" goto :eof
for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -products * -latest -property installationPath`) do set "VS_PATH=%%i"
if defined VS_PATH set "VCVARS=%VS_PATH%\VC\Auxiliary\Build\vcvarsall.bat"
goto :eof
