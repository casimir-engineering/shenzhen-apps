#import "SPDFMacAIToolsReader.h"
#import "SPDFMacAgentGroups.h"
#import "SPDFMacTabGroupIntegration.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacSearchFileCache.h"
#import "SPDFMacSidebarWorkspace.h"
#import <objc/runtime.h>
#import "SPDFMacAIIntegration.h"
#import "SPDFMacFindExecution.h"
static char analysisMetadataKey, citationNavigationKey;
static NSString* WorkspaceLabel(NSString* text, NSUInteger limit) {
    if (text.length<=limit) return text;
    NSRange last=[text rangeOfComposedCharacterSequenceAtIndex:limit-1];
    NSUInteger end=NSMaxRange(last)<=limit ? limit : last.location;
    return end ? [text substringToIndex:end] : @"…";
}
@interface ShenzhenMacDelegate (SPDFMacAIToolsHost)
- (void)rememberActiveTabState;
- (void)finishTabGroupChange;
- (void)goToPage:(NSInteger)page preserveSinglePagePosition:(BOOL)preserve;
@end
@implementation ShenzhenMacDelegate (SPDFMacAIToolsReader)
- (void)aiRememberAnalysis:(NSDictionary*)analysis forPath:(NSString*)path {
    if (!analysis || !path.length) return;
    NSMutableDictionary* cache=objc_getAssociatedObject(self,&analysisMetadataKey);
    if (!cache) { cache=[NSMutableDictionary dictionary]; objc_setAssociatedObject(self,&analysisMetadataKey,cache,OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    cache[path]=@{@"analysis":analysis,@"revision":SPDFSearchFileStamp(path) ?: @"missing"};
}
- (NSArray<NSString*>*)aiDocumentPaths {
    NSMutableArray* paths=[NSMutableArray arrayWithCapacity:_tabs.count];
    for (SPDFDocumentTab* tab in _tabs) if (tab.path.length) [paths addObject:tab.path];
    return paths;
}
- (NSDictionary*)aiDocumentMetadataForPath:(NSString*)path {
    for (SPDFDocumentTab* tab in _tabs) if ([tab.path isEqual:path]) {
        NSDictionary* analysis=[self aiAnalysisForPath:path];
        return @{@"path":path,@"title":tab.title ?: path.lastPathComponent,
            @"analysisAvailable":@(analysis!=nil),@"analysis":analysis ?: @{}};
    }
    return @{@"error":@"Document is no longer open."};
}
- (NSDictionary*)aiCurrentDocumentContext {
    SPDFDocumentTab* tab=[self selectedTab];if(!tab.path.length)return @{};
    return @{@"path":tab.path,@"title":WorkspaceLabel(tab.title ?: tab.path.lastPathComponent,200),
        @"page":@([self isMarkdownActive] ? [self activeMarkdownSession].currentPageIndex+1 : _pageIndex+1)};
}
- (NSDictionary*)aiWorkspaceContext { return [self aiWorkspaceContextWithArguments:@{}]; }
- (NSDictionary*)aiWorkspaceContextWithArguments:(NSDictionary*)arguments {
    NSUInteger first=MAX((NSUInteger)1,[arguments[@"first"] unsignedIntegerValue]);
    NSUInteger groupFirst=MAX((NSUInteger)1,[arguments[@"groupFirst"] unsignedIntegerValue]);
    NSUInteger count=arguments[@"count"] ? [arguments[@"count"] unsignedIntegerValue] : 50;
    if (!count || count>100) return @{@"error":@"Workspace page size must be 1–100."};
    NSString* filter=arguments[@"groupID"];
    NSMutableArray* tabs=[NSMutableArray array],*groups=[NSMutableArray array];
    NSMutableDictionary* byID=[NSMutableDictionary dictionary]; NSUInteger matched=0,tabBytes=0; BOOL tabPageFull=NO;
    for (NSUInteger index=0;index<_tabs.count;index++) {
        SPDFDocumentTab* tab=_tabs[index]; SPDFTabGroup* group=tab.group;
        NSString* identifier=group.identifier ?: @"general";
        NSMutableDictionary* row=byID[identifier];
        if (!row) {
            NSString* name=group.displayName ?: @"General";
            row=[@{@"id":identifier,@"displayName":WorkspaceLabel(name,160),
                @"color":group.colorName ?: @"gray",@"general":@(group ? group.general : YES),
                @"collapsed":@(group.collapsed),@"hidden":@(group.hidden),@"documentCount":@0} mutableCopy];
            byID[identifier]=row; [groups addObject:row];
        }
        row[@"documentCount"]=@([row[@"documentCount"] unsignedIntegerValue]+1);
        if (filter && ![filter isEqual:identifier]) continue;
        matched++;
        if (matched<first || tabs.count>=count || tabPageFull) continue;
        NSString* title=tab.title ?: tab.path.lastPathComponent ?: @"";
        if (title.isAbsolutePath) title=title.lastPathComponent;
        NSDictionary* item=@{@"path":tab.path ?: @"",@"title":WorkspaceLabel(title,200),
            @"index":@(index+1),@"groupID":identifier,@"selected":@(index==(NSUInteger)_selectedTabIndex),
            @"readOnly":@(tab.readOnly),@"missingFile":@(tab.missingFile)};
        NSUInteger bytes=[NSJSONSerialization dataWithJSONObject:item options:0 error:nil].length;
        if (tabs.count && tabBytes+bytes>40000) { tabPageFull=YES; continue; }
        [tabs addObject:item]; tabBytes+=bytes;
    }
    for (SPDFTabGroup* group in [self emptyTabGroups]) if (!byID[group.identifier]) {
        NSString* name=group.displayName;
        NSMutableDictionary* row=[@{@"id":group.identifier,@"displayName":WorkspaceLabel(name,160),
            @"color":group.colorName ?: @"gray",@"general":@(group.general),@"collapsed":@(group.collapsed),
            @"hidden":@(group.hidden),@"documentCount":@0} mutableCopy];
        byID[group.identifier]=row; [groups addObject:row];
    }
    NSUInteger groupOffset=MIN(groupFirst-1,groups.count), groupCount=0,groupBytes=0;
    for (NSUInteger index=groupOffset;index<groups.count && groupCount<count;index++) {
        NSUInteger bytes=[NSJSONSerialization dataWithJSONObject:groups[index] options:0 error:nil].length;
        if (groupCount && groupBytes+bytes>40000) break;
        groupBytes+=bytes; groupCount++;
    }
    NSUInteger next=first+tabs.count,nextGroup=groupFirst+groupCount;
    NSMutableDictionary* result=[@{@"windowSessionID":_windowSessionID ?: @"",@"tabs":tabs,
        @"groups":[groups subarrayWithRange:NSMakeRange(groupOffset,groupCount)],
        @"totalDocuments":@(matched),@"totalGroups":@(groups.count),
        @"next":next<=matched ? @(next) : NSNull.null,@"nextGroup":nextGroup<=groups.count ? @(nextGroup) : NSNull.null,
        @"currentPage":@([self isMarkdownActive] ? [self activeMarkdownSession].currentPageIndex+1 : _pageIndex+1),
        @"colors":spdf_tab_group_colors()} mutableCopy];
    result[@"currentDocument"]=[self aiCurrentDocumentContext];
    result[@"capabilities"]=@{@"available":@[@"document_metadata",@"read_pages",@"search_documents",@"render_page",@"show_document",@"organize_groups",@"list_chats",@"organize_chats",@"read_comments",@"edit_comment",@"reader_state",@"reader_control",@"list_collection",@"open_collection",@"close_document",@"reopen_document",@"rename_document",@"document_job",@"undo_action"],
        @"documentJobs":@{@"kinds":@[@"ocr",@"translate",@"export-pdf"],@"requires":@"OCR and translation need installed local tools; no silent installation."},
        @"unavailable":@{@"delete_files":@"No reversible file deletion adapter."}};
    return result;
}
- (NSDictionary*)aiDocumentCandidateForTab:(SPDFDocumentTab*)tab {
    if (!tab.path.length) return nil;
    NSMutableDictionary* candidate=[@{@"path":tab.path,@"readPath":tab.workingPath ?: tab.path,
        @"title":tab.title ?: tab.path.lastPathComponent,@"landscape":@(tab.markdownLandscape),
        @"revision":SPDFSearchFileStamp(tab.workingPath ?: tab.path) ?: @"missing"} mutableCopy];
    SPDFMacMarkdownSession* session=[tab.path isEqual:_path] && [self isMarkdownActive] ?
        [self activeMarkdownSession] : tab.cachedMarkdownSession;
    if (session.isNavigationReady && session.renderedDocument && session.paginationPlan &&
        [session.loadedSourceRevision isEqual:candidate[@"revision"]]) {
        candidate[@"sourceRevision"]=session.loadedSourceRevision;
        candidate[@"renderedDocument"]=session.renderedDocument; candidate[@"paginationPlan"]=session.paginationPlan;
    }
    return candidate;
}
- (NSDictionary*)aiDocumentCandidateForPath:(NSString*)path {
    for (SPDFDocumentTab* tab in _tabs) if ([tab.path isEqual:path]) return [self aiDocumentCandidateForTab:tab];
    return nil;
}
- (NSArray<NSDictionary*>*)aiDocumentCandidates {
    NSMutableArray* documents=[NSMutableArray array];
    for (SPDFDocumentTab* tab in _tabs) {
        NSDictionary* candidate=[self aiDocumentCandidateForTab:tab]; if (candidate) [documents addObject:candidate];
    }
    return documents;
}
- (NSString*)aiWorkspaceFingerprint {
    NSMutableDictionary* snapshot=[[self performAgentGroupCommand:@{@"action":@"list-groups"}] mutableCopy];
    snapshot[@"currentPage"]=@([self isMarkdownActive] ? [self activeMarkdownSession].currentPageIndex+1 : _pageIndex+1);
    snapshot[@"visiblePath"]=_path ?: @"";
    snapshot[@"search"]=@[_searchField.stringValue ?: @"",@(_findRegexCheckbox.state==NSControlStateValueOn),@(_findRegexMultiline)];
    NSData* data=[NSJSONSerialization dataWithJSONObject:snapshot options:NSJSONWritingSortedKeys error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}
- (NSDictionary*)aiCaptureWorkspace {
    [self rememberActiveTabState];
    NSMutableArray* membership=[NSMutableArray array];
    for (SPDFDocumentTab* tab in _tabs) [membership addObject:@{@"tab":tab,
        @"group":tab.group.dictionary ?: (id)NSNull.null,
        @"search":@{@"query":tab.searchText ?: @"",@"regex":@(tab.searchRegex),@"multiline":@(tab.searchRegexMultiline),@"index":@(tab.findMatchIndex)}}];
    NSMutableArray* empty=[NSMutableArray array];
    for (SPDFTabGroup* group in [self emptyTabGroups]) [empty addObject:group.dictionary];
    NSMutableDictionary* sidebar=[[self sidebarWorkspaceState] mutableCopy]; sidebar[@"emptyGroups"]=empty;
    return @{@"membership":membership,@"empty":empty,@"selected":@(_selectedTabIndex),@"page":@([self isMarkdownActive] ? [self activeMarkdownSession].currentPageIndex : _pageIndex),@"sidebar":sidebar};
}
- (BOOL)aiRestoreWorkspace:(NSDictionary*)snapshot expected:(NSString*)fingerprint {
    if (![fingerprint isEqual:[self aiWorkspaceFingerprint]]) return NO;
    NSArray* records=snapshot[@"membership"];
    if (records.count!=_tabs.count) return NO;
    for (NSDictionary* record in records) if (![_tabs containsObject:record[@"tab"]]) return NO;
    SPDFDocumentTab* current=_selectedTabIndex>=0 && _selectedTabIndex<(NSInteger)_tabs.count ? _tabs[(NSUInteger)_selectedTabIndex] : nil;
    NSMutableDictionary* groups=[NSMutableDictionary dictionary]; NSMutableArray* tabs=[NSMutableArray array];
    for (NSDictionary* record in records) {
        SPDFDocumentTab* tab=record[@"tab"]; NSDictionary* value=record[@"group"];
        if ((id)value==NSNull.null) tab.group=nil;
        else {
            SPDFTabGroup* group=[SPDFTabGroup fromDictionary:value];
            if (!groups[group.identifier]) groups[group.identifier]=group;
            tab.group=groups[group.identifier];
        }
        [tabs addObject:tab];
    }
    _tabs=tabs;
    // Preserve the live document's identity while reordering before selecting
    // the restored target. Setting the target index early makes selectTab's
    // same-index fast path leave the wrong document in the viewport.
    _selectedTabIndex=current ? (NSInteger)[_tabs indexOfObjectIdenticalTo:current] : -1;
    NSInteger restoredIndex=[snapshot[@"selected"] integerValue];
    if (restoredIndex>=0 && restoredIndex<(NSInteger)_tabs.count)
        [self aiNavigateDocument:_tabs[(NSUInteger)restoredIndex].path page:[snapshot[@"page"] integerValue]+1];
    // Selection may auto-collapse other groups. Reinstate the exact captured
    // flags afterwards, including empty groups and the pending new-tab target.
    for (NSDictionary* record in records) {
        SPDFDocumentTab* tab=record[@"tab"]; NSDictionary* value=record[@"group"];
        if ((id)value!=NSNull.null) {
            tab.group.collapsed=[value[@"collapsed"] boolValue]; tab.group.hidden=[value[@"hidden"] boolValue];
            tab.group.lastUsedPath=value[@"lastUsedPath"];
        }
    }
    // Citation highlighting is a reversible reader action too. Restore both
    // inactive tabs' saved searches and the visible search without jumping pages.
    for (NSDictionary* record in records) {
        SPDFDocumentTab* tab=record[@"tab"]; NSDictionary* search=record[@"search"];
        if (!search) continue;
        tab.searchText=search[@"query"]; tab.searchRegex=[search[@"regex"] boolValue];
        tab.searchRegexMultiline=[search[@"multiline"] boolValue]; tab.findMatchIndex=[search[@"index"] integerValue];
        if (tab==[self selectedTab]) {
            _searchField.stringValue=tab.searchText; _findRegexCheckbox.state=tab.searchRegex ? NSControlStateValueOn : NSControlStateValueOff;
            _findRegexMultiline=tab.searchRegexMultiline;
            [self startFindForCurrentQueryResetSavedIndex:NO revealMatch:NO];
        }
    }
    [[self sidebarWorkspaceState] setDictionary:snapshot[@"sidebar"]]; [self resetEmptyTabGroups];
    [self finishTabGroupChange];
    return YES;
}
- (NSDictionary*)aiNavigateDocument:(NSString*)path page:(NSInteger)page {
    return [self aiNavigateDocument:path page:page query:nil];
}
- (void)aiCancelPendingCitation { objc_setAssociatedObject(self,&citationNavigationKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
- (void)aiCompleteCitation:(NSString*)query tab:(SPDFDocumentTab*)tab page:(NSInteger)page token:(id)token expected:(NSString*)expected progress:(NSProgress*)progress sourcePath:(NSString*)sourcePath revision:(NSString*)revision attempts:(NSUInteger)attempts {
    if (progress.cancelled || objc_getAssociatedObject(self,&citationNavigationKey)!=token || [self selectedTab]!=tab ||
        ![[self aiWorkspaceFingerprint] isEqual:expected] ||
        ![revision isEqual:SPDFSearchFileStamp(sourcePath)]) return;
    SPDFMacMarkdownSession* session=[self isMarkdownActive] ? [self activeMarkdownSession] : nil;
    if ((session && !session.isNavigationReady) || (!session && !_doc)) {
        if (!attempts) return;
        __weak ShenzhenMacDelegate* weakSelf=self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,50*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
            [weakSelf aiCompleteCitation:query tab:tab page:page token:token expected:expected progress:progress sourcePath:sourcePath revision:revision attempts:attempts-1];
        }); return;
    }
    if (!query.length) {
        if (session) [self markdownGoToPage:page-1];
        else [self goToPage:page-1 preserveSinglePagePosition:NO];
        return;
    }
    _searchField.stringValue=query; _findRegexCheckbox.state=NSControlStateValueOff; _findRegexMultiline=YES;
    _pendingFindPreferredPage=session ? -1 : page-1;
    if (session) [self markdownGoToPage:page-1];
    BOOL previousNearest=_searchJumpsToNearestResult;
    _searchJumpsToNearestResult=YES;
    __weak ShenzhenMacDelegate* weakSelf=self;
    [self startFindForCurrentQueryResetSavedIndex:YES revealMatch:YES publicationAllowed:^BOOL {
        ShenzhenMacDelegate* owner=weakSelf;
        return owner && !progress.cancelled && objc_getAssociatedObject(owner,&citationNavigationKey)==token &&
            [owner selectedTab]==tab && [[owner aiWorkspaceFingerprint] isEqual:expected] &&
            [revision isEqual:SPDFSearchFileStamp(sourcePath)];
    }];
    _searchJumpsToNearestResult=previousNearest;
}
- (NSDictionary*)aiNavigateDocument:(NSString*)path page:(NSInteger)page query:(NSString*)query {
    return [self aiNavigateDocument:path page:page query:query progress:nil];
}
- (NSDictionary*)aiNavigateDocument:(NSString*)path page:(NSInteger)page query:(NSString*)query progress:(NSProgress*)progress {
    return [self aiNavigateDocument:path page:page query:query progress:progress sourcePath:nil revision:nil];
}
- (NSDictionary*)aiNavigateDocument:(NSString*)path page:(NSInteger)page query:(NSString*)query progress:(NSProgress*)progress
    sourcePath:(NSString*)sourcePath revision:(NSString*)revision {
    NSInteger index=NSNotFound;
    for (NSUInteger i=0;i<_tabs.count;i++) if ([_tabs[i].path isEqual:path]) { index=(NSInteger)i; break; }
    if (index==NSNotFound) return @{@"error":@"Document is no longer open."};
    sourcePath=[sourcePath ?: (_tabs[(NSUInteger)index].workingPath ?: path) copy];
    revision=[revision ?: SPDFSearchFileStamp(sourcePath) copy];
    // The caller validates the page against the file before mutation. Seed the
    // pending tab so asynchronous opening restores the requested page as well.
    if (page<1) return @{@"error":@"Page must be positive."};
    SPDFDocumentTab* target=_tabs[(NSUInteger)index];
    // A citation is an explicit destination, not a request to resume reading.
    // Opening captures scrollOrigin for deferred layout; leaving it intact moves
    // the viewport back after goToPage and makes a second click appear necessary.
    target.pageIndex=page-1; target.hasScrollOrigin=NO; target.markdownAnchor=nil;
    if (index!=_selectedTabIndex) [self selectTabAtIndex:index];
    SPDFMacMarkdownSession* session=[self isMarkdownActive] ? [self activeMarkdownSession] : nil;
    NSInteger count=session ? session.pageCount : (_doc ? spdf_page_count(_doc) : 0);
    if (count>0 && page<=count) {
        if (session) [self markdownGoToPage:page-1]; else [self goToPage:page-1 preserveSinglePagePosition:NO];
    }
    id token=[NSObject new]; objc_setAssociatedObject(self,&citationNavigationKey,token,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    BOOL loading=!count || (session && !session.isNavigationReady);
    if (loading) _pageIndex=page-1;
    if (query.length) {
        // Install the desired reader state before the receipt is fingerprinted.
        // Deferred extraction must not mutate state after a human edit or Undo.
        SPDFDocumentTab* tab=[self selectedTab];
        tab.searchText=[query copy]; tab.searchRegex=NO; tab.searchRegexMultiline=YES; tab.findMatchIndex=-1;
        _searchField.stringValue=query; _findRegexCheckbox.state=NSControlStateValueOff; _findRegexMultiline=YES;
        [self aiCompleteCitation:tab.searchText tab:tab page:page token:token expected:[self aiWorkspaceFingerprint] progress:progress sourcePath:sourcePath revision:revision attempts:400];
    }
    if (!query.length && loading)
        [self aiCompleteCitation:nil tab:target page:page token:token expected:[self aiWorkspaceFingerprint]
            progress:progress sourcePath:sourcePath revision:revision attempts:400];
    // Loading a tab can otherwise save the outgoing/empty viewport over the
    // destination before asynchronous adoption reads it.
    if (!loading) [self rememberActiveTabState];
    [self savePersistentState];
    return @{@"path":path,@"page":@(page),@"opened":@YES,@"loading":@(loading)};
}
@end
