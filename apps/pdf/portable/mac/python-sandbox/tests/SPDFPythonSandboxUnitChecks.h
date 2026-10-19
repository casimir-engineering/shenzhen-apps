// The sandbox's pure parts: the paths an interpreter may use, the profile text, input names, and the work directory's
// hostile-file handling. Included by SPDFPythonSandboxTests.m.
#pragma once
#import "SPDFPythonSandboxInternal.h"

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/shm.h>
#include <sys/stat.h>
#include <sys/time.h>

static void CheckProfile(NSString* python) {
    NSString* reason = nil;
    NSDictionary* paths = SPDFPythonSandboxPathsForInterpreter(python, &reason);
    CHECK(paths != nil, "a real Python's bin/ interpreter is accepted");
    NSString* work = @"/private/var/folders/xx/T/szpy-ABC \"quoted\"";
    NSString* profile = SPDFPythonSandboxProfile(paths ?: @{}, work);
    CHECK([profile hasPrefix:@"(version 1)\n(deny default)\n"], "everything not allowed is denied");
    for (NSString* rule in @[ @"(deny network* system-socket)", @"(deny appleevent-send)", @"(deny mach-lookup)",
                              @"(deny process-fork)" ])
        CHECK([profile containsString:rule], "the promises are spelled out: no network, Apple events, services, fork");
    CHECK([profile containsString:@"(allow file-read* file-write*\n    (subpath \"/private/var/folders/xx/T/szpy-ABC "
                                   @"\\\"quoted\\\"\"))"], "only the work directory is writable, and paths are quoted");
    NSString* home = NSHomeDirectory();
    CHECK(![profile containsString:[NSString stringWithFormat:@"(subpath \"%@\")", home]] &&
          ![profile containsString:@"(subpath \"/Users\")"], "the home folder is never readable as a whole");
    CHECK([profile rangeOfString:@"file-write"].location > [profile rangeOfString:@"process-fork"].location,
          "the denials come first, so nothing below can be mistaken for them");
    NSArray* writes = [[profile componentsSeparatedByString:@"\n"] filteredArrayUsingPredicate:
        [NSPredicate predicateWithFormat:@"SELF CONTAINS 'file-write' AND NOT SELF BEGINSWITH '(deny'"]];
    CHECK(writes.count == 2, "write access is given twice only: the work directory and /dev/null");
    for (NSString* root in paths[@"read_subpaths"])
        CHECK(![home hasPrefix:root] && ![root isEqual:@"/"] && ![root isEqual:@"/usr"],
              "no readable root contains the home folder");
    // System values by name only, and the families (deny default) does not cover denied outright.
    CHECK(![profile containsString:@"(allow sysctl-read)"] &&
          [profile containsString:@"(allow sysctl-read\n    (sysctl-name \"kern.ostype\""] &&
          ![profile containsString:@"kern.proc"] && ![profile containsString:@"sysctl-name-prefix \"kern."],
          "sysctl values are named, and nothing that lists processes or reads their arguments is among them");
    NSRange denyInfo = [profile rangeOfString:@"(deny process-info*)\n"];
    NSRange allowSelf = [profile rangeOfString:@"(allow process-info* (target self))\n"];
    CHECK(denyInfo.location != NSNotFound && allowSelf.location > denyInfo.location,
          "other processes' information is denied, and the later rule gives back only the code's own");
    CHECK([profile containsString:@"(deny ipc-sysv*)\n"] && [profile containsString:@"(deny iokit-get-properties)\n"],
          "System V IPC and the I/O registry are denied");
    CHECK([profile containsString:@"(deny syscall-unix (syscall-number 427 217))\n"],
          "fsgetpath and fsgetpath_ext, which name files from inode numbers, are denied");
    NSUInteger system = [profile rangeOfString:@"(subpath \"/System\")"].location;
    NSUInteger volumes = [profile rangeOfString:@"(deny file-read*\n    (subpath \"/System/Volumes\"))\n"].location;
    NSString* cryptexRule = @"(allow file-read*\n    (subpath \"/System/Volumes/Preboot/Cryptexes\"))";
    NSUInteger cryptexes = [profile rangeOfString:cryptexRule].location;
    NSUInteger data = [profile rangeOfString:@"(deny file-read*\n    (subpath \"/System/Volumes/Data\"))"].location;
    CHECK(system != NSNotFound && volumes > system && cryptexes > volumes && data != NSNotFound && data > cryptexes,
          "after /System: its other volumes are denied, the cryptexes given back, and the Data volume stays denied");
    CHECK([SPDFPythonSandboxAncestors(@"/a/b/c") isEqual:(@[ @"/", @"/a", @"/a/b" ])],
          "ancestors run from / down to the parent");
    char real[1024];
    NSString* temporary = @(realpath(NSTemporaryDirectory().fileSystemRepresentation, real));
    NSArray* above = SPDFPythonSandboxAncestors([temporary stringByAppendingPathComponent:@"szpy-x"]);
    CHECK([above containsObject:@"/private/var/folders"] && ![above containsObject:@"/var/folders"],
          "ancestors keep the real /private/var paths the kernel reports, even for paths that exist");
    CHECK([SPDFPythonSandboxQuote(@"a\\b\"c") isEqual:@"\"a\\\\b\\\"c\""], "SBPL quoting escapes \\ and \"");

    CHECK(!SPDFPythonSandboxPathsForInterpreter(@"/usr/bin/python3", &reason) && reason.length,
          "the /usr/bin/python3 stub is refused: its prefix would be all of /usr");
    CHECK(!SPDFPythonSandboxPathsForInterpreter(@"python3", &reason), "a relative interpreter is refused");
    CHECK(!SPDFPythonSandboxPathsForInterpreter(@"/nonexistent/bin/python3", &reason), "a missing one is refused");
    NSDictionary* env = SPDFPythonSandboxEnvironment(work);
    CHECK([env[@"HOME"] isEqual:work] && [env[@"MPLBACKEND"] isEqual:@"Agg"] && !env[@"PYTHONPATH"] &&
          !env[@"DYLD_LIBRARY_PATH"] && env.count == 12, "the interpreter's environment is built, not inherited");
}

