@echo off
rem Build and run portable/win/tests/selection_differential.c natively.
rem
rem Exactly the shape of search-differential-native.cmd and
rem minimap-differential-native.cmd, which are the working precedent for
rem compiling a REAL GTK header under MSVC beside the port. Two originals are
rem compared here in one program: portable/linux/gtk4/spdf_selection_adapter.c
rem (toolkit-free, needs no shim, but does need portable/core and therefore
rem MuPDF) and portable/linux/gtk4/spdf_docview_internal.h's cursor regions
rem (needs the shared glib shim).
rem
rem WHY THIS IS A .cmd AND NOT A *_test.c: run-tests-native.sh discovers
rem *_test.c and builds it through build-native.cmd, whose include path is
rem portable/core + portable/win/src + MuPDF. The glib shim is not on it and
rem must not be added there -- a shim on every target's include path is a shim
rem that can start satisfying a real include by accident. The three existing
rem differentials made the same call.
rem
rem CONTRACT: this script's exit code is the whole truth.
rem   0  every comparison identical
rem   1  at least one comparison DIFFERs (a transcription error)
rem   2  the matrix did not run
rem   64+ this script could not do its job
rem
rem INVOKE IT BY PATH: this box has NoDefaultCurrentDirectoryInExePath=1.
setlocal EnableExtensions DisableDelayedExpansion

for %%I in ("%~dp0..\..\..") do set "REPO=%%~fI"
if not exist "%REPO%\portable\core\shenzhen_pdf_core.h" (
  echo [selection-differential] "%REPO%" does not look like the ShenzhenPDF repo
  exit /b 93
)
if not defined SPDF_OUT set "SPDF_OUT=C:\spdf-build"
if not defined SPDF_ARCH set "SPDF_ARCH=x64"
if not defined SPDF_MUPDF_INC set "SPDF_MUPDF_INC=%REPO%\mupdf\include"
if not defined SPDF_MUPDF_LIBDIR set "SPDF_MUPDF_LIBDIR=%SPDF_OUT%\mupdf"

where cl.exe >nul 2>&1
if not errorlevel 1 goto have_cl
if not defined SPDF_VCVARS set "SPDF_VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat"
if not exist "%SPDF_VCVARS%" (
  echo [selection-differential] no vcvarsall.bat at "%SPDF_VCVARS%"; set SPDF_VCVARS
  exit /b 91
)
rem vcvarsall.bat prints a harmless 'vswhere.exe is not recognized' here and
rem still returns 0. Judged by exit code, never by output.
call "%SPDF_VCVARS%" %SPDF_ARCH% >nul
if errorlevel 1 (
  echo [selection-differential] vcvarsall.bat %SPDF_ARCH% failed
  exit /b 92
)
:have_cl

if not exist "%SPDF_MUPDF_LIBDIR%\libmupdf.lib" (
  echo [selection-differential] no libmupdf.lib in "%SPDF_MUPDF_LIBDIR%"
  exit /b 66
)
rem A per-target object directory, and it must EXIST: /Fo with a trailing
rem backslash names a directory cl.exe does not create. Several repo sources
rem share a basename, so a flat /Fo would have them overwrite each other.
if not exist "%SPDF_OUT%" mkdir "%SPDF_OUT%"
if not exist "%SPDF_OUT%\obj-selection_differential" mkdir "%SPDF_OUT%\obj-selection_differential"
if not exist "%SPDF_OUT%\obj-selection_differential" (
  echo [selection-differential] cannot create "%SPDF_OUT%\obj-selection_differential"
  exit /b 90
)

rem /fp:precise is MSVC's default and does not contract a*b+c into an FMA, for
rem the reason spdf_win_layout.h's header gives: both sides must evaluate the
rem same operations in the same order.
rem _CRT_SECURE_NO_WARNINGS: the labels are built with sprintf into fixed
rem buffers bounded by the literals above, and thousands of C4996 lines would
rem bury a real DIFFER line. The verdict is the exit code either way.
rem /wd4505: the glib shim and the GTK header define helpers `static`, and the
rem ones this differential does not reach are removed unreferenced.
rem /MT matches libmupdf.lib, as build-native.cmd explains.
cl.exe /nologo /W3 /O2 /fp:precise /MT /TC /D_CRT_SECURE_NO_WARNINGS /wd4505 ^
  /I"%~dp0glib_shim" /I"%REPO%\portable\core" /I"%REPO%\portable\win\src" ^
  /I"%REPO%\portable\linux\gtk4" /I"%SPDF_MUPDF_INC%" ^
  "%~dp0selection_differential.c" ^
  "%REPO%\portable\linux\gtk4\spdf_selection_adapter.c" ^
  "%REPO%\portable\core\shenzhen_pdf_core.c" ^
  "%REPO%\portable\core\spdf_selection.c" ^
  "%REPO%\portable\core\spdf_selection_support.c" ^
  "%REPO%\portable\core\spdf_recolor.c" ^
  "%REPO%\portable\core\spdf_win_compat.c" ^
  /Fo"%SPDF_OUT%\obj-selection_differential\\" /Fe"%SPDF_OUT%\selection_differential.exe" ^
  /link /STACK:8388608 "%SPDF_MUPDF_LIBDIR%\libmupdf.lib" "%SPDF_MUPDF_LIBDIR%\libmupdf-third.lib" ^
  user32.lib gdi32.lib shell32.lib ole32.lib oleaut32.lib advapi32.lib shcore.lib d2d1.lib dwrite.lib windowscodecs.lib uuid.lib
if errorlevel 1 (
  echo [selection-differential] cl.exe failed
  exit /b 65
)

"%SPDF_OUT%\selection_differential.exe"
exit /b %ERRORLEVEL%
