#import "SPDFMacAIChatViewParts.h"
#import "SPDFMacAIChatActivity.h"
#import "SPDFMacCollectionStyle.h"
NSTrackingArea* SPDFChatHoverArea(NSView* owner) {
    return [[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited|
        NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect owner:owner userInfo:nil];
}
@implementation SPDFChatButton
- (void)setRevealed:(BOOL)revealed {
    if(self.revealOnHover) self.alphaValue=revealed || self.window.firstResponder==self ? 1 : 0;
}
- (BOOL)becomeFirstResponder {
    BOOL ok=[super becomeFirstResponder]; if(ok && self.revealOnHover) self.alphaValue=1; return ok;
}
- (BOOL)resignFirstResponder {
    BOOL ok=[super resignFirstResponder];
    if(ok && self.revealOnHover) dispatch_async(dispatch_get_main_queue(), ^{ [self setRevealed:NO]; });
    return ok;
}
- (NSSize)intrinsicContentSize {
    if(self.image) return NSMakeSize(28,28);
    return NSMakeSize(ceil([self.title sizeWithAttributes:@{NSFontAttributeName:self.font}].width)+20,28);
}
- (NSRect)rectForSymbol:(NSImage*)icon {
    NSRect available=NSInsetRect(self.bounds,6,6); NSSize size=icon.size;
    if(size.width<=0 || size.height<=0) return NSZeroRect;
    CGFloat scale=MIN(NSWidth(available)/size.width,NSHeight(available)/size.height);
    return NSMakeRect(NSMidX(available)-size.width*scale/2,NSMidY(available)-size.height*scale/2,
        size.width*scale,size.height*scale);
}
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSBezierPath* shape=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,.5,.5) xRadius:5 yRadius:5];
    BOOL on=self.highlighted || self.state==NSControlStateValueOn;
    if(on || [@[@"send",@"authorize",@"editSend"] containsObject:self.identifier ?: @""]) {
        [SPDFCollectionColor(on ? @"selected" : @"control") setFill]; [shape fill];
    }
    NSColor* ink=SPDFCollectionColor(self.enabled ? @"text" : @"secondary");
    if(self.image) {
        NSImageSymbolConfiguration* configuration=[[NSImageSymbolConfiguration configurationWithPointSize:16
            weight:NSFontWeightMedium] configurationByApplyingConfiguration:
            [NSImageSymbolConfiguration configurationWithPaletteColors:@[ink]]];
        NSImage* icon=[self.image imageWithSymbolConfiguration:configuration];
        [icon drawInRect:[self rectForSymbol:icon] fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
            fraction:self.enabled ? 1 : .65 respectFlipped:YES hints:nil];
        if(self.state==NSControlStateValueOn) { [NSColor.controlAccentColor setStroke]; [shape stroke]; }
    } else {
        NSMutableParagraphStyle* p=[NSMutableParagraphStyle new];
        p.alignment=self.alignment; p.lineBreakMode=NSLineBreakByTruncatingTail;
        NSDictionary* a=@{NSFontAttributeName:self.font,NSForegroundColorAttributeName:ink,
                          NSParagraphStyleAttributeName:p};
        CGFloat h=[self.title sizeWithAttributes:a].height;
        [self.title drawInRect:NSMakeRect(10,floor((self.bounds.size.height-h)/2),self.bounds.size.width-20,h)
            withAttributes:a];
    }
    if(self.window.firstResponder==self) {
        [NSGraphicsContext saveGraphicsState]; NSSetFocusRingStyle(NSFocusRingOnly); [shape fill];
        [NSGraphicsContext restoreGraphicsState];
    }
}
@end
@implementation SPDFChatMessageView
- (void)drawRect:(NSRect)dirty {
    [self.backgroundColor setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:7 yRadius:7] fill];
    [super drawRect:dirty];
    if(self.editable) {
        NSBezierPath* outline=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,1,1) xRadius:7 yRadius:7];
        outline.lineWidth=2; [NSColor.keyboardFocusIndicatorColor setStroke]; [outline stroke];
    }
}
- (void)viewDidChangeEffectiveAppearance { [super viewDidChangeEffectiveAppearance]; self.needsDisplay=YES; }
- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    if(!self.contentHeight || self.measurementScheduled || size.width<=2*self.textContainerInset.width ||
       self.hiddenOrHasHiddenAncestor) return;
    // NSStackView is assigning its cached frames here. Changing constraints in
    // that callback leaves child frames one layout behind their new heights.
    // Measure after the current layout transaction, never at a hidden dock's
    // zero width; that otherwise expands one line into hundreds of points.
    self.measurementScheduled=YES;
    __weak SPDFChatMessageView* weakSelf=self;
    dispatch_async(dispatch_get_main_queue(), ^{
        SPDFChatMessageView* view=weakSelf; if(!view)return;
        view.measurementScheduled=NO;
        CGFloat width=NSWidth(view.bounds)-2*view.textContainerInset.width;
        if(width<=0 || view.hiddenOrHasHiddenAncestor || fabs(width-view.measuredWidth)<.5)return;
        view.measuredWidth=width; [view remeasure];
    });
}
- (void)remeasure {
    CGFloat width=NSWidth(self.bounds)-2*self.textContainerInset.width;
    if(width<=0 || !self.contentHeight) return;
    self.textContainer.containerSize=NSMakeSize(width,CGFLOAT_MAX);
    [self.layoutManager invalidateLayoutForCharacterRange:NSMakeRange(0,self.string.length)
        actualCharacterRange:nil];
    [self.layoutManager ensureLayoutForTextContainer:self.textContainer];
    CGFloat used=ceil(NSMaxY([self.layoutManager usedRectForTextContainer:self.textContainer]));
    CGFloat height=MAX(18,used)+2*self.textContainerInset.height;
    if(fabs(height-self.contentHeight.constant)>.5) {self.contentHeight.constant=height;self.superview.needsLayout=YES;}
    self.needsDisplay=YES;
}
@end
@implementation SPDFChatRoleRow { NSTrackingArea* _hoverArea; }
- (instancetype)initWithLabel:(NSTextField*)label editButton:(SPDFChatButton*)button {
    if(!(self=[super initWithFrame:NSZeroRect])) return nil;
    _label=label; _editButton=button; self.translatesAutoresizingMaskIntoConstraints=NO;
    label.translatesAutoresizingMaskIntoConstraints=NO; [self addSubview:label];
    [NSLayoutConstraint activateConstraints:@[[label.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [label.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.heightAnchor constraintGreaterThanOrEqualToAnchor:label.heightAnchor]]];
    if(!button) return self;
    button.revealOnHover=YES; [button setRevealed:NO]; [self addSubview:button];
    [NSLayoutConstraint activateConstraints:@[[button.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [button.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.heightAnchor constraintEqualToAnchor:button.heightAnchor],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:button.leadingAnchor constant:-8]]];
    return self;
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if(self.editButton && ![self.trackingAreas containsObject:_hoverArea])
        [self addTrackingArea:_hoverArea=SPDFChatHoverArea(self)];
}
- (void)mouseEntered:(NSEvent*)event { (void)event; [self.editButton setRevealed:YES]; }
- (void)mouseExited:(NSEvent*)event { (void)event; [self.editButton setRevealed:NO]; }
@end
static BOOL SummaryMarker(NSDictionary* message) {
    return [message isKindOfClass:NSDictionary.class] && [message[@"role"] isEqual:@"compaction"];
}
NSUInteger SPDFChatMessagePlace(NSArray<NSDictionary*>* messages, NSUInteger index) {
    NSUInteger place=0;
    for(NSUInteger i=0;i<index && i<messages.count;i++) if(!SummaryMarker(messages[i])) place++;
    return place;
}
NSUInteger SPDFChatEditedMessageIndex(NSArray<NSDictionary*>* messages, NSUInteger place, NSString* original) {
    NSUInteger seen=0;
    for(NSUInteger i=0;i<messages.count;i++) {
        if(SummaryMarker(messages[i]) || seen++!=place) continue;
        NSDictionary* message=messages[i];
        BOOL same=[message isKindOfClass:NSDictionary.class] && [message[@"role"] isEqual:@"user"] &&
            [message[@"content"] isEqual:original];
        return same ? i : NSNotFound;
    }
    return NSNotFound;
}
NSTextField* SPDFChatSummaryMarker(void) {
    NSTextField* marker=SPDFCollectionText(@"Earlier messages summarized",11,NSFontWeightMedium,YES);
    marker.identifier=@"summaryMarker"; marker.alignment=NSTextAlignmentCenter;
    marker.toolTip=@"The assistant continues from a short summary of the messages above.";
    marker.translatesAutoresizingMaskIntoConstraints=NO; return marker;
}
@implementation SPDFChatInputScrollView
- (BOOL)composerFocused {
    return [self.window.firstResponder isKindOfClass:NSTextView.class] &&
        [(NSView*)self.window.firstResponder isDescendantOf:self];
}
- (void)drawRect:(NSRect)dirty {
    [super drawRect:dirty];
    NSBezierPath* outline=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,1,1) xRadius:7 yRadius:7];
    outline.lineWidth=[self composerFocused] ? 2 : 1;
    [([self composerFocused] ? NSColor.keyboardFocusIndicatorColor : SPDFCollectionColor(@"line")) setStroke];
    [outline stroke];
}
- (void)updateBorder {
    self.needsDisplay=YES;
    BOOL focused=[self.window.firstResponder isKindOfClass:NSTextView.class] &&
        [(NSView*)self.window.firstResponder isDescendantOf:self];
    self.layer.borderWidth=focused ? 2 : 1;
    self.layer.borderColor=(focused ? NSColor.keyboardFocusIndicatorColor : SPDFCollectionColor(@"line")).CGColor;
}
- (void)viewDidChangeEffectiveAppearance { [super viewDidChangeEffectiveAppearance]; [self updateBorder]; }
- (void)viewDidMoveToWindow { [super viewDidMoveToWindow]; [self updateBorder]; }
- (void)layout { [super layout]; [self updateBorder]; }
// The text is exactly as wide as the field shows, so a word longer than a line wraps at the field's edge.
- (void)tile {
    [super tile]; NSView* text=self.documentView; CGFloat width=NSWidth(self.contentView.bounds);
    if(text && width>0 && fabs(NSWidth(text.frame)-width)>.5) [text setFrameSize:NSMakeSize(width,NSHeight(text.frame))];
}
- (CGFloat)fittingHeight {
    NSTextView* text=self.documentView; [text.layoutManager ensureLayoutForTextContainer:text.textContainer];
    CGFloat used=ceil(NSMaxY([text.layoutManager usedRectForTextContainer:text.textContainer]))+
        2*text.textContainerInset.height+self.contentInsets.top+self.contentInsets.bottom;
    return MIN(SPDFChatComposerMaximumHeight,MAX(SPDFChatComposerHeight,used));
}
@end
@implementation SPDFChatComposer
- (void)didChangeText { [super didChangeText]; if(self.fit) self.fit(); }
- (void)setString:(NSString*)string { [super setString:string]; if(self.fit) self.fit(); }
- (void)setFrameSize:(NSSize)size {
    BOOL rewraps=fabs(size.width-NSWidth(self.frame))>.5; [super setFrameSize:size];
    if(rewraps && self.fit) { void (^fit)(void)=self.fit; dispatch_async(dispatch_get_main_queue(),fit); }
}
- (BOOL)becomeFirstResponder {
    BOOL ok=[super becomeFirstResponder]; [(SPDFChatInputScrollView*)self.enclosingScrollView updateBorder]; return ok;
}
- (BOOL)resignFirstResponder {
    BOOL ok=[super resignFirstResponder];
    dispatch_async(dispatch_get_main_queue(), ^{ [(SPDFChatInputScrollView*)self.enclosingScrollView updateBorder]; });
    return ok;
}
- (void)drawRect:(NSRect)dirty {
    [super drawRect:dirty];
    if(!self.string.length) [@"Ask about your documents…" drawAtPoint:NSMakePoint(13,8)
        withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:13],
                         NSForegroundColorAttributeName:SPDFCollectionColor(@"secondary")}];
}
- (BOOL)performKeyEquivalent:(NSEvent*)event {
    if(self.window.firstResponder==self && !self.hiddenOrHasHiddenAncestor && !self.hasMarkedText &&
       !self.string.length && (event.modifierFlags & NSEventModifierFlagCommand) &&
       [event.charactersIgnoringModifiers.lowercaseString isEqual:@"z"]) {[self keyDown:event];return YES;}
    return [super performKeyEquivalent:event];
}
- (void)keyDown:(NSEvent*)event {
    if(self.hasMarkedText) {[super keyDown:event];return;}
    if(event.keyCode==53 && !self.hasMarkedText) { if(self.closeAction)self.closeAction();return; }
    if ((event.keyCode==36 || event.keyCode==76) && !(event.modifierFlags & NSEventModifierFlagShift)) {
        if (self.submit) self.submit(); return;
    }
    if ((event.modifierFlags & NSEventModifierFlagCommand) &&
        [event.charactersIgnoringModifiers.lowercaseString isEqual:@"z"] && !self.string.length) {
        if(event.modifierFlags & NSEventModifierFlagShift) {if(self.redoAction)self.redoAction();}
        else if (self.undoAction) self.undoAction(); return;
    }
    [super keyDown:event];
}
@end
@implementation SPDFChatFlippedView
- (BOOL)isFlipped { return YES; }
@end
NSButton* SPDFChatMakeButton(NSString* title, NSString* identifier, id target, SEL action) {
    SPDFChatButton* b=[[SPDFChatButton alloc] initWithFrame:NSZeroRect];
    b.title=title ?: @"Untitled chat"; b.font=[NSFont systemFontOfSize:13]; b.bordered=NO;
    b.alignment=NSTextAlignmentCenter; b.target=target; b.action=action; b.identifier=identifier;
    b.accessibilityLabel=title; b.toolTip=title; b.translatesAutoresizingMaskIntoConstraints=NO;
    [b.heightAnchor constraintEqualToConstant:28].active=YES; return b;
}
NSButton* SPDFChatMakeSymbolButton(NSString* symbol, NSString* identifier, id target, SEL action, CGFloat side) {
    SPDFChatButton* b=[[SPDFChatButton alloc] initWithFrame:NSMakeRect(0,0,side,side)];
    b.title=@""; b.image=[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil]; b.bordered=NO;
    b.target=target; b.action=action; b.identifier=identifier; b.translatesAutoresizingMaskIntoConstraints=NO;
    [b.widthAnchor constraintEqualToConstant:side].active=YES;
    [b.heightAnchor constraintEqualToConstant:side].active=YES; return b;
}
static NSColor* Dynamic(NSString* name, unsigned light, unsigned dark) {
    return [NSColor colorWithName:name dynamicProvider:^NSColor*(NSAppearance* appearance) {
        BOOL isDark=[[appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]]
            isEqual:NSAppearanceNameDarkAqua];
        unsigned value=isDark ? dark : light;
        return [NSColor colorWithSRGBRed:((value>>16)&255)/255.0 green:((value>>8)&255)/255.0 blue:(value&255)/255.0
                                   alpha:1];
    }];
}
// About #C4271D on white (5.7:1) and #FF6961 on the dark panel (5.0:1).
NSColor* SPDFChatFailureColor(void) { return Dynamic(@"SPDFChat.failure",0xC4271D,0xFF6961); }
@implementation SPDFChatPillButton {
    NSTrackingArea* _hoverArea;
}
- (NSSize)intrinsicContentSize {
    return NSMakeSize(ceil([self.title sizeWithAttributes:@{NSFontAttributeName:self.font}].width)+20,22);
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas]; if(_hoverArea) [self removeTrackingArea:_hoverArea];
    _hoverArea=[[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited|
        NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:_hoverArea];
}
- (void)mouseEntered:(NSEvent*)event { (void)event; self.hovered=YES; self.needsDisplay=YES; }
- (void)mouseExited:(NSEvent*)event { (void)event; self.hovered=NO; self.needsDisplay=YES; }
// The pill itself is the button VoiceOver reads, with the label naming what it acts on ("Cancel: Searching the
// web"); a plain NSButton leaves that label on the view and speaks for its cell's title alone.
- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityButtonRole; }
- (NSArray*)accessibilityChildren { return @[]; }
- (BOOL)accessibilityPerformPress { if(!self.enabled) return NO; [self performClick:nil]; return YES; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSBezierPath* shape=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,.5,.5) xRadius:5 yRadius:5];
    NSColor* ink;
    if(self.primary) {
        BOOL dark=[[self.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua,
            NSAppearanceNameDarkAqua]] isEqual:NSAppearanceNameDarkAqua];
        NSColor* fill=[SPDFCollectionColor(@"accent") colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        if(self.highlighted || self.hovered) fill=[fill blendedColorWithFraction:self.highlighted ? .28 : .14
            ofColor:dark ? NSColor.whiteColor : NSColor.blackColor];
        [fill setFill]; [shape fill]; ink=SPDFCollectionColor(@"window");
    } else {
        // The Markdown pills' light colours (SPDFMarkdownTheme code controls), lifted in dark to show on the panel.
        [(self.highlighted ? SPDFCollectionColor(@"selected") : self.hovered ?
            Dynamic(@"SPDFChat.pillHover",0xDDE3E9,0x44484E) : Dynamic(@"SPDFChat.pill",0xEAEEF2,0x393D42)) setFill];
        [shape fill]; [Dynamic(@"SPDFChat.pillLine",0xD0D7DE,0x4F535A) setStroke]; [shape stroke];
        ink=SPDFCollectionColor(@"text");
    }
    if(!self.enabled) ink=[ink colorWithAlphaComponent:.5];
    NSMutableParagraphStyle* p=[NSMutableParagraphStyle new];
    p.alignment=NSTextAlignmentCenter; p.lineBreakMode=NSLineBreakByTruncatingTail;
    NSDictionary* a=@{NSFontAttributeName:self.font,NSForegroundColorAttributeName:ink,NSParagraphStyleAttributeName:p};
    CGFloat h=[self.title sizeWithAttributes:a].height;
    [self.title drawInRect:NSMakeRect(8,floor((NSHeight(self.bounds)-h)/2),NSWidth(self.bounds)-16,h) withAttributes:a];
    if(self.window.firstResponder==self) {
        [NSGraphicsContext saveGraphicsState]; NSSetFocusRingStyle(NSFocusRingOnly); [shape fill];
        [NSGraphicsContext restoreGraphicsState];
    }
}
@end
SPDFChatPillButton* SPDFChatMakePill(NSString* title, NSString* identifier, id target, SEL action, BOOL primary) {
    SPDFChatPillButton* b=[[SPDFChatPillButton alloc] initWithFrame:NSZeroRect];
    b.title=title ?: @""; b.font=[NSFont systemFontOfSize:12 weight:NSFontWeightMedium]; b.bordered=NO;
    b.primary=primary; b.target=target; b.action=action; b.identifier=identifier;
    b.accessibilityLabel=title; b.translatesAutoresizingMaskIntoConstraints=NO;
    [b setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [b.heightAnchor constraintEqualToConstant:22].active=YES; return b;
}
@interface SPDFChatWrappingLabel : NSTextField
@property(nonatomic) BOOL rewrapScheduled;
@end
@implementation SPDFChatWrappingLabel
// The width the text has: preferredMaxLayoutWidth is in alignment-rect terms, 4 pt narrower than the frame.
- (CGFloat)textWidth { return NSWidth([self alignmentRectForFrame:self.frame]); }
- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    if(self.rewrapScheduled || self.textWidth<1 || fabs(self.textWidth-self.preferredMaxLayoutWidth)<.5) return;
    // As in SPDFChatMessageView: a new height inside the stack view's frame pass leaves the row one layout behind,
    // so wrap at the new width after it.
    self.rewrapScheduled=YES; __weak SPDFChatWrappingLabel* weakSelf=self;
    dispatch_async(dispatch_get_main_queue(), ^{
        SPDFChatWrappingLabel* label=weakSelf; if(!label) return;
        label.rewrapScheduled=NO; CGFloat width=label.textWidth;
        // Even inside a hidden dock: it is shown again without a new frame, and a label is cheap to wrap.
        if(width<1 || fabs(width-label.preferredMaxLayoutWidth)<.5) return;
        label.preferredMaxLayoutWidth=width; [label invalidateIntrinsicContentSize]; label.superview.needsLayout=YES;
    });
}
@end
NSTextField* SPDFChatLabel(NSString* text, CGFloat size, NSFontWeight weight, NSColor* color, BOOL wraps,
                           CGFloat width) {
    NSTextField* label=wraps ? [SPDFChatWrappingLabel wrappingLabelWithString:text ?: @""] :
        [NSTextField labelWithString:text ?: @""];
    label.font=[NSFont systemFontOfSize:size weight:weight]; label.textColor=color; label.toolTip=text;
    label.translatesAutoresizingMaskIntoConstraints=NO; label.selectable=NO;
    if(wraps) { label.maximumNumberOfLines=0; label.preferredMaxLayoutWidth=MAX(40,width); }
    else label.lineBreakMode=NSLineBreakByTruncatingTail;
    // Below the window's stay-put priority: a long line gives way instead of widening the chat panel.
    [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                    forOrientation:NSLayoutConstraintOrientationHorizontal];
    [label setContentHuggingPriority:wraps ? 1 : NSLayoutPriorityDefaultLow
                      forOrientation:NSLayoutConstraintOrientationHorizontal];
    return label;
}
@implementation SPDFChatFramedImageView
- (void)drawRect:(NSRect)dirty {
    [super drawRect:dirty];
    [SPDFCollectionColor(@"line") setStroke]; [NSBezierPath strokeRect:NSInsetRect(self.bounds,.5,.5)];
}
- (void)viewDidChangeEffectiveAppearance { [super viewDidChangeEffectiveAppearance]; self.needsDisplay=YES; }
@end

