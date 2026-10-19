/* The one line that makes the chapter list's folds survive a relaunch: hands
 * spdf_win_chapter_state's three functions to the content provider as its
 * SpdfWinChapterStore (spdf_win_chrome_content.h explains the seam).
 *
 * A unit of its own, and a static initialiser rather than a call from the
 * app's main, so that LINKED MEANS REMEMBERED with nothing else knowing:
 * build-native.cmd discovers every unit under portable/win/src, so the app
 * always has the store; a test that links the provider without this file (the
 * painter pixel tests) folds for the session only and touches no file, and a
 * test that links the state module without the provider
 * (sidebar_outline_test.c) does not drag the provider in. The registration
 * unit is the only one that needs both. The app could own this line in its
 * main instead; this change's report offers it. */
#include "spdf_win_chapter_state.h"
#include "spdf_win_chrome_content.h"

namespace {
const SpdfWinChapterStore kStore = {spdf_win_chapter_state_load, spdf_win_chapter_state_save,
                                    spdf_win_chapter_state_free_keys};
struct RegisterStore {
    RegisterStore() { spdf_win_chrome_content_set_chapter_store(&kStore); }
} g_register_store;
} /* namespace */
