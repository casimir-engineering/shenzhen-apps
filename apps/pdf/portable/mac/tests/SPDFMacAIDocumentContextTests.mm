#import <Cocoa/Cocoa.h>
#import "SPDFMacAIDocumentContext.h"
#import "SPDFMacAIPagePreview.h"
#import "SPDFMacAITools.h"
#import "SPDFMacAIToolsReader.h"
#import "SPDFMacAIToolsComments.h"
#import "SPDFMacAIReaderControls.h"
#import "SPDFMacAIDocumentActions.h"
#import "SPDFMacAIFileTransaction.h"
#import "SPDFMacAICollectionTools.h"
#import "SPDFMacAIIntegration.h"
#import "SPDFMacAISettings.h"
#import "SPDFMacCollectionStore.h"
#import "SPDFMacSearchFileCache.h"
#import "SPDFMacSidebarWorkspace.h"
#import "SPDFMacTabGroupIntegration.h"
#import "markdown/SPDFMarkdownDocument.h"
#import "SPDFMacMarkdownSession.h"
#include <assert.h>
#undef main
static void Check(BOOL value, const char* message) { if (!value) { fprintf(stderr,"FAIL: %s\n",message); abort(); } }
#import "SPDFMacAIPageRegionChecks.h"
#import "SPDFMacAIAppAccessChecks.h"
#import "SPDFMacAIComposerAcceptanceChecks.h"
#import "SPDFMacAIWizardCredentialChecks.h"
@interface ShenzhenMacDelegate (AIContextCacheProbe)
- (NSDictionary*)aiDocumentCandidateForTab:(SPDFDocumentTab*)tab;
- (void)aiInstallAnalysis:(NSDictionary*)analysis error:(NSError*)error candidate:(NSDictionary*)candidate settings:(SPDFMacAISettings*)settings;
@end
@interface AIContextProbe : ShenzhenMacDelegate
@property(nonatomic) NSMutableDictionary* testSidebar;
@property(nonatomic) BOOL cancelDuringProtection;
@property(nonatomic) NSProgress* testProgress;
@property(nonatomic) NSArray* testCandidates;
@property(nonatomic) NSUInteger candidateCalls;
@property(nonatomic) NSUInteger metadataCalls;
@property(nonatomic) NSUInteger candidateSnapshots;
- (void)setTestPage:(NSInteger)page;
- (void)seedPDF:(NSString*)path;
- (void)seedTabs:(NSArray*)tabs;
- (NSString*)visiblePath;
- (void)seedControls;
- (NSInteger)indexOfTabForPath:(NSString*)path;
@end
@implementation AIContextProbe
- (NSArray*)aiDocumentCandidates { self.candidateCalls++; return self.testCandidates ?: [super aiDocumentCandidates]; }
- (NSArray*)aiDocumentPaths { return self.testCandidates ? [self.testCandidates valueForKey:@"path"] : [super aiDocumentPaths]; }
- (NSDictionary*)aiAnalysisForPath:(NSString*)path { self.metadataCalls++; return [super aiAnalysisForPath:path]; }
- (NSDictionary*)aiDocumentCandidateForTab:(SPDFDocumentTab*)tab {self.candidateSnapshots++;return [super aiDocumentCandidateForTab:tab];}
- (void)setTestPage:(NSInteger)page { _pageIndex=page; }
- (void)seedPDF:(NSString*)path {
    _path=path; char error[1024]={}; _doc=spdf_open(path.fileSystemRepresentation,error,sizeof(error));
}
- (void)seedTabs:(NSArray*)tabs { _tabs=[tabs mutableCopy]; _selectedTabIndex=0; _windowSessionID=@"fixture"; _path=[tabs.firstObject path]; }
- (NSString*)visiblePath { return _path; }
- (void)seedControls {
    _zoom=1; _rememberedCustomZoom=1; _fitMode=SPDFFitModeCustom;
    _searchField=[NSSearchField new]; _findRegexCheckbox=[NSButton new];
    NSSegmentedControl* modes=[NSSegmentedControl new]; modes.segmentCount=5;
    for (NSInteger i=0;i<5;i++) [modes setTag:i forSegment:i];
    _sidebarModeControl=modes; _sidebarModeControl.spdf_selectedSidebarMode=SPDFSidebarModeGroups;
}
- (void)persistActiveState {}
- (void)collectionRefreshHistory {}
- (NSInteger)indexOfTabForPath:(NSString*)path { for (NSUInteger i=0;i<_tabs.count;i++) if ([_tabs[i].path isEqual:path]) return (NSInteger)i; return -1; }
- (void)closeTabAtIndex:(NSInteger)index {
    SPDFDocumentTab* selected=[self selectedTab]; [_tabs removeObjectAtIndex:(NSUInteger)index];
    NSUInteger next=[_tabs indexOfObjectIdenticalTo:selected];
    _selectedTabIndex=_tabs.count ? (next==NSNotFound ? 0 : (NSInteger)next) : -1;
    _path=_selectedTabIndex>=0 ? _tabs[(NSUInteger)_selectedTabIndex].path : nil;
}
- (void)collectionOpenPath:(NSString*)path archived:(BOOL)archived {
    (void)archived; NSInteger index=[self indexOfTabForPath:path];
    if (index<0) { SPDFDocumentTab* tab=[SPDFDocumentTab new]; tab.path=path; tab.title=path.lastPathComponent; [_tabs addObject:tab]; index=(NSInteger)_tabs.count-1; }
    _selectedTabIndex=index; _path=path; [self normalizeTabGroups];
}
- (void)adoptRenamedDocumentFrom:(NSString*)source to:(NSString*)destination replacingReadOnly:(BOOL)copy {
    (void)copy; for (SPDFDocumentTab* tab in _tabs) if ([tab.path isEqual:source]) { tab.path=destination; tab.title=destination.lastPathComponent; }
    if ([_path isEqual:source]) _path=destination;
}

