@echo off
rem Build libmupdf.lib + libmupdf-third.lib for NATIVE x64 WINDOWS, on the
rem machine that will link them. No Parallels VM, no ARM64, no macOS host.
rem
rem   portable\win\mupdf-native-build.cmd [options] [ninja args...]
rem
rem     --no-generate   reuse the existing build.ninja instead of re-deriving it
rem     --clean         delete the output directory first
rem
rem Produces, in C:\spdf-build\mupdf  (override with SPDF_MUPDF_OUT):
rem   libmupdf.lib        MuPDF proper + the 182 embedded font/hyphenation blobs
rem   libmupdf-third.lib  freetype, harfbuzz, libjpeg, lcms2, zlib, jbig2dec,
rem                       openjpeg, mujs, gumbo, extract
rem both x64 (COFF machine 8664), both /MT. That is the path and the CRT
rem portable\win\guest-build.cmd already expects, so the frontend links with no
rem change (portable\win\README.md, "The linking interface").
rem
rem The build description is generated, not checked in: this script calls
rem portable\win\mupdf-gen-ninja-native.sh, which asks mupdf\Makefile itself
rem what to compile via `make -n` and translates that to cl.exe. READ THAT
rem SCRIPT'S HEADER before changing anything here -- it lists every deliberate
rem divergence from the macOS recipe (D1..D6) and explains why
rem mupdf\platform\win32\mupdf.sln is deliberately NOT used.
rem
rem PREREQUISITES, all checkable:
rem   * VS 2022 Build Tools with the native x64 compiler and the VC.CMake.Project
rem     component (that component is where the bundled ninja.exe comes from).
rem   * Git Bash, for the generator. Found via PATH or the usual install dirs.
rem   * GNU make, for `make -n`:  winget install --id ezwinports.make --exact
rem     It lands in %LOCALAPPDATA%\Microsoft\WinGet\Links, which this script adds
rem     to PATH itself so a fresh shell is not required.
rem   * Python 3, for the generator's translation pass.
rem
rem Contract, same as mupdf-build.cmd: this script's exit code is ninja's exit
rem code. Infrastructure failures use 90+ so they can never be mistaken for a
rem compile error. Every conditional is a parenthesised block on purpose; the
rem one-liner "if errorlevel N echo x & exit /b y" runs the exit
rem unconditionally (README gotcha 4), and %ERRORLEVEL% inside an & chain is
rem expanded at parse time (gotcha 3).
rem
rem DELAYED EXPANSION IS ON, and the two hazards pull against each other. cmd
rem parses a whole parenthesised block before running any of it, so %VAR% inside
rem a block reads the value from BEFORE the block -- which is gotcha 3 again,
rem one level down, and it is exactly how "no bash.exe found" appeared on a
rem machine that has bash: `call :find_bash` set it, and the `%BASH%` two lines
rem later had already been substituted with the empty pre-call value. Anything
rem assigned inside a block, or by a routine called from one, is read as !VAR!.
setlocal EnableExtensions EnableDelayedExpansion

rem This script lives in <repo>\portable\win\ .
set "SPDF_WIN=%~dp0"
if "%SPDF_WIN:~-1%"=="\" set "SPDF_WIN=%SPDF_WIN:~0,-1%"
for %%i in ("%SPDF_WIN%\..\..") do set "REPO=%%~fi"

if "%SPDF_MUPDF_OUT%"=="" set "SPDF_MUPDF_OUT=C:\spdf-build\mupdf"
rem The build description lives OUTSIDE the object tree, so --clean cannot
rem delete the thing that describes the build.
if "%SPDF_MUPDF_DESC%"=="" set "SPDF_MUPDF_DESC=C:\spdf-build\mupdf-win-native"

set "DO_GENERATE=1"
set "DO_CLEAN=0"
set "NINJA_ARGS="
:parse
if "%~1"=="" goto parsed
if /i "%~1"=="--no-generate" (
  set "DO_GENERATE=0"
  shift
  goto parse
)
if /i "%~1"=="--clean" (
  set "DO_CLEAN=1"
  shift
  goto parse
)
set "NINJA_ARGS=%NINJA_ARGS% %~1"
shift
goto parse
:parsed

rem ---- 1. Enter the MSVC environment, targeting x64 --------------------------
rem "x64" = host x64, target x64. Native. It also puts the bundled ninja.exe on
rem PATH; ninja is NOT a global install and is not on PATH before this line.
set "VCVARS="
call :find_vcvars
if not exist "%VCVARS%" (
  echo [native] no vcvarsall.bat found -- install VS 2022 Build Tools
  exit /b 91
)
rem vcvarsall prints "'vswhere.exe' is not recognized" on STDERR from its own
rem internals on this box and still succeeds; >nul only silences stdout, so that
rem line leaks through. It is noise. Judge by the exit code and by
rem VSCMD_ARG_TGT_ARCH below, never by the text.
call "%VCVARS%" x64 >nul
if errorlevel 1 (
  echo [native] vcvarsall x64 failed
  exit /b 92
)

