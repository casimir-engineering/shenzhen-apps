// Launch performance probe: a library inserted into the reader (DYLD_INSERT_LIBRARIES, into an ad hoc signed copy of
// the app) that lets its real main() run -- state migration, launch prerender, NSApplication, [NSApp run],
// applicationDidFinishLaunching -- with every window refused before it reaches the screen, no Dock icon (activation
// policy Prohibited), no activation, the updater inert and the Settings sheet disabled. It reports, relative to the kernel's spawn time of this process:
//   dfl_end      applicationDidFinishLaunching returned (window built, startup document opened)
//   order        the window asked to come on screen (refused here)
//   frame        the first frame drawn: the app's own post-launch display pass, then the whole window content
//                drawn once into a bitmap (an offscreen window does not draw on its own)
// with the main thread's CPU time at each point, which moves far less with machine load than wall time does.
// After the frame it waits for the post-launch tail (catch-up save, Friends attach, warm stages) to settle and
// reports the main thread's CPU by then, the Friends attach's own main-thread cost, and when the Friends helper
// started. PROBE_SAMPLE=<n> samples the main thread at 1 kHz until the first frame and prints the top n functions;
// sample_friends and sample_spawn count the samples inside Friends code or a process spawn. Every launch also counts
// the process spawns the main thread made before the first frame, deterministically (SPDFMacLaunchSpawnGuard.mm).
// Every symbol of the reader is reached through the Objective-C runtime, so the same library measures any release's
// app as shipped, for A/B comparison: mac/tests/launch/run-launch-performance.py does exactly that.
//
// Usage: DYLD_INSERT_LIBRARIES=SPDFMacLaunchPerformanceProbe.dylib PROBE_MODE=<mode> [PROBE_DOCUMENT=<path>]
//        <ad hoc signed copy of ShenzhenPDF.app>/Contents/MacOS/ShenzhenPDF [document opened at launch]
//   launch   report and exit once the post-launch work has settled
//   idle     then also measure 60 s (PROBE_IDLE_SECONDS) of idle CPU and wakeups, this process and the
//            Friends helper it spawned (found by executable path under this bundle)
//   open     after launch, open PROBE_DOCUMENT, wait until its renders settle, report footprint
//   pages    after launch, open PROBE_DOCUMENT (a long drawing set) and time a jump to page 30 until sharp
//   seed     save the state (session included) and exit: a template for launches that restore it
//   fixture  write a synthetic drawing set (10 A3 pages of fine curves) to PROBE_DOCUMENT and exit
// Environment: SPDF_STATE_DIR must name a scratch directory (the probe refuses to run without one).

#import <Cocoa/Cocoa.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <libproc.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <signal.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

bool SPDFLaunchPerformanceWriteDrawingSet(const char* path, long pages, long curves);
void SPDFLaunchSpawnGuardInstall(void);
void SPDFLaunchSpawnGuardFrameDrawn(void);
long SPDFLaunchSpawnGuardReport(char* out, size_t size);
// SPDFMacLaunchQuitProbe.mm (first page, interactive, quit timings) and SPDFMacLaunchProfileSeed.mm (PROBE_MODE=profile)
void SPDFProbeTrackLaunch(id reader, double spawnMs), SPDFProbeFrameDrawn(void), SPDFProbeModal(id alert);
void SPDFProbeOrderedOut(NSWindow* window), SPDFProbeAddResults(NSMutableDictionary* out), SPDFProbeSeedProfile(id);
BOOL SPDFProbeRunQuitMode(const char* mode, id reader);

static double gSpawnMs;
static double gOrderMs = -1, gDflEnterMs = -1, gDflEndMs = -1, gFrameMs = -1;
static double gDflEndCpuMs = -1, gFrameCpuMs = -1, gOrderCpuMs = -1;
static double gFrameDrawMs = -1, gFrameFootprintMb = -1;
static int gModals;
static const char* gMode = "launch";
static NSString* gDocument;
static id gDelegate;

