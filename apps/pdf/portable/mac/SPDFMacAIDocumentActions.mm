#import "SPDFMacAIDocumentActions.h"
#import "SPDFMacAIDocumentJobsIntegration.h"
#import "SPDFMacAIToolsReader.h"
#import "SPDFMacTabGroupIntegration.h"
#import "SPDFMacSidebarWorkspace.h"
#import "SPDFMacCollectionIntegration.h"
#import "SPDFMacCollectionReaderNavigation.h"
#import "SPDFMacCollectionStore.h"
#import "SPDFMacDocumentRename.h"
#import "SPDFMacSearchFileCache.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
@interface ShenzhenMacDelegate (AIDocumentActionsHost)
- (void)closeTabAtIndex:(NSInteger)index;
- (NSInteger)indexOfTabForPath:(NSString*)path;
- (void)finishTabGroupChange;
- (void)adoptRenamedDocumentFrom:(NSString*)source to:(NSString*)destination replacingReadOnly:(BOOL)copy;
@end
static NSDictionary* ActionError(NSString* message) { return @{@"error":message}; }
@implementation ShenzhenMacDelegate (SPDFMacAIDocumentActions)
- (NSString*)aiDocumentActionFingerprint {
    NSMutableArray* tabs=[NSMutableArray array],*empty=[NSMutableArray array];
    for (SPDFDocumentTab* tab in _tabs) [tabs addObject:@{@"path":tab.path ?: @"",@"group":tab.group.dictionary ?: @{}}];
    for (SPDFTabGroup* group in [self emptyTabGroups]) [empty addObject:group.dictionary];
    NSDictionary* state=@{@"tabs":tabs,@"empty":empty,@"selected":@(_selectedTabIndex),
        @"page":@([self isMarkdownActive] ? [self activeMarkdownSession].currentPageIndex : _pageIndex)};
    NSData* data=[NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingSortedKeys error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}
- (void)aiCloseTabKeepingReader:(NSInteger)index {
    // Native close can terminate the last-tab window. An assistant must keep
    // its host alive so Undo can reopen the tab. An ephemeral empty group uses
    // the native last-tab branch without changing its close/save machinery.
    NSDictionary* sidebar=[[self sidebarWorkspaceState] copy];
    BOOL preserveHost=_tabs.count==1 && ![self emptyTabGroups].count;
    if (preserveHost) [self createEmptyTabGroup];
    [self closeTabAtIndex:index];
    if (preserveHost) {
        [[self sidebarWorkspaceState] setDictionary:sidebar]; [self resetEmptyTabGroups];
        [self finishTabGroupChange];
    }
}
- (NSDictionary*)aiCloseDocument:(NSString*)path progress:(NSProgress*)progress {
    NSInteger index=[self indexOfTabForPath:path];
    if (index<0 || index>=(NSInteger)_tabs.count || progress.cancelled) return ActionError(@"Document is no longer open, or closing was cancelled.");
    SPDFDocumentTab* tab=_tabs[(NSUInteger)index];
    if (tab.unsavedPastedImage) return ActionError(@"Save this pasted image before asking the assistant to close it.");
    NSDictionary* snapshot=[self aiCaptureWorkspace];
    if (progress.cancelled) return ActionError(@"Cancelled.");
    [self aiCloseTabKeepingReader:index];
    if ([_tabs containsObject:tab]) return ActionError(@"The document was not closed.");
    return @{@"closed":@YES,@"path":path,@"documentReceipt":@{@"kind":@"close",@"tab":tab,@"index":@(index),
        @"before":snapshot,@"after":[self aiDocumentActionFingerprint]}};
}
- (NSDictionary*)aiCloseDocuments:(NSArray<NSString*>*)paths progress:(NSProgress*)progress {
    if (!paths.count || progress.cancelled) return ActionError(@"Nothing to close, or closing was cancelled.");
    NSMutableArray* records=[NSMutableArray array],*kept=[NSMutableArray array];
    for (NSString* path in [NSOrderedSet orderedSetWithArray:paths]) {
        NSInteger index=[self indexOfTabForPath:path];
        if (index<0 || index>=(NSInteger)_tabs.count) continue;
        if (_tabs[(NSUInteger)index].unsavedPastedImage) { [kept addObject:path]; continue; }
        [records addObject:@{@"tab":_tabs[(NSUInteger)index],@"index":@(index)}];
    }
    if (!records.count) return ActionError(kept.count ? @"Save these pasted images before asking the assistant to close them." :
        @"None of these documents is open.");
    [records sortUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) { return [a[@"index"] compare:b[@"index"]]; }];
    NSDictionary* snapshot=[self aiCaptureWorkspace];
    SPDFDocumentTab* selected=[self selectedTab];
    // Background tabs first, from the end, then the one in front: its replacement is chosen among the tabs that stay,
    // so no tab that is about to close gets loaded. One session write for the lot.
    NSMutableArray* order=[NSMutableArray array];
    for (NSDictionary* record in records.reverseObjectEnumerator) if (record[@"tab"]!=selected) [order addObject:record[@"tab"]];
    for (NSDictionary* record in records) if (record[@"tab"]==selected) [order addObject:record[@"tab"]];
    [self performWithBatchedPersistentStateSaves:^{
        for (SPDFDocumentTab* tab in order) {
            NSUInteger index=[self->_tabs indexOfObjectIdenticalTo:tab];
            if (index!=NSNotFound) [self aiCloseTabKeepingReader:(NSInteger)index];
        }
    }];
    NSMutableArray* closed=[NSMutableArray array];
    for (NSDictionary* record in records) if (![_tabs containsObject:record[@"tab"]]) [closed addObject:[record[@"tab"] path]];
    if (closed.count!=records.count) return ActionError(@"Some documents could not be closed.");
    NSMutableDictionary* result=[@{@"closed":@(closed.count),@"paths":closed,@"documentReceipt":@{@"kind":@"close-many",
        @"records":records,@"before":snapshot,@"after":[self aiDocumentActionFingerprint]}} mutableCopy];
    if (kept.count) result[@"keptOpen"]=@{@"reason":@"unsaved pasted image",@"paths":kept};
    return result;
}
- (NSDictionary*)aiOpenCollectionDocumentAtPath:(NSString*)path archived:(BOOL)archived progress:(NSProgress*)progress {
    if (progress.cancelled) return ActionError(@"Cancelled.");
    NSDictionary* before=[self aiCaptureWorkspace]; BOOL existed=[self indexOfTabForPath:path]>=0;
    [self collectionOpenPath:path archived:archived];
    NSInteger index=[self indexOfTabForPath:path];
    if (index<0 || index>=(NSInteger)_tabs.count) return ActionError(@"The Collection document could not be opened.");
    SPDFDocumentTab* tab=_tabs[(NSUInteger)index];
    return @{@"opened":@YES,@"path":path,@"documentReceipt":@{@"kind":@"open",@"before":before,
        @"newTab":existed ? (id)NSNull.null : tab,@"after":[self aiDocumentActionFingerprint]}};
}
- (NSDictionary*)aiRenameDocument:(NSDictionary*)arguments progress:(NSProgress*)progress {
    NSString* source=arguments[@"path"]; NSInteger index=[self indexOfTabForPath:source];
    if (progress.cancelled || index<0 || index>=(NSInteger)_tabs.count) return ActionError(@"Document is unavailable or rename was cancelled.");
    SPDFDocumentTab* tab=_tabs[(NSUInteger)index];
    if (tab.readOnly || tab.unsavedPastedImage || tab.missingFile || tab.workingPath.length)
        return ActionError(@"Use Rename in the tab menu to choose Save As for this document first.");
    NSString* destination=SPDFDocumentRenameDestination(source,arguments[@"name"]);
    if (!destination || [destination isEqual:source]) return ActionError(@"Enter a different filename without path separators.");
    if (![arguments[@"revision"] isEqual:SPDFSearchFileStamp(source)]) return ActionError(@"Document revision changed. Read reader_state again.");
    struct stat info={};
    if (lstat(source.fileSystemRepresentation,&info) || !S_ISREG(info.st_mode)) return ActionError(@"Document is not a regular file.");
    SPDFMacCollectionStore* store=SPDFMacCollectionStore.defaultStore;
    NSDictionary* editable=[store editableInfoForPath:source];
    if (editable) {
        if (progress.cancelled) return ActionError(@"Rename cancelled.");
        NSError* error=nil; NSString* title=editable[@"document"][@"title"];
        NSURL* renamed=[store renameEditablePath:source filename:destination.lastPathComponent
            documentTitle:destination.lastPathComponent expectedTitle:title error:&error];
        if (!renamed) return ActionError(error.localizedDescription ?: @"Collection rename failed.");
        [self adoptRenamedDocumentFrom:source to:renamed.path replacingReadOnly:NO];
        [self collectionSetVersionInfo:[store editableInfoForPath:renamed.path] forTab:tab];
        [self collectionRefreshHistory];
        return @{@"renamed":@YES,@"path":renamed.path,@"documentReceipt":@{@"kind":@"collection-rename",
            @"source":source,@"destination":renamed.path,@"historyID":editable[@"document"][@"id"],@"copyID":editable[@"copyID"],
            @"beforeTitle":title ?: source.lastPathComponent,@"afterTitle":destination.lastPathComponent,
            @"afterRevision":SPDFSearchFileStamp(renamed.path) ?: @""}};
    }
    if (info.st_size>32LL*1024*1024 ||
        ![NSFileManager.defaultManager isWritableFileAtPath:source.stringByDeletingLastPathComponent])
        return ActionError(@"Assistant rename requires a writable normal file up to 32 MiB; use the tab menu for Save As or larger files.");
    NSDictionary* history=[store documentForPath:source];
    if (progress.cancelled || ![arguments[@"revision"] isEqual:SPDFSearchFileStamp(source)]) return ActionError(@"Rename cancelled or source changed.");
    NSError* error=nil;
    if (!SPDFRenameDocumentFile(source,destination,&error)) return ActionError(error.localizedDescription ?: @"Rename failed.");
    if (history[@"id"] && ![store linkDocumentID:history[@"id"] toPath:destination allowMismatch:YES error:&error]) {
        BOOL restored=SPDFRenameDocumentFile(destination,source,nil);
        return ActionError(restored ? @"Collection could not relink this rename. The original filename was restored." : @"Collection relinking and rename rollback failed. The file remains at its new name.");
    }
    [self adoptRenamedDocumentFrom:source to:destination replacingReadOnly:NO];
    [self collectionRefreshHistory];
    return @{@"renamed":@YES,@"path":destination,@"documentReceipt":@{@"kind":@"rename",@"source":source,@"destination":destination,
        @"historyID":history[@"id"] ?: @"",@"afterRevision":SPDFSearchFileStamp(destination) ?: @""}};
}
- (BOOL)aiUndoDocumentAction:(NSDictionary*)receipt progress:(NSProgress*)progress {
    if (progress.cancelled) return NO;
    NSString* kind=receipt[@"kind"];
    if ([kind isEqual:@"job"]) return [self aiUndoDocumentJob:receipt progress:progress];
    if ([kind isEqual:@"collection-rename"]) {
        NSString* source=receipt[@"source"],*destination=receipt[@"destination"];
        SPDFMacCollectionStore* store=SPDFMacCollectionStore.defaultStore;
        NSDictionary* info=[store editableInfoForPath:destination];
        if (![info[@"document"][@"id"] isEqual:receipt[@"historyID"]] || ![info[@"copyID"] isEqual:receipt[@"copyID"]] ||
            ![receipt[@"afterRevision"] isEqual:SPDFSearchFileStamp(destination)] ||
            [NSFileManager.defaultManager fileExistsAtPath:source]) return NO;
        NSURL* restored=[store renameEditablePath:destination filename:source.lastPathComponent
            documentTitle:receipt[@"beforeTitle"] expectedTitle:receipt[@"afterTitle"] error:nil];
        if (!restored) return NO;
        [self adoptRenamedDocumentFrom:destination to:restored.path replacingReadOnly:NO];
        NSInteger index=[self indexOfTabForPath:restored.path];
        if (index>=0 && index<(NSInteger)_tabs.count) [self collectionSetVersionInfo:[store editableInfoForPath:restored.path] forTab:_tabs[(NSUInteger)index]];
        [self collectionRefreshHistory]; return YES;
    }
    if ([kind isEqual:@"rename"]) {
        NSString* source=receipt[@"source"],*destination=receipt[@"destination"];
        if (![receipt[@"afterRevision"] isEqual:SPDFSearchFileStamp(destination)] ||
            [NSFileManager.defaultManager fileExistsAtPath:source]) return NO;
        if (!SPDFRenameDocumentFile(destination,source,nil)) return NO;
        NSString* identifier=receipt[@"historyID"];
        if (identifier.length && ![SPDFMacCollectionStore.defaultStore linkDocumentID:identifier toPath:source allowMismatch:YES error:nil]) {
            SPDFRenameDocumentFile(source,destination,nil); return NO;
        }
        [self adoptRenamedDocumentFrom:destination to:source replacingReadOnly:NO];
        [self collectionRefreshHistory]; return YES;
    }
    if (![receipt[@"after"] isEqual:[self aiDocumentActionFingerprint]]) return NO;
    NSDictionary* before=receipt[@"before"];
    if ([kind isEqual:@"close-many"]) {
        NSArray* records=receipt[@"records"];
        for (NSDictionary* record in records) if ([self indexOfTabForPath:[record[@"tab"] path]]>=0) return NO;
        SPDFDocumentTab* current=[self selectedTab];
        // In ascending order each tab lands where it was, the earlier ones already back before it.
        for (NSDictionary* record in records)
            [_tabs insertObject:record[@"tab"] atIndex:MIN([record[@"index"] unsignedIntegerValue],_tabs.count)];
        _selectedTabIndex=current ? (NSInteger)[_tabs indexOfObjectIdenticalTo:current] : -1;
    } else if ([kind isEqual:@"close"]) {
        SPDFDocumentTab* tab=receipt[@"tab"];
        if ([self indexOfTabForPath:tab.path]>=0) return NO;
        SPDFDocumentTab* current=[self selectedTab];
        NSUInteger insertion=MIN([receipt[@"index"] unsignedIntegerValue],_tabs.count);
        [_tabs insertObject:tab atIndex:insertion];
        _selectedTabIndex=current ? (NSInteger)[_tabs indexOfObjectIdenticalTo:current] : -1;
    } else if ([kind isEqual:@"open"] && receipt[@"newTab"]!=NSNull.null) {
        SPDFDocumentTab* tab=receipt[@"newTab"]; NSUInteger index=[_tabs indexOfObjectIdenticalTo:tab];
        if (index==NSNotFound || tab.unsavedPastedImage) return NO;
        [self aiCloseTabKeepingReader:(NSInteger)index];
    } else if (![kind isEqual:@"open"]) return NO;
    return [self aiRestoreWorkspace:before expected:[self aiWorkspaceFingerprint]];
}
@end

NSDictionary* SPDFAIMapDocumentIDs(NSMutableDictionary* arguments, NSDictionary<NSString*, NSString*>* known) {
    NSArray* identifiers=arguments[@"paths"];
    if (![identifiers isKindOfClass:NSArray.class] || !identifiers.count || identifiers.count>200)
        return ActionError(@"paths must list 1 to 200 document IDs from list_workspace.");
    NSMutableArray* paths=[NSMutableArray array],*unknown=[NSMutableArray array];
    for (id identifier in identifiers) {
        NSString* path=[identifier isKindOfClass:NSString.class] ? known[identifier] : nil;
        if (path) [paths addObject:path]; else [unknown addObject:[identifier isKindOfClass:NSString.class] ? identifier : @"?"];
    }
    if (unknown.count) return @{@"error":@"Some IDs are not open documents: list_workspace again and leave them out.",
        @"notOpen":unknown};
    arguments[@"paths"]=paths;
    return nil;
}
