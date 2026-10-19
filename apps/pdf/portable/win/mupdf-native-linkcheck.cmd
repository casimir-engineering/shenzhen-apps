@echo off
rem Compile, link and RUN portable\win\mupdf-native-linkcheck.c against the x64
rem libmupdf built by portable\win\mupdf-native-build.cmd.
rem
rem   portable\win\mupdf-native-linkcheck.cmd [file.pdf] [page] [zoom]
rem
rem Defaults to portable\win\tests\fixtures\golden.pdf page 0 zoom 1.0. (It only
rem READS that fixture; the tests directory belongs to another track.)
rem
rem This is the "does it link and does it run" half of the proof that
rem mupdf-arch-check-native.cmd cannot give: dumpbin can confirm every member is
rem x64 and still say nothing about whether the archive is usable. It uses the
rem same CRT, stack size and system libraries as portable\win\guest-build.cmd,
rem so a failure here is a real failure of the frontend's link line and not of
rem some unrelated flag set.
rem
rem The script's exit code is the program's exit code (see the .c for the codes),
rem or 9x for infrastructure. Judge by the exit code, never by grepping stdout.
setlocal EnableExtensions EnableDelayedExpansion

set "SPDF_WIN=%~dp0"
if "%SPDF_WIN:~-1%"=="\" set "SPDF_WIN=%SPDF_WIN:~0,-1%"
for %%i in ("%SPDF_WIN%\..\..") do set "REPO=%%~fi"

if "%SPDF_MUPDF_OUT%"=="" set "SPDF_MUPDF_OUT=C:\spdf-build\mupdf"
set "WORK=%SPDF_MUPDF_OUT%\linkcheck"

set "PDF=%~1"
if "%PDF%"=="" set "PDF=%SPDF_WIN%\tests\fixtures\golden.pdf"
set "PAGE=%~2"
if "%PAGE%"=="" set "PAGE=0"
set "ZOOM=%~3"
if "%ZOOM%"=="" set "ZOOM=1.0"

set "VCVARS=%ProgramFiles(x86)%\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat"
if not exist "%VCVARS%" (
  set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
  if exist "!VSWHERE!" (
    for /f "usebackq tokens=*" %%i in (`"!VSWHERE!" -products * -latest -property installationPath`) do set "VS_PATH=%%i"
  )
  if defined VS_PATH set "VCVARS=!VS_PATH!\VC\Auxiliary\Build\vcvarsall.bat"
)
if not exist "%VCVARS%" (
  echo [linkcheck] no vcvarsall.bat found
  exit /b 91
)
rem vcvarsall leaks "'vswhere.exe' is not recognized" on stderr here and still
rem succeeds. Judge by the exit code.
call "%VCVARS%" x64 >nul
if errorlevel 1 (
  echo [linkcheck] vcvarsall x64 failed
  exit /b 92
)

if not exist "%SPDF_MUPDF_OUT%\libmupdf.lib" (
  echo [linkcheck] no libmupdf.lib in %SPDF_MUPDF_OUT% -- run mupdf-native-build.cmd
  exit /b 93
)
if not exist "%SPDF_MUPDF_OUT%\libmupdf-third.lib" (
  echo [linkcheck] no libmupdf-third.lib in %SPDF_MUPDF_OUT%
  exit /b 93
)
if not exist "%PDF%" (
  echo [linkcheck] no such PDF: %PDF%
  exit /b 94
)

if not exist "%WORK%" mkdir "%WORK%"

rem Same flags as guest-build.cmd's app link: /MT because libmupdf.lib is /MT and
rem mixing CRTs produces link errors that read like missing symbols, and
rem /STACK:8388608 to match macOS's 8 MB main thread (Windows defaults to 1 MB,
rem which MuPDF's content-stream and CSS recursion can outrun).
echo [linkcheck] compiling and linking ...
cl /nologo /W3 /O2 /MT /utf-8 /D_CRT_SECURE_NO_WARNINGS ^
   -I"%REPO%\mupdf\include" ^
   "%SPDF_WIN%\mupdf-native-linkcheck.c" ^
   /Fo"%WORK%\\" /Fe"%WORK%\mupdf-native-linkcheck.exe" ^
   /link /STACK:8388608 ^
   "%SPDF_MUPDF_OUT%\libmupdf.lib" "%SPDF_MUPDF_OUT%\libmupdf-third.lib" ^
   user32.lib gdi32.lib shell32.lib ole32.lib oleaut32.lib advapi32.lib ^
   shcore.lib d2d1.lib dwrite.lib windowscodecs.lib uuid.lib
if errorlevel 1 (
  echo [linkcheck] compile/link FAILED
  exit /b 95
)

echo [linkcheck] running: %PDF% page %PAGE% zoom %ZOOM%
"%WORK%\mupdf-native-linkcheck.exe" "%PDF%" %PAGE% %ZOOM%
set "RUN_RC=%ERRORLEVEL%"
if not "%RUN_RC%"=="0" echo [linkcheck] program exited %RUN_RC%
exit /b %RUN_RC%
