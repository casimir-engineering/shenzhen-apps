/* szf_launch_probe.c: measures Shenzhen Files' launch without ever showing it.
 *
 * Inserted into Contents/MacOS/nautilus with DYLD_INSERT_LIBRARIES by the launch-performance harness. It
 *   - keeps the process a background process: TransformProcessType is interposed (the pattern of shenzhen-pdf's
 *     portable/friends/gtk/tests/szfriends_gtk_quiet.c), so GDK's display open puts no icon in the Dock and takes
 *     no focus; NSApplication activation calls are refused as well;
 *   - refuses every NSWindow ordering call, so no window of the app ever reaches the screen, while GTK still
 *     believes its window is mapped and keeps laying it out and painting it;
 *   - records milestones as JSON lines in $SZF_PROBE_OUT: the constructor, the display open, the first GtkWindow
 *     map (the point the first window would appear), the first frame painted after it, and the files view's
 *     end-loading with every file seen. Each carries the wall time and the CPU time used so far, by the main
 *     thread and by the whole process;
 *   - exits at once after the milestone named by $SZF_PROBE_EXIT (map, paint, loaded) or never (none);
 *   - with $SZF_PROBE_DELAY_MS, spins the main thread that long at the display open: the gate's self-test uses it
 *     to prove a regression of that size fails;
 *   - records every posix_spawn, posix_spawnp and fork the main thread makes before the first window maps, as a
 *     main_spawn event each and a count on the map event: the gate fails on any (interposed below, so this is no
 *     sample; calls between system libraries in the shared cache, NSTask's among them, are out of its reach);
 *   - with $SZF_PROBE_SAMPLES, samples the main thread's stack every 500 us until the map (until the files view
 *     has loaded with $SZF_PROBE_SAMPLE_UNTIL=loaded), weighted by the CPU time it used, for
 *     tools/perf/launch_profile.py.
 *
 * GLib, GObject and GTK are reached through dlsym only: the app bundles its own copies, and linking this file
 * against Homebrew's would load a second GLib. Children (the Friends helper) do not inherit the insertion. */

#include <ApplicationServices/ApplicationServices.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <libproc.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <sys/time.h>
#include <unistd.h>

typedef unsigned long GType;
typedef int gboolean;
typedef void *gpointer;
typedef struct { GType g_type; char data[16]; } GValue; /* layout only used through accessors */
typedef gboolean (*EmissionHook)(void *hint, unsigned n, const GValue *values, gpointer data);

static struct {
    GType (*type_from_name)(const char *);
    void *(*type_class_peek)(GType);
    void *(*type_class_ref)(GType);
    unsigned (*signal_lookup)(const char *, GType);
    unsigned long (*add_emission_hook)(unsigned, unsigned, EmissionHook, gpointer, void (*)(gpointer));
    gpointer (*value_peek_pointer)(const GValue *);
    gboolean (*value_get_boolean)(const GValue *);
    gboolean (*instance_is_a)(void *, GType);
    unsigned (*timeout_add)(unsigned, gboolean (*)(gpointer), gpointer);
    GType (*gtk_window_type)(void);
    GType (*frame_clock_type)(void);
} g;

static int out_fd = -1;
static bool active;
static const char *exit_after = "none";
static double start_us;
static int transform_calls, refused_orders, refused_activations, refused_modals, showed_on_screen;
static bool mapped, painted, loaded, view_hook_installed;
static int main_spawns; /* before the map, on the main thread */

static double now_us(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec * 1e6 + tv.tv_usec;
}

static double thread_cpu_ms(void) {
    thread_basic_info_data_t info;
    mach_msg_type_number_t count = THREAD_BASIC_INFO_COUNT;
    mach_port_t thread = mach_thread_self();
    kern_return_t kr = thread_info(thread, THREAD_BASIC_INFO, (thread_info_t)&info, &count);
    mach_port_deallocate(mach_task_self(), thread);
    if (kr != KERN_SUCCESS) return -1;
    return (info.user_time.seconds + info.system_time.seconds) * 1e3 +
           (info.user_time.microseconds + info.system_time.microseconds) / 1e3;
}

static double process_cpu_ms(void) {
    struct rusage ru;
    getrusage(RUSAGE_SELF, &ru);
    return (ru.ru_utime.tv_sec + ru.ru_stime.tv_sec) * 1e3 + (ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) / 1e3;
}

static double footprint_mb(void) {
    struct rusage_info_v4 ri;
    if (proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&ri) != 0) return -1;
    return ri.ri_phys_footprint / 1048576.0;
}

