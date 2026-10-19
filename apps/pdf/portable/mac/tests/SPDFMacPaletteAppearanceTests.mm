#import <Cocoa/Cocoa.h>
#import "SPDFMacPaletteAppearance.h"
#import "SPDFMacCollectionStyle.h"
static int failures;
static void Expect(NSString* name, BOOL success) {
    if (!success) { fprintf(stderr,"FAIL: %s\n",name.UTF8String); failures++; }
}
@interface PaletteFixture : NSObject <NSTableViewDataSource,NSTableViewDelegate>
@property NSArray* rows;
@end
@implementation PaletteFixture
- (NSInteger)numberOfRowsInTableView:(NSTableView*)table { (void)table; return self.rows.count; }
- (CGFloat)tableView:(NSTableView*)table heightOfRow:(NSInteger)row { (void)table; return SPDFPaletteResultHeight(self.rows[row]); }
- (NSView*)tableView:(NSTableView*)table viewForTableColumn:(NSTableColumn*)column row:(NSInteger)row {
    (void)table; (void)column; return SPDFPaletteResultView(self.rows[row]);
}
- (NSTableRowView*)tableView:(NSTableView*)table rowViewForRow:(NSInteger)row { (void)table; (void)row; return SPDFPaletteRowView(); }
@end
static NSView* Find(NSView* view,NSString* identifier) {
    if ([view.identifier isEqual:identifier]) return view;
    for (NSView* child in view.subviews) { NSView* found = Find(child,identifier); if (found) return found; }
    return nil;
}
int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        PaletteFixture* fixture = [PaletteFixture new];
        fixture.rows = @[@{@"kind":@"header",@"title":@"Open documents"},
            @{@"kind":@"openDoc",@"title":@"Interface specification.pdf",@"group":@{@"name":@"Hardware"}},
            @{@"kind":@"openDoc",@"title":@"Controller reference.pdf",@"group":@{@"name":@"Hardware"}},
            @{@"kind":@"header",@"title":@"Groups"},
            @{@"kind":@"collectionGroup",@"title":@"Hardware",@"count":@6},
            @{@"kind":@"collectionGroup",@"title":@"Research",@"count":@4},
            @{@"kind":@"header",@"title":@"Text in Collection"},
            @{@"kind":@"collectionDocument",@"title":@"Bench measurements.pdf · page 1",@"query":@"power",@"subtitle":@"The controller coordinates power sequencing and host communication."}];
        NSSearchField* search = [NSSearchField new]; search.placeholderString = @"Documents, groups, text, or col: for Collection";
        NSTableView* table = [NSTableView new]; table.headerView = nil; table.intercellSpacing = NSZeroSize;
        table.backgroundColor = NSColor.clearColor; [table addTableColumn:[[NSTableColumn alloc] initWithIdentifier:@"result"]];
        table.dataSource = fixture; table.delegate = fixture;
        NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,550,360)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskFullSizeContentView backing:NSBackingStoreBuffered defer:NO];
        window.titleVisibility = NSWindowTitleHidden; window.titlebarAppearsTransparent = YES; window.releasedWhenClosed = NO;
        window.contentView = SPDFPaletteContentView(search,table,nil);
        [window.contentView layoutSubtreeIfNeeded]; [table reloadData]; [table layoutSubtreeIfNeeded];
        Expect(@"palette render remains headless",!window.visible);
        Expect(@"search uses full width less close-button inset",fabs(NSWidth([search alignmentRectForFrame:search.frame])-(NSWidth(window.contentView.bounds)-78))<1);
        NSButton* close = (id)Find(window.contentView,@"PaletteClose");
        Expect(@"palette shows a readable Escape close affordance",[close.title isEqual:@"Esc"] && !close.image &&
            [close.accessibilityLabel isEqual:@"Close search (Escape)"] &&
            close.action == NSSelectorFromString(@"closePalette:") && NSWidth(close.frame)>=42);
        Expect(@"close affordance never overlaps the query",NSMaxX(search.frame)<NSMinX(close.frame));
        Expect(@"title and group share a line in compact results",SPDFPaletteResultHeight(fixture.rows[1])==30);
        Expect(@"text hits retain room for context",SPDFPaletteResultHeight(fixture.rows.lastObject)==50);
        NSView* row = [table viewAtColumn:0 row:1 makeIfNecessary:YES]; [row layoutSubtreeIfNeeded];
        NSView* title = Find(row,@"title"), *meta = Find(row,@"metadata");
        Expect(@"title and group do not overlap",NSMaxX(title.frame)+10 <= NSMinX(meta.frame));
        Expect(@"title and metadata share a baseline",fabs(NSMidY(title.frame)-NSMidY(meta.frame))<1);
        NSString* directory = NSProcessInfo.processInfo.environment[@"SPDF_PALETTE_EVIDENCE"];
        for (NSString* name in @[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]) {
            window.appearance = [NSAppearance appearanceNamed:name];
            [window.contentView layoutSubtreeIfNeeded];
            [table selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
            if (directory.length) {
                [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
                NSBitmapImageRep* bitmap = [window.contentView bitmapImageRepForCachingDisplayInRect:window.contentView.bounds];
                [window.contentView cacheDisplayInRect:window.contentView.bounds toBitmapImageRep:bitmap];
                [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
                    writeToFile:[directory stringByAppendingPathComponent:[name stringByAppendingString:@".png"]] atomically:YES];
            }
        }
        [window close];
        if (!failures) puts("SPDFMacPaletteAppearanceTests passed");
    }
    return failures ? 1 : 0;
}
