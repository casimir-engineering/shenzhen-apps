// The work directory: creating it, writing inputs, measuring it while code runs, reading results back and deleting
// it. Everything the code could have planted is handled: links (never followed), hard links (never read), FIFOs
// (never opened blocking), and the flags and modes that would make deletion fail.
#import "SPDFPythonSandboxInternal.h"

#include <errno.h>
#include <fcntl.h>
#include <fts.h>
#include <libproc.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ipc.h>
#include <sys/proc_info.h>
#include <sys/shm.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>

static const NSUInteger kSPDFMaxCollected = 32;
static const int kSPDFMaxDepth = 4;

NSString* SPDFPythonSandboxMakeWorkDirectory(NSString* parent, NSString** reason) {
    char resolved[PATH_MAX];
    struct stat info;
    if (lstat(parent.fileSystemRepresentation, &info) != 0 || !S_ISDIR(info.st_mode) ||
        !realpath(parent.fileSystemRepresentation, resolved)) {
        if (reason) *reason = @"The folder for work directories is missing.";
        return nil;
    }
    NSString* template = [@(resolved) stringByAppendingPathComponent:@"szpy-XXXXXXXX"];
    char buffer[PATH_MAX];
    strlcpy(buffer, template.fileSystemRepresentation, sizeof buffer);
    if (!mkdtemp(buffer) || !realpath(buffer, resolved)) {
        if (reason) *reason = [NSString stringWithFormat:@"Could not create a work directory: %s.", strerror(errno)];
        return nil;
    }
    return @(resolved);
}

BOOL SPDFPythonSandboxWriteFile(NSString* directory, NSString* name, NSData* data) {
    NSString* path = [directory stringByAppendingPathComponent:name];
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return NO;
    const uint8_t* bytes = data.bytes;
    size_t left = data.length;
    while (left) {
        ssize_t written = write(fd, bytes, left);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) { close(fd); return NO; }
        bytes += written;
        left -= (size_t)written;
    }
    return close(fd) == 0;
}

static int SPDFCompareNames(const FTSENT** a, const FTSENT** b) { return strcmp((*a)->fts_name, (*b)->fts_name); }

void SPDFPythonSandboxMeasure(NSString* directory, unsigned long long* bytes, NSUInteger* entries,
                              NSUInteger maxEntries, BOOL* unreadable) {
    *bytes = 0;
    *entries = 0;
    if (unreadable) *unreadable = NO;
    char* roots[] = {(char*)directory.fileSystemRepresentation, NULL};
    FTS* walk = fts_open(roots, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, NULL);
    if (!walk) return;
    for (FTSENT* entry = fts_read(walk); entry; entry = fts_read(walk)) {
        if (entry->fts_info == FTS_DP || entry->fts_level == 0) continue;
        // A directory the code made unreadable (FTS_DNR) or an entry that cannot be stat'd hides whatever disk is
        // behind it from this walk: the code never needs that under its own work directory, so it ends the run.
        if (entry->fts_info == FTS_DNR || entry->fts_info == FTS_NS || entry->fts_info == FTS_ERR) {
            if (unreadable) *unreadable = YES;
            continue;
        }
        if (++*entries > maxEntries) break;
        // The larger of the size and the disk blocks: fcntl F_PREALLOCATE reserves blocks beyond the end of a file
        // without growing its size (RLIMIT_FSIZE does not stop it), so the size alone would miss that disk use.
        if (entry->fts_info == FTS_F && entry->fts_statp)
            *bytes += MAX((unsigned long long)entry->fts_statp->st_size,
                          (unsigned long long)entry->fts_statp->st_blocks * 512);
    }
    fts_close(walk);
}

// A regular file with no remaining link: anything still linked is in the tree and already counted, and a read-only
// system library the interpreter holds costs the person's writable budget nothing. Keyed by volume and inode, so a
// file both open and mapped, or mapped twice, counts once.
static void SPDFNoteHidden(const struct vinfo_stat* stat, NSMutableDictionary<NSString*, NSNumber*>* files) {
    if ((stat->vst_mode & S_IFMT) != S_IFREG || stat->vst_nlink != 0) return;
    unsigned long long bytes = MAX((unsigned long long)stat->vst_size, (unsigned long long)stat->vst_blocks * 512);
    files[[NSString stringWithFormat:@"%u:%llu", stat->vst_dev, stat->vst_ino]] = @(bytes);
}

