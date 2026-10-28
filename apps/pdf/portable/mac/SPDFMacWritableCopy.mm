// Editing a PDF that cannot be written where it is used to stop and ask for a Save As location ("Save a writable copy
// before adding a comment?"). Every change in ShenzhenPDF is saved as it is made, with no question, so this one is
// too: the document is copied into the app's own storage ("Edited Copies" in the state folder, one folder per copy so
// the file keeps its name), every tab showing it follows the copy as after a rename, and the edit is saved there. The
// original stays untouched where it was; with Collection on, the copy is captured with its history like any document
// the reader opens.
#import "SPDFMacWritableCopy.h"
#include <sys/stat.h>

@interface ShenzhenMacDelegate (SPDFMacWritableCopyHost)
- (NSString*)pathForStateFile:(NSString*)name;
- (void)rememberActiveTabState;
- (void)loadSelectedTab;
- (void)adoptRenamedDocumentFrom:(NSString*)source to:(NSString*)destination replacingReadOnly:(BOOL)copy;
- (BOOL)activePDFNeedsSaveAsBeforeModificationWithReason:(NSString**)reasonOut;
- (BOOL)collectionProtectPath:(NSString*)path operation:(NSString*)operation;
- (void)showError:(NSString*)message detail:(NSString*)detail;
@end

@implementation ShenzhenMacDelegate (SPDFMacWritableCopy)

- (BOOL)moveActivePDFToWritableCopyForOperation:(NSString*)operation {
    SPDFDocumentTab* tab = [self selectedTab];
    NSString* source = [_path copy];
    if (!tab || !source.length) return NO;
    // A read-only source is read through its private shadow copy (the same bytes); never prompt for the original.
    NSString* readPath = _workingPath.length ? _workingPath : source;
    NSString* folder = [[self pathForStateFile:@"Edited Copies"] stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString* destination = [folder stringByAppendingPathComponent:source.lastPathComponent];
    NSFileManager* files = NSFileManager.defaultManager;
    NSError* error = nil;
    if (![files createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:&error] ||
        ![files copyItemAtPath:readPath toPath:destination error:&error]) {
        [self showError:@"Could not keep this change" detail:error.localizedDescription ?: @"The copy could not be made."];
        return NO;
    }
    // A copy of a read-only file is read-only too.
    chmod(destination.fileSystemRepresentation, 0644);
    [self rememberActiveTabState];
    [self adoptRenamedDocumentFrom:source to:destination replacingReadOnly:YES];
    [self discardCachedRuntimeForTab:tab];
    [self loadSelectedTab];
    if (![_path isEqual:destination] || [self activePDFNeedsSaveAsBeforeModificationWithReason:NULL]) return NO;
    return [self collectionProtectPath:_path operation:operation];
}

@end
