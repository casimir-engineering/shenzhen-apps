#import "SPDFMacCollectionAvailability.h"
#include <sys/stat.h>
@interface CollectionFailedReadProbe : WorkspaceReaderProbe
@property NSUInteger openErrors;
@property NSUInteger locateRequests;
- (void)checkFailedSource:(NSURL*)URL;
@end
@implementation CollectionFailedReadProbe
- (void)showCollectionRecovery:(id)sender { (void)sender; self.locateRequests++; }
- (void)showError:(NSString*)message detail:(NSString*)detail { (void)message; (void)detail; self.openErrors++; }
- (void)checkFailedSource:(NSURL*)URL {
    SPDFMacCollectionStore* store=SPDFMacCollectionStore.defaultStore;
    [store updateSettings:@{@"choice":@"enabled"} error:nil];
    NSDictionary* document=[store capturePath:URL.path reason:@"Opened" error:nil];
    Check([document[@"versions"] count]>0,@"fixture has a saved revision before access is lost");
    SPDFDocumentTab* original=[self selectedTab]; SPDFTabGroup* group=original.group;
    original.collectionHistoryDocumentID=document[@"id"]; original.pageIndex=1;
    NSURL* existingCopy=[store editableVersionID:nil documentID:document[@"id"] error:nil];
    SPDFDocumentTab* duplicate=[SPDFDocumentTab new]; duplicate.path=existingCopy.path;
    duplicate.group=SPDFTabGroup.generalGroup; duplicate.collectionHistoryDocumentID=document[@"id"]; [_tabs addObject:duplicate];
    // Exactly the Safari failure: stat succeeds while reading returns a permission error.
    chmod(URL.fileSystemRepresentation,0000);
    Check([NSFileManager.defaultManager attributesOfItemAtPath:URL.path error:nil]!=nil &&
        [NSData dataWithContentsOfURL:URL]==nil,@"metadata-visible source is unreadable");
    NSString* mode=NSProcessInfo.processInfo.environment[@"SPDF_COLLECTION_FAILURE_MODE"];
    if ([mode isEqual:@"missing"]) [NSFileManager.defaultManager removeItemAtURL:URL error:nil];
    if ([mode isEqual:@"invalid"]) {
        chmod(URL.fileSystemRepresentation,0600);
        [@"broken document" writeToURL:URL atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    [self loadSelectedTab];
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:10];
    while ((!_doc || [_path isEqual:URL.path]) && deadline.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    Check(_doc && spdf_page_count(_doc)>0 && ![_path isEqual:URL.path],@"real loader renders Collection after an existing source cannot be read");
    Check([self selectedTab]==original && original.group==group && original.pageIndex==1,@"fallback preserves the original tab group and page");
    Check(_tabs.count==5 && self.openErrors==0,@"recovery adds no duplicate tab or error dialog");
    Check(!original.readOnly && [store editableInfoForPath:original.path]!=nil,@"actual loaded document is editable");
    NSDictionary* info=[store editableInfoForPath:original.path];
    Check(!SPDFCollectionOriginalAvailable(info[@"document"]),@"failed source remains unavailable despite successful stat");
    [_window.contentView layoutSubtreeIfNeeded]; [self updateControls]; [_window.contentView layoutSubtreeIfNeeded];
    NSMutableArray* controls=[NSMutableArray array]; VisibleControls(_toolbar,controls);
    NSButton* pill=nil; NSButton* locate=nil;
    for (NSControl* control in controls) {
        if ([control.identifier isEqual:@"CollectionVersionIndicator"]) pill=(id)control;
        if ([control.identifier isEqual:@"CollectionLocateDocument"]) locate=(id)control;
    }
    Check(pill && locate && [pill valueForKey:@"missing"] && [[pill valueForKey:@"missing"] boolValue],@"native toolbar contains red status and Locate action");
    NSRect rect=[pill convertRect:pill.bounds toView:_toolbar];
    Check(pill && NSContainsRect(_toolbar.bounds,rect) && _toolbarHeightConstraint.constant==36,
        @"status fits on the existing toolbar without adding a row");
    spdf_bitmap bitmap={}; char renderError[1024]={};
    BOOL rendered=_doc && spdf_render_page_rgba(_doc,0,1,&bitmap,renderError,sizeof(renderError));
    Check(rendered && bitmap.width>0 && bitmap.height>0,@"MuPDF renders actual recovered document pixels");
    spdf_free_bitmap(&bitmap);
    if (getenv("SPDF_COLLECTION_TOOLBAR_CAPTURE")) {
        NSBitmapImageRep* image=[_toolbar bitmapImageRepForCachingDisplayInRect:_toolbar.bounds];
        [_toolbar cacheDisplayInRect:_toolbar.bounds toBitmapImageRep:image];
        Check([[image representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
            writeToFile:@(getenv("SPDF_COLLECTION_TOOLBAR_CAPTURE")) atomically:YES],@"real toolbar renders offscreen");
    }
    for (NSNumber* width in @[@1040,@880,@740,@560,@1280]) {
        [self capture:nil width:width.doubleValue sidebar:width.doubleValue>=740 map:width.doubleValue>=880];
        NSRect pillRect=[pill convertRect:pill.bounds toView:_toolbar];
        NSRect locateRect=[locate convertRect:locate.bounds toView:_toolbar];
        Check(NSContainsRect(_toolbar.bounds,pillRect) && NSContainsRect(_toolbar.bounds,locateRect),
            [NSString stringWithFormat:@"inline status and Locate fit at %@ points",width]);
        Check(fabs(NSMidY(pillRect)-NSMidY(locateRect))<.5 && NSWidth(pillRect)>=70,
            @"status and Locate share a center line and readable minimum size");
        NSRect gap=[_toolbarSpacer convertRect:_toolbarSpacer.bounds toView:_toolbar];
        Check(fabs(NSMidX(NSUnionRect(pillRect,locateRect))-NSMidX(gap))<.5,
            @"status cluster is centered in the existing toolbar gap");
        if (getenv("SPDF_COLLECTION_TOOLBAR_CAPTURE") && (width.intValue==740 || width.intValue==1280)) {
            for (NSString* appearance in @[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]) {
                _window.appearance=[NSAppearance appearanceNamed:appearance];
                NSBitmapImageRep* image=[_toolbar bitmapImageRepForCachingDisplayInRect:_toolbar.bounds];
                [_toolbar cacheDisplayInRect:_toolbar.bounds toBitmapImageRep:image];
                NSString* path=[@(getenv("SPDF_COLLECTION_TOOLBAR_CAPTURE")) stringByAppendingFormat:@"-%@-%@.png",width,appearance];
                Check([[image representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES],
                    @"responsive native toolbar evidence saved without showing the app");
            }
        }
        for (NSValue* point in @[[NSValue valueWithPoint:NSMakePoint(2,2)],
            [NSValue valueWithPoint:NSMakePoint(NSWidth(locate.bounds)-2,NSHeight(locate.bounds)-2)],
            [NSValue valueWithPoint:NSMakePoint(NSMidX(locate.bounds),NSMidY(locate.bounds))]]) {
            NSPoint windowPoint=[locate convertPoint:point.pointValue toView:nil];
            NSView* hit=[_window.contentView hitTest:[_window.contentView.superview convertPoint:windowPoint fromView:nil]];
            Check(hit==locate,@"Locate owns both corners and its center in the actual toolbar");
            NSTimeInterval time=NSProcessInfo.processInfo.systemUptime;
            NSEvent* down=[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:windowPoint modifierFlags:0
                timestamp:time windowNumber:_window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];
            NSEvent* up=[NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:windowPoint modifierFlags:0
                timestamp:time+.01 windowNumber:_window.windowNumber context:nil eventNumber:2 clickCount:1 pressure:0];
            NSUInteger before=self.locateRequests; [NSApp postEvent:up atStart:YES]; [hit mouseDown:down];
            Check(self.locateRequests==before+1,@"each Locate press reaches document recovery immediately");
        }
    }
    Check(!_window.visible,@"reader fixture never displays a window");
    chmod(URL.fileSystemRepresentation,0600);
    NSData* recovered=[NSData dataWithContentsOfURL:existingCopy];
    [recovered writeToURL:URL atomically:YES];
    [store capturePath:URL.path reason:@"Restored original" continuingDocumentID:document[@"id"] error:nil];
    [self discardCachedRuntimeForTab:original]; original.path=URL.path; original.workingPath=nil;
    [self collectionSetVersionInfo:nil forTab:original]; [self loadSelectedTab];
    Check(_doc && [_path isEqual:URL.path],@"restored original can be opened again");
    [self capture:nil width:1040 sidebar:YES map:YES];
    Check(pill.hidden && _toolbarHeightConstraint.constant==36,@"returning to an original removes status and restores normal toolbar sizing");
    [self capture:nil width:1280 sidebar:YES map:YES];
    chmod(URL.fileSystemRepresentation,0000); [self loadSelectedTab];
    deadline=[NSDate dateWithTimeIntervalSinceNow:10];
    while ((!_doc || [_path isEqual:URL.path]) && deadline.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    Check(_doc && ![_path isEqual:URL.path] && original==[self selectedTab] && original.group==group,
        @"a second access loss on the same tab recovers again instead of getting stuck");
    chmod(URL.fileSystemRepresentation,0600);
}
@end

static int CheckCollectionFailedReadFixture(NSURL* URL,NSString* root) {
    const char* sample=getenv("SPDF_COLLECTION_FAILURE_SAMPLE");
    if (sample) {
        URL=[NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"Safari collection copy.pdf"]];
        Check([[NSData dataWithContentsOfFile:@(sample)] writeToURL:URL atomically:YES],@"private sample copied into isolated fixture");
    }
    CollectionFailedReadProbe* reader=[CollectionFailedReadProbe new]; [reader prepare:URL width:1280 dark:YES];
    [reader checkFailedSource:URL];
    printf("Collection failed-read checks: %lu failures\n",(unsigned long)failures);
    return failures ? 1 : 0;
}
