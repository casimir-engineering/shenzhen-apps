#import "SPDFMacAIIntegration.h"
#import "SPDFMacCollectionImportIntegration.h"
#import "SPDFMacCollectionIntegration.h"
#import "SPDFMacCollectionReaderNavigation.h"
#import "SPDFMacCollectionStore.h"
#import "SPDFMacCollectionAvailability.h"
#import "SPDFMacCollectionWindow.h"
#import "SPDFMacCollectionCompanion.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
#import <objc/runtime.h>
#import "SPDFMacTabGroups.h"
@interface ShenzhenMacDelegate (CollectionDisplayNameHost)
- (void)showDisplayName:(NSString*)name forTabsAtPath:(NSString*)path;  // SPDFMacDocumentRename.mm
@end
static char kCollectionCompanion, kCollectionImported, kCollectionSettingsObserver, kCollectionContinuity, kCollectionPendingSave;
@implementation ShenzhenMacDelegate (SPDFMacCollectionIntegration)
- (void)collectionAllowImportRetryAfterFailure {
    objc_setAssociatedObject(self,&kCollectionImported,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (void)collectionObserveSettings {
    if (objc_getAssociatedObject(self, &kCollectionSettingsObserver)) return;
    __weak ShenzhenMacDelegate* weakSelf = self;
    id observer = [NSNotificationCenter.defaultCenter addObserverForName:@"SPDFCollectionSettingsChanged" object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification* note) {
            if ([note.userInfo[@"storageLimitOnly"] boolValue]) return;
            ShenzhenMacDelegate* owner = weakSelf; if (!owner) return;
            objc_setAssociatedObject(owner, &kCollectionImported, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            for (SPDFDocumentTab* tab in owner->_tabs) [owner collectionDidOpenPath:tab.path];
        }];
    objc_setAssociatedObject(self, &kCollectionSettingsObserver, observer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (void)collectionRecordObservedChangeAtPath:(NSString*)path {
    SPDFMacCollectionStore* store = SPDFMacCollectionStore.defaultStore;
    if (!store.isEnabled) return;
    NSString* identifier = [store documentForPath:path][@"id"]; if (!identifier) return;
    NSMutableDictionary* pending = objc_getAssociatedObject(self, &kCollectionContinuity);
    if (!pending) { pending = [NSMutableDictionary dictionary]; objc_setAssociatedObject(self, &kCollectionContinuity, pending, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    pending[path] = identifier;
}
- (void)collectionClearObservedChangeAtPath:(NSString*)path {
    [objc_getAssociatedObject(self, &kCollectionContinuity) removeObjectForKey:path];
    [objc_getAssociatedObject(self, &kCollectionPendingSave) removeObjectForKey:path];
}
- (void)collectionDidSavePath:(NSString*)path {
    NSMutableDictionary* saves = objc_getAssociatedObject(self, &kCollectionPendingSave);
    NSString* identifier = saves[path]; [saves removeObjectForKey:path];
    if (identifier) {
        NSMutableDictionary* pending = objc_getAssociatedObject(self, &kCollectionContinuity);
        if (!pending) { pending = [NSMutableDictionary dictionary]; objc_setAssociatedObject(self, &kCollectionContinuity, pending, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
        pending[path] = identifier;
    }
    [self collectionDidOpenPath:path];
}
- (void)collectionRecordPendingSaveAtPath:(NSString*)path {
    SPDFMacCollectionStore* store = SPDFMacCollectionStore.defaultStore;
    NSMutableDictionary* saves = objc_getAssociatedObject(self, &kCollectionPendingSave);
    if (!saves) { saves = [NSMutableDictionary dictionary]; objc_setAssociatedObject(self, &kCollectionPendingSave, saves, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    NSString* identifier = store.isEnabled ? [store documentForPath:path][@"id"] : nil;
    if (identifier) saves[path] = identifier; else [saves removeObjectForKey:path];
}
- (void)collectionDidOpenPath:(NSString*)path {
    if (!path.length) return;
    [self collectionObserveSettings];
    // Only called after a document has opened. Neither main nor empty launch instantiates the store.
    NSString* source = [path copy];
    NSInteger sourceIndex = [self indexOfTabForPath:source];
    SPDFDocumentTab* openedTab = sourceIndex >= 0 ? _tabs[(NSUInteger)sourceIndex] : nil;
    NSDictionary* authorizedCopy = nil;
    BOOL unboundCopy = openedTab.readOnly && openedTab.workingPath.length && !openedTab.readOnlyCopyBinding.count;
    if (openedTab.readOnly && openedTab.workingPath.length && openedTab.readOnlyCopyBinding.count) {
        NSMutableDictionary* binding = [openedTab.readOnlyCopyBinding mutableCopy];
        binding[@"path"] = openedTab.workingPath; authorizedCopy = [binding copy];
    }
    NSMutableDictionary* pending = objc_getAssociatedObject(self, &kCollectionContinuity);
    NSString* continuingID = pending[source]; [pending removeObjectForKey:source];
    dispatch_async(dispatch_get_main_queue(), ^{
        SPDFMacCollectionStore* store = [SPDFMacCollectionStore defaultStore];
        if ([store isArchivePath:source]) {
            NSDictionary* info = [store archiveInfoForPath:source];
            if (openedTab && info) [self collectionConvertTab:openedTab path:source info:info];
            return;
        }
        NSDictionary* openedEditable=[store editableInfoForPath:source];
        if (openedEditable && [openedTab.path isEqual:source]) {
            openedTab.readOnly=NO; openedTab.collectionVersionLabel=nil;
            [self collectionSetVersionInfo:openedEditable forTab:openedTab];
        }
        NSString* choice = [store settings][@"choice"];
        if ([choice isEqual:@"unset"] || !choice.length) {
            [self showUnifiedSettings:nil];
            return;
        }
        if (!store.isEnabled) {
            [self collectionRecordUserOpenForPath:source document:[store documentForPath:source]];
            return;
        }
        if (!objc_getAssociatedObject(self, &kCollectionImported)) {
            objc_setAssociatedObject(self, &kCollectionImported, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [self collectionImportRecentDocuments];
        }
        // Legacy render caches remain readable during launch without a new
        // permission prompt. Their next actual consultation renews the binding.
        if (unboundCopy) {
            [self collectionRecordUserOpenForPath:source document:[store documentForPath:source]]; return;
        }
        NSUInteger userOpenCount = [self collectionConsumeUserOpenForPath:source];
        [store capturePath:source authorizedCopy:authorizedCopy reason:continuingID ? @"Observed save" : @"Opened"
            continuingDocumentID:continuingID userOpenCount:userOpenCount
            completion:^(NSDictionary* doc, NSError* error, BOOL userOpenCountRecorded) {
            // Reading succeeded even when capture was excluded or could not save a new version.
            if (!userOpenCountRecorded)
                [self collectionRecordUserOpenCount:userOpenCount document:doc ?: [store documentForPath:source]];
            NSDictionary* editable = [store editableInfoForPath:source];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (editable && [openedTab.path isEqual:source]) {
                    openedTab.readOnly = NO; openedTab.collectionVersionLabel = nil;
                    [self collectionSetVersionInfo:editable forTab:openedTab];
                }
                if (doc) {
                    if ([openedTab.path isEqual:source]) openedTab.collectionHistoryDocumentID=doc[@"id"];
                    // A name given in ShenzhenPDF to a file that keeps its own comes back with the document.
                    NSString* given=[doc[@"displayName"] isKindOfClass:NSString.class] ? doc[@"displayName"] : nil;
                    if (given.length && [openedTab.path isEqual:source] && !openedTab.displayName.length)
                        [self showDisplayName:given forTabsAtPath:source];
                    [self collectionRememberGroups];
                    [self collectionRememberPasswordForPath:source];
                }
                [self collectionRefreshVersionInfoForDocument:doc];
                if (![self->_path isEqual:source]) return;
                [self collectionRefreshHistory];
                if (error) self->_statusLabel.stringValue = [NSString stringWithFormat:@"Collection: copy failed — %@", error.localizedDescription];
            });
        }];
    });
}
- (BOOL)collectionProtectPath:(NSString*)path operation:(NSString*)operation {
    SPDFMacCollectionStore* store = [SPDFMacCollectionStore defaultStore];
    if ([store isArchivePath:path]) {
        [self showError:@"Collection copies are read-only" detail:@"Use Save a Copy to create a separate editable document."];
        return NO;
    }
    while (YES) {
        NSError* error = nil;
        NSString* continuingID = [objc_getAssociatedObject(self, &kCollectionContinuity) objectForKey:path];
        if ([store ensureProtectedPath:path reason:@"Before edit" continuingDocumentID:continuingID error:&error]) {
            [self collectionRecordPendingSaveAtPath:path];
            return YES;
        }
        NSAlert* alert = [[NSAlert alloc] init];
        alert.messageText = @"The current version is not protected yet";
        alert.informativeText = [NSString stringWithFormat:@"%@\n\nBefore %@, Collection needs a durable copy. Reading is still available.", error.localizedDescription, operation ?: @"editing"];
        [alert addButtonWithTitle:@"Retry"]; [alert addButtonWithTitle:@"Cancel Edit"];
        [alert addButtonWithTitle:@"Continue Without History"];
        NSModalResponse result = [alert runModal];
        if (result == NSAlertSecondButtonReturn) { [self collectionClearObservedChangeAtPath:path]; return NO; }
        if (result == NSAlertThirdButtonReturn) { [self collectionRecordPendingSaveAtPath:path]; return YES; }
    }
}
- (void)installCollectionSettingsMenu:(NSMenu*)menu {
    NSMenuItem* item = [menu addItemWithTitle:@"Collection…" action:@selector(showCollectionManager:) keyEquivalent:@""];
    item.target = self;
}
- (void)addCollectionItemsToTabMenu:(NSMenu*)menu path:(NSString*)path {
    [menu addItem:NSMenuItem.separatorItem];
    NSArray* titles = @[@"Previous Version", @"Version History", @"Locate Document…"];
    NSArray* actions = @[@"showCollectionPreviousVersion:", @"showCollectionHistory:", @"showCollectionRecovery:"];
    for (NSUInteger i = 0; i < titles.count; i++) {
        if (i==2) {
            NSDictionary* doc=[SPDFMacCollectionStore.defaultStore documentForPath:path] ?: [SPDFMacCollectionStore.defaultStore archiveInfoForPath:path][@"document"];
            if (doc ? SPDFCollectionOriginalAvailable(doc) : [NSFileManager.defaultManager fileExistsAtPath:path]) continue;
        }
        NSMenuItem* item = [menu addItemWithTitle:titles[i] action:NSSelectorFromString(actions[i]) keyEquivalent:@""];
        item.target = self; item.representedObject = path;
    }
}
- (NSString*)collectionPathForSender:(id)sender {
    return [sender respondsToSelector:@selector(representedObject)] && [[sender representedObject] isKindOfClass:NSString.class]
        ? [sender representedObject] : _path;
}
- (void)showCollectionManager:(id)sender { (void)sender; [self showCollectionManagerForQuery:nil]; }
- (void)showCollectionSettings:(id)sender {
    (void)sender; [self showCollectionManagerForQuery:nil];
    SPDFCollectionCompanionHost* companion=objc_getAssociatedObject(self,&kCollectionCompanion);
    NSError* error=nil;
    if (companion && ![companion showSettingsWithError:&error] && error) [_window presentError:error];
}
- (void)showCollectionManagerForQuery:(NSString*)query { [self showCollectionManagerForDocumentID:nil query:query]; }
- (void)showCollectionManagerForDocumentID:(NSString*)documentID query:(NSString*)query {
    [self collectionObserveSettings];
    SPDFCollectionCompanionHost* companion=objc_getAssociatedObject(self,&kCollectionCompanion);
    if (!companion) {
        __weak ShenzhenMacDelegate* weakSelf=self;
        companion=[[SPDFCollectionCompanionHost alloc] initWithStore:SPDFMacCollectionStore.defaultStore
            open:^(NSString* path,BOOL archived) { [weakSelf collectionOpenPath:path archived:archived]; }
            navigate:^(NSDictionary* doc,NSDictionary* version,NSUInteger page,NSString* text,BOOL history) {
                [weakSelf collectionNavigateDocument:doc version:version page:page query:text history:history];
            }];
        objc_setAssociatedObject(self,&kCollectionCompanion,companion,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSError* error=nil;
    if (![companion showDocumentID:documentID query:query error:&error] && error) [_window presentError:error];
}
- (void)showCollectionPreviousVersion:(id)sender {
    SPDFMacCollectionStore* store = [SPDFMacCollectionStore defaultStore];
    NSString* path = [self collectionPathForSender:sender];
    NSDictionary* doc = [store documentForPath:path] ?: [store archiveInfoForPath:path][@"document"];
    NSArray* versions = [store versionsForDocumentID:doc[@"id"]];
    if (versions.count < 2) { [self showCollectionHistory:sender]; return; }
    NSDictionary* version = versions[versions.count - 2];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError* error = nil;
        NSURL* URL = [store materializeVersionID:version[@"id"] documentID:doc[@"id"] error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (URL) [self collectionOpenPath:URL.path archived:YES]; else [self->_window presentError:error];
        });
    });
}
- (void)collectionOpenPath:(NSString*)path archived:(BOOL)archived {
    SPDFMacCollectionStore* store = SPDFMacCollectionStore.defaultStore;
    NSDictionary* info = archived ? [store archiveInfoForPath:path] : nil;
    if (info && ![info[@"editable"] boolValue]) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
            NSError* error=nil;
            NSURL* URL=[store editableVersionID:info[@"version"][@"id"] documentID:info[@"document"][@"id"] error:&error];
            NSDictionary* editable=URL ? [store editableInfoForPath:URL.path] : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (URL) [self collectionPresentEditablePath:URL.path info:editable];
                else if (error) [self->_window presentError:error];
            });
        });
        return;
    }
    [self collectionPresentEditablePath:path info:info];
}
- (BOOL)collectionPresentMissingPath:(NSString*)path {
    return [[SPDFMacCollectionStore defaultStore] documentForPath:path] != nil;
}
- (void)showCollectionRecovery:(id)sender {
    NSString* path=[self collectionPathForSender:sender];
    if (!path.length) return;
    SPDFMacCollectionStore* store=SPDFMacCollectionStore.defaultStore;
    NSDictionary* doc=[store documentForPath:path] ?: [store archiveInfoForPath:path][@"document"];
    NSString* original=doc[@"path"] ?: path;
    if (doc ? SPDFCollectionOriginalAvailable(doc) : [NSFileManager.defaultManager fileExistsAtPath:original]) return;
    __weak ShenzhenMacDelegate* weakSelf=self;
    SPDFMacLocateCollectionOriginal(store,doc[@"id"] ?: original,_window, ^(NSString* preview) {
        [weakSelf collectionOpenPath:preview archived:NO];
    }, ^(NSString* restored) {
        ShenzhenMacDelegate* reader=weakSelf; if (!reader) return;
        SPDFDocumentTab* missing=nil;
        for (SPDFDocumentTab* tab in reader->_tabs) if ((tab.missingFile && [tab.path isEqual:original]) || [tab.path isEqual:path]) { missing=tab; break; }
        if (missing) {
            [reader discardCachedRuntimeForTab:missing];
            [reader collectionSetVersionInfo:nil forTab:missing];
            missing.workingPath=nil; missing.readOnly=NO; missing.collectionVersionLabel=nil;
            missing.path=restored; missing.title=restored.lastPathComponent.stringByDeletingPathExtension;
            missing.missingFile=NO; missing.missingMessage=@"";
            NSInteger index=[reader->_tabs indexOfObjectIdenticalTo:missing];
            if (index==reader->_selectedTabIndex) [reader loadSelectedTab]; else [reader selectTabAtIndex:index];
            [reader savePersistentState];
        } else [reader collectionOpenPath:restored archived:NO];
        [reader collectionRefreshHistory];
    });
}
@end
