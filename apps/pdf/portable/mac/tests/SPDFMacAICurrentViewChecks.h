#pragma once
#import "SPDFMacAICurrentView.h"
#import "SPDFMacAIChatVision.h"
@interface AIViewportCanvas : SPDFDocumentView
@property NSUInteger draws;
@end
// The chat store removes current_view's ShenzhenPDF-AI-<UUID>/viewport.png folder once it keeps a copy or the
// preview is discarded, in the app as here. A folder still there fails the check; it is removed first, because a
// failed Check aborts and the run must still leave nothing behind.
static void CheckViewportFolderRemoved(NSDictionary* preview,const char* message) {
    NSString* path=[preview[@"path"] isKindOfClass:NSString.class] ? preview[@"path"] : nil;
    NSString* folder=path.stringByDeletingLastPathComponent;
    NSString* parent=folder.stringByDeletingLastPathComponent.stringByResolvingSymlinksInPath;
    BOOL ours=[path.lastPathComponent isEqual:@"viewport.png"] &&
        [folder.lastPathComponent hasPrefix:@"ShenzhenPDF-AI-"] &&
        [parent isEqual:NSTemporaryDirectory().stringByResolvingSymlinksInPath];
    BOOL gone=ours && ![NSFileManager.defaultManager fileExistsAtPath:folder];
    if(ours && !gone)[NSFileManager.defaultManager removeItemAtPath:folder error:nil];
    Check(gone,message);
}
@implementation AIViewportCanvas
- (void)drawRect:(NSRect)rect {
    self.draws++;[NSColor.redColor setFill];NSRectFill(self.bounds);
    [NSColor.blueColor setFill];NSRectFill(NSMakeRect(100,200,200,100));
}
@end
@interface AIViewportReader : AIContextProbe
@property AIViewportCanvas* canvas;
@property SPDFMacMarkdownSession* textSession;
- (void)prepareViewport:(NSString*)path;
- (NSPoint)viewportOrigin;
@end
@implementation AIViewportReader
- (BOOL)isMarkdownActive{return self.textSession!=nil;}
- (SPDFMacMarkdownSession*)activeMarkdownSession{return self.textSession;}
- (void)prepareViewport:(NSString*)path {
    [self seedPDF:path];[self seedTabs:@[Tab(path,[SPDFTabGroup groupWithColor:@"blue"])]];[self seedControls];
    _pageView=[[AIViewportCanvas alloc] initWithFrame:NSMakeRect(0,0,800,1000)];self.canvas=(id)_pageView;
    SPDFRenderedPage* page=[SPDFRenderedPage new];page.pageIndex=0;page.pageWidth=800;page.pageHeight=1000;
    _pageView.pages=@[page];_pageView.zoom=1;
    _pageScrollView=[[SPDFScrollView alloc] initWithFrame:NSMakeRect(0,0,200,200)];_pageScrollView.documentView=_pageView;
    [_pageScrollView.contentView scrollToPoint:NSMakePoint(100,200)];_selectedText=@"Selected fixture text";
}
- (NSPoint)viewportOrigin{return _pageScrollView.contentView.bounds.origin;}
@end
static void CheckCurrentView(NSString* path,NSString* root) {
    AIViewportCanvas* canvas=[[AIViewportCanvas alloc] initWithFrame:NSMakeRect(0,0,800,1000)];
    NSBitmapImageRep* image=SPDFAICaptureViewport(canvas,NSMakeRect(100,200,200,200));
    NSColor* top=[[image colorAtX:image.pixelsWide/2 y:image.pixelsHigh/4] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    NSColor* bottom=[[image colorAtX:image.pixelsWide/2 y:3*image.pixelsHigh/4] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    Check(top.blueComponent>.9 && bottom.redComponent>.9,"viewport capture crops the correct scroll region without flipping or shifting pixels");
    image=SPDFAICaptureViewport(canvas,canvas.bounds);
    Check(image.pixelsWide==1280 && image.pixelsHigh==1600,"viewport capture stays bounded and preserves aspect ratio");
    Check(!SPDFAICaptureViewport(canvas,NSMakeRect(2000,2000,10,10)),"offscreen empty viewport does not capture unrelated pixels");
    AIViewportReader* reader=[AIViewportReader new];[reader prepareViewport:path];
    SPDFMacAITools* tools=[[SPDFMacAITools alloc] initWithReader:reader];
    Check(!reader.canvas.draws && [tools valueForKey:@"queue"]==nil,"current-view construction never captures or starts a worker");
    NSPoint before=reader.viewportOrigin;NSDictionary* result=CitationTool(tools,@"current_view",@{});
    Check([result[@"captured"] boolValue] && [result[@"path"] hasPrefix:@"doc:"] && [result[@"visiblePages"] count]==1,"current-view tool returns visible pages and opaque document identity");
    if(![result[@"captured"] boolValue])return; // Keep the old-dispatch regression failure diagnostic.
    Check([result[@"visiblePages"][0][@"citation"] isEqual:result[@"citation"]],"visible-page citations retain the captured revision");
    Check([result[@"selectedText"] isEqual:@"Selected fixture text"] && [result[@"zoomPercent"] isEqual:@100],"current-view includes selected text and reader zoom");
    Check(NSEqualPoints(before,reader.viewportOrigin),"capturing current view does not navigate or change scroll position");
    NSDictionary* preview=result[@"_localPreview"];
    Check([preview[@"kind"] isEqual:@"viewport"] && [NSData dataWithContentsOfFile:preview[@"path"]].length>0,"current-view supplies a real viewport image");
    Check(SPDFMacAICitationArguments([NSURL URLWithString:result[@"citation"]])!=nil,"viewport has a valid source citation");
    SPDFMacAIChatStore* store=[[SPDFMacAIChatStore alloc] initWithDirectory:[NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"viewport-chat"]]];
    NSString* chatID=NSUUID.UUID.UUIDString;NSDictionary* saved=[store savePreview:preview chatID:chatID];
    NSArray* wire=SPDFMacAIChatVisionMessages(@[@{@"role":@"preview",@"local":@YES,@"preview":saved}],chatID,store,nil);
    Check([wire[0][@"content"][0][@"text"] containsString:@"viewport"] &&
        [wire[0][@"content"][1][@"image_url"][@"url"] hasPrefix:@"data:image/png;base64,"],"viewport kind and pixels survive storage and reach model input");
    CheckViewportFolderRemoved(preview,"keeping current_view's picture with the chat removes its temporary folder");
    __block NSDictionary* cancelled=nil;
    [tools performTool:@"current_view" arguments:@{} completion:^(NSDictionary* value){cancelled=value;}];[tools cancel];
    NSDate* end=[NSDate dateWithTimeIntervalSinceNow:5];
    while(!cancelled && end.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    // A queued operation may be cancelled before executing; the session's generation
    // guard also drops its result. No image may be delivered after cancellation.
    Check(!cancelled[@"_localPreview"],"cancelled viewport never delivers a late image");
    NSString* markdown=[root stringByAppendingPathComponent:@"viewport.md"];
    [@"# Viewport test\n\nVisible text document." writeToFile:markdown atomically:YES encoding:NSUTF8StringEncoding error:nil];
    SPDFMacMarkdownSession* text=[[SPDFMacMarkdownSession alloc] initWithDocumentURL:[NSURL fileURLWithPath:markdown]];
    NSView* host=[[NSView alloc] initWithFrame:NSMakeRect(0,0,640,480)];
    __block BOOL ready=NO;
    [text activateInHostView:host workQueue:dispatch_queue_create("ai-viewport-text-test",DISPATCH_QUEUE_SERIAL)
        scrollOrigin:NSZeroPoint selectedRange:NSMakeRange(0,0) pageIndex:0 zoom:1 fitMode:SPDFMacMarkdownPageFitPage
        anchor:nil completion:^(BOOL ok,NSError* error){(void)error;ready=ok;}];
    end=[NSDate dateWithTimeIntervalSinceNow:5];
    while((!ready || !text.navigationReady) && end.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    AIViewportReader* textReader=[AIViewportReader new];textReader.textSession=text;
    SPDFDocumentTab* tab=Tab(markdown,[SPDFTabGroup groupWithColor:@"blue"]);tab.cachedMarkdownSession=text;
    [textReader seedTabs:@[tab]];[textReader seedControls];
    SPDFMacAITools* textTools=[[SPDFMacAITools alloc] initWithReader:textReader];
    NSDictionary* textView=CitationTool(textTools,@"current_view",@{});
    Check([textView[@"captured"] boolValue] && [textView[@"citation"] containsString:@"layoutIdentity="],
        "live Markdown viewport carries its exact pagination identity and pixels");
    [SPDFMacAIChatStore discardTemporaryPreview:textView[@"_localPreview"]];
    CheckViewportFolderRemoved(textView[@"_localPreview"],"a discarded current_view picture leaves no folder");
    [text deactivate];
    AIContextProbe* empty=[AIContextProbe new];tools=[[SPDFMacAITools alloc] initWithReader:empty];
    Check(CitationTool(tools,@"current_view",@{})[@"error"]!=nil,"no-document viewport returns a useful error");
}