static double NowMs(void) { return CFAbsoluteTimeGetCurrent() * 1000.0; }
static double ThreadCpuMs(void) { return (double)clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) / 1e6; }
static double ProcessCpuMs(void) {
    struct rusage usage;
    getrusage(RUSAGE_SELF, &usage);
    return (usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000.0 +
           (usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000.0;
}
static double StartTimeMs(pid_t pid) {
    struct kinfo_proc info;
    size_t size = sizeof(info);
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) return NowMs();
    double unixMs = (double)info.kp_proc.p_starttime.tv_sec * 1000.0 + info.kp_proc.p_starttime.tv_usec / 1000.0;
    return unixMs - kCFAbsoluteTimeIntervalSince1970 * 1000.0;
}
// ---- PROBE_SAMPLE=1: a 1 kHz sampler of the main thread until the first frame ---------------------------------
// Suspends the main thread, walks its frame-pointer chain (arm64 keeps frame pointers), resumes it; the stacks are
// symbolized after the frame and printed as inclusive and self sample counts per function.
#include <dlfcn.h>
#include <pthread.h>
#include <algorithm>
#include <map>
#include <set>
#include <string>
#include <vector>
// SPDFMacLaunchProbeSymbols.mm
void SPDFLaunchProbeListReaderMethods(uintptr_t didFinishLaunching, uintptr_t friendsAfterFirstPaint);
std::string SPDFLaunchProbeSymbol(uintptr_t pc);
static mach_port_t gMainThread;
// Fixed storage allocated before sampling starts: the sampler must not allocate while the main thread is suspended,
// which may be holding the malloc lock.
enum { kMaxSamples = 4096, kMaxFrames = 130 };
static uintptr_t (*gStacks)[kMaxFrames];
static int* gDepths;
static volatile long gSampleCount;
static volatile bool gSampling;
static void* SamplerThread(void*) {
    while (gSampling && gSampleCount < kMaxSamples) {
        if (thread_suspend(gMainThread) == KERN_SUCCESS) {
            arm_thread_state64_t state;
            mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
            uintptr_t* stack = gStacks[gSampleCount];
            int depth = 0;
            if (thread_get_state(gMainThread, ARM_THREAD_STATE64, (thread_state_t)&state, &count) == KERN_SUCCESS) {
                stack[depth++] = (uintptr_t)arm_thread_state64_get_pc(state);
                stack[depth++] = (uintptr_t)arm_thread_state64_get_lr(state);
                uintptr_t fp = (uintptr_t)arm_thread_state64_get_fp(state);
                while (fp && !(fp & 7) && depth < kMaxFrames) {
                    uintptr_t* frame = (uintptr_t*)fp;
                    vm_size_t got = 0;
                    uintptr_t pair[2];
                    if (vm_read_overwrite(mach_task_self(), (vm_address_t)frame, sizeof(pair), (vm_address_t)pair,
                                          &got) != KERN_SUCCESS || got != sizeof(pair))
                        break;
                    if (pair[1]) stack[depth++] = pair[1] & 0x0000000FFFFFFFFFull;
                    if (pair[0] <= fp) break;
                    fp = pair[0];
                }
            }
            thread_resume(gMainThread);
            gDepths[gSampleCount] = depth;
            gSampleCount = gSampleCount + 1;
        }
        usleep(1000);
    }
    return NULL;
}
static void StartSampler(void) {
    if (!getenv("PROBE_SAMPLE")) return;
    gMainThread = mach_thread_self();
    gStacks = (uintptr_t(*)[kMaxFrames])calloc(kMaxSamples, sizeof(*gStacks));
    gDepths = (int*)calloc(kMaxSamples, sizeof(int));
    gSampling = true;
    pthread_t thread;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_set_qos_class_np(&attr, QOS_CLASS_USER_INTERACTIVE, 0);
    pthread_create(&thread, &attr, SamplerThread, NULL);
}
static IMP gOrderWindow, gSetPolicy, gMakeKeyAndOrderFront, gDidFinishLaunching, gFriendsAfterFirstPaint;
static long gSampleTotal = -1, gSampleFriends = -1, gSampleSpawn = -1;
static void StopSamplerAndReport(void) {
    if (!gSampling) return;
    gSampling = false;
    usleep(3000);
    SPDFLaunchProbeListReaderMethods((uintptr_t)gDidFinishLaunching, (uintptr_t)gFriendsAfterFirstPaint);
    std::map<std::string, int> inclusive, self;
    gSampleTotal = gSampleCount;
    gSampleFriends = gSampleSpawn = 0;
    for (long n = 0; n < gSampleTotal; n++) {
        std::vector<uintptr_t> stack(gStacks[n], gStacks[n] + gDepths[n]);
        std::set<std::string> seen;
        bool friends = false, spawn = false;
        for (size_t i = 0; i < stack.size(); i++) {
            if (i == 1) continue; // LR: only meaningful when the PC is a leaf; the fp chain covers callers
            std::string name = SPDFLaunchProbeSymbol(stack[i]);
            if (i == 0) self[name]++;
            if (seen.insert(name).second) inclusive[name]++;
            // Friends work on the main thread before the first frame: its classes and C library are all named so.
            if (name.find("riends") != std::string::npos) friends = true;
            if (name.find("posix_spawn") != std::string::npos || name.find("spawn_helper") != std::string::npos)
                spawn = true;
        }
        gSampleFriends += friends;
        gSampleSpawn += spawn;
    }
    std::vector<std::pair<int, std::string>> top;
    for (auto& kv : inclusive) top.push_back({kv.second, kv.first});
    std::sort(top.rbegin(), top.rend());
    fprintf(stderr, "SAMPLE total=%ld\n", gSampleTotal);
    for (size_t i = 0; i < top.size() && i < (size_t)atol(getenv("PROBE_SAMPLE")); i++)
        fprintf(stderr, "SAMPLE incl %5d self %5d %s\n", top[i].first, self[top[i].second], top[i].second.c_str());
}

static double MachToMs(uint64_t t) {
    static mach_timebase_info_data_t base;
    if (!base.denom) mach_timebase_info(&base);
    return (double)t * base.numer / base.denom / 1e6;
}
struct Usage {
    double cpuMs;
    uint64_t interruptWakeups, idleWakeups, footprint;
    bool ok;
};
static Usage UsageOf(pid_t pid) {
    Usage u = {};
    struct rusage_info_v4 info;
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t*)&info) != 0) return u;
    u.cpuMs = MachToMs(info.ri_user_time + info.ri_system_time);
    u.interruptWakeups = info.ri_interrupt_wkups;
    u.idleWakeups = info.ri_pkg_idle_wkups;
    u.footprint = info.ri_phys_footprint;
    u.ok = true;
    return u;
}

