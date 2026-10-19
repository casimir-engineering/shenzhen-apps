// The AI chat message view (SPDFMacChatMarkdownView.h): wide blocks scroll sideways inside the bubble, the
// transcript keeps scrolling over them, width and appearance changes re-render, Copy gives sources.
#pragma once
#import "SPDFMacChatMarkdownFixtures.h"

@interface ChatWheelRecorder : NSResponder
@property(nonatomic) NSUInteger wheels;
@end
@implementation ChatWheelRecorder
- (void)scrollWheel:(NSEvent*)event {
    (void)event;
    self.wheels++;
}
@end

static NSEvent* ChatWheel(int32_t vertical, int32_t horizontal) {
    CGEventRef event = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 2, vertical, horizontal);
    NSEvent* wheel = [NSEvent eventWithCGEvent:event];
    CFRelease(event);
    return wheel;
}

static NSString* const ChatWideMessage =
    @"Rails:\n\n| Rail | Voltage | Current | Regulator | Notes |\n|---|---|---|---|---|\n"
     "| VBUS | 5.0 V | 2 A | none | From USB-C, negotiated by the PD controller at plug-in |\n"
     "| 3V3 | 3.3 V | 600 mA | buck | 92 percent efficient at full load, quieter at light load |\n\n"
     "```c\nint read_voltage(int channel) { return adc_read(channel) * 3300 / 4095; /* millivolts */ }\n```\n\n"
     "Done. These values come from the power section of the schematic and from each regulator's datasheet.";

static void RunChatViewChecks(void) {
    ChatFetchRecorder* recorder = [ChatFetchRecorder new];
    NSWindow* window = ChatWindow(NSMakeRect(0, 0, 420, 700));
    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    NSPasteboard* pasteboard = [NSPasteboard pasteboardWithUniqueName];
    SPDFMacChatMarkdownOptions* options = ChatOptions(0, NO, recorder);
    options.pasteboard = pasteboard;
    SPDFMacChatMarkdownView* view = [[SPDFMacChatMarkdownView alloc] initWithMarkdown:ChatWideMessage width:340
                                                                              options:options];
    view.backgroundColor = NSColor.windowBackgroundColor;
    view.translatesAutoresizingMaskIntoConstraints = YES;
    view.frame = NSMakeRect(0, 0, 340, view.contentHeight.constant);
    NSScrollView* transcript = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 360, 200)];
    NSView* document = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 360, 900)];
    transcript.documentView = document;
    [document addSubview:view];
    [window.contentView addSubview:transcript];
    Check(view.wideBlocks.count == 2,
          [NSString stringWithFormat:@"the wide table and the long code line each scroll sideways (%lu strips)",
                                     (unsigned long)view.wideBlocks.count]);
    for (NSScrollView* strip in view.wideBlocks) {
        Check(NSContainsRect(view.bounds, strip.frame), @"a strip stays inside its bubble");
        Check(NSWidth(strip.documentView.frame) > NSWidth(strip.frame), @"a strip holds a block wider than itself");
        Check(strip.hasHorizontalScroller && !strip.hasVerticalScroller, @"a strip scrolls sideways only");
    }
    // The strip sits exactly over the block it shows.
    NSScrollView* table = view.wideBlocks.firstObject;
    NSUInteger tableIndex = [view.textStorage.string rangeOfString:@"￼"].location;
    NSRect attachment = ChatAttachmentFrame(view, tableIndex);
    Check(fabs(NSMinY(table.frame) - NSMinY(attachment)) < 1 && fabs(NSMinX(table.frame) - NSMinX(attachment)) < 1 &&
              fabs(NSHeight(table.frame) - NSHeight(attachment)) < 1,
          @"the strip covers the block's place in the text");
    // Up and down over a strip still scroll the conversation; sideways scrolls the strip.
    ChatWheelRecorder* wheels = [ChatWheelRecorder new];
    table.nextResponder = wheels;
    [table scrollWheel:ChatWheel(-40, 0)];
    Check(wheels.wheels == 1 && NSMinX(table.contentView.bounds) == 0, @"a vertical swipe passes over the strip");
    [table scrollWheel:ChatWheel(0, -60)];
    Check(wheels.wheels == 1, @"a sideways swipe stays with the strip");
    // Narrower: the message renders again, taller, and its blocks still fit.
    CGFloat tall = view.contentHeight.constant;
    view.contentHeight.active = YES;
    // The chat's search highlights a match with a temporary attribute (SPDFMacAIChatSearch); re-rendering must keep it.
    NSRange match = [view.textStorage.string rangeOfString:@"schematic"];
    [view.layoutManager addTemporaryAttribute:NSBackgroundColorAttributeName value:NSColor.orangeColor
                            forCharacterRange:match];
    [view setFrameSize:NSMakeSize(260, NSHeight(view.frame))];
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
    Check(view.contentHeight.constant > tall, @"a narrower bubble renders the message again, taller");
    Check([view.layoutManager temporaryAttribute:NSBackgroundColorAttributeName atCharacterIndex:match.location
                                  effectiveRange:NULL] != nil,
          @"a search highlight survives the message rendering again at a new width");
    for (NSScrollView* strip in view.wideBlocks) Check(NSMaxX(strip.frame) <= 260 + .5, @"strips follow the new width");
    // Copy gives the blocks' sources, never attachment characters.
    [view setSelectedRange:NSMakeRange(0, view.textStorage.length)];
    [view copy:nil];
    NSString* copied = [pasteboard stringForType:NSPasteboardTypeString];
    Check([copied containsString:@"| Rail | Voltage |"] && [copied containsString:@"int read_voltage"] &&
              ![copied containsString:@"￼"] && [copied hasPrefix:@"Rails:"],
          [@"Copy gives the table's Markdown and the code: " stringByAppendingString:copied ?: @"(nothing)"]);
    // Dark: the same message re-renders in the dark palette.
    NSColor* light = [view.textStorage attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL];
    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    [view viewDidChangeEffectiveAppearance];
    NSColor* dark = [view.textStorage attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL];
    Check(light.brightnessComponent < .3 && dark.brightnessComponent > .8, @"the text follows the appearance");
    [pasteboard releaseGlobally];
    [window close];
}