SPDFChatMessageView* SPDFChatLiteralTextView(NSString* text, CGFloat width, BOOL* marked) {
    NSArray<NSValue*>* markers = nil;
    NSString* shown = SPDFMacAIActivityVisibleText(text ?: @"", &markers);
    NSMutableParagraphStyle* wrap = [NSMutableParagraphStyle new];
    wrap.lineBreakMode = NSLineBreakByWordWrapping;  // a word longer than the line breaks between characters
    NSMutableAttributedString* string = [[NSMutableAttributedString alloc] initWithString:shown attributes:@{
        NSFontAttributeName : [NSFont systemFontOfSize:13], NSParagraphStyleAttributeName : wrap,
        NSForegroundColorAttributeName : SPDFCollectionColor(@"text")}];
    for (NSValue* range in markers)
        [string addAttributes:@{NSFontAttributeName : [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular],
                                NSForegroundColorAttributeName : SPDFCollectionColor(@"secondary")}
                        range:range.rangeValue];
    CGFloat side = MAX(100, width);
    SPDFChatMessageView* view = [[SPDFChatMessageView alloc] initWithFrame:NSMakeRect(0, 0, side, 20)];
    view.editable = NO; view.selectable = YES; view.drawsBackground = NO;
    // Nothing turns into a link or a detected date: the person reads characters, not what they might mean.
    view.automaticLinkDetectionEnabled = NO; view.automaticDataDetectionEnabled = NO;
    view.backgroundColor = SPDFCollectionColor(@"control");  // the message tint, filled as a rounded panel
    view.verticallyResizable = NO; view.horizontallyResizable = NO;
    view.textContainerInset = NSMakeSize(10, 8); view.textContainer.lineFragmentPadding = 0;
    view.textContainer.widthTracksTextView = YES;
    [view.textStorage setAttributedString:string];
    view.textContainer.containerSize = NSMakeSize(side - 20, CGFLOAT_MAX);
    [view.layoutManager ensureLayoutForTextContainer:view.textContainer];
    CGFloat used = ceil(NSMaxY([view.layoutManager usedRectForTextContainer:view.textContainer]));
    view.translatesAutoresizingMaskIntoConstraints = NO;
    view.contentHeight = [view.heightAnchor constraintEqualToConstant:MAX(18, used) + 16];
    view.contentHeight.active = YES;
    [view setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    if (marked) *marked = markers.count > 0;
    return view;
}

NSStackView* SPDFChatLinkList(NSArray<NSDictionary*>* links, CGFloat width, id<NSTextViewDelegate> delegate) {
    NSStackView* list = [NSStackView new];
    list.orientation = NSUserInterfaceLayoutOrientationVertical;
    list.alignment = NSLayoutAttributeLeading;
    list.spacing = 3;
    list.translatesAutoresizingMaskIntoConstraints = NO;
    list.accessibilityElement = YES;
    list.accessibilityRole = NSAccessibilityGroupRole;
    list.accessibilityLabel = @"Pages from this step";
    NSFont* font = [NSFont systemFontOfSize:12];
    CGFloat line = ceil([[NSLayoutManager new] defaultLineHeightForFont:font]);
    for (NSDictionary* link in links) {
        NSURL* URL = link[@"url"];
        BOOL insecure = [link[@"insecure"] isEqual:@YES];
        NSString* address = URL.absoluteString;
        NSRange scheme = [address rangeOfString:@"://"];
        if (scheme.location != NSNotFound) address = [address substringFromIndex:NSMaxRange(scheme)];
        // An http page is a result, never a link the chat opens: plain words, and no address to hover for.
        NSAttributedString* words = [[NSAttributedString alloc] initWithString:link[@"title"] ?: address attributes:
            insecure ? @{NSFontAttributeName : font, NSForegroundColorAttributeName : SPDFCollectionColor(@"text")} :
            @{NSFontAttributeName : font, NSLinkAttributeName : URL,
              NSToolTipAttributeName : [URL.scheme hasPrefix:@"http"] ? URL.absoluteString : link[@"title"] ?: @""}];
        SPDFChatMessageView* title = [[SPDFChatMessageView alloc] initWithFrame:NSMakeRect(0, 0, MAX(40, width), line)];
        title.editable = NO; title.selectable = YES; title.drawsBackground = NO;
        title.backgroundColor = NSColor.clearColor;
        title.verticallyResizable = NO; title.horizontallyResizable = NO;
        title.textContainerInset = NSZeroSize; title.textContainer.lineFragmentPadding = 0;
        title.textContainer.widthTracksTextView = YES;
        title.textContainer.maximumNumberOfLines = 1;
        title.textContainer.lineBreakMode = NSLineBreakByTruncatingTail;
        [title.textStorage setAttributedString:words];
        title.linkTextAttributes = @{NSForegroundColorAttributeName : SPDFCollectionColor(@"accent"),
                                     NSCursorAttributeName : NSCursor.pointingHandCursor};
        title.delegate = delegate;
        title.translatesAutoresizingMaskIntoConstraints = NO;
        CGFloat natural = ceil(words.size.width) + 1;
        [title.heightAnchor constraintEqualToConstant:line].active = YES;
        [title.widthAnchor constraintLessThanOrEqualToConstant:natural].active = YES;
        NSLayoutConstraint* whole = [title.widthAnchor constraintEqualToConstant:natural];
        whole.priority = NSLayoutPriorityDefaultLow;  // the first thing on the row to give way
        whole.active = YES;
        // ...yet it never disappears behind a very long host.
        NSLayoutConstraint* least = [title.widthAnchor constraintGreaterThanOrEqualToConstant:MIN(natural, 60)];
        least.priority = 495;
        least.active = YES;
        NSMutableArray* views = [NSMutableArray arrayWithObject:title];
        if (link[@"title"] && [link[@"host"] length]) {
            NSTextField* host = SPDFChatLabel(link[@"host"], 12, NSFontWeightRegular, SPDFCollectionColor(@"secondary"),
                                              NO, 0);
            // Above the title, below the window's stay-put priority (500): whole unless even the host alone cannot
            // fit, and never widening the chat panel.
            [host setContentCompressionResistancePriority:490 forOrientation:NSLayoutConstraintOrientationHorizontal];
            [host setContentHuggingPriority:NSLayoutPriorityDefaultHigh
                             forOrientation:NSLayoutConstraintOrientationHorizontal];
            [views addObject:host];
        }
        NSView* rest = [NSView new];  // takes what the row has left, so the host follows its title
        rest.translatesAutoresizingMaskIntoConstraints = NO;
        [rest setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
        [rest setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
        [views addObject:rest];
        NSStackView* row = [NSStackView stackViewWithViews:views];
        row.spacing = 6;
        row.distribution = NSStackViewDistributionFill;
        row.alignment = NSLayoutAttributeCenterY;
        row.translatesAutoresizingMaskIntoConstraints = NO;
        NSStackView* entry = row;
        if (insecure) {
            // Why it isn't blue, on a line of its own: beside them it squeezed title and host to a few letters at
            // 320 pt, and the row no longer said which site it was.
            NSTextField* warning = SPDFChatLabel(@"Not a secure page", 12, NSFontWeightRegular,
                                                 SPDFCollectionColor(@"secondary"), NO, 0);
            entry = [NSStackView stackViewWithViews:@[row, warning]];
            entry.orientation = NSUserInterfaceLayoutOrientationVertical;
            entry.alignment = NSLayoutAttributeLeading;
            entry.spacing = 0;
            entry.translatesAutoresizingMaskIntoConstraints = NO;
            [row.widthAnchor constraintEqualToAnchor:entry.widthAnchor].active = YES;
        }
        [list addArrangedSubview:entry];
        [entry.widthAnchor constraintEqualToAnchor:list.widthAnchor].active = YES;
    }
    return list;
}

NSString* SPDFChatRunningToolText(NSString* tool) {
    static NSDictionary* words;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // In progress, so each ends in an ellipsis; "parts" is what the person calls subagents' tasks.
        words = @{@"web_search" : @"Searching the web…", @"open_page" : @"Reading a page…",
                  @"run_python" : @"Running Python…", @"run_subagents" : @"Working on parts…",
                  @"friends_send_message" : @"Preparing a message…",
                  @"friends_read_messages" : @"Reading your Friends chat…",
                  @"friends_search_chats" : @"Reading your Friends chat…",
                  @"search_documents" : @"Searching your documents…", @"read_pages" : @"Reading your documents…",
                  @"render_page" : @"Looking at a page…", @"read_comments" : @"Reading comments…",
                  @"list_workspace" : @"Looking at your documents…",
                  @"document_metadata" : @"Looking at your documents…",
                  @"list_collection" : @"Looking at your documents…", @"current_view" : @"Looking at your documents…",
                  @"reader_state" : @"Looking at your documents…", @"list_chats" : @"Looking through your chats…",
                  @"organize_chats" : @"Organizing your chats…",
                  @"update_document_metadata" : @"Updating document details…",
                  @"rename_document" : @"Renaming a document…", @"show_document" : @"Showing a page…",
                  @"open_collection" : @"Opening a document…", @"document_job" : @"Making a new PDF…",
                  @"organize_groups" : @"Organizing your tabs…", @"reader_control" : @"Changing the view…",
                  @"app_controls" : @"Using the app’s controls…", @"undo_action" : @"Undoing…"};
    });
    return [tool isKindOfClass:NSString.class] ? words[tool] : nil;
}
