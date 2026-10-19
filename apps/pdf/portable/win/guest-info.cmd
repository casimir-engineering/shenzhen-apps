@echo off
rem Prints the guest toolchain identity. Run from the Mac with:
rem   prlctl exec "Windows 11" cmd.exe /c "\\Mac\Home\Documents\spdf-win\portable\win\guest-info.cmd"
rem
rem This is a SCRIPT rather than a chained one-liner on purpose: vcvarsall.bat
rem misbehaves when it is invoked as part of a cmd `&` chain through prlctl
rem (it reports "The system cannot find the path specified." and sets nothing).
rem Inside a .cmd file it works normally.
setlocal EnableExtensions

echo == host ==
echo PROCESSOR_ARCHITECTURE=%PROCESSOR_ARCHITECTURE%
ver

set "VCVARS=C:\BuildTools\VC\Auxiliary\Build\vcvarsall.bat"
if not exist "%VCVARS%" (
  echo no vcvarsall at %VCVARS%
  exit /b 91
)
call "%VCVARS%" arm64 >nul
if errorlevel 1 (
  echo vcvarsall failed
  exit /b 92
)

echo.
echo == compiler ==
cl 2>&1 | findstr /C:"Compiler Version"
where cl

echo.
echo == cmake / ninja ==
cmake --version 2>nul | findstr /C:"cmake version"
if errorlevel 1 echo cmake: NOT on PATH
ninja --version 2>nul
if errorlevel 1 echo ninja: NOT on PATH

echo.
echo == machine type of the last smoke build ==
if exist "C:\spdf-build\recolor_smoke.exe" dumpbin /headers "C:\spdf-build\recolor_smoke.exe" 2>nul | findstr /C:"machine"
exit /b 0
