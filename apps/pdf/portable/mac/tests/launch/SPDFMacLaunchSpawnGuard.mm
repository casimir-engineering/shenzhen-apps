// The launch probe's spawn guard: every posix_spawn, posix_spawnp and fork the main thread makes before the first
// frame is recorded, so the gate fails on one deterministically rather than when a 1 kHz sample happens to land in it.
// A process spawn on the main thread waits on the kernel for the whole exec: Friends starts its helper from a detached
// thread for exactly that reason.
//
// Interposed in the probe itself, because the reader is linked into it and dyld neither interposes an image's calls
// to itself nor calls between the system libraries in the shared cache (a __interpose section here catches neither):
//   - the probe's own symbol pointers for posix_spawn, posix_spawnp and fork are rebound at start, found by name
//     through the indirect symbol table, which works with lazy binding and chained fixups alike;
//   - NSTask, Foundation's own spawn, is caught where every launch of one ends up (-launchWithDictionary:error:).
// The replacements call the originals through pointers taken from dlsym before anything is rebound.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach/mach.h>
#include <pthread.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

typedef int (*SpawnFn)(pid_t*, const char*, const posix_spawn_file_actions_t*, const posix_spawnattr_t*,
                       char* const[], char* const[]);
typedef pid_t (*ForkFn)(void);
static SpawnFn gRealSpawn, gRealSpawnp;
static ForkFn gRealFork;
static volatile bool gFrameDrawn;
// Fixed storage: the first few offenders, by call and path; the count keeps going past it.
enum { kMaxRecorded = 8, kPathLength = 256 };
static char gRecorded[kMaxRecorded][kPathLength];
static volatile long gCount;

static void Record(const char* call, const char* path) {
    if (gFrameDrawn || !pthread_main_np()) return;
    long n = __atomic_fetch_add(&gCount, 1, __ATOMIC_SEQ_CST);
    if (n < kMaxRecorded) snprintf(gRecorded[n], kPathLength, "%s %s", call, path ? path : "");
}

static int GuardSpawn(pid_t* pid, const char* path, const posix_spawn_file_actions_t* actions,
                      const posix_spawnattr_t* attributes, char* const argv[], char* const envp[]) {
    Record("posix_spawn", path);
    return (gRealSpawn ? gRealSpawn : posix_spawn)(pid, path, actions, attributes, argv, envp);
}
static int GuardSpawnp(pid_t* pid, const char* file, const posix_spawn_file_actions_t* actions,
                       const posix_spawnattr_t* attributes, char* const argv[], char* const envp[]) {
    Record("posix_spawnp", file);
    return (gRealSpawnp ? gRealSpawnp : posix_spawnp)(pid, file, actions, attributes, argv, envp);
}
static pid_t GuardFork(void) {
    Record("fork", "");
    return (gRealFork ? gRealFork : fork)();
}

static IMP gTaskLaunch;
static BOOL GuardTaskLaunch(id task, SEL sel, NSDictionary* dictionary, NSError** error) {
    id path = [dictionary isKindOfClass:NSDictionary.class] ? dictionary[@"_NSTaskExecutablePath"] : nil;
    Record("NSTask", [path isKindOfClass:NSString.class] ? [path UTF8String] : "");
    return ((BOOL(*)(id, SEL, id, NSError**))gTaskLaunch)(task, sel, dictionary, error);
}

static const void* ReplacementFor(const char* name) {
    if (!strcmp(name, "_posix_spawn")) return (const void*)GuardSpawn;
    if (!strcmp(name, "_posix_spawnp")) return (const void*)GuardSpawnp;
    if (!strcmp(name, "_fork")) return (const void*)GuardFork;
    return NULL;
}

// The main executable's symbol pointer sections (__got, __la_symbol_ptr, __auth_got): each slot names its symbol
// through the indirect symbol table.
static int RebindMainImage(void) {
    const struct mach_header_64* header = (const struct mach_header_64*)_dyld_get_image_header(0);
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    const struct symtab_command* symtab = NULL;
    const struct dysymtab_command* dysymtab = NULL;
    const struct segment_command_64* linkedit = NULL;
    const uint8_t* cursor = (const uint8_t*)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++, cursor += ((const struct load_command*)cursor)->cmdsize) {
        const struct load_command* command = (const struct load_command*)cursor;
        if (command->cmd == LC_SYMTAB) symtab = (const struct symtab_command*)command;
        if (command->cmd == LC_DYSYMTAB) dysymtab = (const struct dysymtab_command*)command;
        const struct segment_command_64* segment = (const struct segment_command_64*)command;
        if (command->cmd == LC_SEGMENT_64 && !strcmp(segment->segname, "__LINKEDIT")) linkedit = segment;
    }
    if (!symtab || !dysymtab || !linkedit) return 0;
    uintptr_t base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64* symbols = (const struct nlist_64*)(base + symtab->symoff);
    const char* strings = (const char*)(base + symtab->stroff);
    const uint32_t* indirect = (const uint32_t*)(base + dysymtab->indirectsymoff);
    int rebound = 0;
    cursor = (const uint8_t*)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++, cursor += ((const struct load_command*)cursor)->cmdsize) {
        const struct segment_command_64* segment = (const struct segment_command_64*)cursor;
        if (segment->cmd != LC_SEGMENT_64) continue;
        const struct section_64* sections = (const struct section_64*)(segment + 1);
        for (uint32_t s = 0; s < segment->nsects; s++) {
            uint32_t type = sections[s].flags & SECTION_TYPE;
            if (type != S_LAZY_SYMBOL_POINTERS && type != S_NON_LAZY_SYMBOL_POINTERS) continue;
            void** slots = (void**)((uintptr_t)slide + sections[s].addr);
            for (uint64_t n = 0; n < sections[s].size / sizeof(void*); n++) {
                uint32_t index = indirect[sections[s].reserved1 + n];
                if (index & (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) continue;
                const void* replacement = ReplacementFor(strings + symbols[index].n_un.n_strx);
                if (!replacement) continue;
                vm_protect(mach_task_self(), (vm_address_t)&slots[n], sizeof(void*), false,
                           VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
                slots[n] = (void*)replacement;
                rebound++;
            }
        }
    }
    return rebound;
}

void SPDFLaunchSpawnGuardInstall(void) {
    gRealSpawn = (SpawnFn)dlsym(RTLD_DEFAULT, "posix_spawn");
    gRealSpawnp = (SpawnFn)dlsym(RTLD_DEFAULT, "posix_spawnp");
    gRealFork = (ForkFn)dlsym(RTLD_DEFAULT, "fork");
    RebindMainImage();
    Method launch = class_getInstanceMethod(NSClassFromString(@"NSConcreteTask"),
                                            NSSelectorFromString(@"launchWithDictionary:error:"));
    if (launch) gTaskLaunch = method_setImplementation(launch, (IMP)GuardTaskLaunch);
}

void SPDFLaunchSpawnGuardFrameDrawn(void) { gFrameDrawn = true; }

// Main-thread spawns before the first frame, and the first of them as "call path", one per line in `out`.
long SPDFLaunchSpawnGuardReport(char* out, size_t size) {
    long count = gCount;
    size_t used = 0;
    if (size) out[0] = 0;
    for (long n = 0; n < count && n < kMaxRecorded && used < size; n++)
        used += (size_t)snprintf(out + used, size - used, "%s%s", n ? "\n" : "", gRecorded[n]);
    return count;
}
