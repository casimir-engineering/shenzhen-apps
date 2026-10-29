// Android only (build.rs, link_system): the NDK's static C++ runtime names an uncaught C++ exception's type when it
// terminates, through __cxa_demangle, whose demangler is about 120 KB of a phone app's library for that one message.
// This definition answers first, so the linker leaves the demangler out; the message then names the type as the
// compiler mangled it. Nothing else here demangles C++ names.

#include <stddef.h>

__attribute__((visibility("hidden"))) char *__cxa_demangle(const char *mangled, char *buffer, size_t *length,
                                                           int *status) {
    (void)mangled;
    (void)buffer;
    (void)length;
    if (status) *status = -2; // "not a valid name": the caller prints the name as it is
    return NULL;
}
