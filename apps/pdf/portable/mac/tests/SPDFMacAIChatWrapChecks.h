#pragma once
// Long unbroken text (a word with no spaces, a pasted address) in the composer, in sent messages and in the question
// line above the transcript: it wraps inside each, by character where it has to, and nothing is drawn past an edge.
// The composer grows with its text up to SPDFChatComposerMaximumHeight, then scrolls, never sideways. Each check
// runs at a narrow and a normal panel width, light and dark, on the real chat view docked as the reader docks it and
// rendered offscreen (never shown). Included by SPDFMacAIChatViewTests.mm, which defines Check, Capture, ChatFixture
// and ConstraintWatchWindow.
#include <unordered_map>
#include <vector>

static NSString* WrapLongWord(NSUInteger length) {
    NSMutableString* word=[NSMutableString string];
    while(word.length<length) [word appendString:@"testhelloiamatest"];
    return [word substringToIndex:length];
}
static void WrapSettle(NSWindow* window) {
    for(int i=0;i<4;i++) {
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
        [window.contentView layoutSubtreeIfNeeded];
    }
}
// `view` as drawn, in sRGB rows from its visual top, and its commonest colour, taken as its background.
struct WrapPixels { NSInteger width=0, height=0; CGFloat scale=1; std::vector<uint32_t> pixels; uint32_t background=0; };
static WrapPixels WrapCapture(NSView* view) {
    [view layoutSubtreeIfNeeded];
    NSBitmapImageRep* rep=[view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
    WrapPixels p; p.width=rep.pixelsWide; p.height=rep.pixelsHigh; p.scale=p.width/MAX(1.,NSWidth(view.bounds));
    p.pixels.assign((size_t)(p.width*p.height),0);
    CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context=CGBitmapContextCreate(p.pixels.data(),p.width,p.height,8,p.width*4,space,
                                               kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(context,CGRectMake(0,0,p.width,p.height),rep.CGImage);
    CGContextRelease(context); CGColorSpaceRelease(space);
    std::unordered_map<uint32_t,size_t> counts; size_t best=0;
    for(uint32_t pixel : p.pixels) if(++counts[pixel]>best) { best=counts[pixel]; p.background=pixel; }
    return p;
}
static BOOL WrapIsInk(const WrapPixels& p, NSInteger x, NSInteger y) {
    uint32_t a=p.pixels[(size_t)(y*p.width+x)], b=p.background; int most=0;
    for(int shift=0;shift<32;shift+=8) most=MAX(most,abs((int)((a>>shift)&255)-(int)((b>>shift)&255)));
    return most>64;
}
// Ink pixels inside `rect`, in points from the view's visual top-left.
static NSUInteger WrapInk(const WrapPixels& p, NSRect rect) {
    NSInteger x0=MAX(0,(NSInteger)floor(NSMinX(rect)*p.scale)), x1=MIN(p.width,(NSInteger)ceil(NSMaxX(rect)*p.scale));
    NSInteger y0=MAX(0,(NSInteger)floor(NSMinY(rect)*p.scale)), y1=MIN(p.height,(NSInteger)ceil(NSMaxY(rect)*p.scale));
    NSUInteger ink=0;
    for(NSInteger y=y0;y<y1;y++) for(NSInteger x=x0;x<x1;x++) ink+=WrapIsInk(p,x,y);
    return ink;
}
// Separate bands of rows holding ink: the lines of text drawn.
static NSUInteger WrapInkLines(const WrapPixels& p) {
    NSUInteger lines=0; BOOL previous=NO;
    for(NSInteger y=0;y<p.height;y++) {
        BOOL any=NO; for(NSInteger x=0;x<p.width && !any;x++) any=WrapIsInk(p,x,y);
        if(any && !previous) lines++; previous=any;
    }
    return lines;
}
// Every laid-out line of `text`, in its own coordinates, lies within [left, right]; and all of it is laid out.
static BOOL WrapLinesWithin(NSTextView* text, CGFloat left, CGFloat right, CGFloat* widest) {
    NSLayoutManager* layout=text.layoutManager; [layout ensureLayoutForTextContainer:text.textContainer];
    NSPoint origin=text.textContainerOrigin; BOOL inside=layout.firstUnlaidCharacterIndex==text.string.length;
    *widest=0;
    for(NSUInteger glyph=0;glyph<layout.numberOfGlyphs;) {
        NSRange line; NSRect used=[layout lineFragmentUsedRectForGlyphAtIndex:glyph effectiveRange:&line];
        // The bounding rect of the line's glyphs is where its ink goes.
        NSRect ink=NSOffsetRect([layout boundingRectForGlyphRange:line inTextContainer:text.textContainer],origin.x,
                                origin.y);
        used=NSOffsetRect(used,origin.x,origin.y);
        *widest=MAX(*widest,MAX(NSMaxX(used),NSMaxX(ink)));
        inside&=NSMinX(ink)>=left-.5 && NSMaxX(ink)<=right+.5 && NSMaxX(used)<=right+.5;
        glyph=MAX(NSMaxRange(line),glyph+1);
    }
    return inside;
}

static void CheckComposerWraps(SPDFMacAIChatView* view, NSWindow* window, NSString* at) {
    NSTextView* composer=view.composer; NSScrollView* input=composer.enclosingScrollView; NSClipView* clip=input.contentView;
    composer.string=@""; [composer insertText:@"Hi" replacementRange:NSMakeRange(NSNotFound,0)]; WrapSettle(window);
    Check(fabs(NSHeight(input.frame)-SPDFChatComposerHeight)<.5,
          [NSString stringWithFormat:@"%@: a short message keeps the composer at its usual height (%.1f)",at,
                                     NSHeight(input.frame)]);
    composer.string=@""; WrapSettle(window);
    // Typed in pieces, as a person types: the field grows line by line, then stops at its cap and scrolls.
    NSString* word=WrapLongWord(1200); std::vector<CGFloat> heights;
    for(NSUInteger i=0;i<word.length;i+=40) {
        [composer insertText:[word substringWithRange:NSMakeRange(i,MIN(40,word.length-i))]
            replacementRange:NSMakeRange(NSNotFound,0)];
        WrapSettle(window); heights.push_back(NSHeight(input.frame));
    }
    BOOL monotonic=YES, between=NO;
    for(size_t i=0;i<heights.size();i++) {
        if(i && heights[i]<heights[i-1]-.5) monotonic=NO;
        if(heights[i]>SPDFChatComposerHeight+.5 && heights[i]<SPDFChatComposerMaximumHeight-.5) between=YES;
    }
    Check(monotonic && between,[NSString stringWithFormat:@"%@: the composer grows with a long word (%.1f to %.1f)",
                                                          at,heights.front(),heights.back()]);
    Check(fabs(heights.back()-SPDFChatComposerMaximumHeight)<.5,
          [NSString stringWithFormat:@"%@: the composer stops growing at its cap (%.1f, cap %.1f)",at,heights.back(),
                                     SPDFChatComposerMaximumHeight]);
    Check(NSHeight(composer.frame)>NSHeight(clip.bounds)+16 && NSMinY(clip.bounds)>0,
          [NSString stringWithFormat:@"%@: past its cap the composer scrolls up to the typing (text %.0f, shown %.0f, "
                                     "scrolled %.0f)",at,NSHeight(composer.frame),NSHeight(clip.bounds),
                                     NSMinY(clip.bounds)]);
    Check(fabs(NSWidth(composer.frame)-NSWidth(clip.bounds))<.5 && fabs(NSMinX(clip.bounds))<.5 &&
          !input.hasHorizontalScroller,
          [NSString stringWithFormat:@"%@: the composer is exactly as wide as the field and never scrolls sideways "
                                     "(text %.0f, field %.0f, offset %.0f)",at,NSWidth(composer.frame),
                                     NSWidth(clip.bounds),NSMinX(clip.bounds)]);
    // What the field shows (looked at before anything asks for TextKit 1's layout manager): text across the line up to its right inset, nothing in the inset itself.
    WrapPixels shown=WrapCapture(clip); CGFloat w=NSWidth(clip.bounds), h=NSHeight(clip.bounds);
    NSUInteger edge=WrapInk(shown,NSMakeRect(w-6,0,6,h)), body=WrapInk(shown,NSMakeRect(w*.55,0,w*.45-14,h));
    Check(edge==0 && body>40,[NSString stringWithFormat:@"%@: the field draws the long word up to its edge and not past "
                                                       "it (%lu ink pixels at the edge, %lu across the line)",at,
                                                       (unsigned long)edge,(unsigned long)body]);
    Check(WrapInkLines(shown)>=4,[NSString stringWithFormat:@"%@: the field shows the long word over several lines (%lu)",
                                                           at,(unsigned long)WrapInkLines(shown)]);
    CGFloat widest=0;
    BOOL within=WrapLinesWithin(composer,0,NSWidth(clip.bounds)-composer.textContainerInset.width,&widest);
    Check(within,[NSString stringWithFormat:@"%@: every line of a long word ends inside the field (widest %.0f, "
                                            "field %.0f)",at,widest,NSWidth(clip.bounds)]);
    composer.string=@""; WrapSettle(window);
    Check(fabs(NSHeight(input.frame)-SPDFChatComposerHeight)<.5,
          [NSString stringWithFormat:@"%@: an emptied composer returns to its usual height (%.1f)",at,
                                     NSHeight(input.frame)]);
}
static void CheckMessagesWrap(SPDFMacAIChatView* view, NSString* at) {
    NSStackView* messages=[view valueForKey:@"messages"]; NSScrollView* transcript=[view valueForKey:@"scroll"];
    NSUInteger bubbles=0;
    for(NSView* row in messages.arrangedSubviews) {
        if(![row isKindOfClass:SPDFMacChatMarkdownView.class]) continue;
        SPDFMacChatMarkdownView* bubble=(id)row; bubbles++;
        NSString* who=[NSString stringWithFormat:@"%@ %@",at,bubble.accessibilityLabel];
        CGFloat widest=0, right=NSWidth(bubble.bounds)-bubble.textContainerInset.width;
        BOOL within=WrapLinesWithin(bubble,bubble.textContainerInset.width,right,&widest);
        NSRect shownFrame=[bubble convertRect:bubble.bounds toView:transcript.contentView];
        Check(within && !bubble.wideBlocks.count && NSMaxX(shownFrame)<=NSMaxX(transcript.contentView.bounds)+.5,
              [NSString stringWithFormat:@"%@: a long word wraps inside its message (widest %.0f, inside %.0f)",who,
                                         widest,right]);
        NSLayoutManager* layout=bubble.layoutManager;
        NSRect last=[layout lineFragmentUsedRectForGlyphAtIndex:layout.numberOfGlyphs-1 effectiveRange:nil];
        Check(NSMaxY(last)+bubble.textContainerOrigin.y<=NSHeight(bubble.bounds)+.5,
              [NSString stringWithFormat:@"%@: the message is tall enough for its last line",who]);
        WrapPixels drawn=WrapCapture(bubble); CGFloat w=NSWidth(bubble.bounds), h=NSHeight(bubble.bounds);
        // The rounded corners are not text: leave them out of the edge strip.
        NSUInteger edge=WrapInk(drawn,NSMakeRect(w-6,8,6,h-16)), body=WrapInk(drawn,NSMakeRect(w*.55,0,w*.45-12,h));
        Check(edge==0 && body>40 && WrapInkLines(drawn)>=3,
              [NSString stringWithFormat:@"%@: the message draws the long word on several lines up to its edge and "
                                         "not past it (%lu at the edge, %lu across, %lu lines)",who,
                                         (unsigned long)edge,(unsigned long)body,(unsigned long)WrapInkLines(drawn)]);
    }
    Check(bubbles==2,[NSString stringWithFormat:@"%@: both messages are shown (%lu)",at,(unsigned long)bubbles]);
    NSTextField* prompt=[view valueForKey:@"prompt"];
    // Where its text goes: a label's frame reaches 2 pt past its text on each side.
    NSRect place=[prompt.superview convertRect:[prompt alignmentRectForFrame:prompt.frame] toView:view];
    WrapPixels drawn=WrapCapture(prompt); NSUInteger lines=WrapInkLines(drawn);
    NSUInteger edge=WrapInk(drawn,NSMakeRect(NSWidth(prompt.bounds)-2,0,2,NSHeight(prompt.bounds)));
    Check(!prompt.hidden && NSMaxX(place)<=NSWidth(view.bounds)-15.5 && lines>=2 && lines<=3 && edge==0,
          [NSString stringWithFormat:@"%@: your latest question wraps a long word over its lines inside the panel "
                                     "(%lu lines, %lu at the edge, ends at %.0f of %.0f)",at,(unsigned long)lines,
                                     (unsigned long)edge,NSMaxX(place),NSWidth(view.bounds)]);
}
static void RunChatWrapChecks(void) {
    NSString* watch=@"NSConstraintBasedLayoutVisualizeMutuallyExclusiveConstraints";
    [NSUserDefaults.standardUserDefaults registerDefaults:@{watch:@YES}];
    for(NSNumber* width in @[@280,@460]) for(NSAppearanceName name in @[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]) {
        NSString* at=[NSString stringWithFormat:@"%@ pt %@",width,[name isEqual:NSAppearanceNameAqua] ? @"light" : @"dark"];
        // Made as the reader makes it: the panel at its first size, then docked beside the document at `width`.
        CGFloat available=width.doubleValue+(width.doubleValue<320 ? 100 : 280);
        ConstraintWatchWindow* window=[[ConstraintWatchWindow alloc] initWithContentRect:NSMakeRect(0,0,available,640)
            styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        window.appearance=[NSAppearance appearanceNamed:name];
        SPDFMacAIChatView* view=[[SPDFMacAIChatView alloc] initWithFrame:NSMakeRect(0,0,650,520)];
        NSView* reader=[[NSView alloc] initWithFrame:window.contentView.bounds];
        reader.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable; [window.contentView addSubview:reader];
        SPDFMacAIChatDock* dock=[[SPDFMacAIChatDock alloc] initWithReaderView:reader chatView:view
                                                                         width:width.doubleValue];
        // Closed and opened again, as the panel is all day; closed, it is zero points wide.
        WrapSettle(window); [dock setVisible:NO]; WrapSettle(window); [dock setVisible:YES]; WrapSettle(window);
        Check(fabs(NSWidth(view.frame)-width.doubleValue)<.5,
              [NSString stringWithFormat:@"%@: the panel is docked at its width (%.0f)",at,NSWidth(view.frame)]);
        ChatFixture* fixture=[ChatFixture new];
        fixture.chat=@{@"id":@"wrap",@"messages":@[@{@"role":@"user",@"content":WrapLongWord(400)},
                                                   @{@"role":@"assistant",@"content":WrapLongWord(500)}]};
        [view displaySession:(id)fixture]; WrapSettle(window);
        CheckComposerWraps(view,window,at);
        CheckMessagesWrap(view,at);
        Check(!window.conflicts,[NSString stringWithFormat:@"%@: long words break no constraint (%lu broken)",at,
                                                           (unsigned long)window.conflicts]);
        if(width.intValue==280) {
            [view.composer insertText:WrapLongWord(300) replacementRange:NSMakeRange(NSNotFound,0)];
            WrapSettle(window); Capture(view,[@"wrap-" stringByAppendingString:name]);
        }
    }
    [NSUserDefaults.standardUserDefaults registerDefaults:@{watch:@NO}];
}
