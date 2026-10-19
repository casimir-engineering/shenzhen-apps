#!/usr/bin/env bash
# Build tools_panel_probe.exe (see tools_panel_probe.c) with build-native.cmd
# and run it with the given arguments. Git Bash; honours SPDF_OUT and
# SPDF_MUPDF_LIBDIR like every other native build.
#
#   portable/win/tests/tools_panel.sh ocr 'C:\path\scan.pdf' 'C:\path\panel.bmp' [dark]
#   portable/win/tests/tools_panel.sh selection 'C:\path\a.pdf' 'C:\path\panel.bmp' 产品设计 [dark]
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
export SPDF_OUT="${SPDF_OUT:-C:\\spdf-build}"
BUILD_CMD="$(cygpath -w "$REPO_ROOT/portable/win/build-native.cmd")"
SOURCES=(
  portable/win/tests/tools_panel_probe.c
  portable/win/src/spdf_win_panel.cpp portable/win/src/spdf_win_panel_controls.cpp
  portable/win/src/spdf_win_panel_jobs.cpp
  portable/win/src/spdf_win_toolchain.cpp portable/win/src/spdf_win_toolchain_cmd.cpp
  portable/win/src/spdf_win_toolchain_plan.cpp portable/win/src/spdf_win_toolchain_run.cpp
  portable/win/src/spdf_win_toolchain_process.cpp portable/win/src/spdf_win_toolchain_install.cpp
  portable/win/src/spdf_win_ocr.cpp portable/win/src/spdf_win_translate.cpp
  portable/win/src/spdf_win_translate_run.cpp portable/win/src/spdf_win_state.c
  portable/win/src/spdf_win_paths.c portable/core/spdf_yaml.c
  portable/core/shenzhen_pdf_core.c portable/core/spdf_selection.c
  portable/core/spdf_selection_support.c portable/core/spdf_recolor.c portable/core/spdf_win_compat.c
)
MSYS2_ARG_CONV_EXCL='*' cmd.exe /c "$BUILD_CMD" tools_panel_probe "${SOURCES[@]}" > "$SPDF_OUT/tools_panel_probe.build.log" 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then
  echo "tools_panel: build failed ($rc)"; tail -20 "$SPDF_OUT/tools_panel_probe.build.log"; exit $rc
fi
"$SPDF_OUT/tools_panel_probe.exe" "$@"
