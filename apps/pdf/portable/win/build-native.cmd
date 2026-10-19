@echo off
rem Native Windows build. No VM, no prlctl, no \\Mac share -- this runs on the
rem Windows box that owns the checkout.
rem
rem   portable\win\build-native.cmd                          build ShenzhenPDF.exe
rem   portable\win\build-native.cmd <target> <source>...     build one target
rem   portable\win\build-native.cmd --print-sources          print the app source list
rem   portable\win\build-native.cmd --help
rem
rem Sources are REPO-RELATIVE (either slash works): portable/core/spdf_yaml.c.
rem
rem INVOKE IT BY PATH. This box has NoDefaultCurrentDirectoryInExePath=1, so a
rem bare `build-native.cmd` is not found even from portable\win. Use
rem `.\build-native.cmd` or an absolute path. Nothing here depends on the
rem current directory: the repo root is derived from %~dp0 and every source is
rem handed to cl.exe as an absolute path.
rem
rem CONTRACT: this script's exit code IS cl.exe's exit code, verbatim. Nothing
rem here may swallow a failure -- portable/win/tests/run-tests-native.sh reads
rem it as the whole truth about whether a target built, and so does every
rem "did it build?" check after this. Infrastructure failures use codes 64-93 so
rem they stay distinguishable from a genuine compile error (cl.exe returns 2).
rem
rem NB: every conditional below uses a parenthesised block. The tempting
rem one-liner "if errorlevel 1 echo msg & exit /b 90" is WRONG in cmd: the &
rem chain is parsed as a sibling command, so the exit runs unconditionally and
rem the script fails every build. Do not "simplify" these back.
rem
rem Delayed expansion is deliberately OFF. The MSVC environment vcvarsall.bat
rem installs is large and not guaranteed free of `!`, and the source list is
rem accumulated through :add_source, which needs no `!` at all.
rem
rem THE SOURCE LIST IS A RESPONSE FILE, NOT A VARIABLE. cmd caps a command line
rem -- including the expansion of `set "SOURCES=%SOURCES% ..."` -- at 8191
rem characters, and the app is ~70 translation units named by ABSOLUTE path:
rem from a git worktree under .claude\worktrees\<id>\ that is ~9 KB, and the
rem script died with "The input line is too long" before cl.exe ever ran. So
rem :add_source appends each source, quoted, as one line of
rem %SPDF_OUT%\obj-<target>\sources.rsp and cl.exe reads it with @file, which
rem has no such limit. --print-sources prints that file.
setlocal EnableExtensions DisableDelayedExpansion

for %%I in ("%~dp0..\..") do set "REPO=%%~fI"
if not exist "%REPO%\portable\core\shenzhen_pdf_core.h" (
  echo [build-native] "%REPO%" does not look like the ShenzhenPDF repo
  exit /b 93
)

rem Build output lives outside the checkout, matching guest-build.cmd, so a
rem clean/sync can never delete it and .gitignore never has to chase it.
if not defined SPDF_OUT set "SPDF_OUT=C:\spdf-build"
if not defined SPDF_ARCH set "SPDF_ARCH=x64"

rem ---- 0. Arguments ------------------------------------------------------
set "TARGET="
set "RSP="
set "SOURCE_COUNT=0"
set "PRINT_ONLY="

if "%~1"=="" goto app_target
if /i "%~1"=="--help" goto usage
if /i "%~1"=="-h" goto usage
if /i "%~1"=="--print-sources" (
  set "PRINT_ONLY=1"
  goto app_target
)
if /i "%~1"=="--app" (
  shift
  goto app_target
)

set "TARGET=%~1"
call :begin_sources
shift
:collect
if "%~1"=="" goto collected
call :add_source "%~1"
if errorlevel 1 exit /b 65
shift
goto collect
:collected
if "%SOURCE_COUNT%"=="0" (
  echo [build-native] target "%TARGET%" was given no sources
  exit /b 64
)
goto have_sources

