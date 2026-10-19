@echo off
rem Build and run portable/win/tests/palette_differential.c natively.
rem
rem Exactly the shape of search-differential-native.cmd: the pure half of a REAL
rem GTK4 source file (portable/linux/gtk4/spdf_palette.c, under
rem SPDF_PALETTE_TESTING) compiled under MSVC beside the port, over a glib shim
rem that LAYERS on the shared one -- so glib_shim_palette must come FIRST on the
rem include path, and it reaches glib_shim by relative path.
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
  echo [palette-differential] "%REPO%" does not look like the ShenzhenPDF repo
  exit /b 93
)
if not defined SPDF_OUT set "SPDF_OUT=C:\spdf-build"
if not defined SPDF_ARCH set "SPDF_ARCH=x64"

where cl.exe >nul 2>&1
if not errorlevel 1 goto have_cl
if not defined SPDF_VCVARS set "SPDF_VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat"
if not exist "%SPDF_VCVARS%" (
  echo [palette-differential] no vcvarsall.bat at "%SPDF_VCVARS%"; set SPDF_VCVARS
  exit /b 91
)
call "%SPDF_VCVARS%" %SPDF_ARCH% >nul
if errorlevel 1 (
  echo [palette-differential] vcvarsall.bat %SPDF_ARCH% failed
  exit /b 92
)
:have_cl

if not exist "%SPDF_OUT%" mkdir "%SPDF_OUT%"

rem /TC: the GTK source is C and so is the port's header. /wd4505: the layered
rem shim defines every helper `static` and the ones this differential does not
rem reach are removed unreferenced, which is the point of them being static.
cl.exe /nologo /W3 /O2 /MD /TC /D_CRT_SECURE_NO_WARNINGS /wd4505 ^
  /I"%~dp0glib_shim_palette" /I"%~dp0glib_shim" ^
  /I"%REPO%\portable\core" /I"%REPO%\portable\win\src" /I"%REPO%\portable\linux\gtk4" ^
  /Fo"%SPDF_OUT%\palette_differential." /Fe"%SPDF_OUT%\palette_differential.exe" ^
  "%~dp0palette_differential.c"
if errorlevel 1 (
  echo [palette-differential] cl.exe failed
  exit /b 65
)

"%SPDF_OUT%\palette_differential.exe"
exit /b %ERRORLEVEL%
