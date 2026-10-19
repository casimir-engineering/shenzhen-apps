#import "SPDFMacAITools.h"
#import "SPDFMacAICurrentView.h"
#import "SPDFMacAIToolsPrivate.h"
#import "SPDFMacAIReaderControls.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacAIDocumentContext.h"
#import "SPDFMacSearchFileCache.h"
#import "SPDFMacAIChatStore.h"

NSBitmapImageRep* SPDFAICaptureViewport(NSView* view, NSRect rect) {
    if (!NSThread.isMainThread || !view) return nil;
    rect=NSIntersectionRect(rect,view.bounds);
    if (NSIsEmptyRect(rect) || !isfinite(rect.size.width) || !isfinite(rect.size.height)) return nil;
    CGFloat scale=MIN(2.0,1600.0/MAX(rect.size.width,rect.size.height));
    NSBitmapImageRep* bitmap=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:MAX(1,(NSInteger)ceil(rect.size.width*scale)) pixelsHigh:MAX(1,(NSInteger)ceil(rect.size.height*scale))
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    bitmap.size=rect.size;
    // cacheDisplay respects the source rect and rep's logical size: no stretched
    // icons/pages and no offscreen content outside the user's document viewport.
    [view cacheDisplayInRect:rect toBitmapImageRep:bitmap]; return bitmap;
}
static SPDFMacMarkdownPagedView* PagedView(NSView* view) {
    if ([view isKindOfClass:SPDFMacMarkdownPagedView.class]) return (id)view;
    for (NSView* child in view.subviews) { SPDFMacMarkdownPagedView* found=PagedView(child); if(found)return found; }
    return nil;
}
@implementation ShenzhenMacDelegate (AICurrentView)
- (NSDictionary*)aiCurrentViewSnapshot {
    NSDictionary* candidate=[self aiDocumentCandidateForPath:_path];
    if (!candidate) return @{@"error":@"No readable document is displayed."};
    SPDFMacMarkdownSession* text=[self isMarkdownActive] ? [self activeMarkdownSession] : nil;
    if (text && !text.navigationReady) return @{@"error":@"The text document is still loading."};
    SPDFMacMarkdownPagedView* paged=text ? PagedView(text.rootView) : nil;
    NSScrollView* scroll=text ? paged : _pageScrollView;
    NSView* view=scroll.documentView; NSRect visible=scroll.documentVisibleRect;
    if (!view || NSIsEmptyRect(visible) || view.hiddenOrHasHiddenAncestor)
        return @{@"error":@"The document viewport is not visible."};
    NSMutableArray* pages=[NSMutableArray array];
    NSArray* frames=text ? paged.documentPageRects : nil;
    NSUInteger count=text ? frames.count : _pageView.pages.count;
    NSInteger primary=-1; CGFloat largest=0;
    for (NSUInteger i=0;i<count;i++) {
        NSInteger index=text ? (NSInteger)i : _pageView.pages[i].pageIndex;
        NSRect frame=text ? [frames[i] rectValue] : [_pageView rectForPageAtIndex:index];
        NSRect intersection=NSIntersectionRect(visible,frame);
        if (NSIsEmptyRect(intersection) || frame.size.width<=0 || frame.size.height<=0) continue;
        CGFloat area=intersection.size.width*intersection.size.height;
        if (area>largest) {largest=area;primary=index;}
        if (pages.count<32) [pages addObject:@{@"page":@(index+1),@"region":@{
            @"x":@((intersection.origin.x-frame.origin.x)/frame.size.width),
            @"y":@((intersection.origin.y-frame.origin.y)/frame.size.height),
            @"width":@(intersection.size.width/frame.size.width),@"height":@(intersection.size.height/frame.size.height)}}];
    }
    if (primary<0) return @{@"error":@"No page is currently visible. Wait for the document to finish rendering."};
    NSBitmapImageRep* bitmap=SPDFAICaptureViewport(view,visible);
    if (!bitmap) return @{@"error":@"The viewport could not be captured."};
    NSMutableDictionary* state=[[self aiReaderControls] mutableCopy];
    state[@"page"]=@(primary+1);state[@"visiblePages"]=pages;
    state[@"selectedText"]=SPDFAIBoundedText(text ? text.selectedText : (_selectedText ?: @""),4000);
    return @{@"bitmap":bitmap,@"candidate":candidate,@"state":state};
}
@end
static NSString* ViewCitation(NSDictionary* args) {
    NSURLComponents* url=[NSURLComponents new];url.scheme=@"spdf-ai";url.host=@"document";
    NSMutableArray* items=[NSMutableArray array];
    for(NSString* key in @[@"path",@"page",@"revision",@"layoutIdentity"])
        if(args[key])[items addObject:[NSURLQueryItem queryItemWithName:key value:[args[key] description]]];
    url.queryItems=items;return url.string;
}
@implementation SPDFMacAITools (AICurrentView)
- (void)performCurrentViewWithCompletion:(void (^)(NSDictionary*))completion {
    NSDictionary* snapshot=[self.reader aiCurrentViewSnapshot];
    if(snapshot[@"error"]){completion(snapshot);return;}
    if(!self.queue){self.queue=[NSOperationQueue new];self.queue.maxConcurrentOperationCount=1;self.queue.qualityOfService=NSQualityOfServiceUtility;}
    NSProgress* progress=[NSProgress progressWithTotalUnitCount:1];self.progress=progress;NSUInteger generation=self.generation;
    [self.queue addOperationWithBlock:^{@autoreleasepool{
        NSDictionary* candidate=snapshot[@"candidate"]; NSMutableDictionary* result=[snapshot[@"state"] mutableCopy];
        NSString* path=candidate[@"readPath"] ?: candidate[@"path"];
        NSMutableDictionary* citation=[@{@"path":SPDFAIDocumentIdentifier(candidate[@"path"]),
            @"page":result[@"page"],@"revision":candidate[@"revision"]} mutableCopy];
        if(candidate[@"paginationPlan"]) {
            NSDictionary* context=SPDFAIDocumentContextForCandidate(candidate,[result[@"page"] unsignedIntegerValue],1,progress,nil);
            if(context[@"layoutIdentity"])citation[@"layoutIdentity"]=context[@"layoutIdentity"];
            else result[@"error"]=@"The text layout changed. Request the current view again.";
        }
        NSBitmapImageRep* bitmap=snapshot[@"bitmap"];
        NSData* data=progress.cancelled ? nil : [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        NSString* folder=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"ShenzhenPDF-AI-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        NSString* imagePath=[folder stringByAppendingPathComponent:@"viewport.png"];
        if(!result[@"error"] && data.length && data.length<=8*1024*1024 && !progress.cancelled &&
            [candidate[@"revision"] isEqual:SPDFSearchFileStamp(path)] &&
            [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:nil] &&
            [data writeToFile:imagePath options:NSDataWritingAtomic error:nil]) {
            [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:imagePath error:nil];
            NSMutableArray* pages=[NSMutableArray array];
            for(NSDictionary* visible in result[@"visiblePages"]) {
                NSMutableDictionary* page=[visible mutableCopy];NSMutableDictionary* source=[citation mutableCopy];
                source[@"page"]=page[@"page"];page[@"citation"]=ViewCitation(source);[pages addObject:page];
            }
            result[@"visiblePages"]=pages;
            result[@"citation"]=ViewCitation(citation);result[@"captured"]=@YES;
            result[@"scope"]=@"Current document viewport, including its reading appearance and visible highlights; not other applications. Other pages or offscreen areas are not shown.";
            result[@"_localPreview"]=@{@"path":imagePath,@"citation":citation,@"kind":@"viewport",
                @"caption":[NSString stringWithFormat:@"%@ · current view",candidate[@"title"] ?: @"Document"],
                @"pixelWidth":@(bitmap.pixelsWide),@"pixelHeight":@(bitmap.pixelsHigh)};
        } else {
            result[@"error"]=result[@"error"] ?: @"The document changed or its viewport could not be captured. Request it again.";
            [NSFileManager.defaultManager removeItemAtPath:folder error:nil];
        }
        dispatch_async(dispatch_get_main_queue(),^{
            if(progress.cancelled || generation!=self.generation) {
                [SPDFMacAIChatStore discardTemporaryPreview:result[@"_localPreview"]];completion(@{@"error":@"Cancelled."});
            } else completion(result);
        });
    }}];
}
@end
