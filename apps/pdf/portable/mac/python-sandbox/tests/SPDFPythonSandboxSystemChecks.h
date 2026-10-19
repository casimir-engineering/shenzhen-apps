// Real runs through the helper against what the profile's system rules close (SPDFPythonSandboxProfile.m): other
// processes' information, file names from inode numbers, the other volumes under /System/Volumes, System V IPC that
// belongs to someone else, the I/O registry, and disk reserved beyond a file's end. Included by
// SPDFPythonSandboxTests.m after the escape checks.
#pragma once
#import "SPDFPythonSandboxEscapeChecks.h"

#include <sys/fsgetpath.h>
#include <sys/ipc.h>
#include <sys/msg.h>
#include <sys/sem.h>
#include <sys/shm.h>

// The other processes are the helper (the code's parent) and this suite: both run as the same user outside the
// sandbox, which is exactly whose arguments, environment and paths the code must not read.
static NSString* const kSandboxProcessProbe =
    @"import ctypes, multiprocessing, os, platform\n"
     "lib = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)\n"
     "def sysctl(mib):\n"
     "    size = ctypes.c_size_t(1 << 20)\n"
     "    buf = ctypes.create_string_buffer(size.value)\n"
     "    return lib.sysctl((ctypes.c_int * len(mib))(*mib), len(mib), buf, ctypes.byref(size), None, 0) == 0\n"
     "def report(name, opened):\n"
     "    print(('OPEN ' if opened else 'CLOSED ') + name)\n"
     "buf = ctypes.create_string_buffer(4096)\n"
     "report('kern.proc.all', sysctl([1, 14, 0]))\n"
     "for pid in (os.getppid(), %d):\n"
     "    report('kern.proc.pid', sysctl([1, 14, 1, pid]))\n"
     "    report('kern.procargs2', sysctl([1, 49, pid]))\n"
     "    report('proc_pidpath', lib.proc_pidpath(pid, buf, 4096) > 0)\n"
     "    for flavor in (3, 9):\n"
     "        report('proc_pidinfo', lib.proc_pidinfo(pid, flavor, ctypes.c_uint64(0), buf, 4096) > 0)\n"
     "    report('proc_name', lib.proc_name(pid, buf, 256) > 0)\n"
     "pids = (ctypes.c_int * 8192)()\n"
     "report('proc_listallpids', lib.proc_listallpids(pids, ctypes.sizeof(pids)) > 0)\n"
     "iokit = ctypes.CDLL('/System/Library/Frameworks/IOKit.framework/IOKit')\n"
     "cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')\n"
     "iokit.IOServiceMatching.restype = ctypes.c_void_p\n"
     "iokit.IOServiceGetMatchingService.argtypes = [ctypes.c_uint, ctypes.c_void_p]\n"
     "iokit.IOServiceGetMatchingService.restype = ctypes.c_uint\n"
     "iokit.IORegistryEntryCreateCFProperty.argtypes = [ctypes.c_uint, ctypes.c_void_p, ctypes.c_void_p, "
     "ctypes.c_uint]\n"
     "iokit.IORegistryEntryCreateCFProperty.restype = ctypes.c_void_p\n"
     "cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint]\n"
     "cf.CFStringCreateWithCString.restype = ctypes.c_void_p\n"
     "service = iokit.IOServiceGetMatchingService(0, iokit.IOServiceMatching(b'IOPlatformExpertDevice'))\n"
     "key = cf.CFStringCreateWithCString(None, b'IOPlatformSerialNumber', 0x08000100)\n"
     "report('serial number', bool(service and iokit.IORegistryEntryCreateCFProperty(service, key, None, 0)))\n"
     "print('SELF', sysctl([1, 14, 1, os.getpid()]), lib.proc_pidpath(os.getpid(), buf, 4096) > 0)\n"
     "print('CONTROL', os.uname().sysname, os.cpu_count() > 0, multiprocessing.cpu_count() > 0,\n"
     "      platform.platform().startswith('macOS'), os.sysconf('SC_PAGE_SIZE') > 0,\n"
     "      os.sysconf('SC_PHYS_PAGES') > 0)\n";

