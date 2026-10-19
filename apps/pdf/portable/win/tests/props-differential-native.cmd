@echo off
rem Build and run portable/win/tests/props_differential.c natively on Windows.
rem
rem WHAT THIS UNBLOCKS. props_differential.c compiles the GTK4 frontend's
rem portable/linux/gtk4/spdf_props_internal.h -- the shared value-formatting
rem logic, itself a port of portable/mac/SPDFMacPropertiesFormat.mm -- and the
rem port's portable/win/src/spdf_win_props_format.h into ONE binary, and asserts
rem they produce the same bytes and the same numbers. Same argument as
rem layout-differential-native.cmd and its four siblings: the port is compared
rem against the implementation it was transcribed from, not against what its
rem author remembered.
rem
rem THE SHIM IS LAYERED. spdf_props_internal.h needs GString, g_strdup_printf
rem and a GDateTime, which the shared portable/win/tests/glib_shim deliberately
rem does not carry -- so portable/win/tests/glib_shim_props LAYERS on it, and
rem must come FIRST on the include path because it is the one that has to
rem resolve as <glib.h>. That directory's header states precisely which of its
rem parts are real glib semantics and which one part is an instrument; read it
rem before treating a PASS here as more than it is.
rem
rem CONTRACT: this script's exit code is the whole truth.
rem   0  every comparison identical
rem   1  at least one comparison DIFFERs -- a transcription error
rem   2  the matrix did not run (too few comparisons to be meaningful)
rem   64+ this script could not do its job
rem
rem INVOKE IT BY PATH: this box has NoDefaultCurrentDirectoryInExePath=1, so cmd
rem will not find a .cmd in the current directory.
setlocal EnableExtensions DisableDelayedExpansion

for %%I in ("%~dp0..\..\..") do set "REPO=%%~fI"
if not exist "%REPO%\portable\core\shenzhen_pdf_core.h" (
  echo [props-differential] "%REPO%" does not look like the ShenzhenPDF repo
  exit /b 93
)
if not exist "%REPO%\portable\linux\gtk4\spdf_props_internal.h" (
  echo [props-differential] the GTK4 properties helper is missing -- nothing to compare against
  exit /b 94
)

if not defined SPDF_OUT set "SPDF_OUT=C:\spdf-build"
if not defined SPDF_ARCH set "SPDF_ARCH=x64"

where cl.exe >nul 2>&1
if not errorlevel 1 goto have_cl
if not defined SPDF_VCVARS set "SPDF_VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat"
if not exist "%SPDF_VCVARS%" (
  echo [props-differential] no vcvarsall.bat at "%SPDF_VCVARS%" -- set SPDF_VCVARS
  exit /b 91
)
rem vcvarsall prints a harmless "'vswhere.exe' is not recognized" on this box
rem and still returns 0. Judged by exit code, never by output.
call "%SPDF_VCVARS%" %SPDF_ARCH% >nul
if errorlevel 1 (
  echo [props-differential] vcvarsall.bat %SPDF_ARCH% failed
  exit /b 92
)
where cl.exe >nul 2>&1
if errorlevel 1 (
  echo [props-differential] cl.exe still not on PATH after vcvarsall
  exit /b 92
)
:have_cl

if not exist "%SPDF_OUT%" mkdir "%SPDF_OUT%"

rem /utf-8 IS LOAD-BEARING here and not a style choice. Both headers spell the
rem multiplication sign, the middle dot and the em dash as literal characters,
rem and the strings this differential compares CONTAIN them. Without /utf-8
rem MSVC would encode them in the machine's ANSI code page, both sides would
rem change together and the comparison would still pass while the app shipped
rem the wrong bytes -- so props_format_test.c additionally pins the exact UTF-8
rem sequences.
rem /wd4505: the shims define every helper `static`; the unreached ones are
rem removed, which is the point of them being static.
cl.exe /nologo /W3 /O2 /fp:precise /MT /TC /utf-8 /D_CRT_SECURE_NO_WARNINGS /wd4505 ^
  /I"%~dp0glib_shim_props" /I"%~dp0glib_shim" ^
  /I"%REPO%\portable\core" /I"%REPO%\portable\win\src" /I"%REPO%\portable\linux\gtk4" ^
  /Fo"%SPDF_OUT%\props_differential." /Fe"%SPDF_OUT%\props_differential.exe" ^
  "%~dp0props_differential.c"
if errorlevel 1 (
  echo [props-differential] cl.exe failed
  exit /b 65
)

"%SPDF_OUT%\props_differential.exe"
exit /b %ERRORLEVEL%