:app_target
rem The app's own translation units are DISCOVERED, never listed: a track that
rem adds portable\win\src\spdf_win_whatever.cpp must not have to edit this file,
rem and must not silently drop out of the build either. Same approach as
rem portable/win/tests/d2d-cases.sh:92.
set "TARGET=ShenzhenPDF"
call :begin_sources
for %%F in ("%REPO%\portable\win\src\*.c" "%REPO%\portable\win\src\*.cpp") do call :add_source "portable\win\src\%%~nxF"
if "%SOURCE_COUNT%"=="0" (
  echo [build-native] no sources found under "%REPO%\portable\win\src"
  exit /b 93
)
rem The portable/core units are listed explicitly. portable\core also holds the
rem GTK/mac-shared code and the per-suite test mains, so a wildcard there would
rem pull in translation units this binary must not contain.
rem
rem spdf_win_compat.c IS NOT OPTIONAL and IS NOT under portable\win\src. It is
rem the POSIX shim that shenzhen_pdf_core.c:5, spdf_yaml.c:6 and six core test
rem suites #include. Omitting it produces a wall of
rem   LNK2019: unresolved external symbol spdf_compat_*
rem rather than an error at the file that wanted it, so it belongs in EVERY
rem Windows source list. (run-tests.sh's header comment puts it in
rem portable/win/src; that is wrong.)
for %%F in (shenzhen_pdf_core.c spdf_selection.c spdf_selection_support.c spdf_recolor.c spdf_yaml.c spdf_win_compat.c spdf_markdown.c spdf_markdown_support.c spdf_markdown_html.c spdf_markdown_lang.c spdf_markdown_lex.c spdf_markdown_math.c spdf_markdown_fences.c spdf_markdown_open.c) do call :add_source "portable\core\%%F"
call :add_source "ext\md4c\md4c.c"
if errorlevel 1 exit /b 65

if defined PRINT_ONLY (
  type "%RSP%"
  exit /b 0
)

:have_sources

rem ---- 1. Enter the MSVC environment -------------------------------------
rem Skipped when cl.exe already resolves, so a Developer Command Prompt (or a
rem caller that set the environment up once) does not pay ~1.5s per target.
where cl.exe >nul 2>&1
if not errorlevel 1 goto have_cl

if not defined SPDF_VCVARS call :find_vcvars
if not defined SPDF_VCVARS (
  echo [build-native] no vcvarsall.bat found. Install the VS 2022 C++ build
  echo                tools, or set SPDF_VCVARS to its full path.
  exit /b 91
)
if not exist "%SPDF_VCVARS%" (
  echo [build-native] SPDF_VCVARS does not exist: "%SPDF_VCVARS%"
  exit /b 91
)
rem SPDF_ARCH is host=target. x64 on this box: an x64 host building an x64
rem binary, native and unemulated. On an ARM64 Windows machine set
rem SPDF_ARCH=arm64 -- "x64" there would silently produce a binary that only
rem runs under emulation. vcvarsall prints a banner and, on a Build Tools
rem install without the standalone vswhere, one benign "'vswhere.exe' is not
rem recognized" line; neither is an error, so only the exit code is consulted.
call "%SPDF_VCVARS%" %SPDF_ARCH% >nul 2>&1
if errorlevel 1 (
  echo [build-native] "%SPDF_VCVARS%" %SPDF_ARCH% failed
  exit /b 92
)
where cl.exe >nul 2>&1
if errorlevel 1 (
  echo [build-native] vcvarsall reported success but cl.exe is still not on PATH
  exit /b 92
)
:have_cl

