// Documents from another app's folder (WeChat, Mail, Messages, Safari): the reader works on its own copy
// (SPDFMacOtherAppFiles.h), so macOS asks about the other app's data only while the person looks at such a document.
//   - Opened (handed over by the other app, dropped, chosen in Open...): the copy is made at once, while the open
//     itself gives access, and the tab shows the copy.
//   - Restored from an older session that pointed into the other app's folder: the tab moves to the copy without
//     touching the original, made from the private copy an earlier version kept when there is one.
//   - Shown: a copy on disk is drawn first; then, once per run, the original is checked for a newer version in the
//     background (macOS may ask then; the person is already reading). Without a copy, showing the tab is the one
//     moment the original is read; when it cannot be, the tab says where the document is and how to get it here.
#import "SPDFMacDelegatePrivate.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacOtherAppFiles.h"
#import "SPDFMacSupport.h"
#import "SPDFMacTabGroups.h"
#import "SPDFMacTabViewState.h"
#include <sys/stat.h>

@interface ShenzhenMacDelegate (SPDFMacOtherAppFilesHost)
- (SPDFDocumentTab*)selectedTab;
- (void)loadSelectedTab;
- (void)updateTabStrip;
@end

@implementation ShenzhenMacDelegate (SPDFMacOtherAppFiles)

- (NSArray<NSString*>*)otherAppReaderPathsForPaths:(NSArray<NSString*>*)paths {
    NSMutableArray* result = [NSMutableArray arrayWithCapacity:paths.count];
    for (NSString* path in paths) {
        if (![path isKindOfClass:NSString.class] || !SPDFOtherAppContainerOfPath(path)) {
            [result addObject:path];
            continue;
        }
        NSString* copy = SPDFOtherAppCopyPathForSource(path);
        SPDFOtherAppNoteUnreadable(path, NO); // opened again: it may be read again
        BOOL read = SPDFOtherAppRefreshCopy(path, copy, YES, NULL, NULL);
        SPDFOtherAppNoteUnreadable(path, !read);
        if (read) SPDFOtherAppClaimUpdateCheck(path); // just read; no second look this run
        struct stat info;
        BOOL held = lstat(copy.fileSystemRepresentation, &info) == 0;
        if (held && !SPDFOtherAppSourceOfCopy(copy)) SPDFOtherAppRecordSource(path, copy, nil);
        // Without a copy the original stays: the open reports what is wrong with it, as for any document.
        [result addObject:held ? copy : path];
    }
    return result;
}

// A tab that still points into another app's folder (a session from an earlier version) moves to the copy. Nothing
// in the other app's folder is touched: the copy comes from the private copy that version kept, if any.
- (SPDFDocumentTab*)otherAppMigrateTab:(SPDFDocumentTab*)tab {
    NSString* source = tab.path;
    if (!source.length || !SPDFOtherAppContainerOfPathSpelling(source)) return tab;
    NSString* copy = SPDFOtherAppCopyPathForSource(source);
    NSFileManager* files = NSFileManager.defaultManager;
    struct stat info;
    if (lstat(copy.fileSystemRepresentation, &info) != 0) {
        NSString* held = tab.workingPath;
        NSDictionary* fingerprint = tab.readOnlyCopyBinding[@"source"];
        if (held.length && !SPDFOtherAppContainerOfPathSpelling(held) && lstat(held.fileSystemRepresentation, &info) == 0) {
            [files createDirectoryAtPath:copy.stringByDeletingLastPathComponent withIntermediateDirectories:YES
                              attributes:nil error:nil];
            // Fresh bytes, as for any copy (SPDFOtherAppRefreshCopy): no file attributes carried over.
            if (![[NSData dataWithContentsOfFile:held] writeToFile:copy atomically:YES]) fingerprint = nil;
        } else {
            fingerprint = nil;
        }
        SPDFOtherAppRecordSource(source, copy, fingerprint);
    } else if (!SPDFOtherAppSourceOfCopy(copy)) {
        SPDFOtherAppRecordSource(source, copy, nil);
    }
    if ([tab.group.lastUsedPath isEqual:source]) tab.group.lastUsedPath = copy;
    tab.path = copy;
    tab.readOnly = NO;
    tab.workingPath = nil;
    tab.readOnlyCopyBinding = nil;
    tab.copiedSourceFileSize = 0;
    tab.copiedSourceModificationDate = nil;
    return tab;
}

// Called by -loadSelectedTab once the previous document is put away. YES when this tab shows a message instead.
- (BOOL)otherAppShowsMessageForSelectedTab:(SPDFDocumentTab*)tab {
    NSString* copy = tab.path;
    NSString* source = SPDFOtherAppSourceOfCopy(copy);
    if (!source) return NO;
    struct stat info;
    if (lstat(copy.fileSystemRepresentation, &info) == 0) {
        [self otherAppLookForNewerOriginal:source copy:copy];
        return NO;
    }
    if (SPDFOtherAppIsUnreadable(source)) {
        [self otherAppShowMessage:SPDFOtherAppUnavailableMessage(source) forTab:tab];
        return YES;
    }
    [self otherAppShowMessage:@"Opening…" forTab:tab];
    __weak ShenzhenMacDelegate* weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL read = SPDFOtherAppRefreshCopy(source, copy, NO, NULL, NULL);
        dispatch_async(dispatch_get_main_queue(), ^{
            SPDFOtherAppNoteUnreadable(source, !read);
            if (read) SPDFOtherAppClaimUpdateCheck(source);
            ShenzhenMacDelegate* reader = weakSelf;
            if (reader && [reader selectedTab] == tab && [tab.path isEqual:copy]) [reader loadSelectedTab];
        });
    });
    return YES;
}

// The copy is on screen; the original may have changed since. Looked at once per run, after this display, in the
// background: macOS may ask the person now. Refused or gone, the copy simply stays.
- (void)otherAppLookForNewerOriginal:(NSString*)source copy:(NSString*)copy {
    if (SPDFOtherAppIsUnreadable(source) || !SPDFOtherAppClaimUpdateCheck(source)) return;
    __weak ShenzhenMacDelegate* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            BOOL changed = NO;
            BOOL read = SPDFOtherAppRefreshCopy(source, copy, YES, &changed, NULL);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!read) SPDFOtherAppNoteUnreadable(source, YES);
                ShenzhenMacDelegate* reader = weakSelf;
                if (changed && [[reader selectedTab].path isEqual:copy]) [reader reloadSelectedTabFromDiskChange];
            });
        });
    });
}

- (void)otherAppShowMessage:(NSString*)message forTab:(SPDFDocumentTab*)tab {
    tab.missingFile = NO;
    tab.missingMessage = message;
    [self discardCachedRuntimeForTab:tab];
    _doc = NULL;
    [self clearActiveMetadata];
    [self prepareSelectedTabViewState:tab path:tab.path];
    _pageIndex = 0;
    _renderGeneration++;
    [_renderedPages removeAllObjects];
    [self replaceDocumentViewForTabSwitch];
    [self rebuildSidebar];
    [self showEmptyDocumentViewWithMessage:message];
    NSString* name = [self displayNameForPathConsideringOpenTabs:tab.path];
    _window.title = [NSString stringWithFormat:@"%@ - Shenzhen PDF", name];
    _statusLabel.stringValue = [message stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    [self updateTabStrip];
    [self updateControls];
    [self teardownActiveFileWatcher];
}

@end