// ---- hooks -------------------------------------------------------------------------------------------------
static double gFriendsAfterPaintMs = -1, gFriendsAfterPaintCpuMs = -1;
// The reader's Friends attach after the first paint (absent before Friends): its main-thread cost, wall and CPU.
static void TimedFriendsAfterFirstPaint(id delegate, SEL sel) {
    double t0 = NowMs(), c0 = ThreadCpuMs();
    ((void (*)(id, SEL))gFriendsAfterFirstPaint)(delegate, sel);
    gFriendsAfterPaintMs = NowMs() - t0;
    gFriendsAfterPaintCpuMs = ThreadCpuMs() - c0;
}
static void RefuseOrder(id window, SEL sel, NSInteger place, NSInteger other) {
    if (place != NSWindowOut) return;
    SPDFProbeOrderedOut(window), ((void (*)(id, SEL, NSInteger, NSInteger))gOrderWindow)(window, sel, place, other);
}
static void ProhibitedPolicy(id app, SEL sel, NSInteger policy) {
    (void)policy;
    ((void (*)(id, SEL, NSInteger))gSetPolicy)(app, sel, NSApplicationActivationPolicyProhibited);
}
static void Inert(id self, SEL _cmd) { (void)self; (void)_cmd; }
static void InertBool(id self, SEL _cmd, BOOL flag) { (void)self; (void)_cmd; (void)flag; }
static void InertObject(id self, SEL _cmd, id object) { (void)self; (void)_cmd; (void)object; }
static NSModalResponse NoModal(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    gModals++, SPDFProbeModal(self);
    return NSAlertSecondButtonReturn;
}
static CGFloat Retina(id self, SEL _cmd) { (void)self; (void)_cmd; return 2.0; }
static void RecordOrderFront(id window, SEL sel, id sender) {
    if (gOrderMs < 0) {
        gOrderMs = NowMs();
        gOrderCpuMs = ThreadCpuMs();
    }
    ((void (*)(id, SEL, id))gMakeKeyAndOrderFront)(window, sel, sender);
}