static void emit(const char *event, const char *extra_fmt, ...) {
    char extra[256] = "";
    char line[768];
    if (out_fd < 0) return;
    if (extra_fmt) {
        va_list ap;
        va_start(ap, extra_fmt);
        vsnprintf(extra, sizeof extra, extra_fmt, ap);
        va_end(ap);
    }
    double t = now_us();
    int n = snprintf(line, sizeof line,
                     "{\"event\":\"%s\",\"t_ms\":%.3f,\"main_cpu_ms\":%.3f,\"proc_cpu_ms\":%.3f,"
                     "\"footprint_mb\":%.2f,\"refused_orders\":%d,\"refused_activations\":%d,"
                     "\"refused_modals\":%d,\"transform_calls\":%d%s%s}\n",
                     event, (t - start_us) / 1e3, thread_cpu_ms(), process_cpu_ms(), footprint_mb(), refused_orders,
                     refused_activations, refused_modals, transform_calls, extra[0] ? "," : "", extra);
    if (n > 0) write(out_fd, line, (size_t)n < sizeof line ? (size_t)n : sizeof line - 1);
}

/* Any on-screen window of this process is a failure of the probe: report it and leave at once. */
static void check_offscreen(const char *where) {
    static CFArrayRef (*copy_list)(CGWindowListOption, CGWindowID);
    if (!copy_list)
        copy_list = (CFArrayRef(*)(CGWindowListOption, CGWindowID))dlsym(RTLD_DEFAULT, "CGWindowListCopyWindowInfo");
    if (!copy_list) return;
    CFArrayRef list = copy_list(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    if (!list) return;
    int mine = 0;
    pid_t me = getpid();
    for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
        CFDictionaryRef w = CFArrayGetValueAtIndex(list, i);
        CFNumberRef pidref = CFDictionaryGetValue(w, kCGWindowOwnerPID);
        int pid = 0;
        if (pidref && CFNumberGetValue(pidref, kCFNumberIntType, &pid) && pid == me) mine++;
    }
    CFRelease(list);
    if (mine > 0) {
        showed_on_screen = mine;
        emit("ON_SCREEN", "\"where\":\"%s\",\"windows\":%d", where, mine);
        _exit(3);
    }
}


/* ---- Optional main-thread sampler (SZF_PROBE_SAMPLES=<file>) ----------------------------------------------
 * Every 500 us the main thread is suspended, its frame-pointer chain copied into a preallocated buffer (no malloc
 * while it is suspended: it may hold the malloc lock), and resumed. Sampling stops at the window map; the stacks
 * are then written as unslid addresses per image, for symbolising with nm offline. */
#define SAMPLE_MAX 4000
#define DEPTH_MAX 96
static uintptr_t sample_pcs[SAMPLE_MAX][DEPTH_MAX];
static unsigned char sample_depth[SAMPLE_MAX];
static unsigned short sample_cpu_us[SAMPLE_MAX];
static uint64_t last_cpu_us;
static volatile int sample_count;
static volatile bool sampling;
static thread_act_t main_thread;
static uintptr_t stack_lo, stack_hi;
static const char *samples_path;

static void *sampler_main(void *arg) {
    (void)arg;
    while (sampling && sample_count < SAMPLE_MAX) {
        usleep(500);
        if (!sampling) break;
        thread_basic_info_data_t bi;
        mach_msg_type_number_t bc = THREAD_BASIC_INFO_COUNT;
        if (thread_suspend(main_thread) != KERN_SUCCESS) break;
        arm_thread_state64_t st;
        mach_msg_type_number_t sc = ARM_THREAD_STATE64_COUNT;
        int i = sample_count;
        if (thread_get_state(main_thread, ARM_THREAD_STATE64, (thread_state_t)&st, &sc) == KERN_SUCCESS) {
            int d = 0;
            sample_pcs[i][d++] = (uintptr_t)arm_thread_state64_get_pc(st);
            sample_pcs[i][d++] = (uintptr_t)arm_thread_state64_get_lr(st);
            uintptr_t fp = (uintptr_t)arm_thread_state64_get_fp(st);
            while (d < DEPTH_MAX && fp >= stack_lo && fp + 16 <= stack_hi && (fp & 7) == 0) {
                uintptr_t next = ((uintptr_t *)fp)[0];
                uintptr_t ret = ((uintptr_t *)fp)[1] & 0x0000000fffffffffULL; /* strip PAC */
                if (ret) sample_pcs[i][d++] = ret;
                if (next <= fp) break;
                fp = next;
            }
            sample_depth[i] = (unsigned char)d;
            /* Weight: the main thread's CPU time since the previous sample. */
            thread_info(main_thread, THREAD_BASIC_INFO, (thread_info_t)&bi, &bc);
            uint64_t cpu = (uint64_t)(bi.user_time.seconds + bi.system_time.seconds) * 1000000u +
                           bi.user_time.microseconds + bi.system_time.microseconds;
            uint64_t delta = last_cpu_us ? cpu - last_cpu_us : 0;
            last_cpu_us = cpu;
            sample_cpu_us[i] = (unsigned short)(delta > 60000 ? 60000 : delta);
            sample_count = i + 1;
        }
        thread_resume(main_thread);
    }
    return NULL;
}