rem vcvarsall records what it actually configured. This is the cheap, locale-
rem independent version of the architecture check -- the real proof is dumpbin
rem over the finished archives (portable\win\mupdf-arch-check-native.cmd).
if not "%VSCMD_ARG_TGT_ARCH%"=="x64" (
  echo [native] vcvarsall configured target '%VSCMD_ARG_TGT_ARCH%', not x64
  exit /b 96
)
if not "%VSCMD_ARG_HOST_ARCH%"=="x64" (
  echo [native] vcvarsall configured host '%VSCMD_ARG_HOST_ARCH%', not x64
  exit /b 96
)

rem Belt and braces: if the VC.CMake.Project component's ninja did not make it
rem onto PATH, add it explicitly rather than failing with a confusing message.
where ninja >nul 2>&1
if errorlevel 1 (
  for /f "usebackq tokens=*" %%i in (`where /r "%VSINSTALLDIR%Common7\IDE\CommonExtensions\Microsoft\CMake" ninja.exe 2^>nul`) do set "NINJA_DIR=%%~dpi"
  if defined NINJA_DIR set "PATH=!NINJA_DIR!;%PATH%"
)
where ninja >nul 2>&1
if errorlevel 1 (
  echo [native] ninja not on PATH after vcvarsall -- install the
  echo [native] "C++ CMake tools for Windows" ^(VC.CMake.Project^) component
  exit /b 94
)

rem ---- 2. Regenerate the build description -----------------------------------
if "%DO_CLEAN%"=="1" (
  echo [native] cleaning %SPDF_MUPDF_OUT%
  if exist "%SPDF_MUPDF_OUT%" rmdir /s /q "%SPDF_MUPDF_OUT%"
)

if "%DO_GENERATE%"=="1" (
  call :find_bash
  if not exist "!BASH!" (
    echo [native] no bash.exe found -- install Git for Windows
    exit /b 97
  )
  rem GNU make from winget lands here and is only on PATH in shells started
  rem after the install.
  set "PATH=%LOCALAPPDATA%\Microsoft\WinGet\Links;%PATH%"
  echo [native] generating build.ninja in %SPDF_MUPDF_DESC% ...
  rem --allow-missing-generated: mupdf\generated\ is gitignored and is produced
  rem by the POSIX build, so it never exists on a Windows-only machine. The flag
  rem moves the blob-symbol safety net from "compare against the hexdump" to
  rem "assert hexdump.sh's naming rule is unchanged" -- see the generator's D5.
  rem It is spelled out here rather than defaulted so that dropping a safety net
  rem is always visible at the call site.
  "!BASH!" -lc "'%SPDF_WIN:\=/%/mupdf-gen-ninja-native.sh' --allow-missing-generated '%SPDF_MUPDF_DESC:\=/%'"
  if errorlevel 1 (
    echo [native] mupdf-gen-ninja-native.sh failed
    exit /b 93
  )
)

if not exist "%SPDF_MUPDF_DESC%\build.ninja" (
  echo [native] no build.ninja at %SPDF_MUPDF_DESC% -- run without --no-generate
  exit /b 93
)

rem ---- 3. Build --------------------------------------------------------------
rem ninja runs from the OUTPUT directory: build.ninja names its objects with
rem paths relative to here and its sources absolutely under the repo.
if not exist "%SPDF_MUPDF_OUT%" mkdir "%SPDF_MUPDF_OUT%"
cd /d "%SPDF_MUPDF_OUT%"
if errorlevel 1 (
  echo [native] cannot cd to %SPDF_MUPDF_OUT%
  exit /b 95
)

rem -k 0 keeps going after a failure so one bad file reports every OTHER bad
rem file in the same run instead of hiding behind it (README gotcha 16). ninja
rem still exits non-zero, which is the only thing to judge by.
echo [native] ninja -k 0 in %SPDF_MUPDF_OUT%
ninja -k 0 -f "%SPDF_MUPDF_DESC%\build.ninja"%NINJA_ARGS%
set "NINJA_RC=%ERRORLEVEL%"
if not "%NINJA_RC%"=="0" echo [native] ninja exited %NINJA_RC%
exit /b %NINJA_RC%

:find_vcvars
set "VCVARS=%ProgramFiles(x86)%\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat"
if exist "%VCVARS%" goto :eof
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" goto :eof
for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -products * -latest -property installationPath`) do set "VS_PATH=%%i"
if defined VS_PATH set "VCVARS=%VS_PATH%\VC\Auxiliary\Build\vcvarsall.bat"
goto :eof

:find_bash
rem Not `where bash`: on a machine with the WSL shim that finds a Linux bash
rem which cannot see C:\ the way the generator expects.
set "BASH=%ProgramFiles%\Git\bin\bash.exe"
if exist "%BASH%" goto :eof
set "BASH=%ProgramFiles(x86)%\Git\bin\bash.exe"
if exist "%BASH%" goto :eof
set "BASH=%LOCALAPPDATA%\Programs\Git\bin\bash.exe"
goto :eof
