// When the save Fill & Sign and Annotate owe a PDF (SPDFMacFillSaving.mm) can't go into its file.
//
// The file changed underneath. Another app replaced, grew or cut the file after it was read here, or it went. The
// owed save is an increment: only the changed objects, and where everything else is in the file as it was read.
// Appended to the other app's file it would make a damaged PDF and bury that app's change. So the whole document, with
// the changes, is written to a new file in the app's own storage ("Edited Copies", as for a file that can't be changed:
// SPDFMacWritableCopy.mm), the tab follows it as after a rename, and the person is told. The file keeps the other
// app's version.
//
// The save fails (the file made read-only, its folder unwritable, the disk gone). While the document is open the
// person is told once and the save stays owed, tried again by the next change, by leaving the document and by quitting
// (SPDFMacFillSaving.mm). Still failing when the document closes (spdf_close calls the hook below), the changes are
// written to a copy the same way, opened in a new tab, and the person is told. While quitting nobody can be told any
// more: the copy is kept in Edited Copies and its path goes to stderr.
#import "SPDFMacFillSaveCopy.h"

#import "SPDFMacPaletteActivation.h"
#import "SPDFMacQuitFinishing.h"
#import "SPDFMacStateDirectory.h"

#include "spdf_deferred_save.h"

#include <string.h>
#include <sys/xattr.h>

@interface ShenzhenMacDelegate (SPDFMacFillSaveCopyHost)
- (NSInteger)indexOfTabForPath:(NSString*)path;
- (void)discardCachedRuntimeForTab:(SPDFDocumentTab*)tab;
- (void)loadSelectedTab;
- (void)openPaths:(NSArray<NSString*>*)paths;
- (void)adoptRenamedDocumentFrom:(NSString*)source to:(NSString*)destination replacingReadOnly:(BOOL)copy;
- (void)showError:(NSString*)message detail:(NSString*)detail;
@end

// Marks a copy made because the original changed elsewhere, so its palette line says so (SPDFAnnotateChangedCopyNote).
static const char* const kSPDFChangedCopyAttribute = "com.intuition.shenzhenpdf.original-changed";

BOOL SPDFFillIsCopyOfChangedFile(NSString* path) {
    return path.length && getxattr(path.fileSystemRepresentation, kSPDFChangedCopyAttribute, NULL, 0, 0, 0) >= 0;
}

// The whole document with its owed changes, in a folder of its own in Edited Copies under the original's name; the
// copy's path, or nil with *error. Runs on the thread that has the document.
static NSString* SPDFFillKeepInCopy(spdf_document* doc, NSString* original, BOOL changed, NSString** error) {
    NSString* folder = [[SPDFMacStateDirectoryPath() stringByAppendingPathComponent:@"Edited Copies"]
        stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString* name = original.lastPathComponent.length ? original.lastPathComponent : @"Document.pdf";
    NSString* copy = [folder stringByAppendingPathComponent:name];
    NSError* made = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil
                                                       error:&made]) {
        if (error) *error = made.localizedDescription ?: @"The copy could not be made.";
        return nil;
    }
    char err[1024] = {0};
    if (!spdf_save_deferred_copy(doc, copy.fileSystemRepresentation, err, sizeof(err))) {
        if (error) *error = err[0] ? @(err) : @"The copy could not be written.";
        [NSFileManager.defaultManager removeItemAtPath:folder error:nil];  // the empty folder made just now
        return nil;
    }
    if (changed) setxattr(copy.fileSystemRepresentation, kSPDFChangedCopyAttribute, "1", 1, 0, 0);
    return copy;
}

static NSString* SPDFFillChangedTitle(NSString* original) {
    return [NSString stringWithFormat:@"“%@” was changed by another app", original.lastPathComponent];
}

static ShenzhenMacDelegate* SPDFFillSaveCopyReader(void) {
    id delegate = NSApp.delegate;
    if ([delegate isKindOfClass:ShenzhenMacDelegate.class]) return delegate;
    return SPDFMacAllWindowControllers().firstObject;
}

