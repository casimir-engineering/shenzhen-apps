#!/bin/bash
# Source-contract test for Shenzhen Friends containment (brief § Containment and porting).
#
# Friends is one feature in four layers so that Shenzhen Files (GTK4) can host it later by adding only views and
# an adapter. That only stays true if nothing under portable/friends/ reaches into the reader, so this fails on:
#   reader      an identifier or path with the reader's prefixes (the capitalised S-P-D-F prefix, its lowercase
#               C form with an underscore, or the core library's name) in any code, build or fixture file;
#   escape      a quoted #include/#import that climbs out of portable/friends/ (portable/mac, portable/core...);
#   makefile    a Friends makefile that adds a reader include directory, names reader sources or reuses the
#               reader's build variables;
#   layer       service/ or client/ importing AppKit, Cocoa or GTK; client/ using Foundation or Objective-C
#               (it is C99 and libc only); mac/ views including service/ (views talk to the helper only through
#               the client protocol); service/ including mac/; gtk/ views including service/ or mac/, using
#               AppKit, Cocoa, UIKit, Foundation or Objective-C (they are C for GTK hosts on any platform), or Apple's
#               ApplicationServices and Carbon outside gtk/tests/ (where only the probes keep GDK in the background).
#   store       SQLite's C library name or the database's file name outside service/store/ (ADR 0003: the
#               store is the only reader and writer of the database, so nothing else may link SQLite or open it).
# Markdown is exempt: the README must be able to name the reader's adapter files, and the ADRs the database.
#
# Usage (cwd portable/, as make runs it):
#   containment-check.sh <friends dir>              scan the tree
#   containment-check.sh --headers <friends dir> h… compile each public header on its own
#   containment-check.sh --self-test                prove each rule fires on a planted violation
# Environment for --headers: CC (default clang), FRIENDS_HEADER_FLAGS (target flags), FRIENDS_HEADER_INCLUDES.
#
# Bash 3.2 compatible (macOS /bin/bash), like tools/check-file-sizes.sh. The reader's prefixes and the database's
# names are assembled from pieces below so this file does not trip its own scan.

set -euo pipefail

reader_pattern="(^|[^A-Za-z0-9_])(SP""DF|sp""df_|shenzhen""_pdf)"
sqlite_lib="sql""ite3"
sqlite_file="friends.sql""ite"
store_pattern="$sqlite_lib|${sqlite_file/./\\.}"

# Files that still name the database outside the store, each waiting on its owner: only friends.mk now, whose
# comment lists what the service areas link (the helper dropped databasePath and its test in wave 4). A stale entry
# would let a file add the database's name unseen, so remove an entry as soon as its file stops naming it; the rule
# applies to every other file.
store_pending_exemptions=" friends.mk "

# Files allowed to name one reader build variable, each with its reason: universal.mk runs the portable Makefile
# itself for each slice and must turn its release mode off there (the variable belongs to that Makefile, not to a
# reader source Friends uses).
reader_exemptions=" service/helper/universal.mk "

is_code_file() {
    case "$1" in
        *.c|*.h|*.m|*.mm|*.cc|*.cpp|*.cxx|*.hh|*.hpp|*.swift|*.js|*.mjs|*.cjs|*.ts|*.py|*.sh|*.mk|*.json|*.jsonl|\
        *.plist|*.strings|*/Makefile)
            return 0 ;;
    esac
    return 1
}

is_c_family() {
    case "$1" in
        *.c|*.h|*.m|*.mm|*.cc|*.cpp|*.cxx|*.hh|*.hpp) return 0 ;;
    esac
    return 1
}

# Prints "escape" when include path $2, resolved from directory depth $1 below the friends root, leaves it.
include_escapes() {
    awk -v depth="$1" -v path="$2" 'BEGIN {
        n = split(path, parts, "/")
        for (i = 1; i <= n; i++) {
            if (parts[i] == "..") { depth--; if (depth < 0) { print "escape"; exit } }
            else if (parts[i] != "." && parts[i] != "") depth++
        }
    }'
}

