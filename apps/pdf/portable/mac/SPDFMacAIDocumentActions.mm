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
#import "SPDFMacTabGroups.h"
@interface ShenzhenMacDelegate (AIDocumentActionsHost)
- (void)closeTabAtIndex:(NSInteger)index;
- (NSInteger)indexOfTabForPath:(NSString*)path;
- (void)finishTabGroupChange;
- (void)adoptRenamedDocumentFrom:(NSString*)source to:(NSString*)destination replacingReadOnly:(BOOL)copy;
- (void)showDisplayName:(NSString*)name forTabsAtPath:(NSString*)path;
@end
static NSDictionary* ActionError(NSString* message) { return @{@"error":message}; }
// The name to show for a document whose file keeps its own: the name asked for, without the file's extension.
NSString* SPDFAIDisplayNameForRename(NSString* path, NSString* proposed) {
    NSString* name=[proposed isKindOfClass:NSString.class] ?
        [proposed stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
    NSString* extension=path.pathExtension;
    if (extension.length && [name.pathExtension caseInsensitiveCompare:extension]==NSOrderedSame)
        name=[name.stringByDeletingPathExtension stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!name.length || name.length>240 || [name rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location!=NSNotFound)
        return nil;
    return name;
}
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
    return [self aiOpenCollectionDocumentAtPath:path archived:archived afterPath:nil progress:progress];
}
- (NSDictionary*)aiOpenCollectionDocumentAtPath:(NSString*)path archived:(BOOL)archived afterPath:(NSString*)neighbour
                                       progress:(NSProgress*)progress {
    if (progress.cancelled) return ActionError(@"Cancelled.");
    NSDictionary* before=[self aiCaptureWorkspace]; BOOL existed=[self indexOfTabForPath:path]>=0;
    [self collectionOpenPath:path archived:archived];
    NSInteger index=[self indexOfTabForPath:path], beside=neighbour.length ? [self indexOfTabForPath:neighbour] : -1;
    // A new tab goes right after `neighbour`, in its group, where the person will look for it.
    if (!existed && index>=0 && beside>=0 && index!=beside+1 && [self respondsToSelector:@selector(moveTabAtIndex:toGroup:atIndex:)])
        [(id<SPDFTabGroupReader>)self moveTabAtIndex:index toGroup:_tabs[(NSUInteger)beside].group atIndex:beside+1];
    else if (!existed && index==beside+1 && beside>=0 && _tabs[(NSUInteger)index].group!=_tabs[(NSUInteger)beside].group &&
        [self respondsToSelector:@selector(moveTabAtIndex:toGroup:atIndex:)])
        [(id<SPDFTabGroupReader>)self moveTabAtIndex:index toGroup:_tabs[(NSUInteger)beside].group atIndex:index];
    index=[self indexOfTabForPath:path];
    if (index<0 || index>=(NSInteger)_tabs.count) return ActionError(@"The Collection document could not be opened.");
    SPDFDocumentTab* tab=_tabs[(NSUInteger)index];
    return @{@"opened":@YES,@"path":path,@"documentReceipt":@{@"kind":@"open",@"before":before,
        @"newTab":existed ? (id)NSNull.null : tab,@"after":[self aiDocumentActionFingerprint]}};
}
// Gives the document the name it shows in ShenzhenPDF, leaving its file as it is: for a file that can't or mustn't be
// renamed (`why` says which, in the person's terms), or when the assistant was asked to keep the file's name.
- (NSDictionary*)aiShowDocument:(NSString*)source asName:(NSString*)proposed because:(NSString*)why {
    NSString* name=SPDFAIDisplayNameForRename(source,proposed);
    if (!name) return ActionError(@"Give a name on one line, up to 240 characters.");
    NSInteger index=[self indexOfTabForPath:source];
    if (index<0 || index>=(NSInteger)_tabs.count) return ActionError(@"Document is no longer open.");
    SPDFDocumentTab* tab=_tabs[(NSUInteger)index];
    NSString* before=spdf_tab_display_name(tab) ?: @"";
    NSString* filename=source.lastPathComponent;
    if ([name isEqual:before] || (!before.length && [name isEqual:filename.stringByDeletingPathExtension]))
        return ActionError([NSString stringWithFormat:@"Nothing to change: it already shows as “%@”.",name]);
    // Collection keeps the name with the document's history, so it comes back when the document is opened again.
    SPDFMacCollectionStore* store=SPDFMacCollectionStore.defaultStore;
    NSString* identifier=tab.collectionHistoryDocumentID.length ? tab.collectionHistoryDocumentID : [store documentForPath:source][@"id"];
    BOOL kept=identifier.length && [store setDisplayName:name documentID:identifier expectedName:nil error:nil];
    [self showDisplayName:name forTabsAtPath:source];
    return @{@"renamed":@YES,@"path":source,@"title":name,@"fileRenamed":@NO,@"filename":filename,
        @"tellThePerson":[NSString stringWithFormat:@"It now shows as “%@” in its tab%@. The file itself keeps its name, %@, "
            "because %@.",name,kept ? @" and in Collection" : @"",filename,why],
        @"documentReceipt":@{@"kind":@"display-name",@"path":source,@"before":before,@"after":name,@"historyID":kept ? identifier : @""}};
}
- (NSDictionary*)aiRenameDocument:(NSDictionary*)arguments progress:(NSProgress*)progress {
    NSString* source=arguments[@"path"]; NSInteger index=[self indexOfTabForPath:source];
    if (progress.cancelled || index<0 || index>=(NSInteger)_tabs.count) return ActionError(@"Document is unavailable or rename was cancelled.");
    SPDFDocumentTab* tab=_tabs[(NSUInteger)index];
    NSString* target=[arguments[@"target"] isKindOfClass:NSString.class] ? arguments[@"target"] : @"auto";
    if (![@[@"auto",@"file",@"title"] containsObject:target]) return ActionError(@"target must be auto, file or title.");
    // The revision read_pages and reader_state give is the one of the file the reader reads: for a read-only
    // document, its private copy. Either that or the file's own is current.
    NSString* revision=arguments[@"revision"];
    BOOL current=[revision isKindOfClass:NSString.class] && ([revision isEqual:SPDFSearchFileStamp(source)] ||
        (tab.workingPath.length && [revision isEqual:SPDFSearchFileStamp(tab.workingPath)]));
    // Why the file keeps its name, said from the person's side; nil when the file itself can be renamed.
    NSString* keep=nil;
    if (tab.readOnly || tab.workingPath.length) keep=@"it is read-only";
    else if (tab.missingFile) keep=@"the file can't be found right now";
    else if (tab.unsavedPastedImage) keep=@"it is a pasted image that hasn't been saved as a file yet";
    struct stat info={};
    if (!keep && (lstat(source.fileSystemRepresentation,&info) || !S_ISREG(info.st_mode))) keep=@"it isn't a regular file";
    SPDFMacCollectionStore* store=SPDFMacCollectionStore.defaultStore;
    NSDictionary* editable=keep ? nil : [store editableInfoForPath:source];
    if (!keep && !editable && ![NSFileManager.defaultManager isWritableFileAtPath:source.stringByDeletingLastPathComponent])
        keep=@"the folder it is in can't be changed";
    if (!keep && !editable && info.st_size>32LL*1024*1024) keep=@"the assistant doesn't move files larger than 32 MB";
    if ([target isEqual:@"title"] && !keep) keep=@"you asked to keep the file's name";
    if (keep) {
        if ([target isEqual:@"file"])
            return ActionError([NSString stringWithFormat:@"The file can't be renamed here because %@. Use target \"title\" to change the "
                "name ShenzhenPDF shows instead, and say that the file keeps its name.",keep]);
        if (progress.cancelled) return ActionError(@"Rename cancelled.");
        if (revision.length && !current && !tab.missingFile && !tab.unsavedPastedImage)
            return ActionError(@"Document revision changed. Read reader_state again.");
        return [self aiShowDocument:source asName:arguments[@"name"] because:keep];
    }
    NSString* destination=SPDFDocumentRenameDestination(source,arguments[@"name"]);
    if (!destination || [destination isEqual:source]) return ActionError(@"Enter a different filename without path separators.");
    if (![revision isEqual:SPDFSearchFileStamp(source)]) return ActionError(@"Document revision changed. Read reader_state again.");
    if (editable) {
        if (progress.cancelled) return ActionError(@"Rename cancelled.");
        NSError* error=nil; NSString* title=editable[@"document"][@"title"];
        NSURL* renamed=[store renameEditablePath:source filename:destination.lastPathComponent
            documentTitle:destination.lastPathComponent expectedTitle:title error:&error];
        if (!renamed) return ActionError(error.localizedDescription ?: @"Collection rename failed.");
        [self adoptRenamedDocumentFrom:source to:renamed.path replacingReadOnly:NO];
        [self collectionSetVersionInfo:[store editableInfoForPath:renamed.path] forTab:tab];
        [self collectionRefreshHistory];
        return @{@"renamed":@YES,@"path":renamed.path,@"fileRenamed":@YES,@"filename":renamed.lastPathComponent,
            @"documentReceipt":@{@"kind":@"collection-rename",
            @"source":source,@"destination":renamed.path,@"historyID":editable[@"document"][@"id"],@"copyID":editable[@"copyID"],
            @"beforeTitle":title ?: source.lastPathComponent,@"afterTitle":destination.lastPathComponent,
            @"afterRevision":SPDFSearchFileStamp(renamed.path) ?: @""}};
    }
    NSDictionary* history=[store documentForPath:source];
    if (progress.cancelled || ![revision isEqual:SPDFSearchFileStamp(source)]) return ActionError(@"Rename cancelled or source changed.");
    NSError* error=nil;
    if (!SPDFRenameDocumentFile(source,destination,&error)) {
        NSError* cause=error.userInfo[NSUnderlyingErrorKey];
        BOOL refused=error.code==NSFileWriteNoPermissionError ||
            ([cause.domain isEqual:NSPOSIXErrorDomain] && (cause.code==EACCES || cause.code==EPERM || cause.code==EROFS));
        if (refused && ![target isEqual:@"file"]) return [self aiShowDocument:source asName:arguments[@"name"] because:@"macOS doesn't allow renaming it"];
        return ActionError(error.localizedDescription ?: @"Rename failed.");
    }
    if (history[@"id"] && ![store linkDocumentID:history[@"id"] toPath:destination allowMismatch:YES error:&error]) {
        BOOL restored=SPDFRenameDocumentFile(destination,source,nil);
        return ActionError(restored ? @"Collection could not relink this rename. The original filename was restored." : @"Collection relinking and rename rollback failed. The file remains at its new name.");
    }
    [self adoptRenamedDocumentFrom:source to:destination replacingReadOnly:NO];
    [self collectionRefreshHistory];
    return @{@"renamed":@YES,@"path":destination,@"fileRenamed":@YES,@"filename":destination.lastPathComponent,
        @"documentReceipt":@{@"kind":@"rename",@"source":source,@"destination":destination,
        @"historyID":history[@"id"] ?: @"",@"afterRevision":SPDFSearchFileStamp(destination) ?: @""}};
}
- (BOOL)aiUndoDocumentAction:(NSDictionary*)receipt progress:(NSProgress*)progress {
    if (progress.cancelled) return NO;
    NSString* kind=receipt[@"kind"];
    if ([kind isEqual:@"job"]) return [self aiUndoDocumentJob:receipt progress:progress];
    if ([kind isEqual:@"display-name"]) {
        // Only while it still shows the name the assistant gave it: a later rename by the person stays.
        NSString* path=receipt[@"path"],*after=receipt[@"after"],*before=receipt[@"before"];
        NSInteger index=[self indexOfTabForPath:path];
        if (index<0 || index>=(NSInteger)_tabs.count || ![spdf_tab_display_name(_tabs[(NSUInteger)index]) isEqual:after]) return NO;
        NSString* identifier=receipt[@"historyID"];
        if ([identifier length] && ![SPDFMacCollectionStore.defaultStore setDisplayName:before documentID:identifier
            expectedName:after error:nil]) return NO;
        [self showDisplayName:before forTabsAtPath:path];
        return YES;
    }
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
