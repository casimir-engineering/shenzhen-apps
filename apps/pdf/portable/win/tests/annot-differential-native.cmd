@echo off
rem Build and run portable/win/tests/annot_differential.c natively.
rem
rem Exactly the shape of sidebar-differential-native.cmd, with the annotations
rem shim on top: glib_shim_annot layers on glib_shim_search which layers on
rem glib_shim, so all three directories are on the include path and the annot
rem one comes FIRST -- it is the one that must resolve as <glib.h>, and it also
rem supplies the <unistd.h> and <glib/gstdio.h> spdf_annot.c includes.
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
  echo [annot-differential] "%REPO%" does not look like the ShenzhenPDF repo
  exit /b 93
)
if not defined SPDF_OUT set "SPDF_OUT=C:\spdf-build"
if not defined SPDF_ARCH set "SPDF_ARCH=x64"

where cl.exe >nul 2>&1
if not errorlevel 1 goto have_cl
if not defined SPDF_VCVARS set "SPDF_VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat"
if not exist "%SPDF_VCVARS%" (
  echo [annot-differential] no vcvarsall.bat at "%SPDF_VCVARS%"; set SPDF_VCVARS
  exit /b 91
)
rem vcvarsall.bat prints a harmless 'vswhere.exe is not recognized' here and
rem still returns 0. Judged by exit code, never by output.
call "%SPDF_VCVARS%" %SPDF_ARCH% >nul
if errorlevel 1 (
  echo [annot-differential] vcvarsall.bat %SPDF_ARCH% failed
  exit /b 92
)
:have_cl

if not exist "%SPDF_OUT%" mkdir "%SPDF_OUT%"

rem /wd4505: the layered shims define every helper `static`, and the ones this
rem differential does not reach are removed unreferenced -- which is the point
rem of them being static. Same flags as the sidebar differential otherwise.
cl.exe /nologo /W3 /O2 /fp:precise /MD /TC /D_CRT_SECURE_NO_WARNINGS /wd4505 ^
  /I"%~dp0glib_shim_annot" /I"%~dp0glib_shim_search" /I"%~dp0glib_shim" ^
  /I"%REPO%\portable\core" /I"%REPO%\portable\win\src" /I"%REPO%\portable\linux\gtk4" ^
  /Fo"%SPDF_OUT%\annot_differential." /Fe"%SPDF_OUT%\annot_differential.exe" ^
  "%~dp0annot_differential.c"
if errorlevel 1 (
  echo [annot-differential] cl.exe failed
  exit /b 65
)

"%SPDF_OUT%\annot_differential.exe"
exit /b %ERRORLEVEL%
