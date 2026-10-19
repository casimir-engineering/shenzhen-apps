#import "SPDFMacSidebarHitProbe.h"
#import "SPDFMacReadmeFixtures.h"
#import "SPDFMacReadmeWindowCapture.h"
#import "SPDFMacDelegatePrivate.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacTabGroups.h"
#import "SPDFUpdater.h"
#import "SPDFMacWorkspaceChrome.h"
#import "SPDFMacWorkspacePanels.h"
#import "SPDFMacSidebarChapters.h"
#import "SPDFMacCollectionStore.h"
#import "SPDFMacCollectionStyle.h"
#import "SPDFMacCollectionReaderNavigation.h"
#import <PDFKit/PDFKit.h>
#import <objc/runtime.h>
#undef main
static NSUInteger failures;
#import "SPDFMacWorkspaceProbeHelpers.h"
#import "SPDFMacRegexClickChecks.h"
@interface ShenzhenMacDelegate (WorkspaceProbeAccess)
- (void)buildWindow;
- (void)buildMenu;
- (void)checkForUpdates:(id)sender;
- (void)applyPresentationChrome;
- (void)startFindForCurrentQueryResetSavedIndex:(BOOL)reset revealMatch:(BOOL)reveal;
- (void)sidebarModeChanged:(id)sender;
- (void)updateTabStripFrame;
- (void)toggleMinimap:(id)sender;
- (void)toggleSidebar:(id)sender;
@end
@interface WorkspaceReaderProbe : ShenzhenMacDelegate
@property PDFDocument* fixturePDF;
- (void)prepare:(NSURL*)URL width:(CGFloat)width dark:(BOOL)dark;
- (void)capture:(NSString*)path width:(CGFloat)width sidebar:(BOOL)sidebar map:(BOOL)map;
- (void)prepareMarkdown:(NSURL*)URL;
- (void)setProbePresentation:(BOOL)value;
- (void)setProbeFind:(BOOL)value;
- (void)setProbeVersion:(BOOL)value;
- (void)checkResponsivePanels;
- (void)setProbeHistory:(BOOL)value;
@end
@implementation WorkspaceReaderProbe
// These are disk boundaries, not UI code. Keeping them inert makes the full
// production buildWindow safe even when a layout callback wants to persist.
- (void)savePersistentState {}
- (void)persistActiveState {}
- (void)rememberActiveTabState {}
- (void)prepare:(NSURL*)URL width:(CGFloat)width dark:(BOOL)dark {
    _tabs=[NSMutableArray array];
    SPDFTabGroup* research=[SPDFTabGroup groupWithColor:@"Purple"]; research.name=@"Research";
    SPDFTabGroup* general=[SPDFTabGroup generalGroup]; general.collapsed=YES;
    SPDFTabGroup* design=[SPDFTabGroup groupWithColor:@"Teal"]; design.name=@"Design"; design.collapsed=YES;
    NSArray* titles=@[@"Interface specification.pdf",@"Hardware reference.pdf",@"Project notes.md",@"Product brief.pdf",@"Visual guidelines.pdf"];
    for (NSUInteger i=0;i<titles.count;i++) {
        SPDFDocumentTab* tab=[SPDFDocumentTab new]; tab.title=[titles[i] stringByDeletingPathExtension];
        tab.path=i ? [URL.URLByDeletingLastPathComponent.path stringByAppendingPathComponent:titles[i]] : URL.path;
        tab.group=i<3 ? research : i==3 ? general : design;
        tab.showSidebar=YES; tab.showMinimap=YES; tab.zoom=1; tab.fitMode=SPDFFitModeWidth;
        [_tabs addObject:tab];
    }
    _selectedTabIndex=0; _path=URL.path; _zoom=1; _fitMode=SPDFFitModeWidth;
    _markdownFontScale=1; _sidebarWidth=240; _minimapWidth=112;
    _sidebarPreferredVisible=YES; _minimapPreferredVisible=YES;
    _restoredWindowContentSize=NSMakeSize(width,780);
    _renderedPages=[NSMutableArray array]; _sidebarItems=[NSMutableArray array];
    _findMatches=[NSMutableArray array]; _findHighlights=[NSMutableDictionary dictionary];
    _findMatchIndex=-1; _findQueue=[NSOperationQueue new];
    char error[1024]={}; _doc=spdf_open(URL.fileSystemRepresentation,error,sizeof(error));
    Check(_doc!=NULL, [NSString stringWithFormat:@"PDF fixture loads: %s",error]);
    if (!_doc) return;
    spdf_load_outline(_doc,&_outline,error,sizeof(error));
    [self buildWindow];
    _suppressToolbarOverflowUpdates=NO; _uiReady=YES;
    _window.appearance=[NSAppearance appearanceNamed:dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
    [_window setContentSize:NSMakeSize(width,780)];
    PDFDocument* PDF=[[PDFDocument alloc] initWithURL:URL]; self.fixturePDF=PDF;
    for (NSUInteger i=0;i<PDF.pageCount;i++) {
        PDFPage* original=[PDF pageAtIndex:i]; NSRect bounds=[original boundsForBox:kPDFDisplayBoxMediaBox];
        SPDFRenderedPage* page=[SPDFRenderedPage new]; page.pageIndex=i;
        page.pageWidth=NSWidth(bounds); page.pageHeight=NSHeight(bounds);
        page.image=[original thumbnailOfSize:NSMakeSize(bounds.size.width*3,bounds.size.height*3) forBox:kPDFDisplayBoxMediaBox];
        page.imagePointWidth=NSWidth(bounds); page.imagePointHeight=NSHeight(bounds);
        page.imageZoom=1; page.imageScale=1; page.minimapImage=page.image;
        [_renderedPages addObject:page];
    }
    _pageView.pages=_renderedPages; _pageView.zoom=1; _minimapView.pages=_renderedPages;
    [self rebuildSidebar]; [self updateControls];
}
- (void)prepareMarkdown:(NSURL*)URL {
    _selectedTabIndex=2; _path=URL.path; _tabs[2].path=URL.path; _tabs[2].title=URL.lastPathComponent.stringByDeletingPathExtension;
    if (_doc) { spdf_close(_doc); _doc=NULL; }
    spdf_free_outline(&_outline);
    [self installMarkdownHostInDocumentContainer];
    id state=[self valueForKey:@"markdownState"];
    NSView* host=[state valueForKey:@"hostView"]; host.hidden=NO; _pageScrollView.hidden=YES;
    SPDFMacMarkdownSession* session=[[SPDFMacMarkdownSession alloc] initWithDocumentURL:URL fontScale:1 themeVariant:
        [_window.appearance.name isEqual:NSAppearanceNameDarkAqua] ? SPDFMarkdownThemeVariantDark : SPDFMarkdownThemeVariantLight];
    [state setValue:session forKey:@"activeSession"];
    __block BOOL done=NO, ready=NO;
    [session activateInHostView:host workQueue:dispatch_queue_create("workspace-probe.markdown",DISPATCH_QUEUE_SERIAL)
        scrollOrigin:NSZeroPoint selectedRange:NSMakeRange(NSNotFound,0) pageIndex:0 zoom:1
        fitMode:SPDFMacMarkdownPageFitWidth anchor:nil completion:^(BOOL success,NSError* error) {
            ready=success; done=YES; if(error) fprintf(stderr,"Markdown fixture: %s\n",error.localizedDescription.UTF8String);
        }];
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:20];
    while((!done || !session.navigationReady) && deadline.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    Check(done && ready && session.navigationReady && session.pageCount>0,@"actual Markdown renderer populates the native reader host");
    [self rebuildSidebar]; [self updateControls];
}
- (void)checkTextSizeActions {
    SPDFMacMarkdownSession* session=self.activeMarkdownSession;
    for (NSNumber* segment in @[@1,@0]) {
        CGFloat before=session.fontScale; id rendered=session.renderedDocument;
        if (segment.integerValue) [self increaseMarkdownFontSize:nil];
        else [self decreaseMarkdownFontSize:nil];
        Check(segment.integerValue ? session.fontScale>before : session.fontScale<before,@"text size buttons update the active text session");
        NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:10];
        while(session.renderedDocument==rendered && deadline.timeIntervalSinceNow>0)
            [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
        Check(session.renderedDocument!=rendered && session.pageCount>0,@"text size action repaginates the current document");
    }
}
- (void)checkRepeatedMapClicks {
    for (NSNumber* width in @[@1280,@880,@560]) {
    [_window setContentSize:NSMakeSize(width.doubleValue,780)]; [self prioritizeWorkspaceMap];
    [self setMinimapActuallyVisible:YES]; [_window.contentView layoutSubtreeIfNeeded];
    NSView* persistentButton=nil;
    NSPoint point=NSMakePoint(NSWidth(_window.contentView.bounds)-22,NSHeight(_window.contentView.bounds)-66);
    for (NSInteger count=1;count<=4;count++) {
        NSView* hit=[_window.contentView hitTest:point];
        Check([hit isKindOfClass:NSButton.class],@"stationary map click still hits a button after toggling");
        if (![hit isKindOfClass:NSButton.class]) break;
        if (!persistentButton) persistentButton=hit;
        Check(hit==persistentButton,@"map show/hide retains the same control beneath a stationary pointer");
        NSButton* button=(id)hit; BOOL before=_minimapVisible;
        Check(button.action==@selector(toggleMinimap:),@"stationary pointer targets the map toggle");
        NSEvent* down=[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:point modifierFlags:0 timestamp:count*.1
            windowNumber:_window.windowNumber context:nil eventNumber:count*2-1 clickCount:count pressure:1];
        [button mouseDown:down];
        [_window.contentView layoutSubtreeIfNeeded];
        Check(_minimapVisible!=before,@"every stationary click toggles the map, including the second click");
    }
    }
    [self prioritizeWorkspaceSidebar];
}
- (void)checkResponsivePanels {
    _sidebarPreferredVisible=YES; _minimapPreferredVisible=YES; _sidebarWidth=240;
    [self prioritizeWorkspaceSidebar];
    [self setSidebarActuallyVisible:YES]; [self setMinimapActuallyVisible:YES];
    [_window setContentSize:NSMakeSize(560,780)]; [_window.contentView layoutSubtreeIfNeeded];
    [self applyWorkspacePanelPolicy];
    Check(_sidebarVisible && !_minimapVisible && _sidebarWidth==240 && _sidebarPreferredVisible && _minimapPreferredVisible,
        @"compact layout preserves preferred panels/width and prioritizes sidebar");
    [self toggleMinimap:nil]; [_window.contentView layoutSubtreeIfNeeded];
    Check(!_sidebarVisible && _minimapVisible,@"show map reveals it immediately at compact width");
    [self toggleSidebar:nil]; [_window.contentView layoutSubtreeIfNeeded];
    Check(_sidebarVisible && !_minimapVisible,@"show sidebar restores navigation at compact width");
    [_window setContentSize:NSMakeSize(1280,780)]; [_window.contentView layoutSubtreeIfNeeded];
    [self applyWorkspacePanelPolicy]; [_window.contentView layoutSubtreeIfNeeded];
    Check(_sidebarVisible && _minimapVisible && _sidebarWidth==240,@"widening restores both panels and preferred width");
}
- (void)setProbeHistory:(BOOL)value {
    if (value) {
        SPDFMacCollectionStore* store=SPDFMacCollectionStore.defaultStore;
        [store updateSettings:@{@"choice":@"enabled"} error:nil];
        NSDictionary* first=[store capturePath:_path reason:@"opened" error:nil];
        Check(first!=nil,@"initial History capture succeeds");
        PDFDocument* changed=[[PDFDocument alloc] initWithURL:[NSURL fileURLWithPath:_path]];
        changed.documentAttributes=@{PDFDocumentTitleAttribute:[@"History fixture " stringByAppendingString:NSUUID.UUID.UUIDString]};
        [changed writeToURL:[NSURL fileURLWithPath:_path]];
        NSDictionary* second=[store capturePath:_path reason:@"saved" continuingDocumentID:first[@"id"] error:nil];
        Check([second[@"versions"] count]>=2,@"changed PDF stays in the same document history");
        [self showCollectionHistory:nil];
        NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:10];
        while(FindHistoryTable(_sidebarContainer).numberOfRows<2 && deadline.timeIntervalSinceNow>0)
            [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
        Check(FindHistoryTable(_sidebarContainer).numberOfRows>=2,@"actual History loads both captured versions before capture");
        Check(_sidebarModeControl.spdf_selectedSidebarMode==SPDFSidebarModeHistory,@"real captured document exposes History");
    } else {
        _sidebarModeControl.spdf_selectedSidebarMode=SPDFSidebarModeChapters; [self sidebarModeChanged:_sidebarModeControl];
        _sidebarWidth=240; [self restoreSidebarWidth];
    }
}
- (void)setProbeVersion:(BOOL)value {
    NSDictionary* info=value ? @{@"document":@{@"id":@"fixture",@"path":@"/missing/fixture.pdf",@"latestVersionID":@"latest"},
        @"version":@{@"id":@"older",@"capturedAt":@1790812800}} : nil;
    [self collectionSetVersionInfo:info forTab:_tabs[0]];
}
- (void)setProbeFind:(BOOL)value {
    if(value) { _sidebarWidth=240; [self restoreSidebarWidth]; }
    _searchField.stringValue=value ? @"workspace" : @"";
    [self startFindForCurrentQueryResetSavedIndex:YES revealMatch:NO];
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:10];
    while(_findSearchInProgress && deadline.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    if(value) Check(!_findSearchInProgress && _findMatches.count>0,@"real PDF search populates the Find panel");
    _sidebarModeControl.spdf_selectedSidebarMode=value ? SPDFSidebarModeSearch : SPDFSidebarModeChapters;
    [self sidebarModeChanged:_sidebarModeControl];
}
- (void)setProbePresentation:(BOOL)value {
    _presentationMode=value; [self applyPresentationChrome];
    Check(_toolbar.hidden==value && _tabStrip.hidden==value,@"presentation hides and restores reader chrome");
}
- (void)capture:(NSString*)path width:(CGFloat)width sidebar:(BOOL)sidebar map:(BOOL)map {
    [_window setContentSize:NSMakeSize(width,780)];
    [self setSidebarActuallyVisible:sidebar]; [self setMinimapActuallyVisible:map];
    [_window.contentView layoutSubtreeIfNeeded];
    [self syncWorkspaceChrome]; [_window.contentView layoutSubtreeIfNeeded];
    NSSize clip=_pageScrollView.contentView.bounds.size;
    _pageView.viewportWidthHint=clip.width; _pageView.viewportHeightHint=clip.height;
    [_pageView setFrameSize:[_pageView documentSizeForClipSize:clip]];
    [self updateMinimap];
    if (![self isMarkdownActive]) for(SPDFRenderedPage* page in _renderedPages) {
        // Real resize invalidates cached map images. The probe has no render
        // service, so refill these fixtures from the same PDF before capture.
        PDFPage* original=[self.fixturePDF pageAtIndex:page.pageIndex];
        page.image=[original thumbnailOfSize:NSMakeSize(page.pageWidth*3,page.pageHeight*3) forBox:kPDFDisplayBoxMediaBox];
        page.imagePointWidth=page.pageWidth; page.imagePointHeight=page.pageHeight; page.imageZoom=1; page.imageScale=1;
        page.minimapImage=[[self.fixturePDF pageAtIndex:page.pageIndex]
            thumbnailOfSize:NSMakeSize(140,198) forBox:kPDFDisplayBoxMediaBox];
        page.minimapImageZoom=140/page.pageWidth; page.minimapImageScale=1;
        [_minimapView noteThumbnailLoadedForPageIndex:page.pageIndex];
    }
    if ([self isMarkdownActive]) {
        _fitMode=SPDFFitModePage; _tabs[(NSUInteger)_selectedTabIndex].fitMode=SPDFFitModePage;
        [self.activeMarkdownSession applyFitMode:SPDFMacMarkdownPageFitPage];
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.1]]; [self updateControls];
    }
    [self syncSidebarTableColumnWidth];
    _pageView.needsDisplay=YES;
    [_window.contentView layoutSubtreeIfNeeded];
    Check(!_window.visible,@"reader window stays offscreen");
    Check([self probePanelDividerTargets]==0,@"both resize overlays own their full hit and cursor regions");
    if (_sidebarVisible && !_presentationMode) {
        for (NSButton* row in _sidebarModeControl.accessibilityChildren) {
            for (NSNumber* y in @[@1,@7,@14,@21,@27]) {
                NSPoint point = [row convertPoint:NSMakePoint(NSMidX(row.bounds),y.doubleValue) toView:_window.contentView.superview];
                NSView* hit = [_window.contentView hitTest:point];
                Check(hit == row,[NSString stringWithFormat:@"%@ button receives entire height at y=%@ (hit %@)", row.accessibilityLabel,y,NSStringFromClass(hit.class)]);
            }
        }
    }
    Check(NSWidth(_pageScrollView.frame)>100 && NSHeight(_pageScrollView.frame)>100,@"document retains a usable viewport");
    if (![self isMarkdownActive])
        Check(_pageView.pages.count==self.fixturePDF.pageCount && _minimapView.pages.count==self.fixturePDF.pageCount,@"real PDF canvas and map retain every fixture page");
    else Check(self.activeMarkdownSession.pageCount>0,@"Markdown pages survive workspace resizing");
    Check(_sidebarVisible==sidebar && (sidebar || NSWidth(_sidebarContainer.frame)<=1),@"requested sidebar visibility is applied");
    if (!_presentationMode) {
        Check([self isMarkdownActive] ? (!_markdownFontSizeSegments.hidden && [_markdownFontSizeSegments isDescendantOf:_toolbar]) : _markdownFontSizeSegments.hidden,
            @"Markdown text size stays directly reachable and takes no toolbar space for PDF");
        Check([_zoomSegments isDescendantOf:_toolbar] && !_zoomSegments.hidden,@"zoom buttons remain directly reachable");
        if ([self isMarkdownActive]) {
            NSRect zoom=[_toolbar convertRect:[_zoomSegments alignmentRectForFrame:_zoomSegments.frame] fromView:_zoomSegments.superview];
            NSRect text=[_toolbar convertRect:[_markdownFontSizeSegments alignmentRectForFrame:_markdownFontSizeSegments.frame] fromView:_markdownFontSizeSegments.superview];
            Check(NSMinX(text)>=NSMaxX(zoom) && NSMinX(text)-NSMaxX(zoom)<=16 && fabs(NSMidY(text)-NSMidY(zoom))<1,
                @"text size is immediately to the right of zoom on the same row");
            Check(_zoomSegments.segmentStyle==NSSegmentStyleRounded && _markdownFontSizeSegments.segmentStyle==_zoomSegments.segmentStyle,
                @"zoom and text size share the compact flat toolbar style");
        }
        CGFloat longest=0;
        for (NSMenuItem* item in _fitModePopup.itemArray)
            longest=MAX(longest,[item.title sizeWithAttributes:@{NSFontAttributeName:_fitModePopup.font}].width);
        Check(fabs(NSWidth([_fitModePopup alignmentRectForFrame:_fitModePopup.frame])-(ceil(longest)+24))<1 &&
            [_fitModePopup.cell isKindOfClass:NSClassFromString(@"SPDFCenteredZoomCell")],
            @"zoom selector is centered and sized to its longest menu item");
        Check(_pageField.superview==_pageCountLabel.superview &&
            [(NSStackView*)_pageField.superview alignment]==NSLayoutAttributeFirstBaseline &&
            [_pageField.font isEqual:_pageCountLabel.font],@"page counter shares one font and baseline");
        CGFloat titleWidth=[_fitModePopup.titleOfSelectedItem sizeWithAttributes:@{NSFontAttributeName:_fitModePopup.font}].width;
        Check(NSWidth(_fitModePopup.frame)>=ceil(titleWidth)+18,@"zoom selection keeps its full readable title");
        NSMutableArray<NSControl*>* controls=[NSMutableArray array]; VisibleControls(_toolbar,controls);
        NSMutableArray<NSValue*>* bounds=[NSMutableArray array];
        for(NSControl* control in controls) {
            // AppKit frame extents include transparent bezel overdraw beyond
            // constrained alignment rectangles; compare the painted control bounds.
            NSRect rect=[_toolbar convertRect:[control alignmentRectForFrame:control.frame] fromView:control.superview];
            Check(NSMinX(rect)>=-.5 && NSMaxX(rect)<=NSWidth(_toolbar.bounds)+.5 && NSMinY(rect)>=-.5 && NSMaxY(rect)<=NSHeight(_toolbar.bounds)+.5,
                @"direct toolbar controls stay inside the header");
            for(NSValue* value in bounds) Check(!NSIntersectsRect(NSInsetRect(value.rectValue,.5,.5),NSInsetRect(rect,.5,.5)),
                [NSString stringWithFormat:@"toolbar controls never overlap: %@ / %@",NSStringFromRect(value.rectValue),NSStringFromRect(rect)]);
            [bounds addObject:[NSValue valueWithRect:rect]];
        }
        if(_sidebarModeControl.spdf_selectedSidebarMode==SPDFSidebarModeSearch) { CheckRegexClick(_window,_findRegexCheckbox,_searchField);
            for(NSView* control in @[_searchField,_findRegexCheckbox,_findCountLabel,_findSegments]) {
                if(control.hidden) continue;
                NSRect rect=[control convertRect:control.bounds toView:_sidebarContainer];
                Check(NSMinX(rect)>=0 && NSMaxX(rect)<=NSWidth(_sidebarContainer.bounds),@"Find controls fit in the minimum sidebar width");
            }
        }
        if (width==1280 && ![self isMarkdownActive] && _sidebarVisible && _sidebarModeControl.spdf_selectedSidebarMode==SPDFSidebarModeChapters) {
            for (NSControl* control in _sidebarModeControl.accessibilityChildren) CheckIconReadability(control);
            CheckIconReadability(_ocrButton); CheckIconReadability(_translateButton); CheckIconReadability(_readingThemeButton);
            for (NSView* host in _documentContainer.subviews) for(NSView* child in host.subviews)
                if ([child.identifier isEqual:@"WorkspaceMapToggle"] && _minimapVisible) {
                    Check(fabs(NSMaxX(child.frame)-(NSWidth(host.bounds)-8))<1,@"map toggle is anchored to header's right edge");
                    CheckIconReadability((NSControl*)child);
                }
        }
        if (_sidebarModeControl.spdf_selectedSidebarMode==SPDFSidebarModeChapters && _sidebarVisible) {
            [self selectCurrentSidebarRow];
            Check(fabs(NSWidth(_sidebarTable.frame)-NSWidth(_sidebarTable.enclosingScrollView.contentView.bounds))<1,
                @"outline table fits sidebar clip width after resize");
            if (_sidebarItems.count && _sidebarTable.selectedRow>=0) {
                NSTableCellView* cell=[_sidebarTable viewAtColumn:0 row:_sidebarTable.selectedRow makeIfNecessary:YES];
                NSTextField* page=[cell viewWithTag:8802];
                Check(cell.textField.font.pointSize==12,@"outline uses compact regular text");
                Check(NSMaxX(page.frame)<=NSWidth(_sidebarTable.enclosingScrollView.contentView.bounds)-8,@"trailing chapter page remains visible");
            }
        }
        Check([((SPDFSidebarNavigationControl*)_sidebarModeControl).documentTitle isEqual:_tabs[(NSUInteger)_selectedTabIndex].path.lastPathComponent],@"sidebar retains the full document filename");
    }
    NSView* view=_window.contentView;
    for (NSView* child in @[_tabStrip,_toolbar,_sidebarModeControl,_pageScrollView]) {
        NSRect rect=[child convertRect:child.bounds toView:view];
        printf("geometry %s %s\n",NSStringFromClass(child.class).UTF8String,NSStringFromRect(rect).UTF8String);
        Check(isfinite(rect.origin.x)&&isfinite(rect.origin.y)&&isfinite(rect.size.width)&&isfinite(rect.size.height),@"chrome has finite geometry");
    }
    if (path.length) {
        view=_window.contentView.superview; // Include native titlebar and traffic lights.
        [view layoutSubtreeIfNeeded];
        NSBitmapImageRep* bitmap=SPDFReadmeWindowBitmap(_window);
        // cacheDisplay omits the window backing. Composite it explicitly so
        // clear NSView regions do not appear black in PNG viewers.
        NSBitmapImageRep* opaque=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
            pixelsWide:bitmap.pixelsWide pixelsHigh:bitmap.pixelsHigh bitsPerSample:8 samplesPerPixel:4
            hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        opaque.size=view.bounds.size;
        [_window.appearance performAsCurrentDrawingAppearance:^{
            [NSGraphicsContext saveGraphicsState];
            NSGraphicsContext.currentContext=[NSGraphicsContext graphicsContextWithBitmapImageRep:opaque];
            [self->_window.backgroundColor setFill]; NSRectFill(view.bounds);
            [bitmap drawInRect:view.bounds fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
                fraction:1 respectFlipped:YES hints:nil];
            [NSGraphicsContext restoreGraphicsState];
        }];
        Check([[opaque representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES],@"native reader PNG written");
    }
}
@end
#import "SPDFMacWorkspaceBatchChecks.h"
static BOOL updaterInvoked;
static void UpdaterSpy(id object,SEL action,BOOL userInitiated) {
    (void)object; (void)action; updaterInvoked=userInitiated;
}
static void CheckUpdaterMenu(WorkspaceReaderProbe* reader) {
    [reader buildMenu]; NSMenuItem* found=nil;
    for(NSMenuItem* item in NSApp.mainMenu.itemArray.firstObject.submenu.itemArray)
        if(item.action==@selector(checkForUpdates:)) found=item;
    Check(found!=nil && [reader validateMenuItem:found],@"Check for Updates remains reachable and enabled in the reader menu");
    Method method=class_getInstanceMethod(SPDFUpdater.class,@selector(checkForUpdatesUserInitiated:));
    IMP original=method_setImplementation(method,(IMP)UpdaterSpy);
    [reader checkForUpdates:nil];
    method_setImplementation(method,original);
    Check(updaterInvoked,@"native menu route requests a user-initiated update check");
}
static NSUInteger historyShortcutCalls, previousShortcutCalls, groupsShortcutCalls;
static void NavigationShortcutSpy(id object,SEL action,id sender) {
    (void)object; (void)sender;
    if (action==NSSelectorFromString(@"showCollectionHistory:")) historyShortcutCalls++;
    else if (action==NSSelectorFromString(@"showGroupsSidebar:")) groupsShortcutCalls++;
    else previousShortcutCalls++;
}
static void CheckNavigationShortcuts(WorkspaceReaderProbe* reader) {
    for (NSString* key in @[@"h",@"d",@"g"]) {
        NSString* actionName=[key isEqual:@"h"] ? @"showCollectionHistory:" : [key isEqual:@"g"] ? @"showGroupsSidebar:" : @"returnToPreviousTab:";
        NSMenuItem* found=nil; NSUInteger count=0;
        for (NSMenuItem* top in NSApp.mainMenu.itemArray) for (NSMenuItem* item in top.submenu.itemArray)
            if ([item.keyEquivalent isEqual:key] && item.keyEquivalentModifierMask==NSEventModifierFlagCommand) { found=item; count++; }
        Check(count==1 && found.target==reader && found.action==NSSelectorFromString(actionName),@"reader navigation shortcut has one unambiguous menu target");
        if (!found) continue;
        Method method=class_getInstanceMethod(ShenzhenMacDelegate.class,found.action);
        IMP original=method_setImplementation(method,(IMP)NavigationShortcutSpy);
        BOOL autoenable=found.menu.autoenablesItems; found.menu.autoenablesItems=NO; found.enabled=YES;
        NSEvent* event=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand
            timestamp:0 windowNumber:0 context:nil characters:key charactersIgnoringModifiers:key isARepeat:NO keyCode:[key isEqual:@"h"] ? 4 : 2];
        Check([found.menu performKeyEquivalent:event],@"AppKit dispatches the requested navigation key");
        found.menu.autoenablesItems=autoenable; method_setImplementation(method,original);
    }
    Check(historyShortcutCalls>0 && previousShortcutCalls>0 && groupsShortcutCalls>0,@"History and Previous Document commands were dispatched");
}
static NSURL* Fixture(NSString* root) {
    NSURL* URL=[NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"Interface specification.pdf"]];
    PDFDocument* PDF=[[PDFDocument alloc] initWithData:SPDFReadmePDFData()]; PDFOutline* outline=[PDFOutline new];
    for (NSUInteger i=0;i<3;i++) { PDFOutline* entry=[PDFOutline new];
        entry.label=@[@"Overview",@"Reading workspace",@"Technical decisions"][i];
        entry.destination=[[PDFDestination alloc] initWithPage:[PDF pageAtIndex:i] atPoint:NSMakePoint(0,842)];
        [outline insertChild:entry atIndex:i]; }
    PDF.outlineRoot=outline; Check([PDF writeToURL:URL],@"PDF fixture written"); return URL;
}
#import "SPDFMacImageColorChoiceChecks.h"
#import "SPDFMacRestoredFindPanelChecks.h"
#import "SPDFMacMissingDocumentChecks.h"
#import "SPDFMacGroupButtonChecks.h"
#import "SPDFMacFindLifecycleChecks.h"
#import "SPDFMacCollectionFailedReadChecks.h"
// Documentation probes reuse the native reader fixture without its test entry point.
#ifndef SPDF_WORKSPACE_PROBE_REUSE
int main(int argc,const char* argv[]) {
    setvbuf(stdout,NULL,_IONBF,0);
    @autoreleasepool {
        NSString* root=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
        setenv("SPDF_STATE_DIR",root.UTF8String,1); setenv("SPDF_NO_WINDOW_FIRST","1",1);
        // Friends is on by default and attaches after first paint; its state must be the probe's, never the real one.
        setenv("SZFRIENDS_STATE_DIR",root.UTF8String,1);
        [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        spdf_sidebar_probe_install_order_guard();
        NSString* output=argc>1 ? [NSString stringWithUTF8String:argv[1]] : @"";
        if (output.length) [NSFileManager.defaultManager createDirectoryAtPath:output withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL* URL=getenv("SPDF_FIND_PROBE_PATH") ? [NSURL fileURLWithPath:[NSString stringWithUTF8String:getenv("SPDF_FIND_PROBE_PATH")]] : Fixture(root);
        if (getenv("SPDF_COLLECTION_FAILED_READ_ONLY")) return CheckCollectionFailedReadFixture(URL,root);
        NSURL* markdownURL=[NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"Project notes.md"]];
        [SPDFReadmeMarkdown() writeToURL:markdownURL atomically:YES encoding:NSUTF8StringEncoding error:nil];
        for (NSNumber* dark in @[@NO,@YES]) {
            WorkspaceReaderProbe* reader=[WorkspaceReaderProbe new]; [reader prepare:URL width:1280 dark:dark.boolValue];
            if(getenv("SPDF_FIND_ONLY")) { [reader checkFindLifecycle]; return failures ? 1 : 0; }
            if(getenv("SPDF_GROUP_BUTTONS_ONLY")) { [reader checkGroupButtons]; return failures ? 1 : 0; }
            if(getenv("SPDF_REGEX_ONLY")) { [reader setProbeFind:YES]; [reader capture:output.length ? [output stringByAppendingPathComponent:@"regex.png"] : nil width:1280 sidebar:YES map:YES]; return failures ? 1 : 0; }
            if(getenv("SPDF_BATCH_ONLY")) { [reader checkBatchChanges]; return failures ? 1 : 0; }
            CheckMissingDocumentView(); CheckMissingDocumentRecovery(reader,root); CheckUpdaterMenu(reader); CheckNavigationShortcuts(reader); CheckImageColorChoices(reader); CheckRestoredFindPanel(reader);
            [reader checkResponsivePanels]; [reader checkRepeatedMapClicks]; [reader checkBatchChanges];
            for (NSNumber* width in @[@1280,@880,@640,@560]) {
                NSString* name=[NSString stringWithFormat:@"reader-%@-%@.png",dark.boolValue ? @"dark" : @"light",width];
                [reader capture:output.length ? [output stringByAppendingPathComponent:name] : nil width:width.doubleValue sidebar:YES map:YES];
            }
            [reader setProbeHistory:YES]; Check([reader probeHistoryMouseClicks]==0,@"actual History responds across its full button height");
            [reader checkCopyPanelInsets];
            [reader capture:output.length ? [output stringByAppendingPathComponent:dark.boolValue ? @"reader-dark-history.png" : @"reader-light-history.png"] : nil
                width:1280 sidebar:YES map:YES];
            [reader setProbeHistory:NO]; [reader setProbeVersion:YES];
            [reader capture:output.length ? [output stringByAppendingPathComponent:dark.boolValue ? @"reader-dark-version.png" : @"reader-light-version.png"] : nil
                width:640 sidebar:YES map:YES];
            [reader setProbeVersion:NO]; [reader setProbeFind:YES];
            [reader capture:output.length ? [output stringByAppendingPathComponent:dark.boolValue ? @"reader-dark-find.png" : @"reader-light-find.png"] : nil
                width:1280 sidebar:YES map:YES];
            [reader setProbeFind:NO]; [reader capture:output.length ? [output stringByAppendingPathComponent:dark.boolValue ? @"reader-dark-hidden.png" : @"reader-light-hidden.png"] : nil
                width:1280 sidebar:NO map:NO];
            [reader setProbePresentation:YES];
            [reader capture:output.length ? [output stringByAppendingPathComponent:dark.boolValue ? @"reader-dark-presentation.png" : @"reader-light-presentation.png"] : nil
                width:1280 sidebar:NO map:NO];
            [reader setProbePresentation:NO]; [reader prepareMarkdown:markdownURL];
            [reader checkTextSizeActions]; CheckRestoredFindPanel(reader);
            for (NSNumber* width in @[@1280,@880,@560]) {
                NSString* name=[NSString stringWithFormat:@"reader-%@-markdown-%@.png",dark.boolValue ? @"dark" : @"light",width];
                [reader capture:output.length ? [output stringByAppendingPathComponent:name] : nil
                    width:width.doubleValue sidebar:YES map:YES];
            }
            [reader.activeMarkdownSession goToPageAtIndex:1];
            [reader capture:output.length ? [output stringByAppendingPathComponent:dark.boolValue ? @"reader-dark-code.png" : @"reader-light-code.png"] : nil
                width:1280 sidebar:YES map:YES];
        }
        NSURL* textURL=[NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"Plain text.txt"]];
        [@"# This remains plain text, not a heading.\n\nText size applies to plain text too."
            writeToURL:textURL atomically:YES encoding:NSUTF8StringEncoding error:nil];
        WorkspaceReaderProbe* textReader=[WorkspaceReaderProbe new]; [textReader prepare:URL width:1280 dark:NO];
        [textReader prepareMarkdown:textURL]; [textReader checkTextSizeActions];
        [textReader capture:output.length ? [output stringByAppendingPathComponent:@"reader-light-text.png"] : nil
            width:1280 sidebar:YES map:YES];
        Check(NSApp.windows.count>0,@"probe constructed actual reader windows");
        for (NSWindow* window in NSApp.windows) Check(!window.visible,@"no window was displayed");
        [NSFileManager.defaultManager removeItemAtPath:root error:nil];
        if (!failures) puts("SPDFMacWorkspaceProbe passed");
    }
    return failures ? 1 : 0;
}

#endif