static void CheckInputNames(void) {
    for (NSString* name in @[ @"data.csv", @"Q3 sales.tsv", @"a-b_c.json", @"x" ])
        CHECK(SPDFPythonSandboxValidInputName(name), "plain file names are accepted");
    for (id name in @[ @"main.py", @".hidden", @"../x", @"a/b", @"", @"x ", @"a\nb", @"é.txt", @3,
                       [@"" stringByPaddingToLength:101 withString:@"a" startingAtIndex:0] ])
        CHECK(!SPDFPythonSandboxValidInputName(name), "paths, hidden names, main.py and odd names are refused");
}

static void CheckHostileFiles(NSString* scratch) {
    NSString* work = SPDFPythonSandboxMakeWorkDirectory(scratch, nil);
    NSString* outside = [scratch stringByAppendingPathComponent:@"outside.txt"];
    [@"outside secret" writeToFile:outside atomically:NO encoding:NSUTF8StringEncoding error:nil];
    CHECK([work hasPrefix:scratch] && [work.lastPathComponent hasPrefix:@"szpy-"], "work directories are fresh");
    CHECK(SPDFPythonSandboxWriteFile(work, @"result.txt", [@"42" dataUsingEncoding:NSUTF8StringEncoding]),
          "inputs are written");
    CHECK(!SPDFPythonSandboxWriteFile(work, @"result.txt", [NSData data]), "never over an existing file");
    NSString* linkPath = [work stringByAppendingPathComponent:@"link.txt"];
    symlink(outside.fileSystemRepresentation, linkPath.fileSystemRepresentation);
    CHECK(!SPDFPythonSandboxWriteFile(work, @"link.txt", [NSData data]), "never through a link");
    link(outside.fileSystemRepresentation, [work stringByAppendingPathComponent:@"hard.txt"].fileSystemRepresentation);
    mkfifo([work stringByAppendingPathComponent:@"pipe.png"].fileSystemRepresentation, 0600);
    NSString* locked = [work stringByAppendingPathComponent:@"locked"];
    mkdir(locked.fileSystemRepresentation, 0700);
    SPDFPythonSandboxWriteFile(locked, @"inner.txt", [@"x" dataUsingEncoding:NSUTF8StringEncoding]);
    chmod(locked.fileSystemRepresentation, 0);
    NSString* immutable = [work stringByAppendingPathComponent:@"immutable.txt"];
    SPDFPythonSandboxWriteFile(work, @"immutable.txt", [@"y" dataUsingEncoding:NSUTF8StringEncoding]);
    chflags(immutable.fileSystemRepresentation, UF_IMMUTABLE);
    mkdir([work stringByAppendingPathComponent:@".matplotlib"].fileSystemRepresentation, 0700);
    SPDFPythonSandboxWriteFile([work stringByAppendingPathComponent:@".matplotlib"], @"fontlist-v390.json",
                               [@"{}" dataUsingEncoding:NSUTF8StringEncoding]);

    NSUInteger omitted = 0;
    NSArray* files = SPDFPythonSandboxCollect(work, [NSSet set], 1 << 20, &omitted);
    NSMutableDictionary* byName = [NSMutableDictionary dictionary];
    for (NSDictionary* file in files) byName[file[@"name"]] = file;
    CHECK([byName[@"result.txt"][@"data"] isEqual:@"NDI="], "a regular file comes back");
    CHECK([byName[@"link.txt"][@"omitted"] isEqual:@"link"] && !byName[@"link.txt"][@"data"], "links are not followed");
    CHECK([byName[@"hard.txt"][@"omitted"] isEqual:@"linked"], "a hard link to a file elsewhere is not read");
    CHECK([byName[@"pipe.png"][@"omitted"] isEqual:@"not_a_file"], "a FIFO is never opened, so it cannot block");
    CHECK(!byName[@".matplotlib/fontlist-v390.json"] && !byName[@"locked"], "hidden and locked folders are skipped");
    NSData* everything = [NSJSONSerialization dataWithJSONObject:files options:0 error:nil];
    CHECK(![[[NSString alloc] initWithData:everything encoding:NSUTF8StringEncoding] containsString:@"b3V0c2lkZ"],
          "nothing from outside the work directory is in the results");
    NSArray* capped = SPDFPythonSandboxCollect(work, [NSSet setWithObject:@"result.txt"], 0, &omitted);
    CHECK([[capped valueForKey:@"name"] indexOfObject:@"result.txt"] == NSNotFound &&
          [[capped filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"data != nil"]] count] == 0,
          "inputs are skipped and nothing beyond the cap is read");
    unsigned long long bytes = 0;
    NSUInteger entries = 0;
    BOOL unreadable = NO;
    SPDFPythonSandboxMeasure(work, &bytes, &entries, 100, &unreadable);
    CHECK(entries >= 7 && bytes >= 4, "the watchdog's measure counts entries and bytes");
    CHECK(unreadable, "a directory the code locked (the planted 'locked') is seen as unreadable");
    // Disk reserved beyond the end of a file leaves its size at 0; the measure must still see it.
    NSString* reserved = [work stringByAppendingPathComponent:@"reserved.bin"];
    int fd = open(reserved.fileSystemRepresentation, O_RDWR | O_CREAT | O_EXCL, 0600);
    fstore_t store = {F_ALLOCATEALL, F_PEOFPOSMODE, 0, 2 << 20, 0};
    BOOL preallocated = fd >= 0 && fcntl(fd, F_PREALLOCATE, &store) == 0;
    struct stat info;
    CHECK(preallocated && fstat(fd, &info) == 0 && info.st_size == 0, "F_PREALLOCATE reserves 2 MB at size 0");
    unsigned long long before = bytes;
    SPDFPythonSandboxMeasure(work, &bytes, &entries, 100, NULL);
    CHECK(bytes >= before + (2 << 20), "the measure counts blocks reserved beyond a file's size");
    // The same 2 MB reserved on a file that is then unlinked while open is gone from the walk; proc_pidinfo on this
    // process still finds it, as the watchdog does for the sandboxed child. Descriptors are read on every call, even
    // one that walks no memory regions.
    chmod([work stringByAppendingPathComponent:@"locked"].fileSystemRepresentation, 0700); // so the next walk is clean
    unlink(reserved.fileSystemRepresentation);
    SPDFPythonSandboxMeasure(work, &bytes, &entries, 100, &unreadable);
    SPDFPythonSandboxHiddenDisk* hidden = [[SPDFPythonSandboxHiddenDisk alloc] initWithPid:getpid()];
    CHECK(!unreadable && [hidden bytesScanningRegions:0] >= (2 << 20),
          "disk held by an unlinked open file is counted where the walk cannot reach it");
    if (fd >= 0) close(fd);
    CHECK([hidden bytesScanningRegions:0] < (2 << 20), "once the descriptor is closed, that disk is gone");

    CHECK(SPDFPythonSandboxRemoveTree(work), "a booby-trapped work directory is still deleted");
    NSString* kept = [NSString stringWithContentsOfFile:outside encoding:NSUTF8StringEncoding error:nil];
    CHECK([kept isEqual:@"outside secret"], "deleting links and hard links leaves the files they point at");

    NSString* stale = [scratch stringByAppendingPathComponent:@"szpy-stale"];
    NSString* fresh = [scratch stringByAppendingPathComponent:@"szpy-fresh"];
    mkdir(stale.fileSystemRepresentation, 0700);
    mkdir(fresh.fileSystemRepresentation, 0700);
    struct timeval old[2] = {{time(NULL) - 7200, 0}, {time(NULL) - 7200, 0}};
    utimes(stale.fileSystemRepresentation, old);
    SPDFPythonSandboxSweepStale(scratch);
    CHECK(access(stale.fileSystemRepresentation, F_OK) != 0 && access(fresh.fileSystemRepresentation, F_OK) == 0,
          "work directories a killed helper left are swept after an hour, live ones are not");
    rmdir(fresh.fileSystemRepresentation);
    unlink(outside.fileSystemRepresentation);
    CHECK([SPDFPythonSandboxText([NSData dataWithBytes:"ok \xe2\x82" length:5]) hasPrefix:@"ok "],
          "output cut mid-character still decodes");
}

