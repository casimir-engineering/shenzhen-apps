#import "SPDFMacCollectionReaderNavigation.h"
#import "SPDFMacCollectionStore.h"
#import "SPDFMacTabGroups.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
#import <objc/runtime.h>

static char conversionPathKey, conversionPendingKey;
@implementation ShenzhenMacDelegate (CollectionEditableIntegration)
- (void)collectionRememberGroups {
    NSMutableDictionary* groups=nil;
    for (SPDFDocumentTab* tab in _tabs) {
        NSString* identifier=tab.collectionHistoryDocumentID;
        if (!identifier.length) continue;
        if (!groups) groups=[NSMutableDictionary dictionary];
        if (groups[identifier] && [tab.path.pathComponents containsObject:@"editable"]) continue;
        groups[identifier]=tab.group.dictionary ?: SPDFTabGroup.generalGroup.dictionary;
    }
    if (!groups.count) return;
    static dispatch_queue_t groupWrites; static dispatch_once_t once;
    dispatch_once(&once, ^{ groupWrites=dispatch_queue_create("com.shenzhenpdf.collection-groups",DISPATCH_QUEUE_SERIAL); });
    dispatch_async(groupWrites, ^{ [SPDFMacCollectionStore.defaultStore rememberGroups:groups]; });
}
- (BOOL)collectionRestoreMissingTab:(SPDFDocumentTab*)tab path:(NSString*)path {
    // Covers absent, unreadable and damaged sources after a real open fails.
    if ([objc_getAssociatedObject(tab,&conversionPathKey) isEqual:path])
        return [objc_getAssociatedObject(tab,&conversionPendingKey) boolValue];
    NSDictionary* doc=[SPDFMacCollectionStore.defaultStore documentForPath:path];
    if (![doc[@"versions"] count]) return NO;
    tab.missingFile=YES;
    [self collectionConvertTab:tab path:path info:@{@"document":doc,@"sourceReadFailed":@YES}];
    return YES;
}
- (void)collectionConvertTab:(SPDFDocumentTab*)tab path:(NSString*)path info:(NSDictionary*)info {
    if (!tab || [objc_getAssociatedObject(tab,&conversionPathKey) isEqual:path]) return;
    objc_setAssociatedObject(tab,&conversionPathKey,path,OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(tab,&conversionPendingKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (tab == [self selectedTab]) [self showEmptyDocumentViewWithMessage:@"Opening Collection document…"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        SPDFMacCollectionStore* store=SPDFMacCollectionStore.defaultStore;
        NSError* error=nil;
        if ([info[@"sourceReadFailed"] boolValue]) [store recordUnavailableSourcePath:path documentID:info[@"document"][@"id"]];
        NSURL* URL=[store editableVersionID:info[@"version"][@"id"] documentID:info[@"document"][@"id"] error:&error];
        if ([info[@"sourceReadFailed"] boolValue] && [URL.path isEqual:path]) {
            URL=nil; error=[NSError errorWithDomain:@"SPDFCollection" code:8 userInfo:@{NSLocalizedDescriptionKey:@"The Collection document itself could not be read. Its saved history has been preserved."}];
        }
        NSDictionary* editable=URL ? [store editableInfoForPath:URL.path] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![objc_getAssociatedObject(tab,&conversionPathKey) isEqual:path]) return;
            objc_setAssociatedObject(tab,&conversionPendingKey,@NO,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (![self->_tabs containsObject:tab] || ![tab.path isEqual:path]) return;
            if (!URL) {
                // Retain the failed-attempt guard so loading the missing placeholder cannot recurse.
                if (tab==[self selectedTab]) { [self loadSelectedTab]; if(error)[self->_window presentError:error]; }
                return;
            }
            [self collectionAdoptEditablePath:URL.path info:editable tab:tab];
            if (tab==[self selectedTab]) [self loadSelectedTab];
            [self updateTabStrip]; [self savePersistentState];
        });
    });
}
- (void)collectionAdoptEditablePath:(NSString*)path info:(NSDictionary*)info tab:(SPDFDocumentTab*)tab {
    NSString* previous=tab.path;
    // A previous History click may already have opened this working file. Keep
    // the original selected tab/group and close only its inactive duplicate.
    if (tab==[self selectedTab]) for (SPDFDocumentTab* other in _tabs.copy)
        if (other!=tab && [other.path isEqual:path] && !other.unsavedPastedImage)
            [self closeTabAtIndex:[_tabs indexOfObjectIdenticalTo:other]];
    [self discardCachedRuntimeForTab:tab];
    tab.path=path; tab.title=path.lastPathComponent.stringByDeletingPathExtension;
    objc_setAssociatedObject(tab,&conversionPathKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(tab,&conversionPendingKey,@NO,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    tab.readOnly=NO; tab.workingPath=nil; tab.readOnlyCopyBinding=nil;
    tab.collectionVersionLabel=nil; tab.missingFile=NO; tab.missingMessage=@"";
    tab.collectionHistoryDocumentID=info[@"document"][@"id"];
    if ([tab.group.lastUsedPath isEqual:previous]) tab.group.lastUsedPath=path;
    [self collectionSetVersionInfo:info forTab:tab];
}
- (void)collectionPresentEditablePath:(NSString*)path info:(NSDictionary*)info {
    SPDFTabGroup* group=nil; BOOL foundGroup=NO;
    NSDictionary* doc=info[@"document"];
    if (info) {
        for (SPDFDocumentTab* candidate in _tabs) {
            if ([candidate.path isEqual:doc[@"path"]] ||
                (candidate.collectionHistoryDocumentID.length && [candidate.collectionHistoryDocumentID isEqual:doc[@"id"]])) {
                group=candidate.group; foundGroup=YES;
                if ((candidate.missingFile || candidate.missingMessage.length) && [candidate.path isEqual:doc[@"path"]]) {
                    [self collectionAdoptEditablePath:path info:info tab:candidate];
                    if (candidate==[self selectedTab]) [self loadSelectedTab];
                    else [self selectTabAtIndex:[_tabs indexOfObjectIdenticalTo:candidate]];
                    [self updateTabStrip]; [self savePersistentState];
                    [_window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
                    return;
                }
                break;
            }
        }
        if (!foundGroup) group=[SPDFTabGroup fromDictionary:doc[@"tabGroup"]];
        if (group.collectionBackups) group=nil;
        for (SPDFDocumentTab* candidate in _tabs)
            if ([candidate.group.identifier isEqual:group.identifier]) { group=candidate.group; break; }
    }
    BOOL existed=[self indexOfTabForPath:path]>=0;
    [self openPath:path];
    [_window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
    SPDFDocumentTab* tab=[self selectedTab];
    if (!info || ![tab.path isEqual:path]) return;
    if (!existed) tab.group=group;
    tab.readOnly=NO; tab.collectionVersionLabel=nil; tab.collectionHistoryDocumentID=doc[@"id"];
    tab.title=path.lastPathComponent.stringByDeletingPathExtension;
    spdf_tab_groups_normalize(_tabs); _selectedTabIndex=[_tabs indexOfObjectIdenticalTo:tab];
    tab.group.hidden=NO; spdf_tab_groups_activate(_tabs,tab);
    [self collectionSetVersionInfo:info forTab:tab];
    [self updateTabStrip]; [self savePersistentState];
}
@end
