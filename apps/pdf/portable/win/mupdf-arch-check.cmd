@echo off
rem Print the COFF machine type of every member of the built MuPDF libraries and
rem of a named executable. Guest half of portable/win/mupdf-arch-check.sh.
rem
rem   mupdf-arch-check.cmd [extra.exe]
rem
rem WHY THIS EXISTS: Windows on ARM runs x64 binaries under emulation without
rem complaint, so a build that silently targeted the wrong architecture looks
rem like a working build. It is only slower and subtly different -- exactly the
rem sort of thing that would poison a macOS-vs-Windows pixel comparison months
rem later. dumpbin reports the truth per object; the Mac side counts.
rem
rem Output is one "        AA64 machine (ARM64)" line per object, plus a
rem "== <name>" banner before each input. Nothing else, so the caller can parse
rem it with no cleverness.
setlocal EnableExtensions

set "SPDF_OUT=C:\spdf-build"
set "MUPDF_OUT=%SPDF_OUT%\mupdf"

set "VCVARS=C:\BuildTools\VC\Auxiliary\Build\vcvarsall.bat"
if not exist "%VCVARS%" (
  echo [guest] no vcvarsall.bat found
  exit /b 91
)
call "%VCVARS%" arm64 >nul
if errorlevel 1 (
  echo [guest] vcvarsall failed
  exit /b 92
)

if not exist "%MUPDF_OUT%\libmupdf.lib" (
  echo [guest] no libmupdf.lib -- run portable/win/mupdf-build.sh
  exit /b 93
)

echo == libmupdf.lib
dumpbin /nologo /headers "%MUPDF_OUT%\libmupdf.lib" | findstr /C:"machine ("
echo == libmupdf-third.lib
dumpbin /nologo /headers "%MUPDF_OUT%\libmupdf-third.lib" | findstr /C:"machine ("
if not "%~1"=="" (
  if exist "%SPDF_OUT%\%~1" (
    echo == %~1
    dumpbin /nologo /headers "%SPDF_OUT%\%~1" | findstr /C:"machine ("
  ) else (
    echo [guest] no such binary: %SPDF_OUT%\%~1
    exit /b 94
  )
)
exit /b 0