static void SPDFNoteOpenFiles(pid_t pid, NSMutableDictionary<NSString*, NSNumber*>* files) {
    int size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (size <= 0) return;
    // One extra slot in case the child opened more between the sizing call and this one.
    struct proc_fdinfo* list = calloc((size_t)size / PROC_PIDLISTFD_SIZE + 1, PROC_PIDLISTFD_SIZE);
    if (!list) return;
    int filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, list, size + (int)PROC_PIDLISTFD_SIZE);
    for (int i = 0; filled > 0 && i < filled / (int)PROC_PIDLISTFD_SIZE; i++) {
        if (list[i].proc_fdtype != PROX_FDTYPE_VNODE) continue;
        struct vnode_fdinfowithpath info;
        if (proc_pidfdinfo(pid, list[i].proc_fd, PROC_PIDFDVNODEPATHINFO, &info, sizeof info) != sizeof info) continue;
        SPDFNoteHidden(&info.pvip.vip_vi.vi_stat, files);
    }
    free(list);
}

@implementation SPDFPythonSandboxHiddenDisk {
    pid_t _pid;
    uint64_t _cursor;                                  // where the next slice of the region walk starts
    NSMutableDictionary<NSString*, NSNumber*>* _pass;  // mapped files seen by the walk under way
    NSDictionary<NSString*, NSNumber*>* _complete;     // and by the last complete walk
}

- (instancetype)initWithPid:(pid_t)pid {
    if (!(self = [super init])) return nil;
    _pid = pid;
    _pass = [NSMutableDictionary dictionary];
    _complete = @{};
    return self;
}

- (unsigned long long)bytesScanningRegions:(NSUInteger)maxRegions {
    @autoreleasepool { // called every 25 ms for up to 30 s, outside any run loop that would drain it
        return [self scanRegions:maxRegions];
    }
}

- (unsigned long long)scanRegions:(NSUInteger)maxRegions {
    for (NSUInteger i = 0; i < maxRegions; i++) {
        struct proc_regionwithpathinfo info;
        // The region at or after the cursor; none (past the last one, or the child is gone) ends this walk.
        BOOL found = proc_pidinfo(_pid, PROC_PIDREGIONPATHINFO, _cursor, &info, sizeof info) == sizeof info;
        uint64_t next = found ? info.prp_prinfo.pri_address + info.prp_prinfo.pri_size : 0;
        if (found) SPDFNoteHidden(&info.prp_vip.vip_vi.vi_stat, _pass);
        if (!found || next <= _cursor) {
            _complete = [_pass copy];
            [_pass removeAllObjects];
            _cursor = 0;
            break;
        }
        _cursor = next;
    }
    NSMutableDictionary<NSString*, NSNumber*>* files = [_complete mutableCopy];
    // A file the walk under way has already seen counts at once, before its walk completes.
    for (NSString* key in _pass)
        if ([_pass[key] unsignedLongLongValue] > [files[key] unsignedLongLongValue]) files[key] = _pass[key];
    SPDFNoteOpenFiles(_pid, files);
    unsigned long long bytes = 0;
    for (NSNumber* size in files.allValues) bytes += size.unsignedLongLongValue;
    return bytes;
}

@end

// The bytes of one result file, or nil when it is not exactly the regular, singly linked file lstat saw: the open
// does not follow links or wait on a FIFO, and fstat must agree with the walk.
static NSData* SPDFReadResult(const char* path, const struct stat* seen) {
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return nil;
    struct stat info;
    NSMutableData* data = nil;
    if (fstat(fd, &info) == 0 && S_ISREG(info.st_mode) && info.st_nlink == 1 && info.st_ino == seen->st_ino &&
        info.st_dev == seen->st_dev && info.st_size == seen->st_size) {
        data = [NSMutableData dataWithLength:(NSUInteger)info.st_size];
        size_t got = 0;
        while (got < data.length) {
            ssize_t n = read(fd, (uint8_t*)data.mutableBytes + got, data.length - got);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) { data = nil; break; }
            got += (size_t)n;
        }
    }
    close(fd);
    return data;
}

