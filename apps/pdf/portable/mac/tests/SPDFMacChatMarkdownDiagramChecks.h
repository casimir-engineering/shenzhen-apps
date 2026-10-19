// Diagrams at chat scale, measured in offscreen renders: the blank around them is a chat's, not a page's, and their
// node borders stand out from the bubble in both appearances.
#pragma once
#import "SPDFMacChatMarkdownFixtures.h"

// The bubbles a chat message is drawn on: AI chat's assistant bubble and Friends' incoming one (SPDFCollectionColor
// "control", SZFriendsHostValues.m), light then dark.
static NSColor* ChatBubble(unsigned value) {
    return [NSColor colorWithSRGBRed:((value >> 16) & 0xff) / 255.0 green:((value >> 8) & 0xff) / 255.0
                                blue:(value & 0xff) / 255.0 alpha:1];
}

// A message view on `bubble`, drawn into an sRGB bitmap `scale` times its size, so sampled colours are the drawn ones.
static NSBitmapImageRep* ChatDrawn(SPDFMacChatMarkdownView* view, NSColor* bubble, CGFloat scale) {
    view.backgroundColor = bubble;
    NSSize size = view.bounds.size;
    NSBitmapImageRep* device = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:(NSInteger)(size.width * scale) pixelsHigh:(NSInteger)(size.height * scale) bitsPerSample:8
        samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    NSBitmapImageRep* rep = [device bitmapImageRepByRetaggingWithColorSpace:NSColorSpace.sRGBColorSpace];
    rep.size = size;
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
    return rep;
}

static SPDFMacChatMarkdownView* ChatShown(NSString* markdown, NSWindow* window, BOOL dark) {
    window.appearance = [NSAppearance appearanceNamed:dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
    SPDFMacChatMarkdownView* view = [[SPDFMacChatMarkdownView alloc] initWithMarkdown:markdown width:420
                                                                              options:ChatOptions(0, dark, nil)];
    [window.contentView addSubview:view];
    [view viewDidChangeEffectiveAppearance];
    view.translatesAutoresizingMaskIntoConstraints = YES;
    view.frame = NSMakeRect(0, 0, 420, view.contentHeight.constant);
    return view;
}

// YES when a 1x row has anything on it but the bubble, inside the text insets.
static BOOL ChatInkRow(NSBitmapImageRep* rep, NSInteger row, NSColor* bubble) {
    for (NSInteger x = 10; x < rep.pixelsWide - 10; x++) {
        NSColor* color = [rep colorAtX:x y:row];
        if (fabs(color.redComponent - bubble.redComponent) + fabs(color.greenComponent - bubble.greenComponent) +
                fabs(color.blueComponent - bubble.blueComponent) > .06)
            return YES;
    }
    return NO;
}

// The blank rows between the last ink above `y` and the first ink at or below it, in a 1x render.
static NSInteger ChatGapAt(NSBitmapImageRep* rep, NSInteger y, NSColor* bubble) {
    NSInteger below = y, above = y - 1;
    while (below < rep.pixelsHigh && !ChatInkRow(rep, below, bubble)) below++;
    while (above >= 0 && !ChatInkRow(rep, above, bubble)) above--;
    return below - above - 1;
}

// The rect a character's line takes in the view (y down).
static NSRect ChatLineRect(NSTextView* view, NSUInteger index) {
    NSUInteger glyph = [view.layoutManager glyphIndexForCharacterAtIndex:index];
    NSRect line = [view.layoutManager lineFragmentUsedRectForGlyphAtIndex:glyph effectiveRange:NULL];
    return NSOffsetRect(line, view.textContainerOrigin.x, view.textContainerOrigin.y);
}

static void RunChatDiagramSpacingChecks(void) {
    NSWindow* window = ChatWindow(NSMakeRect(0, 0, 440, 1200));
    NSString* message = @"Above the formula, a sentence.\n\n$$\\frac{a}{b} = \\sum_{i=0}^{n} x_i^2$$\n\n"
                         "```mermaid\nflowchart TD\n  A[Start] --> B[Check input]\n  B --> C[Done]\n```\n\n"
                         "```mermaid\npie title Power\n  \"MCU\" : 40\n  \"Radio\" : 60\n```\n\nBelow, a sentence.";
    SPDFMacChatMarkdownView* view = ChatShown(message, window, NO);
    NSColor* bubble = ChatBubble(0xf6f6f5);
    NSBitmapImageRep* rep = ChatDrawn(view, bubble, 1);
    NSArray<NSTextAttachment*>* diagrams = ChatAttachments(view.textStorage);
    NSArray<SPDFMacChatBlock*>* blocks = ChatBlocks(view.textStorage);
    Check(blocks.count == 2 && blocks.firstObject.kind == SPDFMacChatBlockDiagram &&
              blocks.lastObject.kind == SPDFMacChatBlockDiagram,
          @"the message draws its two diagrams");
    // Measured from a row just outside each block, which lies in the blank between it and its neighbour.
    NSRect formula = ChatLineRect(view, [view.textStorage.string rangeOfString:@"\u2211"].location);
    NSMutableArray<NSNumber*>* gaps = [NSMutableArray array];
    [gaps addObject:@(ChatGapAt(rep, (NSInteger)floor(NSMinY(formula)) - 1, bubble))];
    for (NSTextAttachment* diagram in diagrams) {
        NSRect frame = ChatAttachmentFrame(view, ChatIndexOfAttachment(view.textStorage, diagram));
        [gaps addObject:@(ChatGapAt(rep, (NSInteger)floor(NSMinY(frame)) - 1, bubble))];
        [gaps addObject:@(ChatGapAt(rep, (NSInteger)ceil(NSMaxY(frame)), bubble))];
    }
    // A page's spacing left 25 pt above a formula, 60 between a formula and a diagram, 74 between two diagrams;
    // body paragraphs are about 10 pt apart.
    for (NSNumber* gap in gaps)
        Check(gap.integerValue >= 4 && gap.integerValue < 16,
              [NSString stringWithFormat:@"the blank around a diagram or formula is a chat's, 4 to 16 pt: %@",
                                         [gaps componentsJoinedByString:@", "]]);
    [window close];
}

static CGFloat ChatLuminance(NSColor* color) {
    NSColor* rgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    CGFloat channels[3] = {rgb.redComponent, rgb.greenComponent, rgb.blueComponent}, linear[3];
    for (int index = 0; index < 3; index++)
        linear[index] = channels[index] <= 0.04045 ? channels[index] / 12.92
                                                   : pow((channels[index] + 0.055) / 1.055, 2.4);
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2];
}

