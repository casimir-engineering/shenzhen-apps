@echo off
rem Build and run portable/win/tests/gtk_differential.c natively on Windows.
rem
rem WHAT THIS UNBLOCKS. gtk_differential.c is the strongest test in the Windows
rem port: it compiles the GTK4 frontend's spdf_docview_internal.h and the port's
rem spdf_win_layout.h into ONE binary and asserts they agree function by
rem function, so it compares the port against the implementation it was
rem transcribed from rather than against what its author remembered. It has been
rem recorded BLOCKED as "needs glib and the GTK4 headers" for the whole port.
rem
rem That block was real for glib the LIBRARY and not for the header. The layout,
rem fit and zoom-anchor comparisons use glib only for its integer typedefs, its
rem MAX/MIN/CLAMP macros and G_N_ELEMENTS, and portable/win/tests/glib_shim
rem supplies exactly those -- glib's own macro bodies character for character,
rem because the comparison order at the edges (CLAMP with high < low, MAX with a
rem NaN) is part of what is being checked.
rem
rem It is arguably a PURER check than the macOS-side run: both implementations are
rem compiled by the same compiler into the same binary, so a difference cannot be
rem a floating-point difference between two toolchains and can only be a
rem transcription error.
rem
rem WHAT IS SKIPPED, AND WHY IT IS SKIPPED RATHER THAN FAKED.
rem -DSPDF_DIFFERENTIAL_NO_LRU drops the two spdf_lru_* comparisons. They are
rem backed by a real GHashTable, and glib leaves hash ITERATION ORDER
rem unspecified -- so an eviction that picks its victim by iterating would pick a
rem different, equally correct victim under a shim, and this differential would
rem report a mismatch that is not a transcription error. A test that can cry wolf
rem is worse than one that admits it cannot run. Those two still run on macOS and
rem Linux, where real glib is linked. Run portable/win/tests/run-tests.sh from a
rem Mac for the complete set.
rem
rem CONTRACT: this script's exit code is the whole truth.
rem   0  every comparison identical
rem   1  at least one comparison DIFFERs -- a transcription error
rem   2  a struct layout changed, so the differential could not reinterpret
rem   3  the matrix did not run (too few comparisons to be meaningful)
rem   64+ this script could not do its job
rem
rem INVOKE IT BY PATH: this box has NoDefaultCurrentDirectoryInExePath=1, so cmd
rem will not find a .cmd in the current directory.
setlocal EnableExtensions DisableDelayedExpansion

for %%I in ("%~dp0..\..\..") do set "REPO=%%~fI"
if not exist "%REPO%\portable\core\shenzhen_pdf_core.h" (
  echo [layout-differential] "%REPO%" does not look like the ShenzhenPDF repo
  exit /b 93
)
if not exist "%REPO%\portable\linux\gtk4\spdf_docview_internal.h" (
  echo [layout-differential] the GTK4 frontend headers are missing -- nothing to compare against
  exit /b 94
)

if not defined SPDF_OUT set "SPDF_OUT=C:\spdf-build"
if not defined SPDF_ARCH set "SPDF_ARCH=x64"

rem cl.exe may already be on PATH; only pay for vcvarsall when it is not.
where cl.exe >nul 2>&1
if not errorlevel 1 goto have_cl
if not defined SPDF_VCVARS set "SPDF_VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat"
if not exist "%SPDF_VCVARS%" (
  echo [layout-differential] no vcvarsall.bat at "%SPDF_VCVARS%" -- set SPDF_VCVARS
  exit /b 91
)
rem vcvarsall prints "'vswhere.exe' is not recognized" on stderr on a box with
rem NoDefaultCurrentDirectoryInExePath=1 and still returns 0. Judge it by the
rem exit code and by whether cl appeared, never by its output.
call "%SPDF_VCVARS%" %SPDF_ARCH% >nul
if errorlevel 1 (
  echo [layout-differential] vcvarsall failed
  exit /b 92
)
where cl.exe >nul 2>&1
if errorlevel 1 (
  echo [layout-differential] cl.exe still not on PATH after vcvarsall
  exit /b 92
)
:have_cl

set "OBJ=%SPDF_OUT%\obj-layout-differential"
if not exist "%SPDF_OUT%" mkdir "%SPDF_OUT%"
if not exist "%OBJ%" mkdir "%OBJ%"

rem /I order matters: glib_shim must be reachable, and the GTK4 directory is
rem where spdf_docview_internal.h lives. No MuPDF and no libraries -- this
rem differential is pure arithmetic over two headers.
cl /nologo /W3 /O2 /MT /utf-8 /DSPDF_DIFFERENTIAL_NO_LRU /D_CRT_SECURE_NO_WARNINGS ^
   /I "%REPO%\portable\core" ^
   /I "%REPO%\portable\win\src" ^
   /I "%REPO%\portable\linux\gtk4" ^
   /I "%REPO%\portable\win\tests\glib_shim" ^
   "%REPO%\portable\win\tests\gtk_differential.c" ^
   /Fe:"%SPDF_OUT%\layout_differential.exe" /Fo:"%OBJ%\\"
if errorlevel 1 (
  echo [layout-differential] compile failed
  exit /b 65
)

"%SPDF_OUT%\layout_differential.exe"
exit /b %ERRORLEVEL%