scan_tree() {
    local root=$1 violations count=0
    root=${root%/}
    if [ ! -d "$root" ]; then
        echo "containment: no such directory: $root" >&2
        return 2
    fi
    violations=$(mktemp "${TMPDIR:-/tmp}/szfriends-containment.XXXXXX")
    while IFS= read -r -d '' file; do
        is_code_file "$file" || continue
        count=$((count + 1))
        local rel=${file#"$root"/}
        case "$reader_exemptions" in
            *" $rel "*) grep -nE "$reader_pattern" "$file" 2>/dev/null | grep -vE "SP""DF_RELEASE_MODE" ;;
            *) grep -nE "$reader_pattern" "$file" 2>/dev/null ;;
        esac | sed "s|^|$rel:|; s|\$|  [reader]|" >> "$violations" || true
        case "$rel" in
            # The store, and the portable core: its store is the same database's other implementation (ADR 0015
            # § 7), and its tools export the helper's store as vectors and measure the core as phones link it.
            service/store/*|core-rs/*) ;;
            *)
                case "$store_pending_exemptions" in
                    *" $rel "*) ;;
                    *) grep -nE "$store_pattern" "$file" 2>/dev/null \
                           | sed "s|^|$rel:|; s|\$|  [store: only service/store/ names the database]|" \
                           >> "$violations" || true ;;
                esac ;;
        esac

        case "$rel" in
            *.mk|*/Makefile|Makefile)
                grep -nE -- '-I[[:space:]]*(\.\./)*(portable/)?(mac|core|linux|win)([/[:space:]"]|$)' "$file" \
                    | sed "s|^|$rel:|; s|\$|  [makefile: reader include directory]|" >> "$violations" || true
                grep -nE '\$\((MUPDF|CORE_|YAML_|MAC_SRCS|MAC_HDRS|MAC_MARKDOWN|MAC_COLLECTION)' "$file" \
                    | sed "s|^|$rel:|; s|\$|  [makefile: reader build variable]|" >> "$violations" || true
                grep -nE '(^|[[:space:]"'\''=])(\.\./)*(mac|core)/[A-Za-z0-9_]' "$file" \
                    | sed "s|^|$rel:|; s|\$|  [makefile: reader source path]|" >> "$violations" || true
                ;;
        esac

        is_c_family "$file" || continue
        local dir depth line number target
        dir=$(dirname "$rel")
        if [ "$dir" = "." ]; then depth=0; else depth=$(printf '%s' "$dir" | awk -F/ '{ print NF }'); fi
        while IFS= read -r line; do
            number=${line%%:*}
            target=$(printf '%s' "${line#*:}" | sed -E 's/^[^"]*"([^"]*)".*/\1/')
            if [ -n "$(include_escapes "$depth" "$target")" ]; then
                echo "$rel:$number: \"$target\" resolves outside portable/friends  [escape]" >> "$violations"
            fi
        done < <(grep -nE '^[[:space:]]*#[[:space:]]*(include|import)[[:space:]]*"[^"]*\.\./' "$file" || true)

        local ui='^[[:space:]]*(#[[:space:]]*(import|include)[[:space:]]*[<"](AppKit|Cocoa|UIKit|gtk|adwaita)[/.]'
        ui="$ui|@import[[:space:]]+(AppKit|Cocoa|UIKit))"
        case "$rel" in
            service/*|client/*)
                grep -nE "$ui" "$file" | sed "s|^|$rel:|; s|\$|  [layer: UI toolkit outside the views]|" \
                    >> "$violations" || true ;;
        esac
        case "$rel" in
            client/*.m|client/*.mm)
                echo "$rel:1: Objective-C in the C client library  [layer]" >> "$violations" ;;
            client/*)
                grep -nE '^[[:space:]]*#[[:space:]]*(import|include)[[:space:]]*[<"](Foundation|CoreFoundation|objc)/' \
                    "$file" | sed "s|^|$rel:|; s|\$|  [layer: client library is libc only]|" >> "$violations" || true ;;
            mac/*)
                grep -nE '^[[:space:]]*#[[:space:]]*(import|include)[[:space:]]*["<](\.\./)*service/' "$file" \
                    | sed "s|^|$rel:|; s|\$|  [layer: views include service code]|" >> "$violations" || true ;;
            service/*)
                grep -nE '^[[:space:]]*#[[:space:]]*(import|include)[[:space:]]*["<](\.\./)*mac/' "$file" \
                    | sed "s|^|$rel:|; s|\$|  [layer: service includes views]|" >> "$violations" || true ;;
            gtk/*.m|gtk/*.mm|gtk/*/*.m|gtk/*/*.mm)
                echo "$rel:1: Objective-C in the GTK views  [layer]" >> "$violations" ;;
            gtk/*)
                local gtk_include='^[[:space:]]*#[[:space:]]*(import|include)[[:space:]]*'
                grep -nE "$gtk_include[\"<](\\.\\./)*(service|mac)/" "$file" \
                    | sed "s|^|$rel:|; s|\$|  [layer: GTK views include service or AppKit view code]|" \
                    >> "$violations" || true
                grep -nE "($gtk_include[<\"](AppKit|Cocoa|UIKit|Foundation|objc)[/.]|^[[:space:]]*@import)" "$file" \
                    | sed "s|^|$rel:|; s|\$|  [layer: GTK views use Apple UI or Objective-C]|" >> "$violations" || true
                case "$rel" in
                    gtk/tests/*) ;;
                    *) grep -nE "$gtk_include[<\"](ApplicationServices|Carbon)[/.]" "$file" \
                           | sed "s|^|$rel:|; s|\$|  [layer: GTK views use Apple process APIs]|" \
                           >> "$violations" || true ;;
                esac ;;
        esac
    # Cargo's build output (git ignores it) is not source; a build there must not fail the scan.
    done < <(find "$root" -type f -not -path '*/.git/*' -not -path "$root/core-rs/target/*" \
        -not -path "$root/core-rs/fuzz/target/*" -not -path "$root/tauri/target/*" -print0)

    if [ -s "$violations" ]; then
        echo "containment: Friends must not depend on the reader (portable/friends/README.md):" >&2
        cat "$violations" >&2
        rm -f "$violations"
        return 1
    fi
    rm -f "$violations"
    if [ "$count" -eq 0 ]; then
        echo "containment: no code files under $root" >&2
        return 1
    fi
    echo "friends containment scan passed ($count files)"
}

# Each public header must compile alone with only portable/friends on the include path: proves it is
# self-contained and that it cannot reach a reader header even indirectly.
compile_headers() {
    local root=${1%/} failures=0 header rel
    shift
    local cc=${CC:-clang}
    # shellcheck disable=SC2206 # flags are a whitespace-separated list from make
    local flags=(${FRIENDS_HEADER_FLAGS:-} ${FRIENDS_HEADER_INCLUDES:-} -I"$root" -fsyntax-only)
    for header in "$@"; do
        rel=${header#"$root"/}
        if [ ! -f "$header" ]; then
            echo "containment: listed public header is missing: $header" >&2
            failures=$((failures + 1))
            continue
        fi
        case "$rel" in
            gtk/*)
                # C11 with GTK, libadwaita and json-glib, as a GTK host compiles it; twice, for the include guard.
                local gtk_flags
                if ! gtk_flags=$(pkg-config --cflags gtk4 libadwaita-1 json-glib-1.0 2>/dev/null); then
                    echo "containment: $rel needs gtk4, libadwaita-1 and json-glib-1.0 through pkg-config" >&2
                    failures=$((failures + 1))
                    continue
                fi
                # shellcheck disable=SC2086 # pkg-config prints a whitespace-separated list
                if ! printf '#include "%s"\n#include "%s"\n' "$rel" "$rel" \
                    | "$cc" "${flags[@]}" $gtk_flags -std=c11 -Wall -Wextra -Werror -x c -; then
                    failures=$((failures + 1))
                fi ;;
            client/*)
                # Included twice: the include guard must hold. C99 -pedantic because GTK hosts compile it as C.
                if ! printf '#include "%s"\n#include "%s"\n' "$rel" "$rel" \
                    | "$cc" "${flags[@]}" -std=c99 -Wall -Wextra -Werror -pedantic -x c -; then
                    failures=$((failures + 1))
                fi ;;
            *)
                if ! printf '#import "%s"\n' "$rel" | "$cc" "${flags[@]}" -fobjc-arc -Wall -Wextra -Werror \
                    -x objective-c -; then
                    failures=$((failures + 1))
                fi ;;
        esac
    done
    if [ "$failures" -ne 0 ]; then
        echo "containment: $failures public header(s) do not compile on their own" >&2
        return 1
    fi
    echo "friends public headers compile alone ($# headers)"
}

self_test_work=""
self_test() {
    local work failures=0 prefix lower
    work=$(mktemp -d "${TMPDIR:-/tmp}/szfriends-containment-self.XXXXXX")
    self_test_work=$work
    trap '[ -n "$self_test_work" ] && rm -rf "$self_test_work"' EXIT
    prefix="SP""DF"
    lower="sp""df_"

    make_clean_tree() {
        local t=$1
        mkdir -p "$t/service/store" "$t/mac" "$t/client" "$t/avatars" "$t/x"
        printf '#import "avatars/A.h"\n#include "../../client/c.h"\n' > "$t/service/store/ok.m"
        printf '#import <AppKit/AppKit.h>\n#import "avatars/A.h"\n#include "client/c.h"\n' > "$t/mac/ok.m"
        printf '#include <stdio.h>\n#include "cJSON.h"\n' > "$t/client/ok.c"
        mkdir -p "$t/gtk/tests"
        printf '#include <gtk/gtk.h>\n#include "client/szfriends_client.h"\n' > "$t/gtk/ok.c"
        printf '#include <ApplicationServices/ApplicationServices.h>\n' > "$t/gtk/tests/ok.c"
        printf 'x: friends/x/a.c\n\tclang $(MAC_TARGET_FLAGS) -Ifriends -I$(FRIENDS_SODIUM_DIR) -c $<\n' \
            > "$t/x/x.mk"
        printf 'The adapter lives in portable/mac/%sMacFriendsHost.mm\n' "$prefix" > "$t/README.md"
        printf '{"title":"Mei Lin"}\n' > "$t/x/fixture.json"
    }

    expect() {
        local want=$1 label=$2 tree=$3 status=0
        scan_tree "$tree" > /dev/null 2>&1 || status=$?
        if { [ "$want" = pass ] && [ "$status" -ne 0 ]; } || { [ "$want" = fail ] && [ "$status" -ne 1 ]; }; then
            echo "containment self-test: expected $want for $label (status $status)" >&2
            failures=$((failures + 1))
        fi
    }

    plant() {
        local name=$1 path=$2 content=$3
        make_clean_tree "$work/$name"
        mkdir -p "$(dirname "$work/$name/$path")"
        printf '%s\n' "$content" > "$work/$name/$path"
        expect fail "$name" "$work/$name"
    }

    make_clean_tree "$work/clean"
    expect pass "a clean tree" "$work/clean"
    plant objc-identifier service/a.m "id x = [${prefix}MacThing new];"
    plant c-identifier client/b.c "int y = ${lower}yaml_parse(0);"
    plant core-header service/c.m '#include "shenzhen''_pdf_core.h"'
    plant fixture-string x/f.json "{\"source\":\"${prefix}MacTabDrag\"}"
    plant escape-to-mac service/store/d.m '#import "../../../mac/Foo.h"'
    plant escape-to-core service/e.m '#include "../../core/x.h"'
    plant mk-include x/y.mk 'CFLAGS += -I../mac'
    plant mk-include-bare x/z.mk 'CFLAGS += -Imac -Icore'
    plant mk-variable x/v.mk 'LIBS += $(MUPDF_LIBS)'
    plant mk-source x/s.mk 'SRCS += core/color.c'
    plant mk-source-mac x/t.mk 'OBJS := $(BUILD)/x.o mac/Thing.mm'
    plant service-appkit service/f.m '#import <AppKit/AppKit.h>'
    plant client-gtk client/g.c '#include <gtk/gtk.h>'
    plant client-foundation client/h.c '#include <Foundation/Foundation.h>'
    plant client-objc client/i.m 'int z;'
    plant views-include-service mac/j.m '#import "service/store/SZFriendsStore.h"'
    plant gtk-include-service gtk/p.c '#include "service/store/SZFriendsStore.h"'
    plant gtk-include-mac gtk/q.c '#include "../mac/SZFriendsHost.h"'
    plant gtk-appkit gtk/r.c '#import <AppKit/AppKit.h>'
    plant gtk-foundation gtk/tests/s.c '#include <Foundation/Foundation.h>'
    plant gtk-objc gtk/t.m 'int z;'
    plant gtk-process-api gtk/u.c '#include <ApplicationServices/ApplicationServices.h>'
    plant gtk-reader-symbol gtk/v.c "void ${lower}gtk_open(void);"
    plant service-include-views service/k.m '#import "mac/SZFriendsHost.h"'
    plant store-library-helper service/helper/l.m "#import <$sqlite_lib.h>"
    plant store-file-presentation service/presentation/m.m "// opens <state>/$sqlite_file"
    plant store-link-flag x/n.mk "LIBS += -l$sqlite_lib"
    plant store-file-fixture x/o.json "{\"path\":\"$sqlite_file\"}"
    # Files exempt until wave 4 are held to the rule like any other (wave-4 integration sweep).
    plant store-file-helper-paths service/helper/SZFriendsStatePaths.m "// <state>/$sqlite_file"
    plant store-library-helper-header service/helper/SZFriendsHelper.h "#import <$sqlite_lib.h>"

    # The store itself may name both, and documents may describe the database.
    make_clean_tree "$work/store-owner"
    printf '#import <%s.h>\n// <state>/%s\n' "$sqlite_lib" "$sqlite_file" > "$work/store-owner/service/store/db.m"
    printf 'STORE_LIBS := -l%s\n' "$sqlite_lib" > "$work/store-owner/service/store/store.mk"
    printf 'The helper keeps %s through %s.\n' "$sqlite_file" "$sqlite_lib" > "$work/store-owner/x/notes.md"
    expect pass "the store and Markdown naming the database" "$work/store-owner"
    # The portable core's tools may name the database; Cargo's build output is not scanned; universal.mk may turn
    # the portable Makefile's release mode off, and nothing more of the reader's.
    make_clean_tree "$work/core"
    mkdir -p "$work/core/core-rs/tools" "$work/core/core-rs/target/debug" "$work/core/tauri/target/x" \
        "$work/core/service/helper"
    printf '#import <%s.h>\n' "$sqlite_lib" > "$work/core/core-rs/tools/export.m"
    printf '{"features":"%s %s"}\n' "$sqlite_lib" "$prefix" > "$work/core/core-rs/target/debug/lib.json"
    printf '{"features":"%s"}\n' "$sqlite_lib" > "$work/core/tauri/target/x/lib.json"
    printf 'm = $(MAKE) %s_RELEASE_MODE=0\n' "$prefix" > "$work/core/service/helper/universal.mk"
    expect pass "core-rs tools, build output and the universal helper's release mode" "$work/core"
    plant universal-other-reader service/helper/universal.mk "SRCS += \$(${prefix}_MAC_SOURCES)"

    # Header mode: a self-contained header passes; one that leans on an earlier import fails.
    mkdir -p "$work/hdr/service" "$work/hdr/client"
    printf '#import <Foundation/Foundation.h>\n@interface SZFOk : NSObject\n@end\n' > "$work/hdr/service/ok.h"
    printf '#ifndef C_H\n#define C_H\nint c(void);\n#endif\n' > "$work/hdr/client/c.h"
    printf '@interface SZFBad : NSObject\n@end\n' > "$work/hdr/service/bad.h"
    if ! compile_headers "$work/hdr" "$work/hdr/service/ok.h" "$work/hdr/client/c.h" > /dev/null 2>&1; then
        echo "containment self-test: self-contained headers should compile" >&2
        failures=$((failures + 1))
    fi
    if compile_headers "$work/hdr" "$work/hdr/service/bad.h" > /dev/null 2>&1; then
        echo "containment self-test: a header that is not self-contained should fail" >&2
        failures=$((failures + 1))
    fi
    # GTK headers compile as C with GTK's flags: one including what it uses passes, one leaning on GTK fails.
    mkdir -p "$work/hdr/gtk"
    printf '#ifndef G_H\n#define G_H\n#include <gtk/gtk.h>\nGtkWidget *g(void);\n#endif\n' > "$work/hdr/gtk/ok.h"
    printf 'GtkWidget *bad(void);\n' > "$work/hdr/gtk/bad.h"
    if ! compile_headers "$work/hdr" "$work/hdr/gtk/ok.h" > /dev/null 2>&1; then
        echo "containment self-test: a self-contained GTK header should compile" >&2
        failures=$((failures + 1))
    fi
    if compile_headers "$work/hdr" "$work/hdr/gtk/bad.h" > /dev/null 2>&1; then
        echo "containment self-test: a GTK header that is not self-contained should fail" >&2
        failures=$((failures + 1))
    fi

    if [ "$failures" -ne 0 ]; then
        echo "containment self-test: $failures failure(s)" >&2
        return 1
    fi
    echo "friends containment self-test passed"
}

case "${1:-}" in
    --self-test) self_test ;;
    --headers)
        [ "$#" -ge 2 ] || { echo "usage: $0 --headers <friends dir> <header>..." >&2; exit 2; }
        shift
        compile_headers "$@" ;;
    ""|-h|--help) echo "usage: $0 <friends dir> | --headers <friends dir> <header>... | --self-test" >&2; exit 2 ;;
    *) scan_tree "$1" ;;
esac
