#pragma once
// The assistant's Python sandbox (portable/docs/plans/ai-agent-capabilities.md § 4): a small helper the app embeds in
// Contents/Helpers/spdf-python-sandbox. The app writes one JSON request to its stdin and reads one JSON result from its
// stdout; the helper does everything in between, so no other process ever sees the work directory:
//
//   request  {"interpreter": "/…/assistant-python/bin/python3", "code": "…", "files": [{"name", "text"}],
//             "documents_dir": "/…" (optional), "document_files": ["/…"], "write_only_dirs": ["/…"] (Downloads),
//             "limits": {lower limits, for tests}, "work_parent": "/…" (tests; default: the user's temp folder)}
//   result   {"ok": true, "status": "completed" | "failed" | "stopped", "exit_code" | "signal", "limit",
//             "seconds", "stdout", "stdout_truncated", "stderr", "stderr_truncated",
//             "files": [{"name", "size", "data" (base64) | "omitted"}], "files_omitted", "limits"}
//            or {"ok": false, "error": "bad_request" | "interpreter_unavailable" | "sandbox_unavailable" | "internal",
//                "message"}
//
// How a run is contained, and why each part exists:
//   - A fresh work directory (mkdtemp, 0700) holds main.py and the inputs; it is the code's working directory and
//     the only place it may write. It is deleted afterwards whatever happened, without following links the code
//     made, after clearing any flags or modes the code set to make deletion fail.
//   - out/ in the work directory is where the code saves files for the person; they come back like the others,
//     named out/…, and the app decides what to keep. With documents_dir, the work directory also has `documents`, a
//     link to that folder: the app's private folder for this run, holding links to the documents the assistant may
//     see and the images it extracted from them. The profile lets the code read that folder and each document by
//     its exact path (SPDFPythonSandboxDocumentPaths), never write there and never the folders around a document.
//   - The helper spawns itself with --sandboxed-exec. That process sets the rlimits (CPU, file size, open files,
//     no core files, one process), applies the sandbox profile (SPDFPythonSandboxProfile), checks that the profile
//     really holds (a loopback connect and opening /Users must both be refused), and only then execs the
//     interpreter. Any failure before exec is reported on fd 3 and nothing runs: the code never runs unsandboxed.
//   - Beyond files, the profile names the system values (sysctl) the code may read, and denies other processes'
//     information and the I/O registry, which (deny default) alone leaves open.
//   - The helper itself stays outside the sandbox as the watchdog: wall time, memory footprint, output size and the
//     disk the work directory takes (sizes, or blocks reserved beyond them, plus files the code unlinked while still
//     holding them open or mapped), checked every 25 ms, killing the run at the first limit it crosses. Between two
//     checks a fast writer or allocator can overshoot (tens of MB); the rlimits hold inside the kernel regardless
//     (CPU time, one file's size), and the profile forbids creating processes, so killing one pid kills everything
//     the code started.
//   - Results are read back without following links and only from regular files with a single link, so a symlink
//     or hard link the code made cannot smuggle a file from elsewhere into the result.
//
// Stated residuals, measured on macOS 26. The profile cannot stop the sandboxed code from *creating* System V IPC
// objects: shmget, msgget and semget with IPC_CREAT succeed under (deny ipc-sysv*) and under syscall-unix filters,
// because creation is neither a file, a socket nor a service. The code still cannot attach to, read, use or remove
// any object, its own or another program's. Shared memory is the scarce table (kern.sysv.shmmni defaults to 32) and
// the only object that records a creator pid, so after each run the helper removes the segments the child created
// (SPDFPythonSandboxRemoveSharedMemory). Message queues and semaphores record no creator (semmni defaults to 87381,
// a far larger table), so objects of those kinds the code makes are left until reboot. Separately, csops and
// getpgid/getsid on a pid still report which processes exist and their signing identities; no profile rule tried
// closes that, so the list of running programs is a residual too. And the code can read the computer's name
// (kern.hostname), which often holds the person's name: uname() fails as a whole without it, and `import ctypes`, which
// numpy needs, calls uname (SPDFPythonSandboxSysctlRule). The run has no network to send it anywhere, but what it
// prints reaches the model, so the name can end up in the chat or in OpenRouter's request.
#include <signal.h>

// Limits. A request may lower them (tests do, to stay fast), never raise them.
#define SPDF_PYTHON_CPU_SECONDS 20
#define SPDF_PYTHON_WALL_SECONDS 30
#define SPDF_PYTHON_MEMORY_BYTES (512ull * 1024 * 1024)
#define SPDF_PYTHON_STDOUT_BYTES (64 * 1024)
#define SPDF_PYTHON_STDERR_BYTES (16 * 1024)
#define SPDF_PYTHON_OUTPUT_FILE_BYTES (10ull * 1024 * 1024)
// Each open descriptor can hold a file the code unlinked and reserved disk on; fewer descriptors bound how much such
// hidden disk can appear between two watchdog checks. Measured: a numpy, pandas and matplotlib run opening twenty
// data files at once peaks at 25 open descriptors, so 96 leaves wide headroom while well below the former 128.
#define SPDF_PYTHON_OPEN_FILES 96
// Printing beyond the kept 64 KB is drained, so the code keeps running, until it reaches this much: then the run is a
// runaway loop and is stopped rather than left to burn its whole wall time.
#define SPDF_PYTHON_RUNAWAY_OUTPUT_BYTES (1024 * 1024)
// Entries in the work directory before a run is stopped: deleting millions of files would outlast any limit above.
#define SPDF_PYTHON_MAX_ENTRIES 4096
#define SPDF_PYTHON_MAX_INPUTS 16
// Document files one run may read by exact path (SPDFPythonSandboxDocumentPaths).
#define SPDF_PYTHON_MAX_DOCUMENTS 64
#define SPDF_PYTHON_MAX_REQUEST_BYTES (16 * 1024 * 1024)