// Counts renders, so a check can tell a view rendered once.
@interface ChatCountingMarkdownView : SPDFMacChatMarkdownView
@property(nonatomic) NSUInteger renders;
@end
@implementation ChatCountingMarkdownView
- (void)renderNow {
    self.renders++;
    [super renderNow];
}
@end

// A card body flush with its title (SPDFMacAIChatActivityView) renders once, at the full width, with no inset to undo.
static void RunChatViewInsetChecks(void) {
    ChatFetchRecorder* recorder = [ChatFetchRecorder new];
    SPDFMacChatMarkdownOptions* options = ChatOptions(0, NO, recorder);
    NSString* body = @"Searched the web for **delivery dates** and opened two pages, which say Friday at the latest.";
    ChatCountingMarkdownView* flush = [[ChatCountingMarkdownView alloc] initWithMarkdown:body width:260 options:options
                                                                               textInset:NSZeroSize];
    Check(flush.renders == 1 && NSEqualSizes(flush.textContainerInset, NSZeroSize),
          [NSString stringWithFormat:@"a flush view renders once (%lu)", (unsigned long)flush.renders]);
    Check(fabs(flush.textContainer.containerSize.width - 260) < .5, @"its text is laid out across the whole width");
    CGFloat used = ceil(NSMaxY([flush.layoutManager usedRectForTextContainer:flush.textContainer]));
    Check(fabs(flush.contentHeight.constant - MAX(18, used)) < .5, @"its height is its text's, with no inset");
    ChatCountingMarkdownView* bubble = [[ChatCountingMarkdownView alloc] initWithMarkdown:body width:260
                                                                                  options:options];
    Check(bubble.renders == 1 && NSEqualSizes(bubble.textContainerInset, NSMakeSize(10, 8)) &&
              fabs(bubble.textContainer.containerSize.width - 240) < .5,
          @"a chat bubble keeps its 10 by 8 pt inset");
    Check(flush.contentHeight.constant < bubble.contentHeight.constant, @"the flush view is the shorter");
}
