// The Settings window's buttons (SPDFMacSettingsButton.h).
#import "SPDFMacSettingsButton.h"
#import "SPDFMacCollectionStyle.h"

@implementation SPDFSettingsButton
- (NSSize)intrinsicContentSize {
    return NSMakeSize(ceil([self.title sizeWithAttributes:@{NSFontAttributeName:self.font}].width)+24,28);
}
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSBezierPath* shape=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,.5,.5) xRadius:5 yRadius:5];
    BOOL alternative=[@[@"revealKey",@"hideKey"] containsObject:self.identifier];
    BOOL chosen=self.state==NSControlStateValueOn, accent=self.enabled && [@[@"done",@"connect"] containsObject:self.identifier];
    [SPDFCollectionColor(chosen ? @"text" : accent ? @"accentFill" : self.highlighted ? @"lineStrong" : @"control") setFill];
    if(!alternative || self.highlighted) [shape fill];
    NSMutableParagraphStyle* style=[NSMutableParagraphStyle new]; style.alignment=NSTextAlignmentCenter;
    NSDictionary* attributes=@{NSFontAttributeName:self.font,NSForegroundColorAttributeName:SPDFCollectionColor(!self.enabled ?
        @"secondary" : chosen ? @"window" : accent ? @"onAccent" : alternative ? @"accent" : @"text"),NSParagraphStyleAttributeName:style};
    CGFloat h=[self.title sizeWithAttributes:attributes].height;
    [self.title drawInRect:NSMakeRect(8,floor((self.bounds.size.height-h)/2),self.bounds.size.width-16,h)
        withAttributes:attributes];
    if (self.window.firstResponder==self) {
        [NSGraphicsContext saveGraphicsState]; NSSetFocusRingStyle(NSFocusRingOnly); [shape fill];
        [NSGraphicsContext restoreGraphicsState];
    }
}
@end
