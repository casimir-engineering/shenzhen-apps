#pragma once
#import <Foundation/Foundation.h>
#include <pwd.h>
#include <stdlib.h>
#include <unistd.h>

// Documents kept in another app's data: ~/Library/Containers/<app>/ and ~/Library/Group Containers/<group>/ (WeChat,
// Mail and Messages downloads, Safari's PDFs). macOS asks the person before ShenzhenPDF touches anything there ("would
// like to access data from other apps"), even a stat. So a document handed over from such a folder is copied at once
// into ShenzhenPDF's own folder, under the same name, and every tab, recent item, Collection entry, szpdf answer and
// Friends send refers to that copy. The original is only reached while the person is looking at the document: to make
// the copy, or to bring the copy up to date once it is on screen (SPDFMacOtherAppFilesIntegration.mm).

// Whether `path` lies in another app's container, by its spelling alone: nothing on disk is consulted. Comparison is
// case-insensitive (APFS); the home folder is matched as written, as $HOME and as its resolved path. ShenzhenPDF's own
// containers do not count. Use this guard in any code that would touch a remembered path without being asked to.
static inline NSString* SPDFOtherAppContainerOfPathSpelling(NSString* path) {
    static NSArray<NSString*>* roots;
    static NSString* own;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableOrderedSet<NSString*>* homes = [NSMutableOrderedSet orderedSet];
        const struct passwd* user = getpwuid(getuid());
        for (NSString* home in @[ NSHomeDirectory() ?: @"", @(getenv("HOME") ?: ""), @(getenv("CFFIXED_USER_HOME") ?: ""),
                                  user && user->pw_dir ? @(user->pw_dir) : @"" ]) {
            if (![home hasPrefix:@"/"]) continue;
            [homes addObject:home];
            char resolved[PATH_MAX];
            if (realpath(home.fileSystemRepresentation, resolved)) [homes addObject:@(resolved)];
        }
        for (NSString* home in homes.array) // /private/var/... is also spelled /var/...
            if ([home hasPrefix:@"/private/"]) [homes addObject:[home substringFromIndex:8]];
        NSMutableArray* list = [NSMutableArray array];
        for (NSString* home in homes)
            for (NSString* folder in @[ @"Library/Containers/", @"Library/Group Containers/" ])
                [list addObject:[[home stringByAppendingPathComponent:folder] stringByAppendingString:@"/"].lowercaseString];
        roots = [list copy];
        own = (NSBundle.mainBundle.bundleIdentifier ?: @"com.intuition.shenzhenpdf").lowercaseString;
    });
    if (![path isKindOfClass:NSString.class] || ![path hasPrefix:@"/"]) return nil;
    NSString* normal = path;
    if ([normal.lowercaseString hasPrefix:@"/system/volumes/data/"]) normal = [normal substringFromIndex:20];
    while ([normal rangeOfString:@"//"].location != NSNotFound)
        normal = [normal stringByReplacingOccurrencesOfString:@"//" withString:@"/"];
    NSString* spelled = normal.lowercaseString;
    for (NSString* root in roots) {
        if (![spelled hasPrefix:root]) continue;
        NSString* rest = [spelled.length == normal.length ? normal : spelled substringFromIndex:root.length];
        NSString* container = [rest componentsSeparatedByString:@"/"].firstObject;
        NSString* lower = container.lowercaseString;
        if (!container.length || [container isEqual:@"."] || [container isEqual:@".."]) return nil;
        if ([lower isEqual:own] || [lower hasSuffix:[@"." stringByAppendingString:own]]) return nil;
        return container;
    }
    return nil;
}

// The same, also following symbolic links on the way (only outside the containers: a link that leads into one is
// noticed without stepping in). For the moment a document is opened, where a link may hide where it really is.
NSString* SPDFOtherAppContainerOfPath(NSString* path);

// The app people know the container by ("WeChat" for com.tencent.xinWeChat), or nil when it is not installed.
NSString* SPDFOtherAppNameForContainer(NSString* container);

// What a tab shows when the original cannot be read and no copy exists, written for the person reading it.
NSString* SPDFOtherAppUnavailableMessage(NSString* source);

// ShenzhenPDF's copy of `source`: <state>/Documents from other apps/<id>/<same file name>. A path only.
NSString* SPDFOtherAppCopyPathForSource(NSString* source);

// The folder all such copies live in (treated like a temporary folder: changes are saved elsewhere).
NSString* SPDFOtherAppCopiesFolder(void);

// The original `copyPath` stands for, when it is such a copy (whether or not the copy exists yet). Reads only
// ShenzhenPDF's own folder.
NSString* SPDFOtherAppSourceOfCopy(NSString* copyPath);

// Notes which original a copy stands for, before the copy exists or when it was made from bytes already held.
// `fingerprint` (size, mtime, as SPDFReadOnlyFileFingerprint) is what the copy reflects, when known.
BOOL SPDFOtherAppRecordSource(NSString* source, NSString* copyPath, NSDictionary* fingerprint);

// Reads the original now and writes the copy with fresh bytes (none of the other app's file attributes, which would
// make macOS ask again for the copy). macOS may ask the person first: call it only when they opened the document or
// are looking at it, and off the main thread when they are already reading. With `onlyWhenChanged`, an original whose
// size and date match what the copy reflects is not read again. `changed` says whether the copy was (re)written.
BOOL SPDFOtherAppRefreshCopy(NSString* source, NSString* copyPath, BOOL onlyWhenChanged, BOOL* changed, NSError** error);

// For this run of the app: the originals that could not be read (asked again only after the person opens the
// document again), and the originals already checked for a newer version.
void SPDFOtherAppNoteUnreadable(NSString* source, BOOL unreadable);
BOOL SPDFOtherAppIsUnreadable(NSString* source);
BOOL SPDFOtherAppClaimUpdateCheck(NSString* source);