NSArray<NSDictionary*>* SPDFPythonSandboxCollect(NSString* directory, NSSet<NSString*>* skip, unsigned long long cap,
                                                NSUInteger* omitted) {
    NSMutableArray* files = [NSMutableArray array];
    *omitted = 0;
    unsigned long long kept = 0;
    char* roots[] = {(char*)directory.fileSystemRepresentation, NULL};
    FTS* walk = fts_open(roots, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, SPDFCompareNames);
    if (!walk) return files;
    NSUInteger prefix = strlen(roots[0]) + 1;
    for (FTSENT* entry = fts_read(walk); entry; entry = fts_read(walk)) {
        if (entry->fts_level == 0 || entry->fts_info == FTS_DP) continue;
        BOOL hidden = entry->fts_name[0] == '.';
        if (entry->fts_info == FTS_D) {
            if (hidden || entry->fts_level >= kSPDFMaxDepth) fts_set(walk, entry, FTS_SKIP);
            continue;
        }
        if (entry->fts_info == FTS_DNR || entry->fts_info == FTS_DC) continue; // a directory the code locked or looped
        NSString* name = @(entry->fts_path + prefix);
        if (hidden || !name || (entry->fts_level == 1 && [skip containsObject:name])) continue;
        if (files.count >= kSPDFMaxCollected) { ++*omitted; continue; }
        const struct stat* info = entry->fts_statp;
        NSMutableDictionary* file = [@{@"name" : name, @"size" : @(info ? info->st_size : 0)} mutableCopy];
        if (entry->fts_info == FTS_SL || entry->fts_info == FTS_SLNONE) {
            file[@"omitted"] = @"link";
        } else if (entry->fts_info != FTS_F || !info) {
            file[@"omitted"] = @"not_a_file";
        } else if (info->st_nlink != 1) {
            file[@"omitted"] = @"linked";
        } else if (kept + (unsigned long long)info->st_size > cap) {
            file[@"omitted"] = @"too_large";
        } else {
            NSData* data = SPDFReadResult(entry->fts_accpath, info);
            if (data) {
                kept += data.length;
                file[@"data"] = [data base64EncodedStringWithOptions:0];
            } else {
                file[@"omitted"] = @"unreadable";
            }
        }
        [files addObject:file];
    }
    fts_close(walk);
    return files;
}

// One pass. fts changes directory as it descends (no FTS_NOCHDIR), so a tree deeper than PATH_MAX is still reached;
// at each directory's preorder visit the flags and mode are fixed before fts reads it.
static void SPDFRemovePass(const char* root) {
    char* roots[] = {(char*)root, NULL};
    FTS* walk = fts_open(roots, FTS_PHYSICAL | FTS_XDEV, NULL);
    if (!walk) return;
    for (FTSENT* entry = fts_read(walk); entry; entry = fts_read(walk)) {
        const char* path = entry->fts_accpath;
        switch (entry->fts_info) {
        case FTS_D:
            lchflags(path, 0);
            chmod(path, 0700);
            break;
        case FTS_DP:
        case FTS_DNR:
            rmdir(path);
            break;
        case FTS_DC:
        case FTS_ERR:
        case FTS_NS:
            break;
        default:
            if (entry->fts_statp && entry->fts_statp->st_flags) lchflags(path, 0);
            unlink(path);
            break;
        }
    }
    fts_close(walk);
}

BOOL SPDFPythonSandboxRemoveTree(NSString* path) {
    const char* root = path.fileSystemRepresentation;
    struct stat info;
    for (int pass = 0; pass < 3; pass++) {
        if (lstat(root, &info) != 0) return errno == ENOENT;
        if (!S_ISDIR(info.st_mode)) {
            lchflags(root, 0);
            unlink(root);
            continue;
        }
        // A directory the code made unreadable is reported as FTS_DNR without its contents; fixing its mode in this
        // pass lets the next one read and empty it.
        lchflags(root, 0);
        chmod(root, 0700);
        SPDFRemovePass(root);
    }
    return lstat(root, &info) != 0 && errno == ENOENT;
}

// The kern.sysv.ipcs.shm sysctl, as the `ipcs` command reads it: a cursor over the segment table, one struct per
// slot, the shmid rebuilt from the cursor and the slot's sequence number. Reconstructed here because no SDK header
// declares it.
#define SPDF_IPCS_MAGIC 1
#define SPDF_IPCS_SHM_ITER 2
typedef struct {
    int magic, op, cursor, dataLength;
    void* data;
} SPDFIPCSCommand;

