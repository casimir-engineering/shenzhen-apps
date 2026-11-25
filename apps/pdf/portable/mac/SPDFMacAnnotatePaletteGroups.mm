// The Annotate palette's groups (SPDFMacAnnotatePaletteGroups.h).
//
// WAVE 0 STUB (Mac UI B implements): no groups. The 20 colours are real: they are the spec's data.
#import "SPDFMacAnnotatePaletteGroups.h"

#import "SPDFMacFillController.h"

// Windows Paint's two rows, left to right (§ 2 Colors).
const spdf_paint_color SPDFAnnotatePaletteColors[20] = {
    0x000000FFu, 0x7F7F7FFFu, 0x880015FFu, 0xED1C24FFu, 0xFF7F27FFu,  // black, grey 50 %, dark red, red, orange
    0xFFF200FFu, 0x22B14CFFu, 0x00A2E8FFu, 0x3F48CCFFu, 0xA349A4FFu,  // yellow, green, turquoise, indigo, purple
    0xFFFFFFFFu, 0xC3C3C3FFu, 0xB97A57FFu, 0xFFAEC9FFu, 0xFFC90EFFu,  // white, grey 25 %, brown, rose, gold
    0xEFE4B0FFu, 0xB5E61DFFu, 0x99D9EAFFu, 0x7092BEFFu, 0xC8BFE7FFu,  // light yellow, lime, light turquoise,
                                                                     // blue-grey, lavender
};

@implementation SPDFMacAnnotatePaletteGroups {
    __weak SPDFMacFillController* _controller;
}

- (instancetype)initWithController:(SPDFMacFillController*)controller {
    self = [super init];
    if (self) _controller = controller;
    return self;
}

- (NSArray<NSView*>*)row1ForKind:(SPDFAnnotateDocumentKind)kind {
    (void)kind;
    return @[];
}

- (NSView*)row2ForSession:(SPDFMacAnnotateSession*)session {
    (void)session;
    return [[NSView alloc] initWithFrame:NSZeroRect];
}

- (void)layoutRow1InWidth:(CGFloat)width {
    (void)width;
}

- (void)updateFromSession:(SPDFMacAnnotateSession*)session progress:(NSString*)progress {
    (void)session; (void)progress;
}

- (CGFloat)tallestRow2Height {
    return 0;
}

@end
