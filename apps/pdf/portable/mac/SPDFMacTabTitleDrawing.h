#pragma once
#import <Cocoa/Cocoa.h>

// Keep layout and draw options together: clipping used to silently lose the
// filename suffix, while changing this rect on hover made the title jump.
static inline NSParagraphStyle* SPDFTabTitleParagraphStyle(void) {
    NSMutableParagraphStyle* style = [NSMutableParagraphStyle new];
    style.alignment = NSTextAlignmentCenter;
    style.lineBreakMode = NSLineBreakByTruncatingMiddle;
    return style;
}
static inline NSRect SPDFTabTitleRect(NSRect container, CGFloat left, CGFloat right, NSString* title, NSDictionary* attributes) {
    CGFloat height=[title sizeWithAttributes:attributes].height;
    return NSMakeRect(NSMinX(container)+left,NSMidY(container)-height/2,
        MAX(1,NSWidth(container)-left-right),height);
}
static inline void SPDFDrawTabTitle(NSString* title, NSRect rect, NSDictionary* attributes) {
    [title drawWithRect:rect
               options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
            attributes:attributes];
}
