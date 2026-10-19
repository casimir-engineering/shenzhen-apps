@echo off
rem Assert that EVERY member of the built MuPDF libraries is native x64.
rem Native-x64-host sibling of portable\win\mupdf-arch-check.cmd, which asserts
rem AA64 for the ARM64 Parallels guest.
rem
rem   portable\win\mupdf-arch-check-native.cmd [extra.exe ...]
rem
rem WHY THIS EXISTS: "it built and it ran" proves nothing about the target
rem architecture. Windows on ARM runs x64 under emulation silently, and on an
rem x64 host a stray 32-bit (014C) object can still link on some paths. Either
rem way a mis-targeted object would make the whole native-build claim false, and
rem it would only surface much later as a poisoned macOS-vs-Windows pixel
rem comparison. dumpbin reports the truth per object; this counts.
rem
rem Unlike its ARM64 sibling, which prints one line per object and lets the Mac
rem side count, this script does the counting itself and its EXIT CODE is the
rem answer -- there is no other host to parse the output here.
rem
rem   exit 0   every member is 8664 (x64)
rem   exit 1   at least one member is not; the offending machine types are listed
rem   exit 9x  infrastructure
setlocal EnableExtensions EnableDelayedExpansion

if "%SPDF_MUPDF_OUT%"=="" set "SPDF_MUPDF_OUT=C:\spdf-build\mupdf"

set "VCVARS=%ProgramFiles(x86)%\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat"
if not exist "%VCVARS%" (
  set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
  if exist "!VSWHERE!" (
    for /f "usebackq tokens=*" %%i in (`"!VSWHERE!" -products * -latest -property installationPath`) do set "VS_PATH=%%i"
  )
  if defined VS_PATH set "VCVARS=!VS_PATH!\VC\Auxiliary\Build\vcvarsall.bat"
)
if not exist "%VCVARS%" (
  echo [arch] no vcvarsall.bat found
  exit /b 91
)
rem vcvarsall leaks "'vswhere.exe' is not recognized" on stderr on this box and
rem still succeeds. Judge by the exit code.
call "%VCVARS%" x64 >nul
if errorlevel 1 (
  echo [arch] vcvarsall x64 failed
  exit /b 92
)

if not exist "%SPDF_MUPDF_OUT%\libmupdf.lib" (
  echo [arch] no libmupdf.lib in %SPDF_MUPDF_OUT% -- run mupdf-native-build.cmd
  exit /b 93
)

set "BAD=0"
set "TOTAL=0"
call :check "%SPDF_MUPDF_OUT%\libmupdf.lib"
call :check "%SPDF_MUPDF_OUT%\libmupdf-third.lib"
:extras
if "%~1"=="" goto done
call :check "%~1"
shift
goto extras

:done
if not "%BAD%"=="0" (
  echo ARCH CHECK FAILED: %BAD% of %TOTAL% members are not 8664
  exit /b 1
)
echo ARCH CHECK OK: all %TOTAL% members are 8664 ^(native x64^)
exit /b 0

:check
rem dumpbin /headers prints one "        8664 machine (x64)" line per member.
rem Counting the total and the matching lines separately is what makes this a
rem proof rather than a spot check: a member whose header dumpbin could not read
rem at all would change TOTAL without changing the match count.
if not exist "%~1" (
  echo [arch] no such binary: %~1
  exit /b 94
)
set "N=0"
set "OK=0"
for /f "usebackq delims=" %%L in (`dumpbin /nologo /headers "%~1" ^| findstr /C:"machine ("`) do (
  set /a N+=1
  echo %%L | findstr /C:"8664 machine" >nul
  if not errorlevel 1 set /a OK+=1
)
set /a TOTAL+=N
set /a BAD+=N-OK
if "%N%"=="0" (
  echo [arch] %~nx1: dumpbin reported no machine lines at all
  set /a BAD+=1
  goto :eof
)
if "%N%"=="%OK%" (
  echo    %~nx1  %N% members  8664 x64
) else (
  echo    %~nx1  %N% members  ONLY %OK% ARE 8664 -- listing the others:
  dumpbin /nologo /headers "%~1" | findstr /C:"machine (" | findstr /V /C:"8664 machine"
)
goto :eof