static void Replace(Class cls, NSString* name, IMP imp, IMP* original) {
    Method method = cls ? class_getInstanceMethod(cls, NSSelectorFromString(name)) : NULL;
    if (!method) return;
    IMP old = method_setImplementation(method, imp);
    if (original) *original = old;
}

static id Ivar_(id object, const char* name) {
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    return ivar ? object_getIvar(object, ivar) : nil;
}
static BOOL QueuesIdle(id delegate) {
    static const char* const names[] = {"_renderQueue",        "_backgroundRenderQueue", "_minimapQueue",
                                        "_zoomSeedRenderQueue", "_cacheRenderQueue",      "_preloadQueue"};
    for (const char* name : names) {
        NSOperationQueue* queue = Ivar_(delegate, name);
        if (queue.operationCount) return NO;
    }
    return YES;
}
static void Pump(NSTimeInterval seconds) {
    [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}
static void RunFor(NSTimeInterval seconds) {
    NSDate* until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (until.timeIntervalSinceNow > 0) Pump(MIN(0.05, until.timeIntervalSinceNow));
}
// Idle: the run loop sleeps until the app's own timers or sources wake it, so the wakeups counted are the app's.
static void IdleFor(NSTimeInterval seconds) {
    NSDate* until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (until.timeIntervalSinceNow > 0) [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:until];
}
static BOOL RunUntil(NSTimeInterval timeout, BOOL (^done)(void)) {
    NSDate* until = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!done()) {
        if (until.timeIntervalSinceNow <= 0) return NO;
        Pump(0.002);
    }
    return YES;
}