static void sampler_start(void) {
    samples_path = getenv("SZF_PROBE_SAMPLES");
    if (!samples_path) return;
    main_thread = mach_thread_self();
    pthread_t self = pthread_self();
    stack_hi = (uintptr_t)pthread_get_stackaddr_np(self);
    stack_lo = stack_hi - pthread_get_stacksize_np(self);
    sampling = true;
    pthread_t t;
    pthread_create(&t, NULL, sampler_main, NULL);
    pthread_detach(t);
}

static void sampler_stop_and_write(void) {
    if (!samples_path || !sampling) return;
    sampling = false;
    usleep(2000); /* let an in-flight sample finish */
    FILE *f = fopen(samples_path, "a");
    if (!f) return;
    uint32_t n = _dyld_image_count();
    fprintf(f, "# run\n");
    for (int i = 0; i < sample_count; i++) {
        fprintf(f, "%u", (unsigned)sample_cpu_us[i]);
        for (int d = 0; d < sample_depth[i]; d++) {
            uintptr_t pc = sample_pcs[i][d] - (d > 0 ? 1 : 0);
            const char *img = "?";
            uintptr_t off = pc;
            for (uint32_t k = 0; k < n; k++) {
                const struct mach_header_64 *h = (const struct mach_header_64 *)_dyld_get_image_header(k);
                intptr_t slide = _dyld_get_image_vmaddr_slide(k);
                /* find __TEXT segment bounds */
                const struct load_command *lc = (const struct load_command *)(h + 1);
                for (uint32_t c = 0; c < h->ncmds; c++) {
                    if (lc->cmd == LC_SEGMENT_64) {
                        const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
                        if (strcmp(seg->segname, "__TEXT") == 0) {
                            uintptr_t lo = seg->vmaddr + slide, hi = lo + seg->vmsize;
                            if (pc >= lo && pc < hi) {
                                img = _dyld_get_image_name(k);
                                off = pc - slide;
                            }
                            break;
                        }
                    }
                    lc = (const struct load_command *)((const char *)lc + lc->cmdsize);
                }
                if (img[0] != '?') break;
            }
            const char *b = strrchr(img, '/');
            fprintf(f, " %s:%lx", b ? b + 1 : img, (unsigned long)off);
        }
        fprintf(f, "\n");
    }
    fclose(f);
}

static void maybe_exit(const char *milestone) {
    if (strcmp(exit_after, milestone) == 0) {
        check_offscreen(milestone);
        emit("exit", "\"after\":\"%s\"", milestone);
        _exit(0);
    }
}

/* ---- GObject emission hooks --------------------------------------------------------------------------------- */

static gboolean on_end_loading(void *hint, unsigned n, const GValue *values, gpointer data) {
    (void)hint, (void)data;
    gboolean all_seen = n > 1 ? g.value_get_boolean(&values[1]) : 0;
    if (all_seen && !loaded) {
        loaded = true;
        emit("loaded", NULL);
        sampler_stop_and_write();
        check_offscreen("loaded");
        maybe_exit("loaded");
    }
    return !loaded;
}

static void install_view_hook(void) {
    if (view_hook_installed) return;
    GType view = g.type_from_name("NautilusFilesView");
    if (!view || !g.type_class_peek(view)) return;
    unsigned id = g.signal_lookup("end-loading", view);
    if (!id) return;
    g.add_emission_hook(id, 0, on_end_loading, NULL, NULL);
    view_hook_installed = true;
    emit("view_class", NULL);
}

/* Polls for the files view class every millisecond during startup only: never past 30 s, so an idle
 * measurement is not paying for the probe's own timer. */