static CGFloat ChatContrast(NSColor* one, NSColor* two) {
    CGFloat a = ChatLuminance(one), b = ChatLuminance(two);
    return (MAX(a, b) + 0.05) / (MIN(a, b) + 0.05);
}

// The strongest contrast with the bubble along a node's left border, measured in a 4x render: a 1 pt stroke is four
// pixels wide there, so its middle ones are fully covered wherever it falls.
static CGFloat ChatNodeBorderContrast(SPDFMacChatMarkdownView* view, NSColor* bubble) {
    NSBitmapImageRep* rep = ChatDrawn(view, bubble, 4);
    NSTextAttachment* attachment = ChatAttachments(view.textStorage).firstObject;
    SPDFMacChatBlock* block = ChatBlockOf(attachment);
    NSRect frame = ChatAttachmentFrame(view, ChatIndexOfAttachment(view.textStorage, attachment));
    for (SPDFMarkdownPageDecoration* decoration in [block.plan decorationsForPageIndex:0]) {
        SPDFMarkdownDiagramLayout* layout = decoration.diagramLayout;
        for (SPDFMarkdownDiagramShape* shape in layout.shapes) {
            if (shape.kind != SPDFMarkdownDiagramShapeRectangle ||
                shape.strokeRole != SPDFMarkdownDiagramRoleNodeStroke)
                continue;
            // Diagram-local to page to the attachment's place in the view; all y down.
            CGFloat scale = NSWidth(decoration.rect) / layout.size.width;
            NSPoint origin = NSMakePoint(NSMinX(frame) - NSMinX(block.contentRect) + NSMinX(decoration.rect),
                                         NSMinY(frame) - NSMinY(block.contentRect) + NSMinY(decoration.rect));
            CGFloat x = origin.x + NSMinX(shape.rect) * scale, y = origin.y + NSMidY(shape.rect) * scale;
            CGFloat best = 1;
            for (NSInteger px = (NSInteger)((x - 1.5) * 4); px <= (NSInteger)((x + 1.5) * 4); px++)
                best = MAX(best, ChatContrast([rep colorAtX:px y:(NSInteger)(y * 4)], bubble));
            return best;
        }
    }
    Check(NO, @"the flowchart has a node with a border");
    return 0;
}

static void RunChatDiagramContrastChecks(void) {
    NSWindow* window = ChatWindow(NSMakeRect(0, 0, 440, 600));
    NSString* flowchart = @"```mermaid\nflowchart LR\n  USB[USB-C VBUS] --> PD{PD controller}\n```";
    for (NSNumber* dark in @[ @NO, @YES ]) {
        SPDFMacChatMarkdownView* view = ChatShown(flowchart, window, dark.boolValue);
        for (NSNumber* value in dark.boolValue ? @[ @0x232426, @0x34343b ] : @[ @0xf6f6f5, @0xefeff1 ]) {
            CGFloat contrast = ChatNodeBorderContrast(view, ChatBubble(value.unsignedIntValue));
            // The page's hairline grey measured 1.34:1 in light and 1.29:1 in dark on these bubbles.
            Check(contrast >= 3, [NSString stringWithFormat:@"a node's border stands out from the %@ bubble %06x "
                                                             "(%.2f:1, at least 3:1)",
                                                            dark.boolValue ? @"dark" : @"light",
                                                            value.unsignedIntValue, contrast]);
        }
        [view removeFromSuperview];
    }
    [window close];
}