static void CheckProcessInformation(SandboxSuite* suite) {
    NSDictionary* result = SuiteRun(suite, [NSString stringWithFormat:kSandboxProcessProbe, getpid()], nil);
    NSString* out = result[@"stdout"] ?: @"";
    for (NSString* line in [out componentsSeparatedByString:@"\n"])
        if ([line hasPrefix:@"OPEN "]) fprintf(stderr, "  still readable inside the sandbox: %s\n", line.UTF8String);
    NSUInteger closed = [out componentsSeparatedByString:@"CLOSED "].count - 1;
    CHECK(![out containsString:@"OPEN "] && closed == 15,
          "other processes' list, arguments, environment, paths and names, and the serial number, stay closed");
    CHECK([out containsString:@"SELF True True"], "the code still reads its own process information");
    CHECK([out containsString:@"CONTROL Darwin True True True True True"],
          "uname, os.cpu_count, platform and sysconf work with only the named system values");
}

// Objects this suite owns stand in for another program's: the code must not open, read, attach or remove them.
// (deny default) already held this before the profile spelled out (deny ipc-sysv*); the check keeps it held.
static void CheckSystemV(SandboxSuite* suite) {
    key_t key = (key_t)(0x53500000 | (getpid() & 0xffff));
    int shm = shmget(key, 4096, IPC_CREAT | IPC_EXCL | 0600);
    int queue = msgget(key, IPC_CREAT | IPC_EXCL | 0600);
    int semaphores = semget(key, 1, IPC_CREAT | IPC_EXCL | 0600);
    CHECK(shm >= 0 && queue >= 0 && semaphores >= 0, "the suite creates its own System V objects");
    char* shared = shm >= 0 ? shmat(shm, NULL, 0) : (char*)-1;
    if (shared != (char*)-1) { strlcpy(shared, suite.token.UTF8String, 4096); shmdt(shared); }
    NSString* code = [NSString stringWithFormat:
        @"import ctypes\n"
         "lib = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)\n"
         "lib.shmat.restype = ctypes.c_void_p\n"
         "def report(name, value):\n"
         "    print(('OPEN ' if value not in (-1, None, 2 ** 64 - 1) else 'CLOSED ') + name)\n"
         "report('shmget', lib.shmget(%d, ctypes.c_size_t(0), 0))\n"
         "report('shmat', lib.shmat(%d, None, 0))\n"
         "report('shmctl', lib.shmctl(%d, 0, None))\n"
         "report('msgget', lib.msgget(%d, 0))\n"
         "message = ctypes.create_string_buffer(b'\\x01' + b'\\x00' * 7 + b'hi', 10)\n"
         "report('msgsnd', lib.msgsnd(%d, message, 2, 0o4000))\n"
         "report('semget', lib.semget(%d, 1, 0))\n"
         "report('semctl', lib.semctl(%d, 0, 0))\n",
        key, shm, shm, key, queue, key, semaphores];
    NSDictionary* result = SuiteRun(suite, code, nil);
    NSString* out = result[@"stdout"] ?: @"";
    CHECK(![out containsString:@"OPEN "] && [out componentsSeparatedByString:@"CLOSED "].count == 8,
          "another program's shared memory, queue and semaphores cannot be opened, attached, used or removed");
    struct shmid_ds segment;
    shared = shm >= 0 && shmctl(shm, IPC_STAT, &segment) == 0 ? shmat(shm, NULL, SHM_RDONLY) : (char*)-1;
    CHECK(shared != (char*)-1 && strcmp(shared, suite.token.UTF8String) == 0,
          "the suite's segment is still there, unchanged");
    if (shared != (char*)-1) shmdt(shared);
    if (shm >= 0) shmctl(shm, IPC_RMID, NULL);
    if (queue >= 0) msgctl(queue, IPC_RMID, NULL);
    if (semaphores >= 0) semctl(semaphores, 0, IPC_RMID);
}

// fsgetpath names a file from its volume and inode number alone. The suite's own folder beside the work directory
// stands in for the person's files: outside the sandbox the call names it, inside it must not.
static void CheckFileNames(SandboxSuite* suite) {
    struct stat info;
    stat(suite.outside.fileSystemRepresentation, &info);
    fsid_t volume = {{(int32_t)info.st_dev, 0}};
    char path[PATH_MAX] = {0};
    ssize_t named = fsgetpath(path, sizeof path, &volume, info.st_ino);
    CHECK(named > 0 && [@(path) hasSuffix:@"/outside"], "outside the sandbox fsgetpath names the folder");
    NSString* code = [NSString stringWithFormat:
        @"import ctypes, os\n"
         "lib = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)\n"
         "volume = (ctypes.c_int32 * 2)(%d, 0)\n"
         "buf = ctypes.create_string_buffer(1024)\n"
         "n = lib.fsgetpath(buf, 1024, volume, ctypes.c_uint64(%llu))\n"
         "print('NAMED' if n > 0 else 'REFUSED', buf.value.decode(errors='replace') if n > 0 else "
         "os.strerror(ctypes.get_errno()))\n",
        (int)info.st_dev, (unsigned long long)info.st_ino];
    NSDictionary* result = SuiteRun(suite, code, nil);
    CHECK([result[@"stdout"] hasPrefix:@"REFUSED Operation not permitted"] &&
          ![result[@"stdout"] containsString:@"outside"], "inside, fsgetpath cannot name a file the code cannot read");
}

