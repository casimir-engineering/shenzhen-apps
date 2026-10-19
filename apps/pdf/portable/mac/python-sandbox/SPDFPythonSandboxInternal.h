#pragma once
// The work directory's file handling, shared by the run (SPDFPythonSandboxRun.m) and its suite. Every function here
// treats the directory's contents as hostile: they were written by the code that ran.
#import "SPDFPythonSandbox.h"

NS_ASSUME_NONNULL_BEGIN

// A fresh 0700 directory named szpy-XXXXXXXX in `parent`, as its real path (the profile matches real paths).
NSString* _Nullable SPDFPythonSandboxMakeWorkDirectory(NSString* parent, NSString* _Nullable* _Nullable reason);

// Creates `name` in `directory` (never through a link, never over an existing file) holding `data`.
BOOL SPDFPythonSandboxWriteFile(NSString* directory, NSString* name, NSData* data);

// Bytes in regular files (each file's size or its disk blocks, whichever is larger) and entries under `directory`,
// links not followed. Stops counting past `maxEntries`. Sets `*unreadable` (nullable) when the walk meets a
// directory it cannot read or an entry it cannot stat inside the tree: the code has no reason to lock a directory
// under its own work directory, and disk hidden behind one would otherwise go uncounted, so the run treats it as a
// 'files' breach.
void SPDFPythonSandboxMeasure(NSString* directory, unsigned long long* bytes, NSUInteger* entries,
                              NSUInteger maxEntries, BOOL* _Nullable unreadable);

// The disk the measure's walk cannot reach: blocks (as bytes) of regular files the child unlinked yet still holds,
// through an open descriptor or a memory mapping, so they are in no directory yet still hold disk (F_PREALLOCATE
// reserves beyond a file's size, RLIMIT_FSIZE does not stop it, and a mapping outlives its descriptor). Read from
// outside the sandbox with proc_pidinfo, as the same user. Descriptors are read whole on every call; memory regions
// a slice at a time, each call resuming where the last stopped, because the code can make enough regions that one
// full walk would stall the watchdog. A mapped file counts from its latest complete walk, or as soon as the walk
// under way reaches it.
@interface SPDFPythonSandboxHiddenDisk : NSObject
- (instancetype)initWithPid:(pid_t)pid NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// Walks at most `maxRegions` more regions, then answers the bytes held by every such file known so far.
- (unsigned long long)bytesScanningRegions:(NSUInteger)maxRegions;
@end

// The files the code left, by relative path in name order: regular files with a single link get their bytes (base64
// "data") while the total stays within `cap`; links, other kinds and files over the cap are listed with "omitted".
// Hidden names (the helper's .tmp and .matplotlib) and `skip` at the top level are left out; past 32 entries the
// rest are only counted in `omitted`.
NSArray<NSDictionary*>* SPDFPythonSandboxCollect(NSString* directory, NSSet<NSString*>* skip,
                                                unsigned long long cap, NSUInteger* omitted);

// Removes szpy-* directories older than an hour in `parent`: work directories a killed helper could not delete.
void SPDFPythonSandboxSweepStale(NSString* parent);

// The identifiers of every System V shared-memory segment that exists now. Taken just before the child starts, so the
// cleanup after it can tell the segments the run created from those that were already there.
NSSet<NSNumber*>* SPDFPythonSandboxSharedMemoryIdentifiers(void);

// Removes the System V shared-memory segments whose creator was `creator` (the sandboxed child's pid) and that are not
// in `existing` (SPDFPythonSandboxSharedMemoryIdentifiers before the child started): pids are reused, so a segment
// that predates the run is someone else's even when it records the same pid. Returns how many it removed. macOS lets
// the sandboxed code create segments it can never use (SPDFPythonSandbox.h § residuals); shared memory is the scarce
// table and the only object that records its creator, so the helper clears the run's after each run. Call it only
// for a pid that has exited, from outside the sandbox and as the same user.
NSUInteger SPDFPythonSandboxRemoveSharedMemory(pid_t creator, NSSet<NSNumber*>* existing);

// matplotlib's font list from the environment's install, copied so each run does not rebuild it: every run starts
// with an empty MPLCONFIGDIR, and matplotlib would otherwise scan the system's fonts again each time.
void SPDFPythonSandboxSeedMatplotlib(NSString* _Nullable venv, NSString* configDirectory);

// Text from bytes that may end mid-character (a cap cut them) or not be UTF-8 at all.
NSString* SPDFPythonSandboxText(NSData* data);

NS_ASSUME_NONNULL_END