rem ---- 2. Work out what to link against ----------------------------------
rem MuPDF, WHEN it has been built. Linked when present rather than required, so
rem every target whose code is pure C over portable/core keeps building on a
rem machine where MuPDF has never been built. The linker only pulls in the
rem objects a symbol actually needs, so a target that ignores MuPDF pays nothing
rem but the cost of opening the archives. A target that DOES need it fails at
rem the link with unresolved fz_*/pdf_* symbols -- loudly, never silently.
if not defined SPDF_MUPDF_INC set "SPDF_MUPDF_INC=%REPO%\mupdf\include"
if not defined SPDF_MUPDF_LIBDIR set "SPDF_MUPDF_LIBDIR=%SPDF_OUT%\mupdf"
set "MUPDF_LIBS="
if exist "%SPDF_MUPDF_LIBDIR%\libmupdf.lib" (
  if exist "%SPDF_MUPDF_LIBDIR%\libmupdf-third.lib" (
    set "MUPDF_LIBS="%SPDF_MUPDF_LIBDIR%\libmupdf.lib" "%SPDF_MUPDF_LIBDIR%\libmupdf-third.lib""
  )
)
if not defined MUPDF_LIBS echo [build-native] note: no libmupdf.lib in "%SPDF_MUPDF_LIBDIR%" -- MuPDF-dependent targets will not link

rem System import libraries the Windows frontend needs. Listed here so no track
rem has to edit this file to get a Direct2D/DirectWrite/WIC target to link: an
rem unused import library costs nothing in the produced binary.
set "SYS_LIBS=user32.lib gdi32.lib shell32.lib ole32.lib oleaut32.lib advapi32.lib shcore.lib d2d1.lib dwrite.lib windowscodecs.lib uuid.lib"

rem ---- 3. Compile --------------------------------------------------------
rem Per-target object directory: several repo sources share a basename
rem (buffer.c, image.c, util.c...), and a flat /Fo would have them overwrite
rem each other. /Fo needs the trailing backslash to mean "directory".
set "OBJ_DIR=%SPDF_OUT%\obj-%TARGET%"
if not exist "%SPDF_OUT%" mkdir "%SPDF_OUT%"
if not exist "%OBJ_DIR%" mkdir "%OBJ_DIR%"
if not exist "%OBJ_DIR%" (
  echo [build-native] cannot create "%OBJ_DIR%"
  exit /b 90
)

rem Flags copied verbatim from portable/win/guest-build.cmd:112 -- the two build
rem entry points must not drift. /MT is stated explicitly because libmupdf.lib
rem is built /MT too, and mixing CRTs produces link errors that read like
rem missing symbols. /STACK:8388608 matches macOS's 8 MB main thread: Windows
rem defaults to 1 MB and MuPDF's content-stream and CSS recursion can outrun
rem that on real files.
rem THE APP IS A GUI PROGRAM; THE TEST BINARIES ARE CONSOLE PROGRAMS.
rem
rem Without /SUBSYSTEM the linker defaults to CONSOLE because the entry point is
rem main(), and Windows then allocates a terminal window for the app that sits
rem there for the life of the process. Reported from actual use: "it runs from a
rem terminal window that stays open". macOS and GTK show no such thing.
rem
rem /ENTRY:mainCRTStartup keeps main() as written -- the alternative is renaming
rem it to wWinMain, which would gain nothing and cost every caller of
rem CommandLineToArgvW below it.
rem
rem This is applied ONLY to the app. The ~20 test binaries are console programs
rem on purpose: they print their results, and a harness reads them.
rem
rem stdout still works for the harness. Subsystem controls only whether a console
rem is ALLOCATED; when a parent redirects stdout to a pipe or a file -- which is
rem what run-tests-native.d2d.sh and verify-phase1.ps1 do when they parse the
rem `frame ...` geometry lines -- the CRT picks that handle up from STARTUPINFO
rem and printf reaches it unchanged. Measured after this change, not assumed.
set "SUBSYSTEM_FLAGS="
if /i "%TARGET%"=="ShenzhenPDF" set "SUBSYSTEM_FLAGS=/SUBSYSTEM:WINDOWS /ENTRY:mainCRTStartup"