// spdf_close's hook: the owed save still failed as the document closed.
static void SPDFFillSaveFailedAtClose(spdf_document* doc, const char* path, const char* err) {
    @autoreleasepool {
        NSString* original = path ? @(path) : @"";
        BOOL changed = err && !strcmp(err, SPDF_FILE_CHANGED_ELSEWHERE);
        NSString* reason = err && *err ? @(err) : @"The file couldn't be written.";
        NSString* copyError = nil;
        NSString* copy = SPDFFillKeepInCopy(doc, original, changed, &copyError);
        fprintf(stderr, "ShenzhenPDF: a change could not be saved to %s: %s; %s %s\n", original.UTF8String,
                reason.UTF8String, copy ? "kept in" : "no copy either:", (copy ?: copyError ?: @"").UTF8String);
        if (spdf_mac_quit_finishing()) return;  // the windows are gone: the copy waits in Edited Copies
        dispatch_async(dispatch_get_main_queue(), ^{
            ShenzhenMacDelegate* reader = SPDFFillSaveCopyReader();
            if (!reader || spdf_mac_quit_finishing()) return;
            if (copy) [reader openPaths:@[ copy ]];
            NSString* title = changed ? SPDFFillChangedTitle(original)
                                      : [NSString stringWithFormat:@"Couldn't save your latest changes to “%@”",
                                                                   original.lastPathComponent];
            NSString* detail;
            if (!copy)
                detail = [NSString stringWithFormat:@"%@\n\nA copy with them couldn't be made either: %@", reason, copyError];
            else if (changed)
                detail = @"It changed while you were annotating it, so your latest changes were saved in a copy instead, "
                         @"now open in a new tab. The file keeps the other app's version.";
            else
                detail = [NSString stringWithFormat:@"%@\n\nThey were kept in a copy, now open in a new tab. Choose "
                                                    @"File ▸ Save As… to put it where you want.", reason];
            [reader showError:title detail:detail];
        });
    }
}

void SPDFFillSaveCopyInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ spdf_core_set_save_failed_hook(SPDFFillSaveFailedAtClose); });
}

@implementation ShenzhenMacDelegate (SPDFMacFillSaveCopy)

- (BOOL)fillKeepChangesOfChangedFile:(spdf_document*)doc {
    NSString* original = [_path copy];
    NSString* error = nil;
    NSString* copy = SPDFFillKeepInCopy(doc, original, YES, &error);
    if (!copy) {
        [self showError:SPDFFillChangedTitle(original)
                 detail:[NSString stringWithFormat:@"It changed while you were annotating it, so your changes can't go "
                                                   @"into it, and a copy with them couldn't be made: %@\n\nYour changes "
                                                   @"are still here; ShenzhenPDF tries again with your next change.",
                                                   error]];
        return NO;
    }
    // Out of the save (which may run inside leaving the document, or a reload after the change on disk): the tab
    // follows the copy, then the person is told.
    __weak ShenzhenMacDelegate* weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf fillFollowCopy:copy of:original]; });
    return YES;
}

- (void)fillFollowCopy:(NSString*)copy of:(NSString*)original {
    if (spdf_mac_quit_finishing()) return;
    if ([self indexOfTabForPath:original] >= 0) {
        [self adoptRenamedDocumentFrom:original to:copy replacingReadOnly:YES];
        NSInteger index = [self indexOfTabForPath:copy];
        SPDFDocumentTab* tab = index >= 0 && index < (NSInteger)_tabs.count ? _tabs[(NSUInteger)index] : nil;
        if (tab) [self discardCachedRuntimeForTab:tab];  // it was the document read from the other app's file
        if (tab && tab == [self selectedTab]) [self loadSelectedTab];
    } else {
        [self openPaths:@[ copy ]];
    }
    [self showError:SPDFFillChangedTitle(original)
             detail:@"It changed while you were annotating it, so your changes were saved in a copy instead, which is "
                    @"open now. The file keeps the other app's version. Choose File ▸ Save As… to put "
                    @"the copy where you want."];
}

@end
