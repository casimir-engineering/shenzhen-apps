#import "SPDFMacAIAnswerCardView.h"
#import "SPDFMacGroupActionButton.h"
#import "SPDFMacIconGeometry.h"
#import "SPDFMacCollectionStyle.h"
@interface SPDFAnswerEvidenceButton : SPDFGroupActionButton @end
@implementation SPDFAnswerEvidenceButton {
    NSTrackingArea* _hoverArea; BOOL _hovered;
}
- (BOOL)accessibilityPerformPress {
    return self.enabled && [self sendAction:self.action to:self.target];
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas]; if (_hoverArea) [self removeTrackingArea:_hoverArea];
    _hoverArea=[[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited|NSTrackingActiveAlways|NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:_hoverArea];
}
- (void)mouseEntered:(NSEvent*)event { (void)event; _hovered=YES; self.needsDisplay=YES; }
- (void)mouseExited:(NSEvent*)event { (void)event; _hovered=NO; self.needsDisplay=YES; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSBezierPath* shape=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,1,1) xRadius:14 yRadius:14];
    // The chrome's filled button: white on the accent fill (4.9:1), darker under the pointer and when pressed.
    NSColor* fill=SPDFCollectionColor(@"accentFill");
    if(self.highlighted || _hovered) fill=[fill blendedColorWithFraction:self.highlighted ? .25 : .12 ofColor:NSColor.blackColor];
    [fill setFill]; [shape fill];
    NSColor* text=SPDFCollectionColor(@"onAccent");
    NSDictionary* attributes=@{NSFontAttributeName:[NSFont systemFontOfSize:12 weight:NSFontWeightMedium],NSForegroundColorAttributeName:text};
    NSSize size=[self.title sizeWithAttributes:attributes];
    [self.title drawAtPoint:NSMakePoint(13,round((NSHeight(self.bounds)-size.height)/2)) withAttributes:attributes];
    SPDFDrawVectorIcon(SPDFChromeSymbol(@"arrow.right",10,NSFontWeightMedium,text),
                       NSMakeRect(NSWidth(self.bounds)-26,(NSHeight(self.bounds)-12)/2,12,12),YES);
    if(self.window.firstResponder==self) {
        [NSGraphicsContext saveGraphicsState]; NSSetFocusRingStyle(NSFocusRingOnly); [shape fill]; [NSGraphicsContext restoreGraphicsState];
    }
}
@end
@implementation SPDFMacAIAnswerCardView {
    NSButton* _evidence; NSLayoutConstraint* _height; BOOL _measurementPending;
    void (^_openLink)(NSURL*); NSURL* _citation; NSRange _valueRange; BOOL _inlineEvidence;
}
- (instancetype)initWithCard:(NSDictionary*)card width:(CGFloat)width openLink:(void (^)(NSURL*))openLink {
    if (!(self=[super initWithFrame:NSMakeRect(0,0,MAX(180,width),120)])) return nil;
    self.identifier=@"answerCard"; self.editable=NO; self.selectable=YES; self.drawsBackground=NO;
    self.verticallyResizable=NO; self.horizontallyResizable=NO;
    self.textContainerInset=NSMakeSize(18,16); self.textContainer.lineFragmentPadding=0;
    self.textContainer.widthTracksTextView=YES;
    NSMutableParagraphStyle* labelStyle=[NSMutableParagraphStyle new]; labelStyle.paragraphSpacing=7;
    NSMutableAttributedString* text=[[NSMutableAttributedString alloc] initWithString:[card[@"label"] stringByAppendingString:@"\n"]
        attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:12 weight:NSFontWeightMedium],NSForegroundColorAttributeName:SPDFCollectionColor(@"secondary"),NSParagraphStyleAttributeName:labelStyle}];
    _valueRange=NSMakeRange(text.length,[card[@"value"] length]);
    [text appendAttributedString:[[NSAttributedString alloc] initWithString:card[@"value"]
        attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:_valueRange.length>24 ? 28 : _valueRange.length>14 ? 34 : 36 weight:NSFontWeightSemibold],
            NSForegroundColorAttributeName:SPDFCollectionColor(@"text")}]];
    [self.textStorage setAttributedString:text];
    self.accessibilityLabel=[NSString stringWithFormat:@"Answer: %@, %@",card[@"label"],card[@"value"]];
    _citation=[NSURL URLWithString:card[@"citation"]]; _openLink=[openLink copy];
    _evidence=[[SPDFAnswerEvidenceButton alloc] initWithFrame:NSMakeRect(18,72,132,31)];
    _evidence.identifier=@"answerEvidence"; _evidence.title=@"View evidence"; _evidence.bordered=NO;
    _evidence.target=self; _evidence.action=@selector(openEvidence:); _evidence.accessibilityLabel=@"View evidence for this answer";
    _evidence.toolTip=@"Open the cited document passage"; [self addSubview:_evidence];
    self.translatesAutoresizingMaskIntoConstraints=NO;
    _height=[self.heightAnchor constraintEqualToConstant:120]; _height.active=YES;
    [self measure]; return self;
}
- (void)openEvidence:(id)sender { (void)sender; if (_openLink && _citation) _openLink(_citation); }
- (NSArray*)accessibilityChildren {
    // NSTextView normally exposes its text as a leaf, hiding embedded native
    // controls from VoiceOver and accessibility clients. Keep the answer text
    // selectable while exposing its evidence action explicitly.
    NSMutableArray* children=[[super accessibilityChildren] mutableCopy] ?: [NSMutableArray array];
    if (_evidence && ![children containsObject:_evidence]) [children addObject:_evidence];
    return children;
}
- (void)drawRect:(NSRect)dirty {
    NSBezierPath* card=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,.5,.5) xRadius:12 yRadius:12];
    [SPDFCollectionColor(@"card") setFill]; [card fill];
    [SPDFCollectionColor(@"line") setStroke]; [card stroke];
    [super drawRect:dirty];
}
- (void)viewDidChangeEffectiveAppearance { [super viewDidChangeEffectiveAppearance]; self.needsDisplay=YES; }
- (void)measure {
    CGFloat width=NSWidth(self.bounds)-36; if (width<=0 || !_height) return;
    self.textContainer.containerSize=NSMakeSize(width,CGFLOAT_MAX);
    [self.layoutManager ensureLayoutForTextContainer:self.textContainer];
    NSRange glyphs=[self.layoutManager glyphRangeForCharacterRange:_valueRange actualCharacterRange:NULL];
    NSRect value=[self.layoutManager boundingRectForGlyphRange:glyphs inTextContainer:self.textContainer];
    CGFloat naturalWidth=[[self.textStorage attributedSubstringFromRange:_valueRange] size].width;
    _inlineEvidence=NSWidth(self.bounds)>=340 && ceil(naturalWidth)+16+132<=width;
    CGFloat textBottom=ceil(NSMaxY([self.layoutManager usedRectForTextContainer:self.textContainer]))+16;
    CGFloat buttonY=_inlineEvidence ? round(16+NSMidY(value)-31/2.0) : textBottom+12;
    _evidence.frame=NSMakeRect(NSWidth(self.bounds)-18-132,buttonY,132,31);
    CGFloat height=ceil(MAX(textBottom,NSMaxY(_evidence.frame)))+16;
    if(fabs(_height.constant-height)>.5) _height.constant=height;
}
- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    if (_measurementPending || !_height || self.hiddenOrHasHiddenAncestor) return;
    _measurementPending=YES;
    __weak SPDFMacAIAnswerCardView* weakSelf=self;
    dispatch_async(dispatch_get_main_queue(),^{ SPDFMacAIAnswerCardView* view=weakSelf;
        if (!view) return; view->_measurementPending=NO; [view measure];
    });
}
@end