static gboolean poll_view_class(gpointer data) {
    (void)data;
    install_view_hook();
    return !view_hook_installed && now_us() - start_us < 30e6;
}

static gboolean on_after_paint(void *hint, unsigned n, const GValue *values, gpointer data) {
    (void)hint, (void)n, (void)values, (void)data;
    if (mapped && !painted) {
        painted = true;
        emit("paint", NULL);
        check_offscreen("paint");
        maybe_exit("paint");
    }
    return !painted;
}

static gboolean on_map(void *hint, unsigned n, const GValue *values, gpointer data) {
    (void)hint, (void)data;
    if (mapped || n < 1) return !mapped;
    void *instance = g.value_peek_pointer(&values[0]);
    if (instance && g.instance_is_a(instance, g.gtk_window_type())) {
        mapped = true;
        emit("map", "\"main_spawns\":%d", main_spawns);
        if (!getenv("SZF_PROBE_SAMPLE_UNTIL")) sampler_stop_and_write();
        install_view_hook();
        check_offscreen("map");
        maybe_exit("map");
    }
    return !mapped;
}

static bool resolve_glib(void) {
#define R(field, name) if (!(*(void **)&g.field = dlsym(RTLD_DEFAULT, name))) return false
    R(type_from_name, "g_type_from_name");
    R(type_class_peek, "g_type_class_peek");
    R(type_class_ref, "g_type_class_ref");
    R(signal_lookup, "g_signal_lookup");
    R(add_emission_hook, "g_signal_add_emission_hook");
    R(value_peek_pointer, "g_value_peek_pointer");
    R(value_get_boolean, "g_value_get_boolean");
    R(instance_is_a, "g_type_check_instance_is_a");
    R(timeout_add, "g_timeout_add");
    R(gtk_window_type, "gtk_window_get_type");
    R(frame_clock_type, "gdk_frame_clock_get_type");
#undef R
    return true;
}

/* Called by GDK's display open, after gtk_init has GLib, GObject and GTK ready. */
static OSStatus quiet_transform(const ProcessSerialNumber *process, ProcessApplicationTransformState state) {
    (void)process, (void)state;
    transform_calls++;
    if (active && transform_calls == 1) {
        const char *delay = getenv("SZF_PROBE_DELAY_MS");
        if (delay && atoi(delay) > 0) {
            double until = now_us() + atoi(delay) * 1e3;
            while (now_us() < until) {
            }
        }
        emit("display_open", NULL);
        if (resolve_glib()) {
            /* The classes exist moments later anyway; the signals can only be looked up once they do. */
            g.type_class_ref(g.gtk_window_type());
            g.type_class_ref(g.frame_clock_type());
            unsigned map = g.signal_lookup("map", g.gtk_window_type());
            unsigned paint = g.signal_lookup("after-paint", g.frame_clock_type());
            if (map) g.add_emission_hook(map, 0, on_map, NULL, NULL);
            if (paint) g.add_emission_hook(paint, 0, on_after_paint, NULL, NULL);
            g.timeout_add(1, poll_view_class, NULL);
            emit("hooks", "\"map_signal\":%u,\"paint_signal\":%u", map, paint);
        } else {
            emit("hooks_failed", NULL);
        }
    }
    return noErr;
}

/* A process spawn on the main thread before the first window maps: the launch waits on the kernel for the whole
 * exec (Friends starts its helper from a thread of its own for exactly that reason). */
static void note_spawn(const char *call, const char *path) {
    char clean[200];
    size_t n = 0;
    if (!active || mapped || !pthread_main_np()) return;
    main_spawns++;
    for (const char *c = path ? path : ""; *c && n < sizeof clean - 1; c++)
        clean[n++] = (*c == '"' || *c == '\\' || (unsigned char)*c < 0x20) ? '_' : *c;
    clean[n] = 0;
    emit("main_spawn", "\"call\":\"%s\",\"path\":\"%s\"", call, clean);
}

static int spawn_guard(pid_t *pid, const char *path, const posix_spawn_file_actions_t *actions,
                       const posix_spawnattr_t *attributes, char *const argv[], char *const envp[]) {
    note_spawn("posix_spawn", path);
    return posix_spawn(pid, path, actions, attributes, argv, envp);
}

static int spawnp_guard(pid_t *pid, const char *file, const posix_spawn_file_actions_t *actions,
                        const posix_spawnattr_t *attributes, char *const argv[], char *const envp[]) {
    note_spawn("posix_spawnp", file);
    return posix_spawnp(pid, file, actions, attributes, argv, envp);
}

