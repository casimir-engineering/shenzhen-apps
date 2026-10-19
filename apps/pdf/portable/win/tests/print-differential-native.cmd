@echo off
rem Build and run portable/win/tests/print_differential.c natively on Windows.
rem
rem WHAT THIS UNBLOCKS. print_differential.c compiles the GTK4 frontend's
rem portable/linux/gtk4/spdf_print.c -- its PURE half, behind the file's own
rem SPDF_PRINT_TESTING switch -- and the port's spdf_win_print_math.h into ONE
rem binary and asserts they agree function by function. It compares the port
rem against the implementation it was transcribed from rather than against what
rem its author remembered, which is the same argument
rem layout-differential-native.cmd, minimap-differential-native.cmd,
rem search-differential-native.cmd and selection-differential-native.cmd make.
rem
rem NO NEW SHIM. Unlike the search differential, this one needs no layered glib:
rem under SPDF_PRINT_TESTING the GTK file uses <math.h> plus gboolean, TRUE,
rem FALSE, MAX, MIN and CLAMP, and portable/win/tests/glib_shim supplies exactly
rem those, with glib's own macro bodies character for character -- which matters
rem here because CLAMP's comparison order decides spdf_print_clamp_custom_scale
rem for a NaN, and that case IS compared.
rem
rem NOTHING IS SKIPPED. Every function in the GTK file's section 1 is driven.
rem The GTK half below section 1 is compiled out by SPDF_PRINT_TESTING and is
rem GtkPrintOperation lifecycle, which has no counterpart to compare against.
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
  echo [print-differential] "%REPO%" does not look like the ShenzhenPDF repo
  exit /b 93
)
if not exist "%REPO%\portable\linux\gtk4\spdf_print.c" (
  echo [print-differential] the GTK4 print module is missing -- nothing to compare against
  exit /b 94
)

if not defined SPDF_OUT set "SPDF_OUT=C:\spdf-build"
if not defined SPDF_ARCH set "SPDF_ARCH=x64"

where cl.exe >nul 2>&1
if not errorlevel 1 goto have_cl
if not defined SPDF_VCVARS set "SPDF_VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat"
if not exist "%SPDF_VCVARS%" (
  echo [print-differential] no vcvarsall.bat at "%SPDF_VCVARS%" -- set SPDF_VCVARS
  exit /b 91
)
rem vcvarsall prints a harmless "'vswhere.exe' is not recognized" on this box
rem and still returns 0. Judged by exit code, never by output.
call "%SPDF_VCVARS%" %SPDF_ARCH% >nul
if errorlevel 1 (
  echo [print-differential] vcvarsall.bat %SPDF_ARCH% failed
  exit /b 92
)
where cl.exe >nul 2>&1
if errorlevel 1 (
  echo [print-differential] cl.exe still not on PATH after vcvarsall
  exit /b 92
)
:have_cl

if not exist "%SPDF_OUT%" mkdir "%SPDF_OUT%"

rem /fp:precise is MSVC's default and does not contract a*b+c into an FMA, which
rem matters for the same reason spdf_win_layout.h's header comment gives: both
rem sides must evaluate the same operations in the same order, or a difference
rem this test reports as a transcription error would in fact be the compiler.
rem /TC: both sides are C.
rem /wd4505: the shim defines helpers `static` and the unreached ones are
rem removed, which is the point of them being static.
cl.exe /nologo /W3 /O2 /fp:precise /MT /TC /utf-8 /D_CRT_SECURE_NO_WARNINGS /wd4505 ^
  /I"%~dp0glib_shim" ^
  /I"%REPO%\portable\core" /I"%REPO%\portable\win\src" /I"%REPO%\portable\linux\gtk4" ^
  /Fo"%SPDF_OUT%\print_differential." /Fe"%SPDF_OUT%\print_differential.exe" ^
  "%~dp0print_differential.c"
if errorlevel 1 (
  echo [print-differential] cl.exe failed
  exit /b 65
)

"%SPDF_OUT%\print_differential.exe"
exit /b %ERRORLEVEL%
