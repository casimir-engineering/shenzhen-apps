#import "SPDFMacDocumentRename.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacCollectionIntegration.h"
#import "SPDFMacCollectionReaderNavigation.h"
#import "SPDFMacCollectionStore.h"
#import "SPDFMacCollectionTabIdentity.h"
#import "SPDFMacTabGroups.h"
#import "SPDFMacImageSave.h"
#import "SPDFMacSupport.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <sys/stat.h>

@interface ShenzhenMacDelegate (DocumentRenameHost)
- (void)refreshSidebarWorkspacePanel;
- (void)rememberActiveTabState;
- (void)repointActiveFileWatcher;
- (void)deleteReadOnlyCopyIfUnsharedForTab:(SPDFDocumentTab*)tab;
- (NSString*)pathForStateFile:(NSString*)name;
@end
@implementation ShenzhenMacDelegate (DocumentRename)
- (void)showDisplayName:(NSString*)name forTabsAtPath:(NSString*)path {
    NSString* shown=name.length ? name : nil;
    for (SPDFDocumentTab* open in _tabs) if ([open.path isEqual:path]) open.displayName=shown;
    [self updateTabStrip]; [self updateControls]; [self refreshSidebarWorkspacePanel]; [self savePersistentState];
}
- (void)adoptRenamedDocumentFrom:(NSString*)source to:(NSString*)destination replacingReadOnly:(BOOL)copy {
    [self rememberActiveTabState];
    for (SPDFDocumentTab* open in _tabs) if ([open.path isEqual:source]) {
        // The file now has the name the person chose, so it shows that name again rather than an older given one.
        if (open.displayName.length) {
            open.displayName=nil;
            NSString* identifier=open.collectionHistoryDocumentID;
            if (identifier.length) [SPDFMacCollectionStore.defaultStore setDisplayName:nil documentID:identifier expectedName:nil error:nil];
        }
        if (copy) {
            [self deleteReadOnlyCopyIfUnsharedForTab:open];
            open.readOnly=NO; open.workingPath=nil; open.readOnlyCopyBinding=nil;
            open.copiedSourceFileSize=0; open.copiedSourceModificationDate=nil;
        }
        // The title every open and relaunch gives a tab (it kept the extension here, so it changed on relaunch).
        open.path=destination; open.title=spdf_display_name_for_path(destination);
        [open.cachedMarkdownSession relocateDocumentToURL:[NSURL fileURLWithPath:destination]];
        if ([open.group.lastUsedPath isEqual:source]) open.group.lastUsedPath=destination;
        NSDictionary* attributes=[self fileAttributesForPath:destination];
        if (attributes) [self recordFileAttributes:attributes forTab:open];
    }
    if ([_path isEqual:source]) { _path=[destination copy]; if (copy || [_workingPath isEqual:source]) _workingPath=[destination copy]; }
    [_recentlyOpenedPaths removeObject:source]; [self rememberRecentlyOpenedPath:destination];
    [self repointActiveFileWatcher]; [self updateTabStrip]; [self updateControls]; [self savePersistentState];
}
// A document that cannot be renamed where it is (read-only file or folder) is renamed into a writable copy in the
// app's own storage, without a Save As question: the copy takes the new name, its tabs follow it, and its Collection
// history moves with it. The original stays where it was.
- (void)renameIntoWritableCopyFromPath:(NSString*)source name:(NSString*)name {
    NSInteger index=[self indexOfTabForPath:source]; if (index<0) return;
    SPDFDocumentTab* tab=self->_tabs[(NSUInteger)index];
    NSString* readPath=tab.workingPath.length ? tab.workingPath : source;
    NSString* folder=[[self pathForStateFile:@"Edited Copies"] stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString* destination=[folder stringByAppendingPathComponent:name.length ? name : source.lastPathComponent];
    NSDictionary* expected=SPDFImageSaveDestinationIdentity(destination);
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        NSError* error=nil;
        BOOL saved=SPDFSaveImageCopy(readPath,destination,NO,&error,expected);
        if (saved) chmod(destination.fileSystemRepresentation,0644);
        if (saved) {
            SPDFMacCollectionStore* store=SPDFMacCollectionStore.defaultStore;
            NSString* identifier=[store documentForPath:source][@"id"];
            if (identifier) saved=[store rebaseDocumentID:identifier toPath:destination forgettingPath:source error:&error];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!saved) { [self showError:@"Could not rename document" detail:error.localizedDescription ?: @"The original tab and Collection link were kept."]; return; }
            [self adoptRenamedDocumentFrom:source to:destination replacingReadOnly:YES];
            [self collectionRefreshHistory];
        });
    });
}
- (void)renameDocumentFromTab:(NSMenuItem*)sender {
    NSString* source=[sender.representedObject isKindOfClass:NSString.class] ? sender.representedObject : nil;
    NSInteger index=source ? [self indexOfTabForPath:source] : -1;
    if (index<0) return;
    SPDFDocumentTab* tab=_tabs[(NSUInteger)index];
    if (tab.missingFile || tab.unsavedPastedImage) return;
    BOOL collection = [source.pathComponents containsObject:@"editable"] &&
        [SPDFMacCollectionStore.defaultStore editableInfoForPath:source] != nil;
    BOOL writable=!tab.readOnly && [NSFileManager.defaultManager isWritableFileAtPath:source] &&
        [NSFileManager.defaultManager isWritableFileAtPath:source.stringByDeletingLastPathComponent];
    NSAlert* alert=[NSAlert new]; alert.messageText=@"Rename Document";
    alert.informativeText=@"The file will be renamed in its current folder. Its format and version history will be preserved.";
    if (collection) { alert.messageText=@"Rename in Collection"; alert.informativeText=@"Rename this Collection document. Its history and original source reference will be preserved."; }
    [alert addButtonWithTitle:@"Rename"]; [alert addButtonWithTitle:@"Cancel"];
    NSTextField* field=[[NSTextField alloc] initWithFrame:NSMakeRect(0,0,360,24)];
    field.stringValue=source.lastPathComponent.stringByDeletingPathExtension;
    alert.accessoryView=field; alert.window.initialFirstResponder=field;
    [alert beginSheetModalForWindow:_window completionHandler:^(NSModalResponse response) {
        if (response!=NSAlertFirstButtonReturn) return;
        NSString* destination=SPDFDocumentRenameDestination(source,field.stringValue);
        if (!destination) { [self showError:@"Invalid document name" detail:@"Enter a filename without slashes or colons."]; return; }
        if ([source isEqual:destination]) return;
        if ([self indexOfTabForPath:source]<0) return;
        if (!writable && !collection) { [self renameIntoWritableCopyFromPath:source name:destination.lastPathComponent]; return; }
        NSError* error=nil;
        if (collection) {
            NSURL* renamed=[SPDFMacCollectionStore.defaultStore renameEditablePath:source filename:destination.lastPathComponent error:&error];
            if (!renamed) { [self showError:@"Could not rename document" detail:error.localizedDescription]; return; }
            [self adoptRenamedDocumentFrom:source to:renamed.path replacingReadOnly:NO];
            [self collectionSetVersionInfo:[SPDFMacCollectionStore.defaultStore editableInfoForPath:renamed.path] forTab:tab];
            [self collectionRefreshHistory]; return;
        }
        if (!SPDFRenameDocumentFile(source,destination,&error)) {
            NSError* cause=error.userInfo[NSUnderlyingErrorKey];
            if (error.code==NSFileWriteNoPermissionError ||
                ([cause.domain isEqual:NSPOSIXErrorDomain] && (cause.code==EACCES || cause.code==EPERM || cause.code==EROFS)))
                [self renameIntoWritableCopyFromPath:source name:destination.lastPathComponent];
            else [self showError:@"Could not rename document" detail:error.localizedDescription];
            return;
        }
        [self adoptRenamedDocumentFrom:source to:destination replacingReadOnly:NO];
        // Relinking verifies bytes; large documents must not stall the rename UI.
        static dispatch_queue_t relinks; static dispatch_once_t once;
        dispatch_once(&once, ^{ relinks=dispatch_queue_create("com.shenzhenpdf.rename-history",DISPATCH_QUEUE_SERIAL); });
        dispatch_async(relinks, ^{
            SPDFMacCollectionStore* store=SPDFMacCollectionStore.defaultStore;
            NSString* identifier=[store documentForPath:source][@"id"];
            NSError* linkError=nil;
            BOOL linked=!identifier || [store linkDocumentID:identifier toPath:destination allowMismatch:YES error:&linkError];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self collectionRefreshHistory];
                if (!linked) [self showError:@"Document renamed; history link needs attention" detail:linkError.localizedDescription];
            });
        });
    }];
    [field selectText:nil];
}
@end
