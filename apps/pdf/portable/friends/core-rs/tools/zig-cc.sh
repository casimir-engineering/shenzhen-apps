#!/bin/sh
# A C compiler for one Linux target on a Mac, for `cargo check` of crates that build C (the bundled SQLite):
# `zig cc` with the target in SZFRIENDS_ZIG_TARGET ("x86_64-linux-gnu"), dropping the --target=<rust triple> that
# cc-rs adds and zig cannot parse. Used by friends-core-rs-cross-check only; nothing it builds is linked or run.
for argument; do
	shift
	case "$argument" in
	--target=*) ;;
	*) set -- "$@" "$argument" ;;
	esac
done
exec zig cc -target "${SZFRIENDS_ZIG_TARGET:?}" "$@"
