@echo off
rem Guest-side half of the cross-machine build.
rem
rem Runs INSIDE the Parallels VM, normally invoked by portable/win/vm-build.sh as
rem   prlctl exec "Windows 11" cmd.exe /c "\\Mac\Home\Documents\spdf-win\portable\win\guest-build.cmd <target> <src>..."
rem
rem Usage: guest-build.cmd <target-name> <source>... [source paths are relative to the staged tree]
rem
rem Contract: this script's exit code IS the compiler's exit code. Nothing here
rem may swallow a failure -- portable/win/vm-build.sh reports it verbatim to the
rem Mac shell, and every later agent's "did it build?" check depends on it.
rem Infrastructure failures (copy, toolchain discovery) use codes 90+ so they are
rem distinguishable from a genuine compile error (cl.exe returns 2).
rem NB: every conditional below uses a parenthesised block. The tempting
rem one-liner "if errorlevel 8 echo msg & exit /b 90" is WRONG in cmd: the &
rem chain is parsed as a sibling command, so the exit runs unconditionally and
rem the script fails every build. Do not "simplify" these back.
setlocal EnableExtensions

set "SPDF_SRC=\\Mac\Home\Documents\spdf-win"
rem Build from a LOCAL directory, never from the \\Mac share: the compiler opens
rem headers many times over and the Parallels shared-folder redirector makes each
rem open a round trip. See portable/win/README.md for the measured difference.
set "SPDF_DST=C:\spdf"
set "SPDF_OUT=C:\spdf-build"

set "TARGET=%~1"
if "%TARGET%"=="" (
  echo [guest] usage: guest-build.cmd ^<target^> ^<source^>...
  exit /b 64
)
shift

set "SOURCES="
:collect
if "%~1"=="" goto collected
set "SOURCES=%SOURCES% "%SPDF_DST%\%~1""
shift
goto collect
:collected
if "%SOURCES%"=="" (
  echo [guest] no sources given
  exit /b 64
)

rem ---- 1. Refresh the local copy from the share --------------------------
rem /MIR mirrors, so this is idempotent and cheap after the first run (robocopy
rem skips same-size-same-timestamp files). SPDF_OUT deliberately lives OUTSIDE
rem SPDF_DST so /MIR never deletes build output.
if not exist "%SPDF_OUT%" mkdir "%SPDF_OUT%"
robocopy "%SPDF_SRC%" "%SPDF_DST%" /MIR /NFL /NDL /NJH /NJS /NP /R:1 /W:1 >nul
rem robocopy's exit code is a bit field: <8 means success (0=no change, 1=copied,
rem 2=extras, 3=both...). Only >=8 is a real failure. This is the classic
rem robocopy-in-CI trap -- a plain "if errorlevel 1" here would fail every build
rem that actually copied something.
if errorlevel 8 (
  echo [guest] robocopy failed with %ERRORLEVEL%
  exit /b 90
)

rem ---- 2. Enter the MSVC environment -------------------------------------
set "VCVARS=C:\BuildTools\VC\Auxiliary\Build\vcvarsall.bat"
if not exist "%VCVARS%" call :find_vcvars
if not exist "%VCVARS%" (
  echo [guest] no vcvarsall.bat found
  exit /b 91
)

rem "arm64" here means host=ARM64, target=ARM64. The guest is ARM64 Windows, so
rem this is the native, non-emulated toolchain. Using "x64" would silently build
rem an x64 binary that runs only under emulation.
call "%VCVARS%" arm64 >nul
if errorlevel 1 (
  echo [guest] vcvarsall failed
  exit /b 92
)

rem ---- 3. Work out what to link against ----------------------------------
rem MuPDF, when it has been built. portable/win/mupdf-build.sh puts the two
rem static libraries here; see portable/win/README.md, "The linking interface".
rem They are linked WHEN PRESENT rather than required, so the four tracks whose
rem code is pure C (layout, compat, paths, tests) keep building on a machine
rem where MuPDF has never been built. The linker only pulls in the objects a
rem symbol actually needs, so a target that ignores MuPDF pays nothing but the
rem cost of opening the archives.
set "MUPDF_INC=%SPDF_DST%\mupdf\include"
set "MUPDF_LIBDIR=%SPDF_OUT%\mupdf"
set "MUPDF_LIBS="
if exist "%MUPDF_LIBDIR%\libmupdf.lib" (
  if exist "%MUPDF_LIBDIR%\libmupdf-third.lib" (
    set "MUPDF_LIBS=%MUPDF_LIBDIR%\libmupdf.lib %MUPDF_LIBDIR%\libmupdf-third.lib"
  )
)
if not defined MUPDF_LIBS echo [guest] note: no libmupdf.lib yet -- run portable/win/mupdf-build.sh

rem System import libraries the Windows frontend needs. Listing them here means
rem no track has to edit this file to get a Direct2D/DirectWrite/WIC target to
rem link: an unused import library costs nothing in the produced binary.
set "SYS_LIBS=user32.lib gdi32.lib shell32.lib ole32.lib oleaut32.lib advapi32.lib shcore.lib d2d1.lib dwrite.lib windowscodecs.lib uuid.lib"

rem ---- 4. Compile --------------------------------------------------------
rem Per-target object directory: several repo sources share a basename
rem (buffer.c, image.c, util.c...), and a flat /Fo would have them overwrite
rem each other. /Fo needs the trailing backslash to mean "directory".
set "OBJ_DIR=%SPDF_OUT%\obj-%TARGET%"
if not exist "%OBJ_DIR%" mkdir "%OBJ_DIR%"

rem /MT is cl.exe's default and is stated explicitly because libmupdf.lib is
rem built /MT too -- mixing CRTs produces link errors that read like missing
rem symbols. /STACK matches macOS's 8 MB main thread: Windows defaults to 1 MB
rem and MuPDF's content-stream and CSS recursion can outrun that on real files.
cl /nologo /W3 /O2 /MT /utf-8 /D_CRT_SECURE_NO_WARNINGS ^
   /I"%SPDF_DST%\portable\core" /I"%SPDF_DST%\portable\win\src" /I"%MUPDF_INC%" ^
   %SOURCES% /Fe:"%SPDF_OUT%\%TARGET%.exe" /Fo:"%OBJ_DIR%\\" ^
   /link /STACK:8388608 %MUPDF_LIBS% %SYS_LIBS%
set "CL_RC=%ERRORLEVEL%"
if not "%CL_RC%"=="0" echo [guest] cl.exe exited %CL_RC%
exit /b %CL_RC%

:find_vcvars
rem Fallback for an install that did not land in C:\BuildTools. vswhere ships
rem with any VS installer and knows where every instance lives.
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" goto :eof
for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -products * -latest -property installationPath`) do set "VS_PATH=%%i"
if defined VS_PATH set "VCVARS=%VS_PATH%\VC\Auxiliary\Build\vcvarsall.bat"
goto :eof
