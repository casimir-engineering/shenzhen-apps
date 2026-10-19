#!/usr/bin/env bash
# The layout differential case for portable/win/tests/run-tests.sh.
#
# Split out for the same reason probe-cases.sh is: run-tests.sh stays a list of
# WHAT is tested and the per-family plumbing lives beside it. Sourced, never
# executed; it uses record(), log_tail(), $OUT, $TESTS_DIR and $REPO_ROOT from
# the runner and harness-lib.sh.

# The strongest correctness evidence the layout port has, and until this case
# existed it gated nothing at all.
#
# gtk_differential.c compiles portable/win/src/spdf_win_layout.h AND the GTK4
# header it was transcribed from into one binary and compares them for EXACT
# equality across ~400k inputs: layout, visible range, fit modes, zoom
# anchoring, scroll clamping, the render byte cap, and the LRU's eviction
# policy. Anyone editing the layout is editing the thing this compares.
#
# It is macOS-side by construction: it links glib, which will never exist in the
# Windows guest. That is exactly why the file is NOT named `*_test.c` -- the
# name keeps it out of case_win_tests' discovery glob, and renaming it would
# make the guest runner try to build glib under MSVC. The name is load-bearing;
# see the `spdf-test-host` guard in case_win_tests for the belt to that braces.
#
# -ffp-contract=off is not a workaround, it is the point: MSVC under /fp:precise
# does not fuse a*b+c into an FMA and clang does by default, so the flag makes
# both compilers evaluate the operations the source actually writes. If this
# ever disagrees on floating point, suspect this flag first.
#
# Missing glib is BLOCKED, never PASS. A run that could not compare anything
# must not report success -- that is this whole file's founding rule.
case_layout_differential() {
  local log="$OUT/layout-differential.log"
  local out="$OUT/mac/gtk-differential.txt"
  local bin="$OUT/mac/gtk_differential"
  local rc

  pkg-config --exists glib-2.0
  rc=$?
  if [[ $rc -ne 0 ]]; then
    record "layout.differential" BLOCKED "glib-2.0 is not installed on this Mac (brew install glib); the layout port's strongest evidence cannot run and skipping it is not a pass"
    return
  fi
  mkdir -p "$OUT/mac"
  # Not -Werror: portable/linux/gtk4 is another track's code and is not this
  # runner's to keep warning-clean. The port's own sources are built under
  # -Werror by t3-verify.sh and by the guest compiler.
  cc -std=gnu99 -O2 -ffp-contract=off \
     "-I$REPO_ROOT/portable/win/src" "-I$REPO_ROOT/portable/core" \
     "-I$REPO_ROOT/portable/linux/gtk4" \
     $(pkg-config --cflags glib-2.0) -o "$bin" \
     "$TESTS_DIR/gtk_differential.c" "$TESTS_DIR/gtk_differential_cache.c" \
     "$REPO_ROOT/portable/win/src/spdf_win_lru.c" \
     $(pkg-config --libs glib-2.0) > "$log" 2>&1
  rc=$?
  if [[ $rc -ne 0 ]]; then
    record "layout.differential" FAIL "the differential does not compile (cc exited $rc)"
    log_tail "$log" 25
    return
  fi
  "$bin" > "$out" 2>&1
  rc=$?
  if [[ $rc -ne 0 ]]; then
    record "layout.differential" FAIL "the port and the GTK4 original disagree (exit $rc)"
    log_tail "$out" 25
    return
  fi
  record "layout.differential" PASS "$(tail -n 1 "$out")"
}
