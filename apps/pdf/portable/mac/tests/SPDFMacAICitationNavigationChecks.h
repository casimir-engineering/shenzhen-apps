#import "SPDFMacAICitations.h"
#import <PDFKit/PDFKit.h>
// Real PDF find pipeline and AI retrieval/navigation, with only window rendering
// and persistence suppressed. No user document, app window or network is used.
@interface AICitationReaderProbe : ShenzhenMacDelegate
@property(nonatomic) BOOL deferNextSelection;
@property(nonatomic) BOOL restoreSavedViewport;
- (void)finishLoading;
- (void)seedPaths:(NSArray<NSString*>*)paths;
- (BOOL)hasCitationHighlights;
@end
@implementation AICitationReaderProbe
- (void)seedPaths:(NSArray<NSString*>*)paths {
    _tabs=[NSMutableArray array];
    SPDFTabGroup* group=[SPDFTabGroup groupWithColor:@"blue"];
    for(NSString* path in paths)[_tabs addObject:Tab(path,group)];
    _selectedTabIndex=-1;_windowSessionID=@"citation-test";
    _searchField=[NSSearchField new];_findRegexCheckbox=[NSButton new];
    _findQueue=[NSOperationQueue new];_findQueue.maxConcurrentOperationCount=1;
    _findMatches=[NSMutableArray array];_findHighlights=[NSMutableDictionary dictionary];
    _pendingFindPreferredPage=-1;_pendingFindPreferredMatchIndex=-1;
    [self selectTabAtIndex:0];
}
- (void)selectTabAtIndex:(NSInteger)index {
    if(_doc)spdf_close(_doc);_doc=NULL;
    _selectedTabIndex=index;_path=_tabs[(NSUInteger)index].path;_workingPath=_path;
    if(self.deferNextSelection) { self.deferNextSelection=NO;return; }
    [self finishLoading];
}
- (void)finishLoading {
    char error[1024]={};_doc=spdf_open(_path.fileSystemRepresentation,error,sizeof(error));
    if (!self.restoreSavedViewport) return;
    SPDFDocumentTab* tab=[self selectedTab];_pageIndex=tab.pageIndex;
    // Mirror presentOpenedDocument's deferred layout stabilization: it captures
    // the saved origin before the citation's immediate goToPage call.
    NSValue* origin=tab.hasScrollOrigin ? [NSValue valueWithPoint:tab.scrollOrigin] : nil;
    dispatch_async(dispatch_get_main_queue(),^{
        if ([self selectedTab]==tab) self->_pageIndex=origin ? (NSInteger)origin.pointValue.y : self->_pageIndex;
    });
}
- (BOOL)hasCitationHighlights { return !_findSearchInProgress && _findMatches.count>0 && [_findHighlights[@0] count]>0; }
- (void)goToPage:(NSInteger)page preserveSinglePagePosition:(BOOL)preserve { (void)preserve;_pageIndex=page; }
- (void)jumpToFindMatchAtIndex:(NSInteger)index { _findMatchIndex=index;_pageIndex=[_findMatches[(NSUInteger)index][@"page"] integerValue]; }
- (void)rebuildSidebar {}
- (void)showSearchSidebarForFind {}
- (void)updateFindControls {}
- (void)updateMinimap {}
- (void)rememberActiveTabState {}
- (void)savePersistentState {}
- (void)dealloc { [_findQueue cancelAllOperations];if(_doc){spdf_close(_doc);_doc=NULL;} }
@end
static NSDictionary* CitationTool(SPDFMacAITools* tools,NSString* name,NSDictionary* arguments) {
    __block NSDictionary* result=nil;
    [tools performTool:name arguments:arguments completion:^(NSDictionary* value){result=value;}];
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:5];
    while(!result && deadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    Check(result!=nil,"citation tool completes");return result;
}
static void CheckCitationNavigation(NSString* path,NSString* root) {
    NSString* other=[root stringByAppendingPathComponent:@"other-source.pdf"];
    Check([NSFileManager.defaultManager copyItemAtPath:path toPath:other error:nil],"citation fixture copied");
    AICitationReaderProbe* reader=[AICitationReaderProbe new];[reader seedPaths:@[other,path]];
    SPDFMacAITools* tools=[[SPDFMacAITools alloc] initWithReader:reader];
    NSDictionary* search=CitationTool(tools,@"search_documents",@{@"path":SPDFAIDocumentIdentifier(path),@"query":@"Audio amplifier"});
    NSString* link=[search[@"matches"] firstObject][@"citation"];
    NSDictionary* args=SPDFMacAICitationArguments([NSURL URLWithString:link]);
    NSURLComponents* encoded=[NSURLComponents componentsWithString:link];
    NSMutableArray<NSURLQueryItem*>* items=[encoded.queryItems mutableCopy];
    for(NSUInteger i=0;i<items.count;i++) if([items[i] name] && [[items[i] name] isEqual:@"query"])
        items[i]=[NSURLQueryItem queryItemWithName:@"query" value:@"功率 & board input"];
    encoded.queryItems=items;
    Check([SPDFMacAICitationArguments(encoded.URL)[@"query"] isEqual:@"功率 & board input"],"citation query roundtrips Unicode spaces and ampersand");
    for(NSUInteger i=0;i<items.count;i++) if([[items[i] name] isEqual:@"query"])
        items[i]=[NSURLQueryItem queryItemWithName:@"query" value:[@"x" stringByPaddingToLength:513 withString:@"x" startingAtIndex:0]];
    encoded.queryItems=items;
    Check(!SPDFMacAICitationArguments(encoded.URL),"citation rejects passages beyond512characters");
    Check(CitationTool(tools,@"search_documents",@{@"path":SPDFAIDocumentIdentifier(path),@"query":[@"x" stringByPaddingToLength:513 withString:@"x" startingAtIndex:0]})[@"error"]!=nil,"long search rejects instead of dropping citation highlight");
    Check([args[@"query"] isEqual:@"Audio amplifier"],"citation encodes the matched passage");
    NSString* body=[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:search options:0 error:nil] encoding:NSUTF8StringEncoding];
    NSDictionary* chat=@{@"messages":@[@{@"role":@"tool",@"content":body}]};
    Check(SPDFMacAIChatContainsCitation(chat,args),"retrieved passage link accepted");
    NSMutableDictionary* invented=[args mutableCopy];invented[@"query"]=@"invented quote";
    Check(!SPDFMacAIChatContainsCitation(chat,invented),"modified passage URL rejected");
    Check(CitationTool(tools,@"show_document",invented)[@"error"]!=nil,"passage absent from cited page rejected");
    NSDictionary* shown=CitationTool(tools,@"show_document",args);
    Check([shown[@"opened"] boolValue] && [[reader aiReaderControls][@"path"] isEqual:path],"citation opens the correct other tab");
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:5];
    while(!reader.hasCitationHighlights && deadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    Check(reader.hasCitationHighlights,"citation produces real PDF search highlight rectangles");
    Check([[reader aiReaderControls][@"searchQuery"] isEqual:@"Audio amplifier"],"literal query visible in reader controls");
    Check([tools undoLastAction:nil],"citation Undo remains valid after highlighting finishes");
    Check([[reader aiReaderControls][@"path"] isEqual:other] && ![[reader aiReaderControls][@"searchQuery"] length],"Undo restores prior document and search");
    for(NSString* mode in @[@"complete",@"manual-search",@"cancel",@"undo"]) {
        AICitationReaderProbe* pending=[AICitationReaderProbe new];[pending seedPaths:@[other,path]];pending.deferNextSelection=YES;
        SPDFMacAITools* deferred=[[SPDFMacAITools alloc] initWithReader:pending];
        NSDictionary* value=CitationTool(deferred,@"show_document",args);
        Check([value[@"loading"] boolValue],"deferred citation starts loading");
        if([mode isEqual:@"manual-search"]) [[pending valueForKey:@"searchField"] setStringValue:@"human edit"];
        if([mode isEqual:@"cancel"]) [deferred cancel];
        if([mode isEqual:@"undo"]) Check([deferred undoLastAction:nil],"Undo cancels pending citation");
        else [pending finishLoading];
        NSDate* settled=[NSDate dateWithTimeIntervalSinceNow:.25];
        while(settled.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
        if([mode isEqual:@"complete"]) {
            Check(pending.hasCitationHighlights,"deferred source receives highlights once ready");
            Check([deferred undoLastAction:nil],"deferred highlights do not invalidate their own Undo receipt");
        } else Check(!pending.hasCitationHighlights,"cancelled or superseded citation never applies late highlights");
        if([mode isEqual:@"manual-search"]) Check([[pending aiReaderControls][@"searchQuery"] isEqual:@"human edit"],"pending citation preserves manual query");
    }
    NSString* multiPath=[root stringByAppendingPathComponent:@"citation-two-pages.pdf"];
    PDFDocument* multi=[[PDFDocument alloc] initWithURL:[NSURL fileURLWithPath:path]];
    [multi insertPage:[[multi pageAtIndex:0] copy] atIndex:1];
    Check([multi writeToFile:multiPath],"two-page delayed extraction fixture saved");
    // Plain page links (as returned by render_page/read_pages) must survive
    // saved viewport restoration, including a document still being opened.
    for (NSNumber* deferred in @[@NO,@YES]) {
        AICitationReaderProbe* opening=[AICitationReaderProbe new];[opening seedPaths:@[other,multiPath]];
        SPDFDocumentTab* target=[[opening valueForKey:@"tabs"] objectAtIndex:1];
        target.pageIndex=0;target.hasScrollOrigin=YES;target.scrollOrigin=NSMakePoint(0,0);
        opening.restoreSavedViewport=YES;opening.deferNextSelection=deferred.boolValue;
        SPDFMacAITools* navigator=[[SPDFMacAITools alloc] initWithReader:opening];
        CitationTool(navigator,@"show_document",@{@"path":SPDFAIDocumentIdentifier(multiPath),@"page":@2});
        if (deferred.boolValue) [opening finishLoading];
        NSDate* settled=[NSDate dateWithTimeIntervalSinceNow:.15];
        while(settled.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
        Check([[opening valueForKey:@"pageIndex"] integerValue]==1,"first page citation beats the previous saved viewport after layout settles");
        Check([navigator undoLastAction:nil],"first-click navigation keeps Undo valid after deferred layout");
    }
    for(NSString* mode in @[@"complete",@"manual-page",@"manual-search",@"multiline",@"cancel",@"later-tool-cancel",@"source-change",@"undo"]) {
        AICitationReaderProbe* extracting=[AICitationReaderProbe new];[extracting seedPaths:@[multiPath]];
        NSOperationQueue* queue=[extracting valueForKey:@"findQueue"];queue.suspended=YES;
        SPDFMacAITools* delayed=[[SPDFMacAITools alloc] initWithReader:extracting];
        NSDictionary* value=CitationTool(delayed,@"show_document",@{@"path":SPDFAIDocumentIdentifier(multiPath),@"page":@1,@"query":@"Audio amplifier"});
        Check([value[@"opened"] boolValue] && [[extracting valueForKey:@"findSearchInProgress"] boolValue],"citation extraction is queued before intervention");
        if([mode isEqual:@"manual-page"]) [extracting goToPage:1 preserveSinglePagePosition:NO];
        if([mode isEqual:@"manual-search"]) [[extracting valueForKey:@"searchField"] setStringValue:@"human edit"];
        if([mode isEqual:@"multiline"]) [extracting setValue:@NO forKey:@"findRegexMultiline"];
        if([mode isEqual:@"source-change"]) {
            NSMutableData* changed=[[NSData dataWithContentsOfFile:multiPath] mutableCopy];[changed appendBytes:"\n" length:1];
            Check([changed writeToFile:multiPath atomically:YES],"citation source changes during queued extraction");
        }
        if([mode isEqual:@"later-tool-cancel"]) CitationTool(delayed,@"read_pages",@{@"path":SPDFAIDocumentIdentifier(multiPath)});
        if([mode isEqual:@"cancel"] || [mode isEqual:@"later-tool-cancel"]) [delayed cancel];
        if([mode isEqual:@"undo"]) Check([delayed undoLastAction:nil],"Undo supersedes queued extraction");
        queue.suspended=NO;
        NSDate* extractionDeadline=[NSDate dateWithTimeIntervalSinceNow:5];
        while((queue.operationCount || [[extracting valueForKey:@"findSearchInProgress"] boolValue]) && extractionDeadline.timeIntervalSinceNow>0)
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
        Check(![[extracting valueForKey:@"findSearchInProgress"] boolValue],"discarded extraction clears busy state");
        if([mode isEqual:@"complete"]) Check(extracting.hasCitationHighlights,"uninterrupted queued citation publishes highlights");
        else Check(!extracting.hasCitationHighlights,"superseded queued extraction cannot publish late highlights");
        if([mode isEqual:@"manual-page"]) Check([[extracting valueForKey:@"pageIndex"] integerValue]==1,"late extraction preserves human page navigation");
    }
    NSMutableDictionary* stale=[args mutableCopy];stale[@"revision"]=@"old-revision";
    Check(CitationTool(tools,@"show_document",stale)[@"error"]!=nil,"changed source revision rejected");
    Check(CitationTool(tools,@"show_document",@{@"path":args[@"path"],@"page":@999,@"query":@"Audio"})[@"error"]!=nil,"out-of-range passage rejected safely");
    fprintf(stdout,"Citation source links, provenance, cross-tab navigation and PDF highlights passed\n");
}