// The volumes under /System/Volumes other than the system's own: the person's name and account, hardware addresses
// and the serial number. Each is checked readable outside first, so a Mac laid out differently skips rather than
// passing for the wrong reason.
static void CheckSystemVolumes(SandboxSuite* suite) {
    NSMutableArray* targets = [NSMutableArray array];
    for (NSString* name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:@"/System/Volumes/Preboot"
                                                                             error:nil]) {
        if (![[NSUUID alloc] initWithUUIDString:name]) continue;
        NSString* root = [@"/System/Volumes/Preboot" stringByAppendingPathComponent:name];
        for (NSString* file in @[ @"var/db/AllUsersInfo.plist",
                                  @"Library/Preferences/SystemConfiguration/NetworkInterfaces.plist" ]) {
            NSString* path = [root stringByAppendingPathComponent:file];
            if (access(path.fileSystemRepresentation, R_OK) == 0) [targets addObject:path];
        }
    }
    if (access("/System/Volumes/Hardware", R_OK) == 0) [targets addObject:@"/System/Volumes/Hardware"];
    if (targets.count < 3)
        printf("SPDFPythonSandboxTests: only %lu of the /System/Volumes files are readable on this Mac\n",
               (unsigned long)targets.count);
    NSMutableString* code = [NSMutableString stringWithString:
        @"import os\n"
         "def attempt(path):\n"
         "    try:\n"
         "        os.listdir(path) if os.path.basename(path) == 'Hardware' else open(path, 'rb').read(1)\n"
         "        print('READ', path)\n"
         "    except Exception as error:\n"
         "        print('BLOCKED', type(error).__name__)\n"];
    for (NSString* path in targets) [code appendFormat:@"attempt(%@)\n", SPDFPythonSandboxQuote(path)];
    [code appendString:@"print('CRYPTEXES', len(os.listdir('/System/Volumes/Preboot/Cryptexes')) > 0)\n"];
    NSDictionary* result = SuiteRun(suite, code, nil);
    NSString* out = result[@"stdout"] ?: @"";
    CHECK(![out containsString:@"READ "] &&
          [out componentsSeparatedByString:@"BLOCKED PermissionError"].count == targets.count + 1,
          "the person's account details, hardware addresses and the serial number under /System/Volumes stay closed");
    CHECK([out containsString:@"CRYPTEXES True"], "the parts of macOS kept in its cryptexes stay readable");
}