// The Friends helper this launch spawned from this bundle, if it is running.
static pid_t HelperPid(void) {
    NSString* helpers =
        [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Contents/Helpers/Shenzhen Friends.app"];
    int count = proc_listallpids(NULL, 0);
    if (count <= 0) return 0;
    pid_t* pids = (pid_t*)calloc((size_t)count + 16, sizeof(pid_t));
    count = proc_listallpids(pids, (int)((count + 16) * sizeof(pid_t)));
    pid_t found = 0;
    char path[PROC_PIDPATHINFO_MAXSIZE];
    for (int i = 0; i < count && !found; i++) {
        // This launch's own helper: another probe running from the same bundle has its own.
        struct proc_bsdinfo info;
        if (pids[i] == getpid() || proc_pidinfo(pids[i], PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info) ||
            (pid_t)info.pbi_ppid != getpid() || proc_pidpath(pids[i], path, sizeof(path)) <= 0)
            continue;
        if ([[NSString stringWithUTF8String:path] hasPrefix:helpers]) found = pids[i];
    }
    free(pids);
    return found;
}

static NSWindow* MainWindow(void) { return Ivar_(gDelegate, "_window"); }

void SPDFProbeFinish(NSDictionary* extra) {
    Usage self_ = UsageOf(getpid());
    NSMutableDictionary* out = [@{
        @"mode" : @(gMode),
        @"dfl_enter_ms" : @(gDflEnterMs - gSpawnMs),
        @"dfl_end_ms" : @(gDflEndMs - gSpawnMs),
        @"order_ms" : @(gOrderMs < 0 ? -1 : gOrderMs - gSpawnMs),
        @"frame_ms" : @(gFrameMs - gSpawnMs),
        @"frame_draw_ms" : @(gFrameDrawMs),
        @"dfl_end_main_cpu_ms" : @(gDflEndCpuMs),
        @"order_main_cpu_ms" : @(gOrderCpuMs),
        @"frame_main_cpu_ms" : @(gFrameCpuMs),
        @"frame_footprint_mb" : @(gFrameFootprintMb),
        @"exit_footprint_mb" : @(self_.footprint / 1048576.0),
        @"process_cpu_ms" : @(ProcessCpuMs()),
        @"modals" : @(gModals),
    } mutableCopy];
    if (gFriendsAfterFirstPaint) {
        out[@"friends_after_paint_ms"] = @(gFriendsAfterPaintMs);
        out[@"friends_after_paint_cpu_ms"] = @(gFriendsAfterPaintCpuMs);
        // The helper link's state (SZFriendsLinkState: 2 ready), so a Friends-on measurement is known to include
        // the connection rather than a link still looking for its helper.
        SEL stateSel = NSSelectorFromString(@"friendsState");
        id state = [gDelegate respondsToSelector:stateSel] ? ((id (*)(id, SEL))objc_msgSend)(gDelegate, stateSel) : nil;
        id link = [state respondsToSelector:NSSelectorFromString(@"link")] ? [state valueForKey:@"link"] : nil;
        out[@"friends_link_state"] = link ? [link valueForKey:@"state"] : @(-1);
        if (link && [link valueForKey:@"statusText"]) out[@"friends_link_status"] = [link valueForKey:@"statusText"];
    }
    if (gSampleTotal >= 0) {
        out[@"sample_total"] = @(gSampleTotal);
        out[@"sample_friends"] = @(gSampleFriends);
        out[@"sample_spawn"] = @(gSampleSpawn);
    }
    char spawns[2048];
    out[@"main_spawns_before_frame"] = @(SPDFLaunchSpawnGuardReport(spawns, sizeof(spawns)));
    out[@"main_spawns_before_frame_calls"] = @(spawns);
    SPDFProbeAddResults(out);
    [out addEntriesFromDictionary:extra ?: @{}];
    NSData* json = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingSortedKeys error:nil];
    fprintf(stdout, "PROBE %s\n", [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
    fflush(stdout);
    pid_t helper = HelperPid();
    if (helper > 0) kill(helper, SIGTERM);
    _exit(0);
}

static void AfterFrame(void) {
    NSMutableDictionary* extra = [NSMutableDictionary dictionary];
    // Post-launch tail: the catch-up save, Friends attach, the idle warm stages.
    RunFor(1.5);
    RunUntil(20.0, ^{ return QueuesIdle(gDelegate); });
    extra[@"settled_footprint_mb"] = @(UsageOf(getpid()).footprint / 1048576.0);
    extra[@"settled_ms"] = @(NowMs() - gSpawnMs);
    extra[@"settled_main_cpu_ms"] = @(ThreadCpuMs());
    pid_t helper = HelperPid();
    extra[@"helper_running"] = @(helper > 0);
    if (helper > 0) extra[@"helper_start_ms"] = @(StartTimeMs(helper) - gSpawnMs);
    if (helper > 0) extra[@"helper_footprint_mb"] = @(UsageOf(helper).footprint / 1048576.0);
    if (!strcmp(gMode, "idle")) {
        const char* secondsText = getenv("PROBE_IDLE_SECONDS");
        double seconds = secondsText ? atof(secondsText) : 60.0;
        RunFor(3.0); // let the helper finish its own start
        helper = HelperPid();
        Usage a0 = UsageOf(getpid()), h0 = helper ? UsageOf(helper) : Usage{};
        double t0 = NowMs();
        IdleFor(seconds);
        double elapsed = (NowMs() - t0) / 1000.0;
        Usage a1 = UsageOf(getpid()), h1 = helper ? UsageOf(helper) : Usage{};
        extra[@"idle_seconds"] = @(elapsed);
        extra[@"idle_cpu_ms"] = @(a1.cpuMs - a0.cpuMs);
        extra[@"idle_wakeups_per_s"] = @((a1.interruptWakeups - a0.interruptWakeups) / elapsed);
        extra[@"idle_pkg_wakeups_per_s"] = @((a1.idleWakeups - a0.idleWakeups) / elapsed);
        extra[@"idle_footprint_mb"] = @(a1.footprint / 1048576.0);
        if (helper && h0.ok && h1.ok) {
            extra[@"helper_idle_cpu_ms"] = @(h1.cpuMs - h0.cpuMs);
            extra[@"helper_idle_wakeups_per_s"] = @((h1.interruptWakeups - h0.interruptWakeups) / elapsed);
            extra[@"helper_idle_pkg_wakeups_per_s"] = @((h1.idleWakeups - h0.idleWakeups) / elapsed);
            extra[@"helper_footprint_mb"] = @(h1.footprint / 1048576.0);
        }
    } else if (!strcmp(gMode, "open") && gDocument) {
        double t0 = NowMs(), c0 = ThreadCpuMs();
        ((void (*)(id, SEL, id))objc_msgSend)(gDelegate, NSSelectorFromString(@"openPaths:"), @[ gDocument ]);
        extra[@"open_return_ms"] = @(NowMs() - t0);
        extra[@"open_main_cpu_ms"] = @(ThreadCpuMs() - c0);
        RunFor(0.3);
        BOOL settled = RunUntil(60.0, ^{ return QueuesIdle(gDelegate); });
        extra[@"open_settled_ms"] = @(NowMs() - t0);
        extra[@"open_settled"] = @(settled);
        RunFor(1.0);
        RunUntil(20.0, ^{ return QueuesIdle(gDelegate); });
        extra[@"open_footprint_mb"] = @(UsageOf(getpid()).footprint / 1048576.0);
    } else if (!strcmp(gMode, "pages") && gDocument) {
        ((void (*)(id, SEL, id))objc_msgSend)(gDelegate, NSSelectorFromString(@"openPaths:"), @[ gDocument ]);
        RunFor(0.3);
        RunUntil(60.0, ^{ return QueuesIdle(gDelegate); });
        SEL visibleSel = NSSelectorFromString(@"visibleDocumentPageIndexesWithExtraRadius:preferredPage:");
        SEL matchesSel = NSSelectorFromString(@"renderedPageImage:matchesZoom:displayScale:");
        typedef NSArray<NSNumber*>* (*VisibleFn)(id, SEL, NSInteger, NSInteger*);
        typedef BOOL (*MatchesFn)(id, SEL, id, CGFloat, CGFloat);
        typedef void (*GoFn)(id, SEL, NSInteger, BOOL);
        BOOL (^sharp)(void) = ^BOOL {
          NSInteger preferred = -1;
          NSArray<NSNumber*>* pages = ((VisibleFn)objc_msgSend)(gDelegate, visibleSel, 0, &preferred);
          NSArray* rendered = Ivar_(gDelegate, "_renderedPages");
          Ivar zoomIvar = class_getInstanceVariable(object_getClass(gDelegate), "_zoom");
          CGFloat zoom = *(CGFloat*)((uint8_t*)(__bridge void*)gDelegate + ivar_getOffset(zoomIvar));
          for (NSNumber* n in pages)
              if (!((MatchesFn)objc_msgSend)(gDelegate, matchesSel, rendered[n.unsignedIntegerValue], zoom, 2.0))
                  return NO;
          return pages.count > 0;
        };
        double t0 = NowMs(), c0 = ThreadCpuMs();
        ((GoFn)objc_msgSend)(gDelegate, NSSelectorFromString(@"goToPage:preserveSinglePagePosition:"), 29, NO);
        extra[@"jump_return_ms"] = @(NowMs() - t0);
        extra[@"jump_main_cpu_ms"] = @(ThreadCpuMs() - c0);
        BOOL ok = RunUntil(30.0, sharp);
        extra[@"jump_sharp_ms"] = @(ok ? NowMs() - t0 : -1);
        RunUntil(60.0, ^{ return QueuesIdle(gDelegate); });
        extra[@"pages_footprint_mb"] = @(UsageOf(getpid()).footprint / 1048576.0);
    } else if (!strcmp(gMode, "profile")) {
        SPDFProbeSeedProfile(gDelegate);
    } else if (SPDFProbeRunQuitMode(gMode, gDelegate)) {
    } else if (!strcmp(gMode, "seed")) {
        ((void (*)(id, SEL))objc_msgSend)(gDelegate, NSSelectorFromString(@"savePersistentState"));
        RunFor(0.5);
    }
    SPDFProbeFinish(extra);
}

static void WrappedDidFinishLaunching(id delegate, SEL sel, NSNotification* note) {
    gDelegate = delegate;
    gDflEnterMs = NowMs();
    SPDFProbeTrackLaunch(delegate, gSpawnMs);
    ((void (*)(id, SEL, id))gDidFinishLaunching)(delegate, sel, note);
    gDflEndMs = NowMs();
    gDflEndCpuMs = ThreadCpuMs();
    // Queued behind the app's own post-launch display pass (dispatched in applicationDidFinishLaunching).
    dispatch_async(dispatch_get_main_queue(), ^{
      NSWindow* window = MainWindow();
      NSView* content = window.contentView;
      double d0 = NowMs();
      [content layoutSubtreeIfNeeded];
      NSBitmapImageRep* rep = [content bitmapImageRepForCachingDisplayInRect:content.bounds];
      if (rep) [content cacheDisplayInRect:content.bounds toBitmapImageRep:rep];
      gFrameMs = NowMs();
      SPDFLaunchSpawnGuardFrameDrawn();
      SPDFProbeFrameDrawn();
      StopSamplerAndReport();
      gFrameDrawMs = gFrameMs - d0;
      gFrameCpuMs = ThreadCpuMs();
      gFrameFootprintMb = UsageOf(getpid()).footprint / 1048576.0;
      // A run-loop block, not a main-queue one: AfterFrame spins the run loop, and the main queue does not drain
      // inside one of its own blocks -- the app's post-launch work (dispatch_after) would never run.
      CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopDefaultMode, ^{ AfterFrame(); });
      CFRunLoopWakeUp(CFRunLoopGetMain());
    });
}

// Runs when dyld loads the library, after the reader's classes are registered and before its main(). The processes the
// reader starts (the Friends helper) do not inherit the library; one that loads it anyway is left alone.
__attribute__((constructor)) static void ProbeStart(void) {
    unsetenv("DYLD_INSERT_LIBRARIES");
    if (!NSClassFromString(@"ShenzhenMacDelegate")) return;
    gSpawnMs = StartTimeMs(getpid());
    SPDFLaunchSpawnGuardInstall();
    StartSampler();
    setvbuf(stdout, NULL, _IONBF, 0);
    if (getenv("PROBE_MODE") && !strcmp(getenv("PROBE_MODE"), "fixture")) {
        const char* path = getenv("PROBE_DOCUMENT");
        _exit(path && SPDFLaunchPerformanceWriteDrawingSet(path, 10, 12000) ? 0 : 2);
    }
    const char* state = getenv("SPDF_STATE_DIR");
    if (!state || !*state) {
        fprintf(stderr, "SPDF_STATE_DIR must name a scratch directory\n");
        _exit(2);
    }
    // Mode and document come from the environment: AppKit reads every non-option argument as a file to open.
    if (getenv("PROBE_MODE")) gMode = getenv("PROBE_MODE");
    if (getenv("PROBE_DOCUMENT")) gDocument = [NSString stringWithUTF8String:getenv("PROBE_DOCUMENT")];
    setenv("SPDF_NO_ACTIVATE", "1", 1);
    @autoreleasepool {
        Replace(NSApplication.class, @"setActivationPolicy:", (IMP)ProhibitedPolicy, &gSetPolicy);
        Replace(NSApplication.class, @"activateIgnoringOtherApps:", (IMP)InertBool, NULL);
        Replace(NSApplication.class, @"activate", (IMP)Inert, NULL);
        Replace(NSWindow.class, @"orderWindow:relativeTo:", (IMP)RefuseOrder, &gOrderWindow);
        Replace(NSWindow.class, @"makeKeyAndOrderFront:", (IMP)RecordOrderFront, &gMakeKeyAndOrderFront);
        Replace(NSWindow.class, @"backingScaleFactor", (IMP)Retina, NULL);
        Replace(NSAlert.class, @"runModal", (IMP)NoModal, NULL);
        Class updater = NSClassFromString(@"SPDFUpdater");
        for (NSString* name in @[ @"consumePendingUpdateMarkerAndSweep", @"scheduleDailyUpdateCheckIfNeeded",
                                  @"armRecurringUpdateCheck" ])
            Replace(updater, name, (IMP)Inert, NULL);
        Class reader = NSClassFromString(@"ShenzhenMacDelegate");
        Replace(reader, @"showUnifiedSettingsMode:", (IMP)InertBool, NULL);
        Replace(reader, @"showShortcutHelp:", (IMP)InertObject, NULL);
        Replace(reader, @"applicationDidFinishLaunching:", (IMP)WrappedDidFinishLaunching, &gDidFinishLaunching);
        Replace(reader, @"friendsAfterFirstPaint", (IMP)TimedFriendsAfterFirstPaint, &gFriendsAfterFirstPaint);
        if (!gDidFinishLaunching) {
            fprintf(stderr, "reader delegate has no applicationDidFinishLaunching:\n");
            _exit(2);
        }
    }
    // The reader's main() runs next; a document on the command line opens at launch, as `ShenzhenPDF <path>` does.
}
