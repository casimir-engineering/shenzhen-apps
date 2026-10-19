#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
password_impl="$root/portable/mac/SPDFMacPassword.mm"
credential_impl="$root/portable/mac/SPDFMacPasswordCredentials.mm"
password_header="$root/portable/mac/SPDFMacPassword.h"
app_impl="$root/portable/mac/ShenzhenPDFMac.mm"
properties_impl="$root/portable/mac/SPDFMacPropertiesPanel.mm"
core_impl="$root/portable/core/shenzhen_pdf_core.c"
core_header="$root/portable/core/shenzhen_pdf_core.h"
file_actions_impl="$root/portable/mac/SPDFMacMarkdownFileActions.mm"
translation_impl="$root/portable/mac/SPDFMacTranslationEnablement.mm"
context_menu_impl="$root/portable/mac/SPDFMacContextMenuIntegration.mm"

grep -q 'NSSecureTextField' "$password_impl"
grep -q 'beginSheet:' "$password_impl"
if grep -q 'runModal' "$password_impl"; then
    echo "password prompt must remain asynchronous" >&2
    exit 1
fi
if grep -Eiq 'NSUserDefaults|settings\.json|session\.json|bookmarks\.json|NSLog|os_log' "$password_impl" "$credential_impl"; then
    echo "password implementation contains persistence or logging" >&2
    exit 1
fi
grep -q 'sourceIdentityTokenForSourcePath:' "$password_header"
grep -q 'sourceIdentityTokenForSourcePath:sourcePath' "$app_impl"
if grep -q 'cacheTokenForSourcePath:sourcePath.*sourceIdentity' "$app_impl"; then
    echo "password prompt file-race check must not use a credential/cache token" >&2
    exit 1
fi
python3 - "$password_impl" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
create = 'credential = [[SPDFPasswordCredential alloc] initWithPassword:_passwordField.stringValue];'
clear = '_passwordField.stringValue = @"";'
if create not in source or clear not in source or source.index(clear, source.index(create)) - source.index(create) > 180:
    raise SystemExit("secure password field is not cleared immediately after credential creation")
PY
if grep -n 'spdf_open(' "$app_impl" "$properties_impl"; then
    echo "macOS reopen path bypasses the credential-aware opener" >&2
    exit 1
fi
# COPY IS UNCONDITIONAL, by product decision. The PDF copy flag is advisory,
# and the text is decrypted and on screen by the time it could be consulted, so
# the core exempts it (see shenzhen_pdf_core.h). This guard used to require the
# frontend to enforce that flag; it now pins the exemption instead, so the
# "Copying is not allowed" dialog cannot come back by way of the core.
grep -q 'permission == FZ_PERMISSION_COPY) return 1;' "$core_impl" || {
    echo "the core must grant copy permission unconditionally" >&2
    exit 1
}
grep -q "copy must be allowed even for a restricted user" "$root/portable/core/tests/SPDFCorePasswordTests.c" || {
    echo "the unconditional-copy exemption must stay pinned by a core test" >&2
    exit 1
}
# The other permissions are still read from the document.
grep -q "allowed = fz_has_permission(doc->ctx, doc->doc, (fz_permission)permission) != 0;" "$core_impl" || {
    echo "print/edit/annotate must still consult the document's own flags" >&2
    exit 1
}
# The frontend's copy gates are gone with the policy: nothing may reintroduce a
# copy-permission refusal on the paths the user reaches.
if grep -qE "spdf_has_permission\(_doc, 'c'\)|ensureContentCopyPermissionForOperation" \
    "$app_impl" "$file_actions_impl" "$translation_impl" "$context_menu_impl"; then
    echo "copy is unconditional; a copy-permission gate came back in the frontend" >&2
    exit 1
fi
if grep -q 'Copying is not allowed' "$app_impl" "$file_actions_impl"; then
    echo "the 'Copying is not allowed' dialog must not come back" >&2
    exit 1
fi
grep -q "allowed = doc->password_protected ? 0 : 1;" "$core_impl"
if grep -q 'spdf_save_decrypted_copy' "$core_impl" "$core_header" "$app_impl"; then
    echo "password support must not create plaintext decrypted copies" >&2
    exit 1
fi
grep -q 'OCR is unavailable for password-protected PDFs' "$app_impl"
grep -q '!spdf_is_password_protected(_doc) &&' "$app_impl"
grep -q "spdf_has_permission(_doc, 'h') ? 1200.0 : 150.0" "$app_impl"

echo "SPDF mac password source tests passed"