// Visits every segment in the table: its identifier, rebuilt from the cursor and the slot's sequence number, and its
// description.
static void SPDFEachSegment(void (^visit)(int identifier, const struct shmid_ds* segment)) {
    long slots = 0;
    size_t size = sizeof slots;
    // kern.sysv.shmmni is a long; a wild value would make the loop run away, so bound it before trusting it.
    if (sysctlbyname("kern.sysv.shmmni", &slots, &size, NULL, 0) != 0 || slots <= 0 || slots > (1 << 20)) return;
    for (long cursor = 0; cursor < slots; cursor++) {
        struct shmid_ds segment;
        SPDFIPCSCommand command = {SPDF_IPCS_MAGIC, SPDF_IPCS_SHM_ITER, (int)cursor, sizeof segment, &segment};
        size_t length = sizeof command;
        // An unused slot answers ENOENT; keep scanning, because a used slot can sit past an empty one.
        if (sysctlbyname("kern.sysv.ipcs.shm", &command, &length, &command, length) != 0) continue;
        visit((segment.shm_perm._seq << 16) | (int)(cursor & 0xffff), &segment);
    }
}

NSSet<NSNumber*>* SPDFPythonSandboxSharedMemoryIdentifiers(void) {
    NSMutableSet* identifiers = [NSMutableSet set];
    SPDFEachSegment(^(int identifier, const struct shmid_ds* segment) {
        (void)segment;
        [identifiers addObject:@(identifier)];
    });
    return identifiers;
}

NSUInteger SPDFPythonSandboxRemoveSharedMemory(pid_t creator, NSSet<NSNumber*>* existing) {
    __block NSUInteger removed = 0;
    SPDFEachSegment(^(int identifier, const struct shmid_ds* segment) {
        // A segment that was there before the run belongs to someone else, even when the pid it records is the
        // child's: pids are reused, and that program may have exited long ago and left the segment for another.
        if (segment->shm_cpid != creator || [existing containsObject:@(identifier)]) return;
        if (shmctl(identifier, IPC_RMID, NULL) == 0) removed++;
    });
    return removed;
}

void SPDFPythonSandboxSweepStale(NSString* parent) {
    NSArray* names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:parent error:nil];
    time_t cutoff = time(NULL) - 3600;
    for (NSString* name in names) {
        if (![name hasPrefix:@"szpy-"]) continue;
        NSString* path = [parent stringByAppendingPathComponent:name];
        struct stat info;
        if (lstat(path.fileSystemRepresentation, &info) == 0 && S_ISDIR(info.st_mode) && info.st_uid == getuid() &&
            info.st_mtime < cutoff)
            SPDFPythonSandboxRemoveTree(path);
    }
}

void SPDFPythonSandboxSeedMatplotlib(NSString* venv, NSString* configDirectory) {
    if (!venv) return;
    NSString* source = [venv stringByAppendingPathComponent:@".matplotlib"];
    NSUInteger copied = 0;
    for (NSString* name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:source error:nil]) {
        if (![name hasPrefix:@"fontlist-"] || ![name.pathExtension isEqual:@"json"] || copied >= 4) continue;
        NSString* path = [source stringByAppendingPathComponent:name];
        struct stat info;
        if (lstat(path.fileSystemRepresentation, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size > 2 << 20)
            continue;
        NSData* data = [NSData dataWithContentsOfFile:path];
        if (data && SPDFPythonSandboxWriteFile(configDirectory, name, data)) copied++;
    }
}

NSString* SPDFPythonSandboxText(NSData* data) {
    if (!data.length) return @"";
    NSString* text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (text) return text;
    NSString* converted = nil;
    BOOL lossy = NO;
    [NSString stringEncodingForData:data
                    encodingOptions:@{NSStringEncodingDetectionSuggestedEncodingsKey : @[ @(NSUTF8StringEncoding) ],
                                      NSStringEncodingDetectionUseOnlySuggestedEncodingsKey : @YES,
                                      NSStringEncodingDetectionAllowLossyKey : @YES}
                    convertedString:&converted
                usedLossyConversion:&lossy];
    return converted ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] ?: @"";
}
