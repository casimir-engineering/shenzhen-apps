#!/usr/bin/env bash
# Build tools_e2e_probe.exe (see tools_e2e_probe.c) with build-native.cmd and
# run it with the given arguments. Git Bash; SPDF_OUT and SPDF_MUPDF_LIBDIR
# are honoured as for every other native build.
#
#   portable/win/tests/tools_e2e.sh probe eng
#   portable/win/tests/tools_e2e.sh install-ocr chi_sim+eng
#   portable/win/tests/tools_e2e.sh ocr 'C:\path\scan.pdf' eng
#   portable/win/tests/tools_e2e.sh install-argos zh en
#   portable/win/tests/tools_e2e.sh translate zh en 产品设计
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
export SPDF_OUT="${SPDF_OUT:-C:\\spdf-build}"
BUILD_CMD="$(cygpath -w "$REPO_ROOT/portable/win/build-native.cmd")"
SOURCES=(
  portable/win/tests/tools_e2e_probe.c
  portable/win/src/spdf_win_toolchain.cpp portable/win/src/spdf_win_toolchain_cmd.cpp
  portable/win/src/spdf_win_toolchain_plan.cpp portable/win/src/spdf_win_toolchain_run.cpp
  portable/win/src/spdf_win_toolchain_process.cpp portable/win/src/spdf_win_toolchain_install.cpp
  portable/win/src/spdf_win_ocr.cpp portable/win/src/spdf_win_translate.cpp
  portable/win/src/spdf_win_translate_run.cpp portable/win/src/spdf_win_state.c
  portable/win/src/spdf_win_paths.c portable/core/spdf_yaml.c
  portable/core/shenzhen_pdf_core.c portable/core/spdf_selection.c
  portable/core/spdf_selection_support.c portable/core/spdf_recolor.c portable/core/spdf_win_compat.c
)
# MSYS2_ARG_CONV_EXCL='*' as in run-tests-native.lib.sh: MSYS would otherwise
# rewrite /c to C:\ on its way into cmd.exe.
MSYS2_ARG_CONV_EXCL='*' cmd.exe /c "$BUILD_CMD" tools_e2e_probe "${SOURCES[@]}" > "$SPDF_OUT/tools_e2e_probe.build.log" 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then
  echo "tools_e2e: build failed ($rc)"; tail -20 "$SPDF_OUT/tools_e2e_probe.build.log"; exit $rc
fi
"$SPDF_OUT/tools_e2e_probe.exe" "$@"
