// The Layers sidebar (SPDFMacAnnotateLayersPanel.h).
//
// WAVE 0 STUB (Mac UI B implements): an empty view that is never attached.
#import "SPDFMacAnnotateLayersPanel.h"

#import "SPDFMacFillController.h"

@implementation SPDFMacAnnotateLayersPanel {
    __weak SPDFMacFillController* _controller;
}

- (instancetype)initWithController:(SPDFMacFillController*)controller {
    self = [super initWithFrame:NSZeroRect];
    if (self) _controller = controller;
    return self;
}

- (void)attachToContainer:(NSView*)container {
    (void)container;
}

- (void)detach {
}

- (CGFloat)preferredWidth {
    return 0;
}

- (void)reloadFromSession:(SPDFMacAnnotateSession*)session {
    (void)session;
}

- (void)selectionDidChange {
}

@end
