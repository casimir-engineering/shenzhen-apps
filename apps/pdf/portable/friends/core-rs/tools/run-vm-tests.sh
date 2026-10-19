# Sourced by run-device-tests.sh for windows-vm and linux-vm (its header documents both). Uses $friends, $here,
# report() and failed from there. The suites' temporary homes go to a tmp directory inside the run's own directory
# (TEMP and TMP, or TMPDIR), never the guest user's; a home a suite leaves there fails the run before the whole
# directory is removed.

# The workspace (without build output), the fixtures, the helper files and the host's vectors the tests read, and
# the vendored sources szfriends-datachannel-sys compiles (it finds ext/ beside core-rs), as base64 of a gzipped tar.
# With a `cargo vendor` directory as $1, the crates go along in vendor/ and the guest builds from them instead of
# fetching.
vm_payload() { # vendor directory (optional)
    local vendor=()
    [ -n "${1:-}" ] && vendor=(-C "$1/.." "$(basename "$1")")
    COPYFILE_DISABLE=1 tar --no-xattrs -czf - --exclude 'core-rs/target' --exclude 'core-rs/fuzz/target' \
        --exclude '.DS_Store' -C "$friends" \
        core-rs fixtures service/session/tests/vectors service/identity/wordlist \
        service/store/tests/fixtures service/thumbnails/fuzz/corpus/frame \
        -C "$friends/.." server/friends/test/vectors/host-list-v1.json \
        -C "$friends/../.." ext/libdatachannel ext/libjuice ext/usrsctp ext/plog ext/mbedtls \
        ${vendor[@]+"${vendor[@]}"} | base64
}

# Prints one line per target: its result, then the failing output when there is one.
vm_report() { # target, cargo output, exit status
    local suites tests
    suites=$(printf '%s\n' "$2" | grep -c "test result: ok" || true)
    tests=$(printf '%s\n' "$2" | sed -n 's/^test result: ok\. \([0-9]*\) passed.*/\1/p' | paste -sd+ - | bc)
    if [ "$3" = 0 ] && ! printf '%s\n' "$2" | grep -q "FAILED"; then
        printf '%s: %s tests in %s suites passed\n' "$1" "${tests:-0}" "$suites"
    else
        failed=1
        printf '%s: failed (exit %s)\n' "$1" "$3"
        printf '%s\n' "$2" | tail -40
    fi
}

# Fails the run when the suites left temporary homes behind (their names start with szf).
vm_leftovers() { # target, the names left
    [ -z "$2" ] && return 0
    failed=1
    printf '%s: %s temporary homes left behind:\n%s\n' "$1" "$(printf '%s\n' "$2" | wc -l | tr -d ' ')" \
        "$(printf '%s\n' "$2" | head -20)"
}

# Through cmd.exe only: the guest's PowerShell can hang under prlctl exec. The payload goes in as base64 lines.
run_windows_vm() { # VM name
    local vm=$1 dir output status target
    local exec=(prlctl exec "$vm" --current-user)
    dir=$("${exec[@]}" cmd /c "echo %TEMP%\\szfriends-core-rs-%RANDOM%%RANDOM%" </dev/null | tr -d '\r')
    case "$dir" in *szfriends-core-rs-*) ;; *) echo "windows-vm: no temporary directory ($dir)" >&2; return 1 ;; esac
    "${exec[@]}" cmd /c "mkdir $dir\\tmp" </dev/null
    vm_payload | fold -w 76 | "${exec[@]}" cmd /c "findstr ^^ > $dir\\tree.b64"
    "${exec[@]}" cmd /c "certutil -decode $dir\\tree.b64 $dir\\tree.tgz >nul && tar -xzf $dir\\tree.tgz -C $dir" \
        </dev/null >/dev/null
    for target in ${SZFRIENDS_WINDOWS_TARGETS:-aarch64-pc-windows-msvc x86_64-pc-windows-msvc}; do
        status=0
        output=$("${exec[@]}" cmd /c "cd /d $dir\\core-rs && set CARGO_TARGET_DIR=$dir\\target&& set \
SZFRIENDS_DIR=$dir&& set TEMP=$dir\\tmp&& set TMP=$dir\\tmp&& %USERPROFILE%\\.cargo\\bin\\cargo.exe test \
--workspace --locked --no-fail-fast --target $target 2>&1" </dev/null | tr -d '\r') || status=$?
        vm_report "$target" "$output" "$status"
        vm_leftovers "$target" "$("${exec[@]}" cmd /c "dir /b $dir\\tmp\\szf* 2>nul" </dev/null | tr -d '\r')"
    done
    "${exec[@]}" cmd /c "rmdir /s /q $dir" </dev/null
}

