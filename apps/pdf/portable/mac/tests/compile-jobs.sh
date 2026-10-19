# shellcheck shell=sh
# Bounded parallel compilation for the hand-rolled macOS test drivers.
#
# Sourced, not executed. The Markdown suites link a large fixed set of shared
# translation units into every test binary; compiling each one ONCE and linking
# the objects is the whole point, and doing those compiles concurrently is what
# keeps the suites in seconds rather than minutes.
#
# Usage:
#     . "$SCRIPT_DIR/compile-jobs.sh"
#     spdf_job "$CXX" $CXXFLAGS -c "$SRC" -o "$OBJ"
#     ...
#     spdf_join    # waits for everything; exits nonzero if any compile failed
#
# spdf_join deliberately reaps every job before failing, so a broken build
# prints all of the compiler's diagnostics instead of only the first one.

SPDF_JOBS=${SPDF_COMPILE_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}
SPDF_JOB_PIDS=""
SPDF_JOB_COUNT=0
SPDF_JOB_FAILED=0

spdf_reap_oldest() {
    _spdf_pid=${SPDF_JOB_PIDS%% *}
    SPDF_JOB_PIDS=${SPDF_JOB_PIDS#* }
    SPDF_JOB_COUNT=$((SPDF_JOB_COUNT - 1))
    wait "$_spdf_pid" || SPDF_JOB_FAILED=1
}

# Run one compile in the background, blocking first if the machine is already
# saturated. Without the cap a suite would fork one clang per translation unit
# -- ~100 at once, each holding an ObjC++ AST.
spdf_job() {
    while [ "$SPDF_JOB_COUNT" -ge "$SPDF_JOBS" ]; do
        spdf_reap_oldest
    done
    "$@" &
    SPDF_JOB_PIDS="$SPDF_JOB_PIDS$! "
    SPDF_JOB_COUNT=$((SPDF_JOB_COUNT + 1))
}

spdf_join() {
    while [ "$SPDF_JOB_COUNT" -gt 0 ]; do
        spdf_reap_oldest
    done
    if [ "$SPDF_JOB_FAILED" -ne 0 ]; then
        echo "compilation failed" >&2
        exit 1
    fi
}