rem ---- 3a. Resources (app only) --------------------------------------------
rem portable\win\spdf_win.rc carries the icon, the manifest (per-monitor-v2
rem DPI, long paths, common controls 6) and VERSIONINFO, with its numbers taken
rem from portable\win\src\spdf_win_about_version.h -- hence the /I. rc.exe
rem ships in the same Windows SDK that provides the headers cl.exe already
rem needs, and vcvarsall puts it on PATH; a missing rc.exe is an infrastructure
rem failure (66), not a compile error, so it stays distinguishable. The .res is
rem handed to cl.exe on the command line, which passes it to the linker.
rem
rem The ~20 test binaries get no resources on purpose: they are console
rem programs, and a manifest declaring PerMonitorV2 would change how the
rem window-opening tests (properties_dialog_test) measure themselves.
set "RES_FILE="
if /i "%TARGET%"=="ShenzhenPDF" (
  where rc.exe >nul 2>&1
  if errorlevel 1 (
    echo [build-native] rc.exe is not on PATH; the Windows SDK that provides it is part of the VS C++ build tools
    exit /b 66
  )
  rc /nologo /I"%REPO%\portable\win\src" /fo"%OBJ_DIR%\spdf_win.res" "%REPO%\portable\win\spdf_win.rc"
  if errorlevel 1 (
    echo [build-native] rc.exe failed on portable\win\spdf_win.rc
    exit /b 66
  )
  set "RES_FILE="%OBJ_DIR%\spdf_win.res""
)

cl /nologo /W3 /O2 /MT /utf-8 /D_CRT_SECURE_NO_WARNINGS ^
   /I"%REPO%\portable\core" /I"%REPO%\portable\win\src" /I"%SPDF_MUPDF_INC%" ^
   @"%RSP%" %RES_FILE% /Fe:"%SPDF_OUT%\%TARGET%.exe" /Fo:"%OBJ_DIR%\\" ^
   /link /STACK:8388608 %SUBSYSTEM_FLAGS% %MUPDF_LIBS% %SYS_LIBS%
set "CL_RC=%ERRORLEVEL%"
if not "%CL_RC%"=="0" echo [build-native] cl.exe exited %CL_RC% building %TARGET%
if "%CL_RC%"=="0" if /i "%TARGET%"=="ShenzhenPDF" call :publish_dist
exit /b %CL_RC%

rem ---- subroutines -------------------------------------------------------

:publish_dist
rem THE ONE PLACE TO LOOK FOR THE APP. %SPDF_OUT% is a working directory: it
rem holds the app beside forty test executables, their object directories and
rem the harness's scratch, and a parallel build points it somewhere else
rem entirely. So the app -- and only the app, not the tests -- is also copied
rem to dist\, next to where the macOS build leaves ShenzhenPDF.app, under the
rem exact name a release carries (portable\win\package-release.cmd writes the
rem same name plus its .sha256 sidecar). dist\ is git-ignored.
rem
rem A FAILED COPY IS NOT A FAILED BUILD: the usual cause is that the last copy
rem is running, which is a thing a reader does on purpose. Say so and leave the
rem build's exit code alone.
if not exist "%REPO%\dist" mkdir "%REPO%\dist"
copy /y "%SPDF_OUT%\%TARGET%.exe" "%REPO%\dist\ShenzhenPDF-win-x64.exe" >nul 2>&1
if errorlevel 1 (
  echo [build-native] built %SPDF_OUT%\%TARGET%.exe, but could not copy it to dist\ShenzhenPDF-win-x64.exe
  echo [build-native] ^(is that copy running? the build itself succeeded^)
  exit /b 0
)
echo [build-native] %SPDF_OUT%\%TARGET%.exe -^> dist\ShenzhenPDF-win-x64.exe
exit /b 0


