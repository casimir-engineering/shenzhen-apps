// What the sandbox allows: paths derived from the interpreter, the SBPL profile, the environment and input names.
// Pure functions over paths, so the suite can check each rule without running anything.
#import "SPDFPythonSandbox.h"

#include <limits.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

static NSString* const kSPDFCryptexes = @"/System/Volumes/Preboot/Cryptexes";

static NSString* SPDFRealPath(NSString* path) {
    char resolved[PATH_MAX];
    return realpath(path.fileSystemRepresentation, resolved) ? @(resolved) : nil;
}

NSArray<NSString*>* SPDFPythonSandboxAncestors(NSString* path) {
    NSMutableArray<NSString*>* ancestors = [NSMutableArray array];
    // Not stringByStandardizingPath: it turns an existing /private/var/… into /var/…, and the profile must name the
    // real paths the kernel reports.
    NSString* current = path;
    while (current.length > 1) {
        current = current.stringByDeletingLastPathComponent;
        [ancestors insertObject:current atIndex:0];
    }
    return ancestors;
}

NSString* SPDFPythonSandboxQuote(NSString* text) {
    NSString* escaped = [text stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    return [NSString stringWithFormat:@"\"%@\"", escaped];
}

// Every symlink met while resolving `path`, in directories as well as the last component: the kernel reads each
// one on the way, and the profile has to allow that read. Homebrew's venv interpreter alone crosses three
// (bin/python3 → /opt/homebrew/opt/python@3.14 → ../Cellar/… → ../Frameworks/…/python3.14).
static NSArray<NSString*>* SPDFSymlinksResolving(NSString* path) {
    NSMutableArray<NSString*>* links = [NSMutableArray array];
    NSMutableArray<NSString*>* pending = [path.pathComponents mutableCopy];
    NSString* resolved = @"/";
    if (pending.count && [pending[0] isEqual:@"/"]) [pending removeObjectAtIndex:0];
    for (NSUInteger hops = 0; pending.count && hops < 64; hops++) {
        NSString* component = pending[0];
        [pending removeObjectAtIndex:0];
        if ([component isEqual:@"."] || !component.length) continue;
        if ([component isEqual:@".."]) { resolved = resolved.stringByDeletingLastPathComponent; continue; }
        NSString* next = [resolved stringByAppendingPathComponent:component];
        struct stat info;
        if (lstat(next.fileSystemRepresentation, &info) != 0) return links;
        if (!S_ISLNK(info.st_mode)) { resolved = next; continue; }
        [links addObject:next];
        char target[PATH_MAX];
        ssize_t length = readlink(next.fileSystemRepresentation, target, sizeof target - 1);
        if (length <= 0) return links;
        target[length] = 0;
        NSString* destination = @(target);
        NSMutableArray* expanded = [destination.pathComponents mutableCopy];
        if ([destination hasPrefix:@"/"]) { resolved = @"/"; [expanded removeObjectAtIndex:0]; }
        [pending replaceObjectsInRange:NSMakeRange(0, 0) withObjectsFromArray:expanded];
    }
    return links;
}

static BOOL SPDFPath(NSString* path, NSString* root) {
    return [path isEqual:root] || [path hasPrefix:[root stringByAppendingString:@"/"]];
}

NSDictionary<NSString*, id>* SPDFPythonSandboxPathsForInterpreter(NSString* interpreter, NSString** reason) {
    NSString* why = nil;
    NSMutableDictionary* paths = nil;
    NSString* home = SPDFRealPath(NSHomeDirectory()) ?: NSHomeDirectory();
    NSString* real = [interpreter hasPrefix:@"/"] ? SPDFRealPath(interpreter) : nil;
    NSString* bin = real.stringByDeletingLastPathComponent;
    NSString* prefix = bin.stringByDeletingLastPathComponent;
    if (!real || access(real.fileSystemRepresentation, X_OK) != 0) {
        why = @"The interpreter is missing or not executable.";
    } else if (![bin.lastPathComponent isEqual:@"bin"] || prefix.pathComponents.count < 4) {
        // pathComponents counts "/" too: /usr/bin/python3, Xcode's stub, would make all of /usr readable.
        why = @"The interpreter is not inside a Python installation's bin directory.";
    } else if (SPDFPath(prefix, home) || SPDFPath(home, prefix)) {
        why = @"Python installed in the home folder is not used, only a virtual environment there.";
    } else {
        NSString* venv = nil;
        NSString* candidate = interpreter.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
        BOOL isDirectory = NO;
        if ([NSFileManager.defaultManager fileExistsAtPath:[candidate stringByAppendingPathComponent:@"pyvenv.cfg"]
                                               isDirectory:&isDirectory] && !isDirectory)
            venv = SPDFRealPath(candidate);
        if (venv && (SPDFPath(home, venv) || venv.pathComponents.count < 3)) {
            why = @"The virtual environment would expose the home folder.";
        } else {
            NSArray* links = SPDFSymlinksResolving(interpreter);
            NSMutableArray* readRoots = [NSMutableArray arrayWithObject:prefix];
            NSMutableArray* execRoots = [NSMutableArray arrayWithObject:prefix];
            if (venv) { [readRoots addObject:venv]; [execRoots addObject:venv]; }
            for (NSString* brew in @[ @"/opt/homebrew", @"/usr/local" ])
                if (SPDFPath(real, [brew stringByAppendingString:@"/Cellar"])) {
                    [readRoots addObject:[brew stringByAppendingString:@"/Cellar"]];
                    [readRoots addObject:[brew stringByAppendingString:@"/opt"]];
                }
            paths = [@{@"exec_literals" : [@[ interpreter, real ] arrayByAddingObjectsFromArray:links],
                       @"exec_subpaths" : execRoots,
                       @"read_literals" : [@[ interpreter ] arrayByAddingObjectsFromArray:links],
                       @"read_subpaths" : readRoots} mutableCopy];
            if (venv) paths[@"venv"] = venv;
        }
    }
    if (reason) *reason = why;
    return paths;
}

NSArray<NSString*>* SPDFPythonSandboxWriteOnlyPaths(NSArray* requested) {
    NSMutableOrderedSet* paths = [NSMutableOrderedSet orderedSet];
    NSString* home = SPDFRealPath(NSHomeDirectory()) ?: NSHomeDirectory();
    for (NSString* folder in [@[ [home stringByAppendingPathComponent:@"Downloads"] ]
             arrayByAddingObjectsFromArray:[requested isKindOfClass:NSArray.class] ? requested : @[]]) {
        if (![folder isKindOfClass:NSString.class] || ![folder hasPrefix:@"/"]) continue;
        // Both spellings: the kernel reports real paths, and a folder not made yet has none.
        [paths addObject:folder];
        NSString* real = SPDFRealPath(folder);
        if (real) [paths addObject:real];
    }
    return paths.array;
}

NSDictionary<NSString*, id>* SPDFPythonSandboxDocumentPaths(NSString* folder, NSArray* files, NSString** reason) {
    NSString* why = nil;
    NSString* home = SPDFRealPath(NSHomeDirectory()) ?: NSHomeDirectory();
    NSString* real = [folder isKindOfClass:NSString.class] && [folder hasPrefix:@"/"] ? SPDFRealPath(folder) : nil;
    struct stat info;
    NSMutableArray* literals = [NSMutableArray array], *subpaths = [NSMutableArray array];
    if (!real || lstat(real.fileSystemRepresentation, &info) != 0 || !S_ISDIR(info.st_mode)) {
        why = @"documents_dir must be an existing folder.";
    } else if (info.st_uid != getuid() || (info.st_mode & 077)) {
        why = @"documents_dir must be private to this user (mode 0700).";
    } else if (SPDFPath(home, real) || real.pathComponents.count < 4) {
        // A folder holding the home folder (or "/", "/Users") would open every file in it.
        why = @"documents_dir must not contain the home folder.";
    } else if (![files isKindOfClass:NSArray.class] || files.count > SPDF_PYTHON_MAX_DOCUMENTS) {
        why = @"document_files must be a list of at most 64 paths.";
    } else {
        for (id file in files) {
            NSString* path = [file isKindOfClass:NSString.class] && [file hasPrefix:@"/"] ? SPDFRealPath(file) : nil;
            // A file by its exact path; a folder the person attached with all it holds, but never one that holds
            // the home folder or a top-level folder of the system.
            BOOL exists = path && lstat(path.fileSystemRepresentation, &info) == 0;
            if (exists && S_ISREG(info.st_mode)) {
                [literals addObject:path];
            } else if (exists && S_ISDIR(info.st_mode) && !SPDFPath(home, path) && path.pathComponents.count >= 3) {
                [subpaths addObject:path];
            } else {
                why = @"Each document must be an existing file, or a folder that does not hold the home folder.";
                break;
            }
        }
    }
    if (reason) *reason = why;
    return why ? nil : @{@"document_subpaths" : [@[ real ] arrayByAddingObjectsFromArray:subpaths],
                         @"document_literals" : literals};
}

static void SPDFAppendRule(NSMutableString* profile, NSString* rule, NSString* filter, NSArray<NSString*>* paths) {
    NSMutableOrderedSet* unique = [NSMutableOrderedSet orderedSetWithArray:paths];
    if (!unique.count) return;
    [profile appendFormat:@"(%@", rule];
    for (NSString* path in unique) [profile appendFormat:@"\n    (%@ %@)", filter, SPDFPythonSandboxQuote(path)];
    [profile appendString:@")\n"];
}

NSString* SPDFPythonSandboxProfile(NSDictionary<NSString*, id>* paths, NSString* workDirectory) {
    NSMutableString* profile = [NSMutableString stringWithString:@"(version 1)\n(deny default)\n"];
    // Spelled out although `deny default` covers them, because these are the promises: no network, no Apple events,
    // no system services, no new processes. Later rules win in SBPL, and nothing below allows any of them.
    [profile appendString:@"(deny network* system-socket)\n(deny appleevent-send)\n(deny mach-lookup)\n"
                           "(deny process-fork)\n"];
    SPDFAppendRule(profile, @"allow process-exec", @"literal", paths[@"exec_literals"]);
    SPDFAppendRule(profile, @"allow process-exec", @"subpath", paths[@"exec_subpaths"]);
    SPDFAppendRule(profile, @"allow file-read*", @"literal", paths[@"read_literals"]);
    SPDFAppendRule(profile, @"allow file-read*", @"subpath", paths[@"read_subpaths"]);
    // Downloads is the assistant's to write (through the app), never to read: refused by name even though (deny
    // default) already refuses it, so no rule added later for the interpreter or the system can open it by accident.
    // The document rules below come later and win: a file this chat saved, or a folder the person gave it.
    SPDFAppendRule(profile, @"deny file-read*", @"subpath", paths[@"deny_read_subpaths"]);
    // The documents the assistant may see, read only: the folder the app prepared for this run (links to them, the
    // images it extracted, index.json) and each linked document by its exact path, never the folder it is in.
    SPDFAppendRule(profile, @"allow file-read*", @"subpath", paths[@"document_subpaths"]);
    SPDFAppendRule(profile, @"allow file-read*", @"literal", paths[@"document_literals"]);
    // The system: dyld's shared cache and system libraries, time zones, locales, and the random and null devices.
    NSArray* systemRoots = @[ @"/System", @"/usr/lib", @"/usr/share", @"/private/var/db/timezone" ];
    NSArray* systemFiles = @[ @"/private/etc/localtime", @"/dev/null", @"/dev/zero", @"/dev/random", @"/dev/urandom" ];
    SPDFAppendRule(profile, @"allow file-read*", @"subpath", systemRoots);
    SPDFAppendRule(profile, @"allow file-read*", @"literal", systemFiles);
    // The other volumes under /System/Volumes are the Mac's and the person's, not the system's: measured on macOS
    // 26, Preboot holds the person's full name, account and picture (var/db/AllUsersInfo.plist) and the network
    // interfaces' hardware addresses, Hardware the serial number. Only the cryptexes, where macOS keeps part of
    // itself (the OS and Safari libraries), are read back.
    SPDFAppendRule(profile, @"deny file-read*", @"subpath", @[ @"/System/Volumes" ]);
    SPDFAppendRule(profile, @"allow file-read*", @"subpath", @[ kSPDFCryptexes ]);
    // /System/Volumes/Data is where the person's files live under their other name; the kernel reports such paths
    // under their usual names (/Users/…), so this only states the intent, and later rules keep winning.
    SPDFAppendRule(profile, @"deny file-read*", @"subpath", @[ @"/System/Volumes/Data" ]);
    // Python's startup resolves its own path with realpath(), which opens "/" and stats each directory above the
    // interpreter, the venv and the work directory: the names of the directories on the way, nothing inside them.
    // /etc and /var are the links /etc/localtime is reached through.
    [profile appendString:@"(allow file-read-data (literal \"/\"))\n"];
    NSMutableArray* ancestors = [NSMutableArray arrayWithObjects:@"/etc", @"/var", nil];
    NSArray* roots = [[[[[[paths[@"read_subpaths"] arrayByAddingObjectsFromArray:paths[@"read_literals"]]
        arrayByAddingObjectsFromArray:systemRoots] arrayByAddingObjectsFromArray:systemFiles]
        arrayByAddingObjectsFromArray:paths[@"document_subpaths"] ?: @[]]
        arrayByAddingObjectsFromArray:paths[@"document_literals"] ?: @[]]
        arrayByAddingObjectsFromArray:@[ kSPDFCryptexes, workDirectory ]];
    for (NSString* root in roots) [ancestors addObjectsFromArray:SPDFPythonSandboxAncestors(root)];
    SPDFAppendRule(profile, @"allow file-read-metadata", @"literal", ancestors);
    SPDFAppendRule(profile, @"allow file-read* file-write*", @"subpath", @[ workDirectory ]);
    // Ownership and extended attributes in the work directory serve no computation; flags and modes stay allowed
    // because shutil.copy2 sets them, and deletion clears them afterwards.
    SPDFAppendRule(profile, @"deny file-write-owner file-write-xattr", @"subpath", @[ workDirectory ]);
    [profile appendString:@"(allow file-write-data file-ioctl (literal \"/dev/null\"))\n"];
    [profile appendString:SPDFPythonSandboxSysctlRule()];
    // (deny default) does not reach process-info or the I/O registry on macOS 26, measured: without these rules the
    // code could read any of the person's processes' arguments, environment and paths (kern.procargs2,
    // proc_pidinfo), list every process, and read the Mac's serial number. Later rules win, so the code still reads
    // its own process information. System V IPC is spelled out like the promises above: (deny default) already
    // keeps other programs' objects closed, and macOS checks nothing when the code creates one of its own.
    [profile appendString:@"(deny process-info*)\n(allow process-info* (target self))\n(allow signal (target self))\n"
                           "(deny ipc-sysv*)\n(deny iokit-get-properties)\n"];
    // fsgetpath and fsgetpath_ext turn a volume and inode number into the file's full path without any access to
    // the folders on the way, and no file rule is consulted: measured, they named every file in the home folder.
    // Nothing Python, numpy, pandas or matplotlib does calls them.
    [profile appendFormat:@"(deny syscall-unix (syscall-number %d %d))\n", SYS_fsgetpath, SYS_fsgetpath_ext];
    return profile;
}

NSString* SPDFPythonSandboxSysctlRule(void) {
    // Each name is read by something a run needs; the suite's escape checks show the rest stay closed (kern.proc.all
    // above all, which lists every process on the Mac).
    NSArray* names = @[
        // uname(), which os.uname, platform and ctypes' import call: it fails whole if any of these is refused.
        // kern.hostname too, although it is the computer's name: measured on macOS 26, without it `import ctypes`
        // raises PermissionError, and numpy needs ctypes.
        @"kern.ostype", @"kern.osrelease", @"kern.version", @"kern.hostname", @"hw.machine",
        // libSystem and CoreFoundation at startup, and platform.mac_ver's version checks.
        @"kern.osproductversion", @"kern.osvariant_status", @"kern.iossupportversion",
        // os.cpu_count and sysconf: processors, memory, page size (getpagesize reads hw.pagesize_compat), argument
        // and group limits.
        @"hw.ncpu", @"hw.memsize", @"hw.pagesize", @"hw.pagesize_compat", @"kern.argmax", @"kern.ngroups",
        // Thread counts and CPU identification in numpy's math libraries (OpenBLAS where numpy ships it, Accelerate)
        // and Pillow's codecs, which matplotlib saves through; OpenSSL reads the brand string.
        @"hw.logicalcpu", @"hw.physicalcpu", @"hw.nperflevels", @"hw.cpufamily", @"hw.cpusubfamily",
        @"machdep.cpu.brand_string",
    ];
    NSMutableString* rule = [NSMutableString stringWithString:@"(allow sysctl-read\n    (sysctl-name"];
    for (NSString* name in names) [rule appendFormat:@" %@", SPDFPythonSandboxQuote(name)];
    // CPU features (numpy's dispatch, zlib, OpenSSL) and the performance and efficiency core clusters.
    [rule appendString:@")\n    (sysctl-name-prefix \"hw.optional.\")\n    (sysctl-name-prefix \"hw.perflevel\"))\n"];
    return rule;
}

NSDictionary<NSString*, NSString*>* SPDFPythonSandboxEnvironment(NSString* workDirectory) {
    return @{
        @"PATH" : @"/usr/bin:/bin",
        @"HOME" : workDirectory,
        @"TMPDIR" : [workDirectory stringByAppendingPathComponent:@".tmp"],
        @"LANG" : @"en_US.UTF-8",
        @"LC_CTYPE" : @"en_US.UTF-8",
        // getpass.getuser() reads these before asking the directory service, which the profile does not reach.
        @"USER" : @"python",
        @"LOGNAME" : @"python",
        // No window server inside the sandbox: Agg draws to files. The config directory is the work directory's own,
        // because matplotlib refuses one it cannot write and would warn on every run.
        @"MPLBACKEND" : @"Agg",
        @"MPLCONFIGDIR" : [workDirectory stringByAppendingPathComponent:@".matplotlib"],
        // One math thread: the CPU limit counts every thread, so BLAS fanning out over all cores would spend 20 s of
        // CPU in a few seconds of wall time and end runs that one thread finishes.
        @"OPENBLAS_NUM_THREADS" : @"1",
        @"OMP_NUM_THREADS" : @"1",
        @"VECLIB_MAXIMUM_THREADS" : @"1",
    };
}

BOOL SPDFPythonSandboxValidInputName(id name) {
    if (![name isKindOfClass:NSString.class]) return NO;
    NSString* text = name;
    if (!text.length || text.length > 100 || [text isEqual:@"main.py"] || [text isEqual:@"documents"] ||
        [text isEqual:@"out"] || [text hasPrefix:@"."])
        return NO;
    NSCharacterSet* allowed =
        [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
                                                            "0123456789._- "];
    return [text rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound &&
           ![text hasSuffix:@" "] && ![text isEqual:@".."];
}