// Exit codes of --sandboxed-exec when the interpreter never started.
#define SPDF_PYTHON_EXIT_REFUSED 126
#define SPDF_PYTHON_EXIT_EXEC_FAILED 127

#ifdef __cplusplus
extern "C" {
#endif

// argv: helper --sandboxed-exec <cpu seconds> <file bytes> <profile> <interpreter> [arguments…]. Never returns: it
// execs the interpreter inside the sandbox or exits 126/127 after writing why to fd 3 (and stderr).
int spdf_python_sandbox_exec(int argc, char* _Nonnull* _Nonnull argv, char* _Nonnull* _Nonnull envp)
    __attribute__((noreturn));

// Set by the helper's SIGTERM handler: the app pressed Stop or gave up waiting.
extern volatile sig_atomic_t spdf_python_sandbox_stop_requested;

#ifdef __cplusplus
}
#endif

#ifdef __OBJC__
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" { // defined in Objective-C files, also declared to the reader's Objective-C++ suite
#endif
NS_ASSUME_NONNULL_BEGIN

// What the sandbox lets one interpreter read and exec, from the interpreter's path alone, so a request cannot widen
// it: the interpreter and every symlink on the way to it, its prefix (the directory above its real bin/), the
// virtual environment around it, and Homebrew's Cellar and opt when the interpreter is Homebrew's (its standard
// library links libraries there: OpenSSL, mpdecimal, xz, SQLite). Keys: exec_literals, exec_subpaths,
// read_literals, read_subpaths, venv (absent when not a venv). nil with a reason for an interpreter outside these
// shapes: a relative path, the /usr/bin/python3 stub (whose prefix would be /usr), or one installed in the home
// folder other than as a virtual environment.
NSDictionary<NSString*, id>* _Nullable SPDFPythonSandboxPathsForInterpreter(NSString* interpreter,
                                                                         NSString* _Nullable* _Nullable reason);

// The SBPL profile for `paths` and the (real) work directory.
NSString* SPDFPythonSandboxProfile(NSDictionary<NSString*, id>* paths, NSString* workDirectory);
// The folders a run may never read (deny_read_subpaths): the home folder's Downloads and the request's
// write_only_dirs, each as given and by its real path. Rules for this run's documents come after them and win.
NSArray<NSString*>* SPDFPythonSandboxWriteOnlyPaths(NSArray* _Nullable requested);

// The profile's sysctl rule: the named system values Python, numpy, pandas and matplotlib read, and nothing else.
NSString* SPDFPythonSandboxSysctlRule(void);

// Every directory above `path`, "/" first: path resolution needs to read their metadata, and nothing more.
NSArray<NSString*>* SPDFPythonSandboxAncestors(NSString* path);

// An SBPL string literal.
NSString* SPDFPythonSandboxQuote(NSString* text);

// The interpreter's whole environment; nothing is inherited. HOME and TMPDIR point into the work directory and
// matplotlib draws without a window server.
NSDictionary<NSString*, NSString*>* SPDFPythonSandboxEnvironment(NSString* workDirectory);

// The documents a run may read (request keys documents_dir and document_files): the app's private folder prepared
// for this run, by its real path, as document_subpaths, and each document file by its exact real path as
// document_literals; a folder the person attached to the chat, listed in files, joins document_subpaths with all it
// holds. nil with a reason for a prepared folder that is missing, not private (0700, this user's) or that contains
// the home folder, and for anything in files that is neither a regular file nor a folder clear of the home folder.
NSDictionary<NSString*, id>* _Nullable SPDFPythonSandboxDocumentPaths(NSString* folder, NSArray* files,
                                                                      NSString* _Nullable* _Nullable reason);

// Input names: one plain file name the code can open as written, never main.py (the code), documents or out (the
// folders a run gets) or a hidden name (the helper's own .tmp and .matplotlib).
BOOL SPDFPythonSandboxValidInputName(id name);

// Runs one request and returns its result (the shapes above). `helperPath` is this helper's own executable, spawned
// with --sandboxed-exec.
NSDictionary<NSString*, id>* SPDFPythonSandboxRun(NSDictionary<NSString*, id>* request, NSString* helperPath);

// Deletes a work directory the code may have booby-trapped: links are removed, never followed; flags and modes that
// would block deletion are cleared first. YES when it is gone.
BOOL SPDFPythonSandboxRemoveTree(NSString* path);

NS_ASSUME_NONNULL_END
#ifdef __cplusplus
}
#endif
#endif