:begin_sources
rem Start the response file for %TARGET% (see the header): its directory is the
rem per-target object directory, created here because :add_source runs before
rem step 3 does. A stale file from the last build is removed, never appended to.
set "RSP=%SPDF_OUT%\obj-%TARGET%\sources.rsp"
if not exist "%SPDF_OUT%" mkdir "%SPDF_OUT%"
if not exist "%SPDF_OUT%\obj-%TARGET%" mkdir "%SPDF_OUT%\obj-%TARGET%"
if exist "%RSP%" del "%RSP%"
set "SOURCE_COUNT=0"
exit /b 0

:add_source
rem Accept forward or back slashes so a bash caller can pass repo-relative
rem paths exactly as run-tests.sh writes them. Existence is checked HERE: an
rem absent source otherwise reaches cl.exe as C1083 for a path the reader then
rem has to reconstruct out of the command line.
if not exist "%REPO%\%~1" (
  echo [build-native] source does not exist: %~1
  exit /b 1
)
>>"%RSP%" echo "%REPO%\%~1"
set /a SOURCE_COUNT+=1
exit /b 0

:find_vcvars
rem vswhere ships with any VS installer and knows where every instance lives.
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if exist "%VSWHERE%" call :vcvars_from_vswhere
if defined SPDF_VCVARS exit /b 0
rem Fixed fallbacks, in the order a machine is most likely to have them. The
rem bare C:\BuildTools entry is where the Parallels guest keeps its install
rem (guest-build.cmd:62), so one script serves both boxes.
for %%D in (
  "C:\BuildTools"
  "%ProgramFiles%\Microsoft Visual Studio\2022\BuildTools"
  "%ProgramFiles(x86)%\Microsoft Visual Studio\2022\BuildTools"
  "%ProgramFiles%\Microsoft Visual Studio\2022\Community"
  "%ProgramFiles%\Microsoft Visual Studio\2022\Professional"
  "%ProgramFiles%\Microsoft Visual Studio\2022\Enterprise"
) do call :try_vcvars "%%~D"
exit /b 0

:vcvars_from_vswhere
rem A separate subroutine, not a parenthesised block: %VS_PATH% inside the same
rem block as the `for /f` that sets it expands at PARSE time, i.e. to nothing.
rem That is the classic cmd delayed-expansion trap and it fails silently here --
rem the script would fall through to the fixed fallbacks and look fine on this
rem machine while never honouring vswhere on anyone else's.
set "VS_PATH="
for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -products * -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VS_PATH=%%i"
if not defined VS_PATH exit /b 0
call :try_vcvars "%VS_PATH%"
exit /b 0

:try_vcvars
if defined SPDF_VCVARS exit /b 0
if exist "%~1\VC\Auxiliary\Build\vcvarsall.bat" set "SPDF_VCVARS=%~1\VC\Auxiliary\Build\vcvarsall.bat"
exit /b 0

:usage
echo Native Windows build for ShenzhenPDF.
echo.
echo   build-native.cmd                        build ShenzhenPDF.exe
echo   build-native.cmd ^<target^> ^<source^>...   build one target
echo   build-native.cmd --print-sources        print the app source list
echo.
echo Sources are repo-relative. Output goes to %%SPDF_OUT%%\^<target^>.exe.
echo.
echo Environment:
echo   SPDF_OUT           build output directory      (default C:\spdf-build^)
echo   SPDF_ARCH          vcvarsall host=target arch  (default x64^)
echo   SPDF_VCVARS        full path to vcvarsall.bat  (default: discovered^)
echo   SPDF_MUPDF_INC     MuPDF include directory     (default ^<repo^>\mupdf\include^)
echo   SPDF_MUPDF_LIBDIR  libmupdf.lib directory      (default %%SPDF_OUT%%\mupdf^)
echo.
echo Exit codes: cl.exe's own, verbatim, or 64 usage / 65 missing source /
echo 66 rc.exe missing or failed ^(app target^) / 90 output dir / 91 no vcvarsall /
echo 92 vcvarsall failed / 93 bad repo.
exit /b 0
