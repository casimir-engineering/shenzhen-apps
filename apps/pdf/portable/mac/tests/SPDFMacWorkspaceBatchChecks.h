// Included by the production reader probe; never orders a reader window onscreen.
#import <objc/message.h>
#import "SPDFMacHeaderDragView.h"
#import "SPDFMacWindowChrome.h"
static NSView* BatchFind(NSView* host,NSString* identifier) {
    if([host.identifier isEqual:identifier]) return host;
    for(NSView* child in host.subviews) { NSView* found=BatchFind(child,identifier); if(found) return found; }
    return nil;
}
static NSUInteger BatchDragCalls;
static void BatchDragSpy(id object,SEL action,NSEvent* event) { (void)object; (void)action; (void)event; BatchDragCalls++; }
@interface WorkspaceReaderProbe (BatchChecks)
- (void)checkBatchChanges;
- (void)checkSingleImageFit;
- (void)checkCopyPanelInsets;
- (void)fitWidth:(id)sender;
- (void)fitPage:(id)sender;
- (void)fitHeight:(id)sender;
- (void)resizeDocumentView;
@end
@implementation WorkspaceReaderProbe (BatchChecks)
- (void)checkBatchChanges {
    [_window setContentSize:NSMakeSize(1280,780)]; [self applyWorkspacePanelPolicy];
    [_window.contentView layoutSubtreeIfNeeded];
    Check(fabs(NSMinY(_splitView.frame))<.5,@"reader reaches bottom of window without redundant footer");
    NSView* pill=BatchFind(_sidebarContainer,@"WorkspaceSourcePill");
    Check(pill && pill.hidden,@"ordinary originals have no source-status pill");
    [self setProbeVersion:YES]; [self syncWorkspaceChrome];
    Check(!pill.hidden && NSMaxY(pill.frame)<45,@"Collection status appears at bottom of left panel");
    [self setProbeVersion:NO]; [self syncWorkspaceChrome];
    Method method=class_getInstanceMethod(SPDFWindow.class,@selector(handleChromeMouseDown:));
    IMP original=method_setImplementation(method,(IMP)BatchDragSpy);
    NSEvent* down=[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:NSZeroPoint modifierFlags:0 timestamp:0
        windowNumber:_window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
    NSUInteger headers=0;
    for(NSView* host in @[_sidebarContainer,_documentContainer]) for(NSView* view in host.subviews)
        if([view isKindOfClass:SPDFHeaderDragView.class]) {
            NSPoint point=host==_sidebarContainer ?
                [_sidebarModeControl convertPoint:NSMakePoint(20,58) toView:nil] :
                [view convertPoint:NSMakePoint(12,20) toView:nil];
            NSView* frame=_window.contentView.superview;
            NSView* hit=[frame hitTest:frame.superview ? [frame.superview convertPoint:point fromView:nil] : point];
            Check(hit==view,[NSString stringWithFormat:@"%@ empty header hits drag surface, got %@",host==_sidebarContainer ? @"Sidebar" : @"Map",NSStringFromClass(hit.class)]);
            [hit mouseDown:down]; headers++;
        }
    method_setImplementation(method,original);
    Check(headers==2 && BatchDragCalls>=2,@"both panel headers route empty-space presses to native window drag");
    for(NSButton* control in _sidebarModeControl.accessibilityChildren)
        Check(spdf_window_chrome_view_is_interactive(control),@"sidebar buttons retain click ownership instead of dragging");
    _pageScrollView.scrollerStyle=NSScrollerStyleLegacy;
    _pageScrollView.hasHorizontalScroller=YES; _pageScrollView.hasVerticalScroller=YES;
    [_pageScrollView tile];
    CGFloat first=[self zoomForFitMode:SPDFFitModePage pageIndex:0];
    Check(!_pageScrollView.hasHorizontalScroller,@"first Fit Page removes stale Fit Width horizontal scroller before measuring");
    CGFloat second=[self zoomForFitMode:SPDFFitModePage pageIndex:0];
    Check(fabs(first-second)<.0001,@"repeating Fit Page does not change fitted zoom");
    _pageScrollView.scrollerStyle=NSScrollerStyleOverlay;
    [self checkSingleImageFit];
}
- (void)checkSingleImageFit {
    spdf_document* previous=_doc;
    NSString* previousPath=_path; NSMutableArray* pages=_renderedPages;
    CGFloat zoom=_zoom; SPDFFitMode mode=_fitMode;
    for(NSValue* dimensions in @[[NSValue valueWithSize:NSMakeSize(400,900)],
                                 [NSValue valueWithSize:NSMakeSize(900,400)],
                                 [NSValue valueWithSize:NSMakeSize(940,692)]]) {
        NSSize size=dimensions.sizeValue;
        NSBitmapImageRep* bitmap=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
            pixelsWide:size.width pixelsHigh:size.height bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
            isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        memset(bitmap.bitmapData,255,bitmap.bytesPerRow*bitmap.pixelsHigh);
        // Distinct top/bottom bands make clipping visible in native evidence.
        for(NSInteger y=0;y<bitmap.pixelsHigh;y++) for(NSInteger x=0;x<bitmap.pixelsWide;x++) {
            unsigned char* pixel=bitmap.bitmapData+y*bitmap.bytesPerRow+x*4;
            if(y<12 || y>=bitmap.pixelsHigh-12) { pixel[0]=y<12 ? 90 : 210; pixel[1]=110; pixel[2]=y<12 ? 210 : 90; }
        }
        NSString* path=[NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"png"]];
        [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
        char error[1024]={}; spdf_document* image=spdf_open(path.fileSystemRepresentation,error,sizeof(error));
        Check(image!=NULL,@"image fit regression fixture loads"); if(!image) continue;
        _doc=image; _path=path;
        SPDFRenderedPage* page=[SPDFRenderedPage new]; page.pageWidth=size.width; page.pageHeight=size.height;
        _renderedPages=[NSMutableArray arrayWithObject:page]; _pageView.pages=_renderedPages;
        for(NSNumber* style in @[@(NSScrollerStyleLegacy),@(NSScrollerStyleOverlay)]) {
            _pageScrollView.scrollerStyle=(NSScrollerStyle)style.integerValue;
            for(NSNumber* action in @[@2,@1,@3,@2,@3,@1]) {
                SEL selector=action.intValue==1 ? @selector(fitPage:) : action.intValue==2 ? @selector(fitWidth:) : @selector(fitHeight:);
                ((void(*)(id,SEL,id))objc_msgSend)(self,selector,nil);
                CGFloat first=_zoom; NSRect frame=_pageView.frame;
                if(action.intValue!=2)
                    Check([_pageView rectForPageAtIndex:0].size.height<=_pageScrollView.contentView.bounds.size.height+.5,
                        @"first Fit Page/Height already fits the settled viewport");
                ((void(*)(id,SEL,id))objc_msgSend)(self,selector,nil);
                NSString* label=[NSString stringWithFormat:@"Cmd+%@ %.0fx%.0f %@",action,size.width,size.height,style.intValue==0 ? @"legacy" : @"overlay"];
                Check(fabs(first-_zoom)<.0001 && NSEqualRects(frame,_pageView.frame),
                    [label stringByAppendingString:@" first and repeated fit have identical geometry"]);
                for(NSView* divider in @[_sidebarDividerView,_minimapDividerView])
                    Check(fabs(NSMinY([divider convertRect:divider.bounds toView:_window.contentView]))<.01,
                        [label stringByAppendingString:@" panel separator reaches bottom"]);
                if(style.integerValue==NSScrollerStyleLegacy && size.width!=940) {
                    NSString* output=NSProcessInfo.processInfo.arguments.lastObject;
                    if([output hasPrefix:@"/"]) {
                        NSView* content=_window.contentView; [content layoutSubtreeIfNeeded];
                        NSBitmapImageRep* shot=[content bitmapImageRepForCachingDisplayInRect:content.bounds];
                        [content cacheDisplayInRect:content.bounds toBitmapImageRep:shot];
                        NSString* name=[NSString stringWithFormat:@"image-%.0fx%.0f-cmd%@.png",size.width,size.height,action];
                        [[shot representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
                            writeToFile:[output stringByAppendingPathComponent:name] atomically:YES];
                    }
                }
                if(action.intValue!=2) {
                    NSRect pageRect=[_pageView rectForPageAtIndex:0];
                    Check(pageRect.size.height<=_pageScrollView.contentView.bounds.size.height+.5,
                        [label stringByAppendingString:@" page bottom fits in the settled viewport"]);
                    Check(!_pageScrollView.hasVerticalScroller,[label stringByAppendingString:@" has no stale vertical scroller"]);
                }
            }
        }
        _doc=previous; spdf_close(image);
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    }
    _doc=previous; _path=previousPath; _renderedPages=pages; _pageView.pages=pages;
    _zoom=zoom; _fitMode=mode; _pageView.zoom=zoom;
    _pageScrollView.scrollerStyle=NSScrollerStyleOverlay; [self resizeDocumentView];
}
- (void)checkCopyPanelInsets {
    NSInteger mode=_sidebarModeControl.spdf_selectedSidebarMode;
    [self setProbeVersion:YES];
    for(NSNumber* value in @[@(SPDFSidebarModeGroups),@(SPDFSidebarModeHistory)]) {
        _sidebarModeControl.spdf_selectedSidebarMode=value.integerValue;
        [self sidebarModeChanged:_sidebarModeControl]; [self syncWorkspaceChrome];
        [_window.contentView layoutSubtreeIfNeeded];
        NSView* pill=BatchFind(_sidebarContainer,@"WorkspaceSourcePill"); BOOL found=NO;
        for(NSView* body in _sidebarContainer.subviews)
            if(!body.hidden && [body.identifier isEqual:@"WorkspaceSidebarBody"]) {
                found=YES;
                Check(NSMinY(body.frame)>=NSMaxY(pill.frame)+7,
                    @"History and Groups leave room for the copy pill without obscuring content");
            }
        Check(found,@"copy-panel clearance uses a real visible History/Groups body");
    }
    [self setProbeVersion:NO];
    _sidebarModeControl.spdf_selectedSidebarMode=mode; [self sidebarModeChanged:_sidebarModeControl];
}
@end
