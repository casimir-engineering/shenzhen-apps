#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname "$0")/../../../.." && pwd)
cd "$root"

runtime_files="
portable/linux/gtk4/spdf_tab.c
portable/linux/gtk4/spdf_tab_open.c
portable/linux/gtk4/spdf_password_controller.c
portable/linux/gtk4/spdf_render.c
portable/linux/gtk4/spdf_docview.c
portable/linux/gtk4/spdf_search.c
portable/linux/gtk4/spdf_sidebar.c
portable/linux/gtk4/spdf_print.c
portable/linux/gtk4/spdf_palette.c
portable/linux/gtk4/spdf_translate.c
portable/linux/gtk4/spdf_watcher.c
portable/linux/gtk4/spdf_window_open.c
portable/linux/gtk4/spdf_annot.c
portable/linux/gtk4/spdf_ocr.c
"

for file in $runtime_files; do
    if grep -n 'spdf_open(' "$file"; then
        echo "GTK4 runtime still contains an unauthenticated compatibility open" >&2
        exit 1
    fi
done

grep -q 'spdf_password_open_async' portable/linux/gtk4/spdf_tab_open.c
grep -q 'g_task_run_in_thread' portable/linux/gtk4/spdf_password_controller.c
grep -q 'spdf_password_prompt_cancel' portable/linux/gtk4/spdf_watcher.c
if grep -q 'g_main_loop_run' portable/linux/gtk4/spdf_password_prompt.c; then
    echo "Password prompt must not run nested main loops" >&2
    exit 1
fi
grep -q 'SPDF_OPEN_BAD_PASSWORD' portable/linux/gtk4/spdf_password_lifecycle.c
grep -q 'gtk_password_entry_new' portable/linux/gtk4/spdf_password_prompt.c
grep -q 'gtk_editable_set_text.*""' portable/linux/gtk4/spdf_password_prompt.c
grep -q 'spdf_password_credential_unref(tab->credential)' portable/linux/gtk4/spdf_tab.c

for file in spdf_render.c spdf_docview.c spdf_search.c spdf_print.c spdf_palette.c spdf_translate.c spdf_watcher.c; do
    grep -q 'spdf_password' "portable/linux/gtk4/$file"
done

grep -q "spdf_has_permission(tab->doc, 'c')" portable/linux/gtk4/spdf_window.c
grep -q "spdf_password_require_permission.*'p'" portable/linux/gtk4/spdf_print.c
grep -q "spdf_has_permission(doc, 'h')" portable/linux/gtk4/spdf_print.c
grep -q 'spdf_password_require_permission' portable/linux/gtk4/spdf_annot.c
grep -q 'spdf_password_require_ocr' portable/linux/gtk4/spdf_ocr.c
grep -q 'Save an intentionally unprotected copy' portable/linux/gtk4/spdf_password_prompt.c
grep -A2 'char\* text = job->source.credential' portable/linux/gtk4/spdf_translate.c |
    grep -q 'translate_fallback_extract_text'

if grep -E -n 'settings|state_save|documents\.json|password.*(printf|warning|message)' \
    portable/linux/gtk4/spdf_password.c portable/linux/gtk4/spdf_password_controller.c \
    portable/linux/gtk4/spdf_password_prompt.c; then
    echo "Password credential code must not persist or log secrets" >&2
    exit 1
fi
if grep -R -E -n 'decrypt|decrypted.*temp|plaintext' portable/linux/gtk4/spdf_password*.c portable/linux/gtk4/spdf_ocr.c; then
    echo "Protected-document flow must not create plaintext decrypted files" >&2
    exit 1
fi

echo "GTK4 password source-contract tests passed"