// Walks this process's memory regions with `hidden` until `done` holds, within 20,000 slices.
static BOOL SandboxScanUntil(SPDFPythonSandboxHiddenDisk* hidden, NSUInteger slice, BOOL (^done)(unsigned long long)) {
    for (int i = 0; i < 20000; i++)
        if (done([hidden bytesScanningRegions:slice])) return YES;
    return NO;
}

// A file mapped, then closed and unlinked, holds its disk through the mapping alone: no descriptor lists it and no
// directory holds it. The watchdog's region walk must still count it, a slice at a time.
static void CheckMappedDisk(NSString* scratch) {
    NSString* path = [scratch stringByAppendingPathComponent:@"mapped.bin"];
    int fd = open(path.fileSystemRepresentation, O_RDWR | O_CREAT | O_EXCL, 0600);
    fstore_t store = {F_ALLOCATEALL, F_PEOFPOSMODE, 0, 4 << 20, 0};
    char page[4096] = {1};
    BOOL ready = fd >= 0 && fcntl(fd, F_PREALLOCATE, &store) == 0 && write(fd, page, sizeof page) == sizeof page;
    void* mapping = ready ? mmap(NULL, sizeof page, PROT_READ, MAP_SHARED, fd, 0) : MAP_FAILED;
    if (fd >= 0) close(fd);
    unlink(path.fileSystemRepresentation);
    CHECK(mapping != MAP_FAILED, "a preallocated file is mapped, then closed and unlinked");
    SPDFPythonSandboxHiddenDisk* hidden = [[SPDFPythonSandboxHiddenDisk alloc] initWithPid:getpid()];
    CHECK([hidden bytesScanningRegions:1] < (4 << 20),
          "one region per call starts at the bottom of memory, far below the mapping: the walk goes in slices");
    CHECK(SandboxScanUntil(hidden, 1, ^BOOL(unsigned long long bytes) { return bytes >= (4 << 20); }),
          "later slices reach the mapping, and the 4 MB it holds are counted");
    if (mapping != MAP_FAILED) munmap(mapping, sizeof page);
    CHECK(SandboxScanUntil(hidden, 64, ^BOOL(unsigned long long bytes) { return bytes < (4 << 20); }),
          "once unmapped, the next complete walk no longer counts it");
}

// pids are reused: a segment that predates the run belongs to someone else even when it records the child's pid. This
// process stands in for the child, with one segment from before the run and one made during it.
static void CheckSharedMemoryOwnership(void) {
    int before = shmget(IPC_PRIVATE, 4096, IPC_CREAT | 0600);
    NSSet<NSNumber*>* existing = SPDFPythonSandboxSharedMemoryIdentifiers();
    int during = shmget(IPC_PRIVATE, 4096, IPC_CREAT | 0600);
    CHECK(before >= 0 && during >= 0 && [existing containsObject:@(before)] && ![existing containsObject:@(during)],
          "the identifiers taken before the run list the older segment and not the newer one");
    NSUInteger removed = SPDFPythonSandboxRemoveSharedMemory(getpid(), existing);
    struct shmid_ds info;
    CHECK(removed == 1 && shmctl(before, IPC_STAT, &info) == 0 && shmctl(during, IPC_STAT, &info) != 0,
          "only the segment made during the run is removed, although both record the same creator pid");
    if (before >= 0) shmctl(before, IPC_RMID, NULL);
    if (during >= 0) shmctl(during, IPC_RMID, NULL);
}
