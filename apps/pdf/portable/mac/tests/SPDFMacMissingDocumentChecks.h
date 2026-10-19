#import "SPDFMacEmptyDocumentView.h"
@interface MissingDocumentViewProbe : NSObject
@property SPDFDocumentTab* selectedTab;
@end
@implementation MissingDocumentViewProbe
@end
static void CheckMissingDocumentView(void) {
    MissingDocumentViewProbe* target=[MissingDocumentViewProbe new]; target.selectedTab=[SPDFDocumentTab new];
    NSView* owner=[[NSView alloc] initWithFrame:NSMakeRect(0,0,640,480)];
    SPDFShowEmptyDocumentView(owner,@"Open a document",target);
    NSView* view=owner.subviews.firstObject;
    NSButton* button=[view valueForKey:@"openButton"];
    Check([button.title isEqual:@"Open document"] && button.action==@selector(newTabRequested:),@"ordinary empty reader does not offer recovery");
    target.selectedTab.missingFile=YES;
    SPDFShowEmptyDocumentView(owner,@"File moved or deleted",target);
    Check([button.title isEqual:@"Locate document"] && button.action==NSSelectorFromString(@"showCollectionRecovery:") && button.target==target,
        @"missing document gets a working locator action");
    Check(fabs(NSMidX(button.frame)-NSMidX(view.bounds))<1,@"missing document action is centered in viewport");
    Check([[view valueForKey:@"formats"] isHidden] && [[view valueForKey:@"shortcut"] isHidden],@"missing view omits unrelated welcome hints");
    target.selectedTab.missingFile=NO;
    SPDFShowEmptyDocumentView(owner,@"Could not open document",target);
    Check(button.action==@selector(newTabRequested:) && ![[view valueForKey:@"formats"] isHidden],@"other errors and recovered tabs do not retain missing-file recovery");
}
#import "SPDFMacCollectionIntegration.h"
static NSWindow* MissingLocatorWindow;
static void CaptureMissingLocator(id object,SEL action,id sender) { (void)action; (void)sender; MissingLocatorWindow=object; }
static void CollectLocatorTitles(NSView* view,NSMutableSet* titles) {
    if([view isKindOfClass:NSButton.class]) [titles addObject:[(NSButton*)view title]];
    for(NSView* child in view.subviews) CollectLocatorTitles(child,titles);
}
static void CheckMissingDocumentRecovery(ShenzhenMacDelegate* reader,NSString* root) {
    NSString* path=[root stringByAppendingPathComponent:@"missing-fixture.pdf"];
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    NSMenuItem* sender=[NSMenuItem new]; sender.representedObject=path;
    Method show=class_getInstanceMethod(NSWindow.class,@selector(makeKeyAndOrderFront:));
    IMP original=method_setImplementation(show,(IMP)CaptureMissingLocator);
    [reader showCollectionRecovery:sender];
    method_setImplementation(show,original);
    Check(MissingLocatorWindow!=nil,@"missing tab context action opens locator instead of only History");
    NSMutableSet* titles=[NSMutableSet set]; CollectLocatorTitles(MissingLocatorWindow.contentView,titles);
    Check([titles containsObject:@"Search This Computer"] && [titles containsObject:@"Choose File Manually…"],@"locator offers automatic and manual finding");
    [MissingLocatorWindow close]; MissingLocatorWindow=nil;
    NSMenu* missingMenu=[NSMenu new]; [reader addCollectionItemsToTabMenu:missingMenu path:path];
    Check([missingMenu itemWithTitle:@"Locate Document…"]!=nil,@"missing document menu offers recovery");
    [@"fixture" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSMenu* availableMenu=[NSMenu new]; [reader addCollectionItemsToTabMenu:availableMenu path:path];
    Check([availableMenu itemWithTitle:@"Locate Document…"]==nil,@"available document menu omits recovery");
    original=method_setImplementation(show,(IMP)CaptureMissingLocator);
    [reader showCollectionRecovery:sender];
    method_setImplementation(show,original);
    Check(MissingLocatorWindow==nil,@"available original never opens recovery even through a stale menu action");
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
}
