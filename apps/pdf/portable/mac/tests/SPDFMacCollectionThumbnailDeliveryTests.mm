#import <Cocoa/Cocoa.h>
#import "SPDFMacCollectionThumbnailDelivery.h"

@interface ThumbnailDeliveryTable : NSTableView
@property(nonatomic) NSRange visibleRows;
@property(nonatomic) NSUInteger visits;
@property(nonatomic) BOOL requestedCreation;
@property(nonatomic, strong) NSView* fixtureCell;
@end
@implementation ThumbnailDeliveryTable
- (NSRange)rowsInRect:(NSRect)rect { (void)rect; return self.visibleRows; }
- (NSView*)viewAtColumn:(NSInteger)column row:(NSInteger)row makeIfNecessary:(BOOL)create {
    (void)column; (void)row; self.visits++; self.requestedCreation |= create; return self.fixtureCell;
}
@end
static void Expect(BOOL condition, const char* message) {
    if (!condition) { fprintf(stderr,"FAIL: %s\n",message); exit(1); }
}
int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        ThumbnailDeliveryTable* table = [ThumbnailDeliveryTable new];
        table.visibleRows = NSMakeRange(5000,8); table.fixtureCell = [NSView new];
        NSImageView* matching = [NSImageView new]; matching.identifier = @"current";
        NSImageView* reused = [NSImageView new]; reused.identifier = @"different";
        [table.fixtureCell addSubview:matching]; [table.fixtureCell addSubview:reused];
        NSImage* image = [[NSImage alloc] initWithSize:NSMakeSize(10,10)];
        // Count the previous full-list traversal with the same spy and fixture.
        for (NSInteger index=0;index<10000;index++) [table viewAtColumn:0 row:index makeIfNecessary:NO];
        NSUInteger baseline = table.visits; table.visits = 0;
        SPDFCollectionDeliverThumbnail(table,10000,@"current",image,nil);
        Expect(table.visits == 8,"completion work is bounded to eight visible rows among 10,000");
        Expect(!table.requestedCreation,"completion never instantiates offscreen cells");
        Expect(matching.image == image && reused.image == nil,"only a matching current cell gets the image");
        printf("Thumbnail completion visits: baseline %lu, optimized %lu (10,000 rows / 8 visible)\n",
            (unsigned long)baseline,(unsigned long)table.visits);
        SPDFCollectionDeliverThumbnail(table,10000,@"current",nil,@"Locked document");
        Expect([matching.toolTip isEqual:@"Locked document"],"visible failures retain their explanation");
        table.visits=0; table.visibleRows=NSMakeRange(NSNotFound,0);
        SPDFCollectionDeliverThumbnail(table,10000,@"current",image,nil);
        Expect(table.visits == 0,"empty viewport visits no rows");
        table.visibleRows=NSMakeRange(9998,NSUIntegerMax);
        SPDFCollectionDeliverThumbnail(table,10000,@"current",image,nil);
        Expect(table.visits == 2,"stale viewport clamps to the current result count without overflow");
        table.visits=0; table.visibleRows=NSMakeRange(5000,8);
        SPDFCollectionDeliverThumbnail(table,10,@"current",image,nil);
        Expect(table.visits == 0,"replacement with fewer results ignores a stale viewport");
        puts("SPDFMacCollectionThumbnailDeliveryTests passed");
    }
    return 0;
}
