#import <Cocoa/Cocoa.h>

// A completed preview updates only visible cells. Offscreen rows read the same
// image from the bounded thumbnail cache when AppKit creates their views.
static inline void SPDFCollectionDeliverThumbnail(NSTableView* table, NSUInteger rowCount,
                                                  NSString* key, NSImage* image, NSString* failure) {
    NSRange visible = [table rowsInRect:table.visibleRect];
    if (visible.location == NSNotFound || visible.location >= rowCount) return;
    NSUInteger end = visible.location + MIN(visible.length,rowCount-visible.location);
    for (NSUInteger index = visible.location; index < end; index++) {
        NSView* cell = [table viewAtColumn:0 row:(NSInteger)index makeIfNecessary:NO];
        for (NSView* child in cell.subviews) {
            if (![child isKindOfClass:NSImageView.class] || ![child.identifier isEqual:key]) continue;
            if (image) ((NSImageView*)child).image = image;
            else child.toolTip = failure ?: @"Preview unavailable; open the saved copy.";
        }
    }
}
