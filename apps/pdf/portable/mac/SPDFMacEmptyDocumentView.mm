#import "SPDFMacEmptyDocumentView.h"
#import <objc/runtime.h>
#import "SPDFMacModels.h"
@interface NSObject (EmptyDocumentState)
- (SPDFDocumentTab*)selectedTab;
@end

@interface SPDFEmptyOpenButton : NSButton
@end
@implementation SPDFEmptyOpenButton
- (BOOL)acceptsFirstMouse:(NSEvent*)event { (void)event; return YES; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSBezierPath* shape=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,1,1) xRadius:8 yRadius:8];
    [(self.highlighted ? NSColor.selectedControlColor : NSColor.controlAccentColor) setFill]; [shape fill];
    NSString* label=[self.title isEqual:@"Locate document"] ? self.title : @"＋  Open document";
    NSDictionary* attributes=@{NSFontAttributeName:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName:NSColor.whiteColor};
    NSSize size=[label sizeWithAttributes:attributes];
    [label drawAtPoint:NSMakePoint(floor(NSMidX(self.bounds)-size.width/2),floor(NSMidY(self.bounds)-size.height/2)) withAttributes:attributes];
    if (self.window.firstResponder==self) {
        [NSGraphicsContext saveGraphicsState]; NSSetFocusRingStyle(NSFocusRingOnly); [shape fill]; [NSGraphicsContext restoreGraphicsState];
    }
}
@end

@interface SPDFEmptyDocumentView : NSView
@property NSString* message;
@property NSButton* openButton;
@property NSTextField* titleLabel;
@property NSTextField* hint;
@property NSTextField* formats;
@property NSTextField* shortcut;
@end
@implementation SPDFEmptyDocumentView
- (BOOL)isFlipped { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (NSView*)hitTest:(NSPoint)point {
    NSView* hit=[super hitTest:point];
    // Empty space continues to reach the document view's existing drop target.
    return hit==self.openButton ? hit : nil;
}
- (NSTextField*)label:(NSString*)text size:(CGFloat)size weight:(NSFontWeight)weight {
    NSTextField* label=[NSTextField wrappingLabelWithString:text];
    label.font=[NSFont systemFontOfSize:size weight:weight]; label.alignment=NSTextAlignmentCenter;
    label.textColor=NSColor.secondaryLabelColor; [self addSubview:label]; return label;
}
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self=[super initWithFrame:frame])) {
        self.titleLabel=[self label:@"Your next document" size:22 weight:NSFontWeightSemibold];
        self.titleLabel.textColor=NSColor.labelColor;
        self.hint=[self label:@"Drop a file here to start reading" size:13 weight:NSFontWeightRegular];
        self.formats=[self label:@"PDF · Markdown · Text & code\nImages · EPUB · Office documents" size:12 weight:NSFontWeightRegular];
        self.shortcut=[self label:@"or press ⌘O" size:11 weight:NSFontWeightRegular];
        self.openButton=[[SPDFEmptyOpenButton alloc] initWithFrame:NSZeroRect];
        self.openButton.title=@"Open document"; self.openButton.accessibilityLabel=@"Open document";
        self.openButton.bordered=NO; self.openButton.action=@selector(newTabRequested:);
        [self addSubview:self.openButton];
    }
    return self;
}
- (void)layout {
    [super layout];
    CGFloat width=MIN(400,MAX(100,NSWidth(self.bounds)-32));
    CGFloat x=floor((NSWidth(self.bounds)-width)/2), y=MAX(12,floor((NSHeight(self.bounds)-258)/2));
    self.titleLabel.frame=NSMakeRect(x,y+84,width,30);
    self.hint.frame=NSMakeRect(x,y+119,width,22);
    self.formats.frame=NSMakeRect(x,y+148,width,38);
    self.openButton.frame=NSMakeRect(floor(NSMidX(self.bounds)-88),y+197,176,36);
    self.shortcut.frame=NSMakeRect(x,y+240,width,18);
}
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    CGFloat cx=NSMidX(self.bounds), y=MAX(12,floor((NSHeight(self.bounds)-258)/2));
    for (NSNumber* offset in @[@-1,@1,@0]) {
        NSInteger i=offset.integerValue;
        NSRect page=NSMakeRect(cx-22+i*22,y+8+labs(i)*6,44,58);
        [[NSColor.labelColor colorWithAlphaComponent:i==0 ?.09:.035] setFill];
        NSBezierPath* shape=[NSBezierPath bezierPathWithRoundedRect:page xRadius:6 yRadius:6]; [shape fill];
        [[NSColor.controlAccentColor colorWithAlphaComponent:i==0 ?.65:.18] setStroke]; shape.lineWidth=1; [shape stroke];
        for (NSInteger line=0;i==0 && line<3;line++) {
            [[NSColor.secondaryLabelColor colorWithAlphaComponent:.4] setFill];
            NSRectFillUsingOperation(NSMakeRect(NSMinX(page)+10,NSMinY(page)+18+line*8,line==2 ? 16:24,2),NSCompositingOperationSourceOver);
        }
    }
}
@end
static char emptyViewKey;
void SPDFHideEmptyDocumentView(NSView* owner) {
    NSView* view=objc_getAssociatedObject(owner,&emptyViewKey); view.hidden=YES;
}
void SPDFShowEmptyDocumentView(NSView* owner, NSString* message, id target) {
    SPDFEmptyDocumentView* view=objc_getAssociatedObject(owner,&emptyViewKey);
    if (!view) {
        view=[[SPDFEmptyDocumentView alloc] initWithFrame:NSZeroRect];
        objc_setAssociatedObject(owner,&emptyViewKey,view,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [owner addSubview:view];
    }
    view.hidden=NO; view.openButton.target=target;
    BOOL missing=[target respondsToSelector:@selector(selectedTab)] && [target selectedTab].missingFile;
    view.openButton.title=missing ? @"Locate document" : @"Open document";
    view.openButton.accessibilityLabel=view.openButton.title;
    view.openButton.action=missing ? NSSelectorFromString(@"showCollectionRecovery:") : @selector(newTabRequested:);
    view.formats.hidden=missing; view.shortcut.hidden=missing;
    BOOL welcome=!message.length || [message isEqual:@"Open a document"];
    view.titleLabel.stringValue=welcome ? @"Your next document" : message;
    view.hint.stringValue=missing ? @"Find it automatically or choose its new location" : welcome ? @"Drop a file here to start reading" : @"You can open another document";
    // Center in what the reader can actually see, never in a stale page canvas.
    view.frame=NSIsEmptyRect(owner.visibleRect) ? owner.bounds : owner.visibleRect;
    [view setNeedsLayout:YES]; [view layoutSubtreeIfNeeded];
}
