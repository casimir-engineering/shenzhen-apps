#import "SPDFMacHeaderDragView.h"
#import "SPDFMacCollectionStyle.h"
#import "SPDFMacUIHelpers.h"
@implementation SPDFHeaderDragView
- (void)drawRect:(NSRect)dirty {
    (void)dirty; [SPDFCollectionColor(@"pane") setFill]; NSRectFill(self.bounds);
}
- (BOOL)acceptsFirstMouse:(NSEvent*)event { (void)event; return YES; }
- (BOOL)mouseDownCanMoveWindow { return YES; }
- (void)mouseDown:(NSEvent*)event { [(SPDFWindow*)self.window handleChromeMouseDown:event]; }
@end