// A segment the sandboxed code creates with IPC_CREAT cannot be removed by the code itself (its own shmctl is
// refused), so the helper removes it after the run by creator pid. None with the child's pid may remain.
static void CheckSharedMemoryCleanup(SandboxSuite* suite) {
    NSDictionary* result = SuiteRun(suite,
        @"import ctypes, os\n"
         "lib = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)\n"
         "key = 0x53530000 | (os.getpid() & 0xffff)\n"
         "shm = lib.shmget(key, ctypes.c_size_t(4096), 0o1000 | 0o600)\n"  // IPC_CREAT
         "print('SHMGET', shm, 'PID', os.getpid())\n", nil);
    NSString* out = result[@"stdout"] ?: @"";
    NSArray* words = [out componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSUInteger shmgetAt = [words indexOfObject:@"SHMGET"], pidAt = [words indexOfObject:@"PID"];
    CHECK(shmgetAt != NSNotFound && pidAt != NSNotFound && [words[shmgetAt + 1] integerValue] >= 0,
          "the sandboxed code can still create a shared-memory segment on this macOS");
    if (pidAt == NSNotFound) return;
    pid_t child = (pid_t)[words[pidAt + 1] intValue];
    // The helper ran its cleanup before answering, so nothing of the child's is left for the suite to find.
    CHECK(SPDFPythonSandboxRemoveSharedMemory(child, [NSSet set]) == 0,
          "the helper removed the segment the child created; none with its pid remains");
}

// The ways disk hides from the work-directory walk: a file unlinked while open, one unlinked while mapped after its
// descriptor is closed, and a directory the code locks after filling it. Each must end the run as a 'files' breach,
// like plain preallocation.
static void CheckHiddenDisk(SandboxSuite* suite) {
    NSDictionary* unlinked = SuiteRun(suite,
        @"import fcntl, os, struct, time\n"
         "fd = os.open('hidden.bin', os.O_RDWR | os.O_CREAT, 0o600)\n"
         "os.unlink('hidden.bin')\n"  // gone from the tree, still open
         "fcntl.fcntl(fd, 42, struct.pack('IiqqQ', 4, 3, 0, 32 << 20, 0))\n"
         "print('reserved', flush=True)\n"
         "time.sleep(5)\nprint('survived')\n", nil);
    CHECK([unlinked[@"stdout"] containsString:@"reserved"] && ![unlinked[@"stdout"] containsString:@"survived"] &&
          [unlinked[@"limit"] isEqual:@"files"] && [unlinked[@"seconds"] doubleValue] < 3,
          "disk reserved on a file the code unlinked while open still ends the run");
    // libc's mmap through ctypes: Python's mmap module keeps a duplicate descriptor, which the watchdog already counts.
    NSDictionary* mapped = SuiteRun(suite,
        @"import ctypes, fcntl, os, struct, time\n"
         "lib = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)\n"
         "lib.mmap.restype = ctypes.c_void_p\n"
         "lib.mmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int, ctypes.c_int, ctypes.c_int, "
         "ctypes.c_int64]\n"
         "fd = os.open('mapped.bin', os.O_RDWR | os.O_CREAT, 0o600)\n"
         "fcntl.fcntl(fd, 42, struct.pack('IiqqQ', 4, 3, 0, 32 << 20, 0))\n"
         "os.write(fd, b'x' * 4096)\n"
         "kept = lib.mmap(None, 4096, 1, 1, fd, 0)\n"  // PROT_READ, MAP_SHARED
         "os.close(fd)\n"  // no descriptor left: only the mapping holds the file
         "os.unlink('mapped.bin')\n"
         "print('mapped', flush=True)\n"
         "time.sleep(5)\nprint('survived')\n", nil);
    CHECK([mapped[@"stdout"] containsString:@"mapped"] && ![mapped[@"stdout"] containsString:@"survived"] &&
          [mapped[@"limit"] isEqual:@"files"] && [mapped[@"seconds"] doubleValue] < 3,
          "disk reserved on a file the code unlinked while it stays mapped, its descriptor closed, still ends the run");
    NSDictionary* locked = SuiteRun(suite,
        @"import fcntl, os, struct, time\n"
         "os.mkdir('vault')\n"
         "fd = os.open('vault/big.bin', os.O_RDWR | os.O_CREAT, 0o600)\n"
         "fcntl.fcntl(fd, 42, struct.pack('IiqqQ', 4, 3, 0, 32 << 20, 0))\n"
         "os.chmod('vault', 0)\n"  // the walk now sees only an unreadable directory
         "print('locked', flush=True)\n"
         "time.sleep(5)\nprint('survived')\n", nil);
    CHECK([locked[@"stdout"] containsString:@"locked"] && ![locked[@"stdout"] containsString:@"survived"] &&
          [locked[@"limit"] isEqual:@"files"] && [locked[@"seconds"] doubleValue] < 3,
          "a directory the code locks after filling it ends the run rather than hiding its disk");
}

// F_PREALLOCATE reserves disk without growing the file, and RLIMIT_FSIZE does not stop it: the watchdog has to see it.
static void CheckPreallocation(SandboxSuite* suite) {
    NSDictionary* result = SuiteRun(suite,
        @"import fcntl, os, struct, time\n"
         "fd = os.open('reserved.bin', os.O_RDWR | os.O_CREAT, 0o600)\n"
         "fcntl.fcntl(fd, 42, struct.pack('IiqqQ', 4, 3, 0, 32 << 20, 0))\n"
         "print('reserved at size', os.fstat(fd).st_size, flush=True)\n"
         "time.sleep(5)\n"
         "print('survived')\n", nil);
    CHECK([result[@"stdout"] containsString:@"reserved at size 0"] && ![result[@"stdout"] containsString:@"survived"]
          && [result[@"limit"] isEqual:@"files"] && [result[@"seconds"] doubleValue] < 3,
          "32 MB reserved beyond the end of a file counts against the 10 MB output limit");
}
