#import "SPDFMacAIChatDock.h"
@interface SPDFChatSplitView : NSSplitView
@property BOOL trackingDivider;
@end
@implementation SPDFChatSplitView
- (void)mouseDown:(NSEvent*)event {
    NSPoint point=[self convertPoint:event.locationInWindow fromView:nil];
    NSRect divider=NSMakeRect(NSMaxX(self.subviews.firstObject.frame),0,self.dividerThickness,NSHeight(self.bounds));
    self.trackingDivider=NSPointInRect(point,divider);
    @try {[super mouseDown:event];} @finally {self.trackingDivider=NO;}
}
- (void)drawDividerInRect:(NSRect)rect {[NSColor.separatorColor setFill];NSRectFill(rect);}
@end
@interface SPDFMacAIChatDock ()
@property NSSplitView* split;
@property NSView* chat;
@property NSView* reader;
@property CGFloat width;
@property BOOL visible;
@property BOOL adjusting;
@end
@implementation SPDFMacAIChatDock
- (instancetype)initWithReaderView:(NSView*)reader chatView:(NSView*)chat width:(CGFloat)width {
    if(!(self=[super init]))return nil;
    _reader=reader;_chat=chat;_width=isfinite(width) && width>=320 ? MIN(640,width) : 400;
    NSView* parent=reader.superview; NSRect frame=reader.frame;
    _split=[[SPDFChatSplitView alloc] initWithFrame:frame];_split.vertical=YES;_split.dividerStyle=NSSplitViewDividerStyleThin;
    _split.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;_split.delegate=self;
    [reader removeFromSuperview];[parent addSubview:_split];
    chat.translatesAutoresizingMaskIntoConstraints=YES;reader.translatesAutoresizingMaskIntoConstraints=YES;
    [_split addSubview:chat];[_split addSubview:reader];
    [self setVisible:YES];return self;
}
- (void)setVisible:(BOOL)visible {
    _visible=visible;self.chat.hidden=!visible;[self layoutPanels];
}
- (void)layoutPanels {
    if(self.adjusting)return;self.adjusting=YES;
    CGFloat available=NSWidth(self.split.bounds);
    CGFloat width=self.visible ? MIN(self.width,MAX(320,available-280)) : 0;
    width=MIN(width,MAX(0,available-100));
    CGFloat divider=self.visible ? self.split.dividerThickness : 0;
    self.chat.frame=NSMakeRect(0,0,width,NSHeight(self.split.bounds));
    self.reader.frame=NSMakeRect(width+divider,0,MAX(0,available-width-divider),NSHeight(self.split.bounds));
    self.adjusting=NO;
}
- (void)splitView:(NSSplitView*)split resizeSubviewsWithOldSize:(NSSize)size { (void)split;(void)size;[self layoutPanels]; }
- (CGFloat)splitView:(NSSplitView*)split constrainMinCoordinate:(CGFloat)value ofSubviewAt:(NSInteger)index {
    (void)value;(void)index;return self.visible ? MIN(320,MAX(0,NSWidth(split.bounds)-100)) : 0;
}
- (CGFloat)splitView:(NSSplitView*)split constrainMaxCoordinate:(CGFloat)value ofSubviewAt:(NSInteger)index {
    (void)value;(void)index;return self.visible ? MAX(MIN(320,NSWidth(split.bounds)-100),MIN(640,NSWidth(split.bounds)-280)) : 0;
}
- (BOOL)splitView:(NSSplitView*)split shouldHideDividerAtIndex:(NSInteger)index { (void)split;(void)index;return !self.visible; }
- (void)splitViewDidResizeSubviews:(NSNotification*)note {
    (void)note;if(self.adjusting || !self.visible || ![(SPDFChatSplitView*)self.split trackingDivider])return;
    self.width=NSWidth(self.chat.frame);if(self.resized)self.resized(self.width);
}
@end
