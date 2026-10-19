/* spdf_win_about_version.h — the one place the Windows build says what version
 * it is.
 *
 * Read by three consumers that must never disagree: the About box
 * (spdf_win_about.cpp), the updater's "am I older than the release?" compare
 * (spdf_win_updater_ui.cpp) and the exe's VERSIONINFO resource
 * (portable/win/spdf_win.rc, which rc.exe preprocesses with these defines).
 * A version string that lives in three files is a version string that will
 * one day be bumped in two of them, and the updater would then either offer
 * the build the user already runs or refuse the one it should take.
 *
 * KEEP IN STEP WITH the other frontends' single sources of truth, which the
 * release pipeline bumps together: portable/linux/gtk4/spdf_app.h
 * SPDF_APP_VERSION / SPDF_APP_BUILD, portable/mac/Info.plist
 * CFBundleShortVersionString / CFBundleVersion, portable/Makefile MAC_VERSION /
 * MAC_BUILD. The release tag is "<version>-<build>", e.g. 26.9.2-1, and that
 * is exactly what SPDF_WIN_RELEASE_TAG spells, because the updater compares
 * the running identity against GitHub's tag_name with all four numeric fields
 * (spdf_win_updater_versions_match_release_target).
 *
 * Pure preprocessor: rc.exe and cl.exe both read it, so nothing but #define
 * lines and comments may appear here. */
#ifndef SPDF_WIN_ABOUT_VERSION_H
#define SPDF_WIN_ABOUT_VERSION_H

/* YY.M.D of the release; the numeric parts feed VERSIONINFO, which wants four
 * 16-bit integers, so the build is the fourth. */
#define SPDF_WIN_VERSION_YEAR 26
#define SPDF_WIN_VERSION_MONTH 9
#define SPDF_WIN_VERSION_DAY 2
#define SPDF_WIN_VERSION_BUILD 1

#define SPDF_WIN_VERSION_STR "26.9.2"
#define SPDF_WIN_BUILD_STR "1"
/* Spelled out rather than pasted from the two above because rc.exe does not
 * concatenate adjacent string literals inside a VERSIONINFO VALUE; about_test.c
 * checks the three agree. */
#define SPDF_WIN_RELEASE_TAG "26.9.2-1"
#define SPDF_WIN_FILE_VERSION_STR "26.9.2.1"

/* Identity strings shared by the resource script, the shell registration and
 * the taskbar. The ProgID is what HKCU\Software\Classes and the .pdf
 * OpenWithProgids list carry (spdf_win_assoc.h); the AppUserModelID is what
 * groups the app's windows on the taskbar under one icon. */
#define SPDF_WIN_PRODUCT_NAME "Shenzhen PDF"
#define SPDF_WIN_COMPANY_NAME "Casimir Engineering"
#define SPDF_WIN_COPYRIGHT "Copyright (c) Casimir Engineering. GNU AGPL v3 (SumatraPDF lineage)."
#define SPDF_WIN_EXE_NAME "ShenzhenPDF.exe"
#define SPDF_WIN_PROGID "ShenzhenPDF.Document"
#define SPDF_WIN_APP_USER_MODEL_ID "CasimirEngineering.ShenzhenPDF"

/* Resource ids. 1 for the icon because Explorer and the taskbar take the
 * lowest-numbered icon group as the exe's icon; 1 for the manifest because
 * CREATEPROCESS_MANIFEST_RESOURCE_ID is 1. */
#define SPDF_WIN_RES_ICON_APP 1
#define SPDF_WIN_RES_MANIFEST 1

#endif /* SPDF_WIN_ABOUT_VERSION_H */
