#import <Cocoa/Cocoa.h>

#import "SPDFMacDelegatePrivate.h"

// The environment external tools run in.
//
// Shenzhen PDF shells out to two Python programs -- ocrmypdf and Argos
// Translate -- and both broke on machines whose Python was set up differently:
// conda, pyenv, a python.org framework build, an activated virtualenv, a
// `pip install --user` tree. The cause was always the same two leaks.
//
// First, the app handed those tools its OWN environment. A GUI app launched
// from a terminal, or on a machine with `launchctl setenv`, carries PYTHONHOME,
// PYTHONPATH, VIRTUAL_ENV, CONDA_PREFIX or __PYVENV_LAUNCHER__ -- variables
// that point an interpreter at ANOTHER installation's standard library.
// Homebrew's ocrmypdf has its own vendored interpreter; give it a PYTHONHOME
// belonging to conda and it fails to import its own modules.
//
// Second, the installers ran under `bash -lc`. A login shell sources the
// user's dotfiles, so whichever `python3` their conda/pyenv hook put first is
// the one that installed the tool -- and nothing guaranteed the app would find
// that same interpreter later.
//
// So: tools are launched with a scrubbed environment and a deterministic PATH,
// installers run without a login shell, and Argos is installed into a
// virtualenv the app owns rather than into whatever Python happens to answer.

// The virtualenv the app installs Python tools into, and the executables in it.
// Under Application Support, beside the tesseract data, so it is removable with
// the rest of the app's state and needs no administrator rights.
FOUNDATION_EXPORT NSString* spdf_mac_tool_venv_path(void);
FOUNDATION_EXPORT NSString* spdf_mac_tool_venv_bin_path(void);

// Where to look for `tool`, in order: the app's own virtualenv first, then the
// caller's fixed candidates, then ~/.local/bin. A PATH sweep still follows in
// the caller, so a machine that already had a working install keeps it.
FOUNDATION_EXPORT NSArray<NSString*>* spdf_mac_tool_candidate_paths(NSString* tool,
                                                                    NSArray<NSString*>* candidates);

// The PATH a tool and its own subprocesses see: the virtualenv, the directories
// the resolved tools live in, then the usual prefixes, then whatever the app
// inherited -- deduplicated, in that order.
FOUNDATION_EXPORT NSArray<NSString*>* spdf_mac_tool_search_directories(NSArray<NSString*>* toolPaths,
                                                                       NSString* inheritedPath);

// YES for a variable that redirects an interpreter or the dynamic loader at
// another installation. These are dropped rather than passed through.
FOUNDATION_EXPORT BOOL spdf_mac_tool_environment_key_is_banned(NSString* key);

// `inherited` scrubbed of those variables, with a deterministic PATH, UTF-8 I/O
// for the pipes the app reads, and `extra` applied last so a caller can set
// something it owns (TESSDATA_PREFIX) that the scrub would otherwise drop.
FOUNDATION_EXPORT NSDictionary<NSString*, NSString*>* spdf_mac_tool_environment(
    NSDictionary<NSString*, NSString*>* inherited, NSArray<NSString*>* toolPaths,
    NSDictionary<NSString*, NSString*>* extra);

// ocrmypdf and Argos Translate are NEVER installed globally: Homebrew provides
// only the C programs ocrmypdf shells out to (tesseract, ghostscript), and the
// Python programs themselves go into the virtualenv. So "is it in the
// virtualenv?" is what decides whether OCR or translation can run at all, and a
// machine without one is sent to the installer, which shows what it is doing.
FOUNDATION_EXPORT BOOL spdf_mac_tool_venv_has_tool(NSString* toolName);

// One installer attempt per session. A machine with no Python 3 anywhere the
// installer looks cannot build the environment, and must not be asked again on
// every run; after one attempt the caller falls through to whatever is already
// on the machine rather than refusing to work.
FOUNDATION_EXPORT BOOL spdf_mac_tool_install_attempted(void);
FOUNDATION_EXPORT void spdf_mac_tool_note_install_attempt(void);

// The environment build as an INSTALLER step, for the panel that shows a live
// log: same virtualenv, but it says what it is doing and why it stopped. It is
// spliced into a script running under `set -e`, so it is guarded throughout --
// a machine with no usable Python still finishes installing the rest.
FOUNDATION_EXPORT NSString* spdf_mac_tool_environment_install_step(NSArray<NSString*>* packages);

// The installer for Argos Translate: builds the app's virtualenv from a Python
// found at a FIXED path (never `command -v python3`, which is the ambiguity
// this whole file exists to remove) and installs argostranslate into it.
FOUNDATION_EXPORT NSString* spdf_mac_tool_argos_install_script(void);

@interface ShenzhenMacDelegate (SPDFMacToolEnvironment)
// The controlled environment for an external tool launch. Every NSTask that
// runs a tool goes through this, and it is also where a machine still on its
// own copies is put on the path to the virtualenv.
- (NSDictionary<NSString*, NSString*>*)taskEnvironmentWithToolPaths:(NSArray<NSString*>*)toolPaths;
- (NSDictionary<NSString*, NSString*>*)taskEnvironmentWithToolPaths:(NSArray<NSString*>*)toolPaths
                                                              extra:(NSDictionary<NSString*, NSString*>*)extra;
@end
