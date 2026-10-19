@echo off
rem Build and run portable/win/tests/minimap_differential.c natively.
rem
rem It needs two include paths build-native.cmd does not carry -- the GTK4
rem frontend's headers and portable/win/tests/glib_shim -- and build-native.cmd's
rem include list belongs to the build track, so this driver invokes cl.exe
rem directly. Same relationship portable/win/tests/t3-verify.sh has to
rem gtk_differential.c on the Mac side.
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
  echo [minimap-differential] "%REPO%" does not look like the ShenzhenPDF repo
  exit /b 93
)
if not defined SPDF_OUT set "SPDF_OUT=C:\spdf-build"
if not defined SPDF_ARCH set "SPDF_ARCH=x64"

where cl.exe >nul 2>&1
if not errorlevel 1 goto have_cl
if not defined SPDF_VCVARS set "SPDF_VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat"
if not exist "%SPDF_VCVARS%" (
  echo [minimap-differential] no vcvarsall.bat at "%SPDF_VCVARS%"; set SPDF_VCVARS
  exit /b 91
)
rem vcvarsall.bat prints a harmless 'vswhere.exe is not recognized' here and
rem still returns 0. Judged by exit code, never by output.
call "%SPDF_VCVARS%" %SPDF_ARCH% >nul
if errorlevel 1 (
  echo [minimap-differential] vcvarsall.bat %SPDF_ARCH% failed
  exit /b 92
)
:have_cl

if not exist "%SPDF_OUT%" mkdir "%SPDF_OUT%"

rem /fp:precise is MSVC's default and does not contract a*b+c into an FMA, which
rem matters here for the same reason spdf_win_layout.h's header comment gives:
rem both sides must evaluate the same operations in the same order.
rem _CRT_SECURE_NO_WARNINGS: the labels are built with sprintf into fixed buffers
rem whose lengths are bounded by the fixture names, and 130k C4996 lines would
rem bury a real DIFFER line. The verdict is the exit code either way.
cl.exe /nologo /W3 /O2 /fp:precise /MD /TC /D_CRT_SECURE_NO_WARNINGS ^
  /I"%REPO%\portable\core" /I"%REPO%\portable\win\src" /I"%REPO%\portable\linux\gtk4" ^
  /I"%~dp0glib_shim" ^
  /Fo"%SPDF_OUT%\minimap_differential." /Fe"%SPDF_OUT%\minimap_differential.exe" ^
  "%~dp0minimap_differential.c"
if errorlevel 1 (
  echo [minimap-differential] cl.exe failed
  exit /b 65
)

"%SPDF_OUT%\minimap_differential.exe"
exit /b %ERRORLEVEL%