# The vendor directory the Linux guest builds from: $SZFRIENDS_VM_VENDOR, a `cargo vendor` directory prepared on the
# Mac for this workspace's Cargo.lock (a guest whose clock has run off fails crates.io's certificate), as an absolute
# path; nothing when unset.
vm_vendor() {
    [ -z "${SZFRIENDS_VM_VENDOR:-}" ] && return 0
    [ -d "$SZFRIENDS_VM_VENDOR" ] || { echo "linux-vm: no vendor directory at $SZFRIENDS_VM_VENDOR" >&2; return 1; }
    (cd "$SZFRIENDS_VM_VENDOR" && pwd)
}

# Points the guest's $dir/cargo-home at the vendor directory unpacked in $dir, and prints the cargo flag that keeps
# the build off the network.
vm_linux_vendored() { # guest directory, vendor directory on the Mac (may be empty), the prlctl exec command
    local dir=$1 vendor=$2
    shift 2
    [ -z "$vendor" ] && return 0
    "$@" "mkdir -p $dir/cargo-home && printf '%s\\n' '[source.crates-io]' 'replace-with = \"vendored\"' \
'[source.vendored]' 'directory = \"$dir/$(basename "$vendor")\"' > $dir/cargo-home/config.toml"
    echo --offline
}

# Incremental compilation stays off in the Linux guest (CARGO_INCREMENTAL=0): its clock may read decades ahead of the
# copied sources, and incremental state goes by file dates.
run_linux_vm() { # VM name
    local vm=$1 dir output status vendor offline
    local exec=(prlctl exec "$vm")
    [ "${SZFRIENDS_VM_AS_ROOT:-0}" = 1 ] || exec+=(--current-user)
    local bin=${SZFRIENDS_VM_TOOLCHAIN:-'$HOME/.cargo/bin'}
    vendor=$(vm_vendor) || return 1
    dir=$("${exec[@]}" "mktemp -d /tmp/szfriends-core-rs.XXXXXX")
    case "$dir" in /tmp/szfriends-core-rs.*) ;; *) echo "linux-vm: no temporary directory ($dir)" >&2; return 1 ;; esac
    # The tmp directory is like /tmp, and the run's own reachable, so a test's helper running as another user (as
    # linux_system.rs starts one) can reach the home it is given.
    vm_payload "$vendor" | "${exec[@]}" "base64 -d | tar -xzf - -C $dir && chmod 711 $dir && mkdir -m 1777 $dir/tmp"
    offline=$(vm_linux_vendored "$dir" "$vendor" "${exec[@]}")
    status=0
    output=$("${exec[@]}" "cd $dir/core-rs && PATH=$bin:\$PATH RUSTC=$bin/rustc CARGO_HOME=$dir/cargo-home \
CARGO_TARGET_DIR=$dir/target CARGO_INCREMENTAL=0 SZFRIENDS_DIR=$dir TMPDIR=$dir/tmp SZFRIENDS_REQUIRE_SYSTEM_TESTS=1 \
$bin/cargo test --workspace --locked $offline --no-fail-fast 2>&1") || status=$?
    vm_report "linux-vm ($("${exec[@]}" "uname -m"))" "$output" "$status"
    vm_leftovers linux-vm "$("${exec[@]}" "cd $dir/tmp && ls -d szf* 2>/dev/null || true")"
    "${exec[@]}" "rm -rf $dir"
}

run_vm_tests() { # windows-vm | linux-vm, VM name (optional)
    local vm
    case "$1" in
    windows-vm) vm=${2:-Windows 11} ;;
    linux-vm) vm=${2:-Ubuntu 24.04 (with Rosetta)} ;;
    esac
    if ! prlctl status "$vm" 2>/dev/null | grep -q " running"; then
        echo "$1: the VM \"$vm\" is not running (resuming it is the caller's choice)" >&2
        failed=1
        return
    fi
    if [ "$1" = windows-vm ]; then run_windows_vm "$vm"; else run_linux_vm "$vm"; fi || failed=1
}
