#pragma once

#import <AppKit/AppKit.h>

// Markdown sheets share one size and vertical stride. Exact containment keeps
// clicks in the gutter or inter-page gap from borrowing a neighboring page.
static inline NSInteger SPDFMacMarkdownPageIndexAtPoint(NSPoint point, NSUInteger pageCount,
                                                        NSRect firstPageFrame, CGFloat pageGap) {
    if (!pageCount || NSIsEmptyRect(firstPageFrame)) return -1;
    CGFloat stride = NSHeight(firstPageFrame) + pageGap;
    NSInteger candidate = (NSInteger)floor((point.y - NSMinY(firstPageFrame)) / stride);
    if (candidate < 0 || candidate >= (NSInteger)pageCount) return -1;
    NSRect candidateFrame = NSOffsetRect(firstPageFrame, 0, candidate * stride);
    return NSPointInRect(point, candidateFrame) ? candidate : -1;
}

// A context-menu item carries the page it was created for. Other callers
// (toolbar, main menu, shortcuts) have no represented page and therefore use
// the live page. This avoids a closed context menu poisoning a later command.
static inline NSInteger SPDFMacPageIndexForActionSender(id sender, NSInteger contextPageIndex,
                                                        NSInteger currentPageIndex) {
    if ([sender isKindOfClass:NSMenuItem.class]) {
        id represented = ((NSMenuItem*)sender).representedObject;
        if ([represented isKindOfClass:NSNumber.class]) return ((NSNumber*)represented).integerValue;
    }
    return contextPageIndex >= 0 ? contextPageIndex : currentPageIndex;
}

// Menu wording names both the pointer/current page and the output type. Page
// indexes are zero-based internally and one-based everywhere the user sees.
static inline NSString* SPDFMacCopyPageMenuTitle(NSInteger pageIndex, BOOL image) {
    NSString* kind = image ? @"Image" : @"PDF";
    if (pageIndex < 0) return [NSString stringWithFormat:@"Copy Page as %@", kind];
    return [NSString stringWithFormat:@"Copy Page %ld as %@", (long)pageIndex + 1, kind];
}
