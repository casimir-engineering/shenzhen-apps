#import "SPDFKeycapLabel.h"

// NSTextFieldCell draws single-line text top-aligned when the field is taller
// than the text, so labels rode high inside the fixed-height keycaps. Centering
// the title rect fixes that without changing the cell's size (and thus the
// cap's width). Line-box centering is optically right for the system font: SF's
// ascent/descent are balanced around the cap height.
@interface SPDFKeycapLabelCell : NSTextFieldCell
@end

@implementation SPDFKeycapLabelCell

- (NSRect)titleRectForBounds:(NSRect)bounds {
    NSRect titleRect = [super titleRectForBounds:bounds];
    CGFloat textHeight = self.attributedStringValue.size.height;
    if (NSHeight(titleRect) > textHeight) {
        titleRect.origin.y += (NSHeight(titleRect) - textHeight) / 2.0;
        titleRect.size.height = textHeight;
    }
    return titleRect;
}

- (void)drawInteriorWithFrame:(NSRect)cellFrame inView:(NSView*)controlView {
    [super drawInteriorWithFrame:[self titleRectForBounds:cellFrame] inView:controlView];
}

@end

@implementation SPDFKeycapLabel

+ (Class)cellClass {
    return [SPDFKeycapLabelCell class];
}

@end