- (void)renderDocumentAndScrollToPage:(NSInteger)page alignTop:(BOOL)align { (void)page;(void)align; }
- (void)toggleReadingTheme:(id)sender { (void)sender; _darkReadingTheme=!_darkReadingTheme; }
- (void)toggleDarkThemePreservesImages:(id)sender { (void)sender; [self selectedTab].preservesImageColors=![self selectedTab].preservesImageColors; }
- (void)prioritizeWorkspaceMap {}
- (void)prioritizeWorkspaceSidebar {}
- (void)setMinimapActuallyVisible:(BOOL)visible { _minimapVisible=visible; }
- (void)rebuildSidebar {}
- (void)startFindForCurrentQueryResetSavedIndex:(BOOL)reset revealMatch:(BOOL)reveal { (void)reset;(void)reveal; }

- (void)rememberActiveTabState {}
- (void)updateTabStrip {}
- (void)refreshSidebarWorkspacePanel {}
- (void)collectionRememberGroups {}
- (void)savePersistentState {}
- (NSMutableDictionary*)sidebarWorkspaceState { if (!_testSidebar) _testSidebar=[NSMutableDictionary dictionary]; return _testSidebar; }
- (BOOL)isMarkdownActive { return NO; }
- (void)selectTabAtIndex:(NSInteger)index {
    if (index==_selectedTabIndex) return;
    _selectedTabIndex=index; _path=_tabs[(NSUInteger)index].path;
}
- (BOOL)ensureActivePDFCanBeModifiedForOperation:(NSString*)operation {
    (void)operation; if (self.cancelDuringProtection) [self.testProgress cancel]; return YES;
}
- (void)reloadSelectedTabFromDiskChange {
    if (_doc) spdf_close(_doc); char message[1024]={}; _doc=spdf_open(_path.fileSystemRepresentation,message,sizeof(message));
}
- (void)refreshActiveTabCachedFileAttributesAfterSelfSave {}
- (void)collectionDidSavePath:(NSString*)path { (void)path; }
- (BOOL)collectionProtectPath:(NSString*)path operation:(NSString*)operation { (void)path;(void)operation;return YES; }
- (void)dealloc { if (_doc) { spdf_close(_doc); _doc=NULL; } }
@end
static NSString* FixturePDF(NSString* root) {
    NSString* path=[root stringByAppendingPathComponent:@"evidence.pdf"];
    CGRect media=CGRectMake(0,0,300,300);
    CGContextRef context=CGPDFContextCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],&media,NULL);
    CGPDFContextBeginPage(context,NULL);
    NSGraphicsContext* old=NSGraphicsContext.currentContext;
    NSGraphicsContext.currentContext=[NSGraphicsContext graphicsContextWithCGContext:context flipped:NO];
    [@"Audio amplifier chapter evidence" drawAtPoint:NSMakePoint(20,240) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:14]}];
    NSGraphicsContext.currentContext=old;
    CGPDFContextEndPage(context); CGPDFContextClose(context); CGContextRelease(context); return path;
}
static SPDFDocumentTab* Tab(NSString* path, SPDFTabGroup* group) {
    SPDFDocumentTab* tab=[SPDFDocumentTab new]; tab.path=path; tab.title=path.lastPathComponent; tab.group=group; return tab;
}
#import "SPDFMacAIPageToolChecks.h"
#import "SPDFMacAITextReadChecks.h"
#import "SPDFMacAIChatFolderToolChecks.h"
#import "SPDFMacAICitationNavigationChecks.h"
#import "SPDFMacAIDocumentLinkNavigationChecks.h"
#import "SPDFMacAIOptionalRevisionChecks.h"
#import "SPDFMacAICurrentViewChecks.h"
#import "SPDFMacAICollectionRenameChecks.h"
#import "SPDFMacAIMetadataHistoryChecks.h"
int main(void) { @autoreleasepool {
    NSString* emojiBoundary=[[@"a" stringByPaddingToLength:63999 withString:@"a" startingAtIndex:0] stringByAppendingString:@"😀x"];
    NSString* boundedEmoji=SPDFAIBoundedText(emojiBoundary,64000);
    Check(boundedEmoji.length==63999 && [NSJSONSerialization dataWithJSONObject:@[boundedEmoji] options:0 error:nil]!=nil,"bounded context preserves surrogate pairs");
    NSString* longCombiningBoundary=[@"e" stringByPaddingToLength:100002 withString:@"\u0301" startingAtIndex:0];
    Check(SPDFAIBoundedText(longCombiningBoundary,100000).length==0,"bounded context never exceeds budget for a long composed sequence");
    Check([SPDFAIBoundedText(@"abcd",2) isEqual:@"ab"] && [SPDFAIBoundedText(@"😀",2) isEqual:@"😀"] && SPDFAIBoundedText(@"a",0).length==0,"bounded context exact and zero boundaries");
    [NSApplication sharedApplication];CheckNativeAppAccess();
    NSString* root=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    setenv("SPDF_STATE_DIR",[[root stringByAppendingPathComponent:@"state"] fileSystemRepresentation],1);
    CheckComposerAcceptance();
    CheckWizardCredentialPreservation();
    NSString* path=FixturePDF(root); CheckCitationNavigation(path,root); CheckDocumentLinkNavigation(path,root); NSProgress* progress=[NSProgress progressWithTotalUnitCount:1]; NSError* error=nil;
    NSDictionary* context=SPDFAIDocumentContext(path,NO,1,5,progress,&error);
    Check(context && !error && [context[@"pageCount"] integerValue]==1,"PDF extraction");
    NSArray* matches=SPDFAISearchContext(context,@"Audio",5);
    Check(matches.count==1 && [matches[0][@"page"] integerValue]==1,"search anchors exact page");
    NSString* text=matches[0][@"text"];
    NSRange hit=NSMakeRange([matches[0][@"matchOffset"] unsignedIntegerValue],[matches[0][@"matchLength"] unsignedIntegerValue]);
    Check([[text substringWithRange:hit] isEqual:@"Audio"],"snippet includes exact match");
    Check(!SPDFAIDocumentContext(path,NO,2,5,progress,nil),"out of range rejected");
    Check(SPDFAIDocumentContext(path,NO,1,5,progress,nil)==context,"repeat reads use existing bounded index cache");
    NSString* markdown=[root stringByAppendingPathComponent:@"layout.md"];
    NSMutableString* source=[NSMutableString stringWithString:@"# Layout fixture\n\n"];
    for (NSUInteger i=0;i<100;i++) [source appendFormat:@"Paragraph %lu contains evidence that belongs to its actual page.\n\n",(unsigned long)i];
    [source writeToFile:markdown atomically:YES encoding:NSUTF8StringEncoding error:nil];
    SPDFMarkdownRenderOptions* options=SPDFMarkdownRenderOptions.defaultOptions; options.fontScale=2;
    SPDFMarkdownDocument* document=[SPDFMarkdownDocument documentWithURL:[NSURL fileURLWithPath:markdown] options:options error:nil];
    SPDFMarkdownPaginationPlan* plan=[document paginationPlanForConfiguration:SPDFMarkdownPageConfiguration.A4LandscapeConfiguration];
    NSDictionary* candidate=@{@"readPath":markdown,@"revision":SPDFSearchFileStamp(markdown),@"sourceRevision":SPDFSearchFileStamp(markdown),
        @"renderedDocument":document.renderedDocument,@"paginationPlan":plan};
    NSDictionary* live=SPDFAIDocumentContextForCandidate(candidate,1,100,progress,nil);
    Check([live[@"pageCount"] unsignedIntegerValue]==plan.pages.count,"live text page count uses current typography");
    Check([live[@"layoutIdentity"] length]==64,"live layout has stable fingerprint");
    NSUInteger target=plan.pages.count-1; NSMutableString* expected=[NSMutableString string];
    for (SPDFMarkdownPageFragment* fragment in plan.pages[target].fragments) {
        [expected appendString:[document.renderedDocument.attributedString.string substringWithRange:fragment.attributedRange]];
        [expected appendString:@"\n"];
    }
    Check([live[@"pages"][target][@"text"] isEqual:expected],"live text citations match actual rendered page fragments");
    Check(!SPDFAIDocumentContextForCandidate(@{@"readPath":markdown},1,5,progress,nil),"missing live layout cannot invent page references");
    NSString* hash=SPDFAIContentHash(path,progress,nil); Check(hash.length==64,"streamed hash");
    [progress cancel]; Check(!SPDFAIDocumentContext(path,NO,1,5,progress,nil),"cancelled read rejected");
    progress=[NSProgress progressWithTotalUnitCount:1];
    PageRegionChecks(root);
    CheckPageImageTool(path);
    CheckOptionalRevisions(path);
    CheckCurrentView(path,root);
    CheckTextOnlyPageRead(path);
    NSDictionary* preview=SPDFAIPagePreview(path,NO,1,progress,&error);
    Check(preview && [NSData dataWithContentsOfFile:preview[@"path"]].length>0,"trusted preview generated");
    [NSFileManager.defaultManager removeItemAtPath:[preview[@"path"] stringByDeletingLastPathComponent] error:nil];
    NSURL* cacheURL=[NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"analysis"]];
    SPDFMacAIAnalysisCache* cache=[[SPDFMacAIAnalysisCache alloc] initWithRootURL:cacheURL];
    Check(![cache analysisForHash:hash] && ![NSFileManager.defaultManager fileExistsAtPath:cacheURL.path],"cache construction/read is lazy");
    NSDictionary* model=@{@"summary":@"An amplifier.",@"keywords":@[@"Audio"],@"chapters":@[@{@"title":@"Audio",@"page":@1}],
        @"analyzedPages":@[@1],@"partial":@NO,@"model":@"fixture/model"};
    NSDictionary* analysis=SPDFAIValidateAnalysis(model,1,NO,&error);
    Check(analysis && [cache storeAnalysis:analysis forHash:hash error:&error],"valid analysis persisted");
    Check([[cache analysisForHash:hash][@"model"] isEqual:@"fixture/model"],"provenance retained");
    Check([SPDFAIValidateAnalysis(model,1,YES,nil)[@"chapters"] count]==0,"authored chapters never replaced");
    NSMutableDictionary* invalid=[model mutableCopy]; invalid[@"analyzedPages"]=@[];
    Check(!SPDFAIValidateAnalysis(invalid,1,NO,nil),"hallucinated chapter outside evidence rejected");
    Check(![cache storeAnalysis:analysis forHash:@"../escape" error:nil],"unsafe cache identity rejected");
    AIContextProbe* reader=[AIContextProbe new]; [reader seedPDF:path];
    NSDictionary* originalComments=[reader aiReadCommentsAtPath:path];
    NSProgress* edit=[NSProgress progressWithTotalUnitCount:1]; reader.testProgress=edit; reader.cancelDuringProtection=YES;
    NSDictionary* args=@{@"path":path,@"revision":originalComments[@"revision"],@"operation":@"add",@"page":@1,@"text":@"Review this"};
    Check([reader aiEditComment:args progress:edit][@"error"]!=nil,"cancel during permission handling blocks commit");
    Check([[reader aiReadCommentsAtPath:path][@"comments"] count]==0,"cancelled edit leaves original unchanged");
    reader.cancelDuringProtection=NO; edit=[NSProgress progressWithTotalUnitCount:1];
    NSDictionary* receipt=[reader aiEditComment:args progress:edit];
    Check(receipt[@"beforeBytes"] && !receipt[@"error"],"comment has inverse receipt");
    Check([[reader aiReadCommentsAtPath:path][@"comments"] count]==1,"comment saved");
    Check([reader aiUndoCommentReceipt:receipt progress:progress],"comment inverse restored");
    Check([SPDFAIContentHash(path,progress,nil) isEqual:hash],"undo restores exact original bytes");
    AIContextProbe* workspace=[AIContextProbe new]; SPDFTabGroup* group=[SPDFTabGroup groupWithColor:@"purple"];
    SPDFDocumentTab* first=Tab(@"/first.pdf",group),*second=Tab(@"/second.pdf",group);
    [workspace seedTabs:@[first,second]]; SPDFTabGroup* empty=[workspace createEmptyTabGroup];
    NSDictionary* before=[workspace aiCaptureWorkspace];
    [workspace selectTabAtIndex:1]; empty.name=@"Changed"; [workspace syncEmptyTabGroups];
    Check([workspace aiRestoreWorkspace:before expected:[workspace aiWorkspaceFingerprint]],"workspace inverse accepted");
    Check([[workspace visiblePath] isEqual:@"/first.pdf"],"undo restores actual visible document, not only selected index");
    Check(![[workspace emptyTabGroups].firstObject.name isEqual:@"Changed"],"empty group restored");
    Check([[workspace pendingNewDocumentGroup].identifier isEqual:empty.identifier],"pending target restored");
    SPDFMacAITools* tools=[[SPDFMacAITools alloc] initWithReader:workspace];
    __block NSDictionary* result=nil;
    [tools performTool:@"read_pages" arguments:@{@"path":@"/etc/passwd"} completion:^(NSDictionary* value){ result=value; }];
    Check(result[@"error"]!=nil,"model cannot read arbitrary files");
    [tools performTool:@"performSelector" arguments:@{} completion:^(NSDictionary* value){ result=value; }];
    Check(result[@"error"]!=nil,"arbitrary selector rejected");
    result=nil;
    [tools performTool:@"list_workspace" arguments:@{} completion:^(NSDictionary* value){ result=value; }];
    NSString* json=[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:result options:0 error:nil] encoding:NSUTF8StringEncoding];
    Check([json rangeOfString:@"/first.pdf"].location==NSNotFound && [json containsString:@"doc:"],"workspace exposes opaque IDs instead of local paths");
    CheckChatFolderTools(reader);
    [reader seedTabs:@[Tab(path,group)]]; SPDFMacAITools* readTools=[[SPDFMacAITools alloc] initWithReader:reader];
    result=nil;
    [readTools performTool:@"read_pages" arguments:@{@"path":SPDFAIDocumentIdentifier(path)} completion:^(NSDictionary* value){ result=value; }];
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:5];
    while (!result && deadline.timeIntervalSinceNow>0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    Check(result && !result[@"error"] && [result[@"path"] isEqual:SPDFAIDocumentIdentifier(path)],"opaque ID resolves to authorized document");
    Check([result[@"pages"][0][@"citation"] containsString:@"doc:"],"citation URL contains opaque ID");
    [SPDFMacAIChatStore discardTemporaryPreview:result[@"_localPreview"]];
    NSMutableDictionary* navigationCandidate=[candidate mutableCopy]; navigationCandidate[@"path"]=markdown;
    navigationCandidate[@"title"]=markdown.lastPathComponent; reader.testCandidates=@[navigationCandidate.copy];
    result=nil;
    [readTools performTool:@"show_document" arguments:@{@"path":SPDFAIDocumentIdentifier(markdown),@"page":@1,
        @"layoutIdentity":live[@"layoutIdentity"]} completion:^(NSDictionary* value){ result=value; }];
    // Change immutable layout identity after worker capture but before main-thread navigation.
    navigationCandidate[@"paginationPlan"]=[NSObject new]; reader.testCandidates=@[navigationCandidate.copy];
    deadline=[NSDate dateWithTimeIntervalSinceNow:5];
    while (!result && deadline.timeIntervalSinceNow>0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    Check(result[@"error"]!=nil && [[reader visiblePath] isEqual:path],"citation refuses layout change between retrieval and navigation");
    reader.testCandidates=nil;
    SPDFMacMarkdownSession* sourceSession=[[SPDFMacMarkdownSession alloc] initWithDocumentURL:[NSURL fileURLWithPath:markdown]];
    NSView* sourceHost=[[NSView alloc] initWithFrame:NSMakeRect(0,0,640,480)];
    dispatch_queue_t sourceQueue=dispatch_queue_create("ai-source-revision-test",DISPATCH_QUEUE_SERIAL);
    __block BOOL sourceLoaded=NO;
    [sourceSession activateInHostView:sourceHost workQueue:sourceQueue scrollOrigin:NSZeroPoint selectedRange:NSMakeRange(0,0)
        pageIndex:0 zoom:1 fitMode:SPDFMacMarkdownPageFitPage anchor:nil completion:^(BOOL ok,NSError* error){(void)error;sourceLoaded=ok;}];
    deadline=[NSDate dateWithTimeIntervalSinceNow:5];
    while ((!sourceLoaded || !sourceSession.isNavigationReady) && deadline.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    Check([sourceSession.loadedSourceRevision isEqual:SPDFSearchFileStamp(markdown)],"installed source retains parser revision");
    AIContextProbe* sourceReader=[AIContextProbe new]; SPDFDocumentTab* sourceTab=Tab(markdown,group);
    sourceTab.cachedMarkdownSession=sourceSession; [sourceReader seedTabs:@[sourceTab]];
    Check([sourceReader aiDocumentCandidates][0][@"paginationPlan"]!=nil,"current parsed source supplies live context");
    NSString* loadedRevision=sourceSession.loadedSourceRevision;
    [@"# Changed source\nNew evidence." writeToFile:markdown atomically:YES encoding:NSUTF8StringEncoding error:nil];
    Check([sourceSession.loadedSourceRevision isEqual:loadedRevision] &&
        ![sourceReader aiDocumentCandidates][0][@"paginationPlan"],"old render cannot adopt new disk revision before watcher reload");
    NSMutableDictionary* staleCandidate=[candidate mutableCopy]; staleCandidate[@"revision"]=SPDFSearchFileStamp(markdown);
    Check(!SPDFAIDocumentContextForCandidate(staleCandidate,1,1,progress,nil) &&
        !SPDFAIPagePreviewForCandidate(staleCandidate,1,progress,nil),"stale snapshot cannot supply text or preview under new file hash");
    [sourceSession reloadFromDiskWithStatus:nil]; deadline=[NSDate dateWithTimeIntervalSinceNow:5];
    while ((!sourceSession.isNavigationReady || ![sourceSession.loadedSourceRevision isEqual:SPDFSearchFileStamp(markdown)]) && deadline.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    Check([sourceSession.loadedSourceRevision isEqual:SPDFSearchFileStamp(markdown)] &&
        [sourceReader aiDocumentCandidates][0][@"paginationPlan"]!=nil,"disk reload installs fresh source provenance with its render");
    [sourceSession deactivate];

    [reader seedControls];
    NSProgress* controlProgress=[NSProgress progressWithTotalUnitCount:1];
    NSDictionary* zoom=[reader aiApplyReaderControl:@{@"path":path,@"control":@"zoom",@"value":@"125"} progress:controlProgress];
    Check(zoom[@"controlReceipt"] && [[reader aiReaderControls][@"zoomPercent"] doubleValue]==125,"reader zoom applies exact desired percentage");
    [reader aiApplyReaderControl:@{@"path":path,@"control":@"theme",@"value":@"dark"} progress:controlProgress];
    Check([reader aiUndoReaderControl:zoom[@"controlReceipt"] progress:controlProgress],"zoom inverse ignores unrelated theme edit");
    Check([[reader aiReaderControls][@"zoomPercent"] doubleValue]==100 && [[reader aiReaderControls][@"theme"] isEqual:@"dark"],"undo restores only its own settings");
    NSDictionary* map=[reader aiApplyReaderControl:@{@"path":path,@"control":@"map",@"value":@"shown"} progress:controlProgress];
    Check([[reader aiReaderControls][@"mapVisible"] boolValue],"map control shows panel");
    Check([reader aiUndoReaderControl:map[@"controlReceipt"] progress:controlProgress] && ![[reader aiReaderControls][@"mapVisible"] boolValue],"map inverse restores preference");
    NSDictionary* search=[reader aiApplyReaderControl:@{@"path":path,@"control":@"find",@"value":@"Audio"} progress:controlProgress];
    Check([[reader aiReaderControls][@"searchQuery"] isEqual:@"Audio"],"find control sets query");
    Check([reader aiUndoReaderControl:search[@"controlReceipt"] progress:controlProgress] && ![[reader aiReaderControls][@"searchQuery"] length],"find inverse restores prior query and panel");
    Check([reader aiApplyReaderControl:@{@"path":path,@"control":@"zoom",@"value":@"120garbage"} progress:controlProgress][@"error"]!=nil,"numeric control rejects trailing junk");
    Check([reader aiApplyReaderControl:@{@"path":path,@"control":@"text-size",@"value":@"125"} progress:controlProgress][@"error"]!=nil,"PDF text size unsupported explicitly");
    Check([reader aiApplyReaderControl:@{@"path":@"/different.pdf",@"control":@"theme",@"value":@"light"} progress:controlProgress][@"error"]!=nil,"reader control cannot mutate wrong active document");
    [controlProgress cancel];
    Check([reader aiApplyReaderControl:@{@"path":path,@"control":@"theme",@"value":@"light"} progress:controlProgress][@"error"]!=nil && [[reader aiReaderControls][@"theme"] isEqual:@"dark"],"cancelled controls cannot mutate");
    controlProgress=[NSProgress progressWithTotalUnitCount:1];
    NSDictionary* rotation=[reader aiApplyReaderControl:@{@"path":path,@"control":@"rotate",@"value":@"clockwise",@"revision":SPDFSearchFileStamp(path)} progress:controlProgress];
    Check(rotation[@"fileReceipt"]!=nil,"PDF rotation supplies exact file inverse");
    Check([reader aiUndoCommentReceipt:rotation[@"fileReceipt"] progress:controlProgress] && [SPDFAIContentHash(path,progress,nil) isEqual:hash],"PDF rotation undo restores exact bytes");
    result=nil;
    [readTools performTool:@"reader_control" arguments:@{@"path":SPDFAIDocumentIdentifier(path),@"control":@"map",@"value":@"shown"} completion:^(NSDictionary* value){ result=value; }];
    Check([result[@"undoable"] boolValue] && !result[@"controlReceipt"] && readTools.canUndo,"tool action journal strips private receipt");
    Check([readTools undoLastAction:nil] && ![[reader aiReaderControls][@"mapVisible"] boolValue],"tool undo dispatch restores reader control");
    NSData* sourceBytes=[NSData dataWithContentsOfFile:path];
    NSDictionary* failedEdit=SPDFAIMutatePDF(path,SPDFSearchFileStamp(path),controlProgress,^BOOL(spdf_document* document,char* message,size_t length) {
        (void)document; snprintf(message,length,"deliberate failed mutation"); return NO;
    },nil);
    Check(!failedEdit && [[NSData dataWithContentsOfFile:path] isEqual:sourceBytes],"failed staged mutation cannot alter original");
    NSDictionary* firstEdit=SPDFAIMutatePDF(path,SPDFSearchFileStamp(path),controlProgress,^BOOL(spdf_document* document,char* message,size_t length) {
        return spdf_rotate_page(document,0,90,message,length);
    },nil);
    NSDictionary* secondEdit=SPDFAIMutatePDF(path,SPDFSearchFileStamp(path),controlProgress,^BOOL(spdf_document* document,char* message,size_t length) {
        return spdf_rotate_page(document,0,90,message,length);
    },nil);
    Check(firstEdit && secondEdit && SPDFAIUndoFileTransaction(secondEdit,controlProgress,nil) &&
        SPDFAIUndoFileTransaction(firstEdit,controlProgress,nil) && [[NSData dataWithContentsOfFile:path] isEqual:sourceBytes],
        "two-step file undo restores exact bytes despite replacement stamps");
    NSMutableData* externalBytes=[sourceBytes mutableCopy]; [externalBytes appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
    NSDictionary* raced=SPDFAIMutatePDF(path,SPDFSearchFileStamp(path),controlProgress,^BOOL(spdf_document* document,char* message,size_t length) {
        [externalBytes writeToFile:path atomically:YES]; return spdf_rotate_page(document,0,90,message,length);
    },nil);
    Check(!raced && [[NSData dataWithContentsOfFile:path] isEqual:externalBytes],"external edit during staged mutation is never overwritten");
    [sourceBytes writeToFile:path atomically:YES]; [reader seedTabs:@[Tab(path,group)]];
    NSDictionary* renamed=[reader aiRenameDocument:@{@"path":path,@"name":@"renamed.pdf",@"revision":SPDFSearchFileStamp(path)} progress:controlProgress];
    NSString* renamedPath=[root stringByAppendingPathComponent:@"renamed.pdf"];
    Check(renamed[@"documentReceipt"] && ![NSFileManager.defaultManager fileExistsAtPath:path] && [NSFileManager.defaultManager fileExistsAtPath:renamedPath],"rename moves only the authorized file");
    Check([reader aiUndoDocumentAction:renamed[@"documentReceipt"] progress:controlProgress] && [NSFileManager.defaultManager fileExistsAtPath:path],"rename inverse restores original path");
    [workspace seedTabs:@[first,second]]; [workspace seedControls];
    NSDictionary* closed=[workspace aiCloseDocument:first.path progress:controlProgress];
    Check([closed[@"closed"] boolValue] && [[workspace visiblePath] isEqual:second.path],"close selects remaining document");
    Check([workspace aiUndoDocumentAction:closed[@"documentReceipt"] progress:controlProgress] && [[workspace visiblePath] isEqual:first.path],"reopen restores previous group order and selection");
    [workspace seedTabs:@[first]];
    closed=[workspace aiCloseDocument:first.path progress:controlProgress];
    Check([closed[@"closed"] boolValue] && ![workspace visiblePath],"last tab close leaves empty reader for Undo");
    Check([workspace aiUndoDocumentAction:closed[@"documentReceipt"] progress:controlProgress] && [[workspace visiblePath] isEqual:first.path],"last tab can reopen");
    NSDictionary* sameOpen=[workspace aiOpenCollectionDocumentAtPath:first.path archived:NO progress:controlProgress];
    [workspace setTestPage:5];
    Check(![workspace aiUndoDocumentAction:sameOpen[@"documentReceipt"] progress:controlProgress],"document action undo preserves subsequent human page navigation");
    [workspace setTestPage:0];
    NSDictionary* opened=[workspace aiOpenCollectionDocumentAtPath:path archived:NO progress:controlProgress];
    Check([opened[@"opened"] boolValue] && [[workspace visiblePath] isEqual:path],"Collection target opens through native path adapter");
    Check([workspace aiUndoDocumentAction:opened[@"documentReceipt"] progress:controlProgress] && [[workspace visiblePath] isEqual:first.path],"undo Collection open restores prior document");
    SPDFMacCollectionStore* collection=SPDFMacCollectionStore.defaultStore;
    Check([collection updateSettings:@{@"choice":@"enabled"} error:nil],"isolated Collection enabled");
    NSDictionary* captured=[collection capturePath:path reason:@"test" error:nil];
    Check(captured!=nil,"fixture captured");
    NSDictionary* catalog=SPDFAICollectionDocuments(@"evidence",1,controlProgress);
    Check([catalog[@"documents"] count]==1,"Collection title search lists fixture");
    NSString* collectionID=catalog[@"documents"][0][@"documentID"];
    NSDictionary* collectionTarget=SPDFAICollectionOpenTarget(collectionID,NO,controlProgress);
    Check([collectionTarget[@"readPath"] isEqual:path] && ![collectionTarget[@"archived"] boolValue],"Collection latest uses original when available");
    collectionTarget=SPDFAICollectionOpenTarget(collectionID,YES,controlProgress);
    Check([collectionTarget[@"archived"] boolValue] && [NSFileManager.defaultManager fileExistsAtPath:collectionTarget[@"readPath"]],"explicit Collection copy materializes saved document");
    CheckAICollectionRename(reader,collection,captured,collectionTarget[@"readPath"],group);
    Check(SPDFAICollectionOpenTarget(@"/etc/passwd",NO,controlProgress)[@"error"]!=nil,"Collection rejects arbitrary path IDs");
    [reader seedTabs:@[Tab(path,group)]]; result=nil;
    SPDFMacAITools* jobTools=[[SPDFMacAITools alloc] initWithReader:reader];
    Check(![NSFileManager.defaultManager fileExistsAtPath:[[root stringByAppendingPathComponent:@"state"] stringByAppendingPathComponent:@"Assistant Exports"]],"tool creation and ordinary reads never create job storage");
    [jobTools performTool:@"document_job" arguments:@{@"path":SPDFAIDocumentIdentifier(path),@"kind":@"export-pdf",
        @"revision":SPDFSearchFileStamp(path)} completion:^(NSDictionary* value){ result=value; }];
    deadline=[NSDate dateWithTimeIntervalSinceNow:10];
    while (!result && deadline.timeIntervalSinceNow>0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    NSString* generatedPath=[reader visiblePath];
    Check([result[@"completed"] boolValue] && [result[@"undoable"] boolValue] &&
        !result[@"documentReceipt"] && [result[@"path"] hasPrefix:@"doc:"] && [generatedPath hasPrefix:[root stringByAppendingString:@"/"]] &&
        ![generatedPath isEqual:path] && [NSFileManager.defaultManager fileExistsAtPath:generatedPath],"async export dispatcher returns opaque result and Undo action");
    Check([jobTools undoLastAction:nil] && [[reader visiblePath] isEqual:path] &&
        ![NSFileManager.defaultManager fileExistsAtPath:generatedPath],"job Undo removes only owned output and restores reader");
    AIContextProbe* large=[AIContextProbe new]; NSMutableArray* many=[NSMutableArray array];
    for (NSUInteger index=0;index<1000;index++) {
        SPDFTabGroup* manyGroup=[SPDFTabGroup fromDictionary:@{@"id":[NSString stringWithFormat:@"group-%lu",(unsigned long)index],@"name":@"Many documents",@"color":@"blue"}];
        [many addObject:Tab([NSString stringWithFormat:@"/workspace/document-%lu.pdf",(unsigned long)index],manyGroup)];
    }
    [large seedTabs:many]; SPDFMacAITools* largeTools=[[SPDFMacAITools alloc] initWithReader:large]; result=nil;
    [largeTools performTool:@"list_workspace" arguments:@{} completion:^(NSDictionary* value){result=value;}];
    Check([result[@"tabs"] count]==50 && [result[@"groups"] count]==50 && [result[@"next"] integerValue]==51 &&
        [result[@"nextGroup"] integerValue]==51 && [result[@"totalDocuments"] integerValue]==1000,"workspace discovery paginates large hierarchy");
    Check(!large.candidateCalls && !large.metadataCalls,"listing does no file-stat candidate pass or per-document analysis lookup");
    NSUInteger workspaceBytes=[NSJSONSerialization dataWithJSONObject:result options:0 error:nil].length;
    Check(workspaceBytes<100000,"large workspace discovery fits tool-result budget");
    printf("1000-tab workspace first page: %lu bytes, %lu candidate passes, %lu analysis lookups\n",(unsigned long)workspaceBytes,(unsigned long)large.candidateCalls,(unsigned long)large.metadataCalls);
    NSString* firstID=result[@"tabs"][0][@"path"],*firstGroup=result[@"groups"][0][@"id"];
    [largeTools performTool:@"list_workspace" arguments:@{@"first":@51,@"groupFirst":@51,@"count":@100} completion:^(NSDictionary* value){result=value;}];
    Check([result[@"tabs"] count]==100 && [result[@"tabs"][0][@"index"] integerValue]==51 &&
        [result[@"next"] integerValue]==151,"workspace continuation preserves order without duplicates");
    [largeTools performTool:@"list_workspace" arguments:@{@"groupID":firstGroup} completion:^(NSDictionary* value){result=value;}];
    Check([result[@"totalDocuments"] integerValue]==1 && [result[@"tabs"][0][@"path"] isEqual:firstID],"group scope filters document discovery");
    NSMutableString* longLabel=[NSMutableString string]; for (NSUInteger i=0;i<200;i++) [longLabel appendString:@"📖"];
    for (SPDFDocumentTab* tab in many) { tab.title=longLabel; tab.group.name=longLabel; }
    [largeTools performTool:@"list_workspace" arguments:@{@"count":@100} completion:^(NSDictionary* value){result=value;}];
    Check([NSJSONSerialization dataWithJSONObject:result options:0 error:nil].length<100000 && result[@"next"]!=NSNull.null,
        "UTF8-heavy names obey byte budget with continuation even at maximum page size");
    result=nil;
    [largeTools performTool:@"document_metadata" arguments:@{@"path":firstID} completion:^(NSDictionary* value){result=value;}];
    deadline=[NSDate dateWithTimeIntervalSinceNow:5];
    while(!result && deadline.timeIntervalSinceNow>0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    Check(result && !result[@"error"] && large.metadataCalls==1 && !large.candidateCalls,"explicit metadata performs one lookup without eager workspace analysis");
    NSString* combining=[@"A" stringByPaddingToLength:120000 withString:@"\u0301" startingAtIndex:0];
    [many.firstObject setTitle:combining]; [[many.firstObject group] setName:combining];
    [largeTools performTool:@"list_workspace" arguments:@{} completion:^(NSDictionary* value){result=value;}];
    Check([result[@"tabs"][0][@"title"] length]<=200 && [result[@"groups"][0][@"displayName"] length]<=160 &&
        [NSJSONSerialization dataWithJSONObject:result options:0 error:nil].length<100000,"oversized composed character cannot escape first-row byte budget");
    SPDFMacAISettings* cacheSettings=[[SPDFMacAISettings alloc] initWithURL:[NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"probe-settings.yaml"]]];
    cacheSettings.enabled=YES;cacheSettings.automaticAnalysis=YES;
    [large seedTabs:@[]]; [large configureAIAnalysis:cacheSettings]; [large seedTabs:many];
    NSString* metadataPath=[many.lastObject path];
    NSDictionary* metadataCandidate=[large aiDocumentCandidateForPath:metadataPath];
    [large aiInstallAnalysis:@{@"model":cacheSettings.model,@"summary":@"Cached source summary",@"keywords":@[],@"chapters":@[]}
        error:nil candidate:metadataCandidate settings:cacheSettings];
    large.candidateSnapshots=0; large.candidateCalls=0; large.metadataCalls=0;
    result=nil;
    [largeTools performTool:@"document_metadata" arguments:@{@"path":SPDFAIDocumentIdentifier(metadataPath)} completion:^(NSDictionary* value){result=value;}];
    deadline=[NSDate dateWithTimeIntervalSinceNow:5];
    while(!result && deadline.timeIntervalSinceNow>0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    Check([result[@"analysis"][@"summary"] isEqual:@"Cached source summary"] && large.candidateSnapshots==1 &&
        !large.candidateCalls && large.metadataCalls==1,"production cached metadata validates only its selected document in 1000-tab workspace");
    CheckAIMetadataHistory(root,path);
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
    puts("SPDFMacAIDocumentContextTests passed"); return 0;
} }
