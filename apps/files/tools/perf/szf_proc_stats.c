/* szf_proc_stats: prints one JSON line per pid with its CPU time, memory footprint, wakeups and how many of its
 * windows are on screen (which must always be 0 for the launch probe). Usage: szf_proc_stats <pid>... */
#include <CoreGraphics/CoreGraphics.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>

static int onscreen_windows(pid_t pid) {
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    int mine = 0;
    if (!list) return -1;
    for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
        CFNumberRef ref = CFDictionaryGetValue(CFArrayGetValueAtIndex(list, i), kCGWindowOwnerPID);
        int owner = 0;
        if (ref && CFNumberGetValue(ref, kCFNumberIntType, &owner) && owner == pid) mine++;
    }
    CFRelease(list);
    return mine;
}

int main(int argc, char **argv) {
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    int status = 0;
    for (int i = 1; i < argc; i++) {
        pid_t pid = (pid_t)atoi(argv[i]);
        struct rusage_info_v4 ri;
        if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&ri) != 0) {
            printf("{\"pid\":%d,\"error\":\"gone\"}\n", pid);
            status = 1;
            continue;
        }
        double cpu_ms = (double)(ri.ri_user_time + ri.ri_system_time) * tb.numer / tb.denom / 1e6;
        printf("{\"pid\":%d,\"cpu_ms\":%.3f,\"footprint_mb\":%.2f,\"resident_mb\":%.2f,\"lifetime_max_footprint_mb\":%.2f,"
               "\"idle_wakeups\":%llu,\"interrupt_wakeups\":%llu,\"onscreen\":%d}\n",
               pid, cpu_ms, ri.ri_phys_footprint / 1048576.0, ri.ri_resident_size / 1048576.0,
               ri.ri_lifetime_max_phys_footprint / 1048576.0, ri.ri_pkg_idle_wkups, ri.ri_interrupt_wkups,
               onscreen_windows(pid));
    }
    return status;
}