static pid_t fork_guard(void) {
    note_spawn("fork", "");
    return fork();
}

/* Applies to every image but this one: the app, its bundled GLib and GTK, the Friends client. */
__attribute__((used, section("__DATA,__interpose"))) static const struct {
    const void *replacement;
    const void *original;
} szf_probe_interposers[] = {
    {(const void *)quiet_transform, (const void *)TransformProcessType},
    {(const void *)spawn_guard, (const void *)posix_spawn},
    {(const void *)spawnp_guard, (const void *)posix_spawnp},
    {(const void *)fork_guard, (const void *)fork},
};

/* ---- AppKit refusals ---------------------------------------------------------------------------------------- */

static void refuse_order(id self, SEL _cmd) {
    (void)self, (void)_cmd;
    refused_orders++;
}
static void refuse_activation(id self, SEL _cmd) {
    (void)self, (void)_cmd;
    refused_activations++;
}
static BOOL refuse_activation_bool(id self, SEL _cmd) {
    (void)self, (void)_cmd;
    refused_activations++;
    return NO;
}
static long refuse_modal(id self, SEL _cmd) {
    (void)self, (void)_cmd;
    refused_modals++;
    emit("refused_modal", "\"selector\":\"%s\"", sel_getName(_cmd));
    return -1001; /* NSModalResponseAbort */
}

static void replace(const char *class_name, const char *selector, IMP imp) {
    Class cls = objc_getClass(class_name);
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel_registerName(selector));
    if (!m) return;
    /* class_replaceMethod adds an override on this class even when the method is inherited. */
    class_replaceMethod(cls, sel_registerName(selector), imp, method_getTypeEncoding(m));
}

static void refuse_appkit(void) {
    static const char *orders[] = {"orderFront:", "makeKeyAndOrderFront:", "orderFrontRegardless",
                                   "orderWindow:relativeTo:", "makeKeyWindow", "makeMainWindow", "orderBack:",
                                   "setIsVisible:", "deminiaturize:", "toggleFullScreen:"};
    static const char *windows[] = {"NSWindow", "NSPanel", "GdkMacosWindow"};
    for (size_t c = 0; c < sizeof windows / sizeof *windows; c++)
        for (size_t s = 0; s < sizeof orders / sizeof *orders; s++) replace(windows[c], orders[s], (IMP)refuse_order);
    replace("GdkMacosWindow", "showAndMakeKey:", (IMP)refuse_order);
    replace("NSApplication", "activateIgnoringOtherApps:", (IMP)refuse_activation);
    replace("NSApplication", "activate", (IMP)refuse_activation);
    replace("NSApplication", "unhide:", (IMP)refuse_activation);
    replace("NSApplication", "unhideWithoutActivation", (IMP)refuse_activation);
    replace("NSApplication", "setActivationPolicy:", (IMP)refuse_activation_bool);
    replace("NSApplication", "requestUserAttention:", (IMP)refuse_modal);
    replace("NSApplication", "runModalForWindow:", (IMP)refuse_modal);
    replace("NSApplication", "beginModalSessionForWindow:", (IMP)refuse_modal);
    replace("NSAlert", "runModal", (IMP)refuse_modal);
    replace("NSRunningApplication", "activateWithOptions:", (IMP)refuse_activation_bool);
}

__attribute__((constructor)) static void szf_probe_init(void) {
    char path[PATH_MAX];
    uint32_t size = sizeof path;
    const char *base;
    struct proc_bsdinfo info;

    /* The Friends helper and anything else the app starts run without the probe. */
    unsetenv("DYLD_INSERT_LIBRARIES");
    if (_NSGetExecutablePath(path, &size) != 0) return;
    base = strrchr(path, '/');
    base = base ? base + 1 : path;
    if (strcmp(base, "nautilus") != 0) return;

    if (proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, sizeof info) == sizeof info)
        start_us = info.pbi_start_tvsec * 1e6 + info.pbi_start_tvusec;
    else
        start_us = now_us();
    const char *out = getenv("SZF_PROBE_OUT");
    if (out) out_fd = open(out, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (getenv("SZF_PROBE_EXIT")) exit_after = getenv("SZF_PROBE_EXIT");
    active = true;
    refuse_appkit();
    emit("ctor", "\"start_epoch_ms\":%.3f", start_us / 1e3);
    sampler_start();
}
