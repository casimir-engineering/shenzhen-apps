// Shared helpers for the chat Markdown suite (SPDFMacChatMarkdownTests.mm): checks, a counting image fetcher that
// never touches the network, clicks delivered to a view, and lookups into rendered messages.
#pragma once
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import "../SPDFMacChatMarkdownParts.h"
#import "../SPDFMacChatMarkdownView.h"

static void Check(BOOL condition, NSString* message) {
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    exit(1);
}

// Every image request a test makes goes through one of these: it counts, and answers with a small PNG or nothing.
@interface ChatFetchRecorder : NSObject
@property(nonatomic) NSUInteger count;
@property(nonatomic, strong) NSMutableArray<NSURL*>* URLs;
@property(nonatomic) BOOL fails;
- (SPDFMacChatMarkdownImageFetch)fetcher;
@end
@implementation ChatFetchRecorder
- (instancetype)init {
    if ((self = [super init])) _URLs = [NSMutableArray array];
    return self;
}
+ (NSData*)picture {
    NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:320 pixelsHigh:200
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
        bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [[NSColor colorWithSRGBRed:.20 green:.45 blue:.75 alpha:1] setFill];
    NSRectFill(NSMakeRect(0, 0, 320, 200));
    [[NSColor colorWithSRGBRed:.95 green:.75 blue:.20 alpha:1] setFill];
    NSRectFill(NSMakeRect(40, 40, 120, 80));
    [NSGraphicsContext restoreGraphicsState];
    return [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}
- (SPDFMacChatMarkdownImageFetch)fetcher {
    __weak ChatFetchRecorder* weakSelf = self;
    return ^(NSURL* URL, void (^completion)(NSData*)) {
      ChatFetchRecorder* recorder = weakSelf;
      recorder.count++;
      [recorder.URLs addObject:URL];
      completion(recorder.fails ? nil : [ChatFetchRecorder picture]);
    };
}
@end

static NSEvent* ChatPendingUp;
@implementation NSWindow (ChatMarkdownTestEvents)
- (NSEvent*)chatMarkdownNextEvent:(NSEventMask)mask {
    (void)mask;
    NSEvent* event = ChatPendingUp;
    ChatPendingUp = nil;
    return event;
}
@end

// A click at `point` (in `view`'s coordinates): mouse down to `view`, the matching mouse up from the event queue.
static void ChatClick(NSView* view, NSPoint point) {
    NSPoint location = [view convertPoint:point toView:nil];
    NSEvent* down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:location modifierFlags:0 timestamp:1
                                   windowNumber:view.window.windowNumber context:nil eventNumber:1 clickCount:1
                                       pressure:1];
    ChatPendingUp = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:location modifierFlags:0
                                      timestamp:1.01 windowNumber:view.window.windowNumber context:nil eventNumber:2
                                     clickCount:1 pressure:0];
    Method original = class_getInstanceMethod(NSWindow.class, @selector(nextEventMatchingMask:));
    Method injected = class_getInstanceMethod(NSWindow.class, @selector(chatMarkdownNextEvent:));
    method_exchangeImplementations(original, injected);
    NSView* root = view.window.contentView;
    NSView* target = [root hitTest:[root.superview convertPoint:location fromView:nil]] ?: view;
    [target mouseDown:down];
    method_exchangeImplementations(original, injected);
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
}

static SPDFMacChatMarkdownOptions* ChatOptions(CGFloat width, BOOL dark, ChatFetchRecorder* recorder) {
    SPDFMacChatMarkdownOptions* options = [SPDFMacChatMarkdownOptions new];
    options.width = width;
    options.dark = dark;
    options.fetchImage = recorder.fetcher;
    options.openLink = ^(NSURL* URL) {
      Check(NO, [@"a test link opened unexpectedly: " stringByAppendingString:URL.absoluteString]);
    };
    return options;
}

static NSArray<NSTextAttachment*>* ChatAttachments(NSAttributedString* text) {
    NSMutableArray* found = [NSMutableArray array];
    [text enumerateAttribute:NSAttachmentAttributeName inRange:NSMakeRange(0, text.length) options:0
                  usingBlock:^(id value, NSRange range, BOOL* stop) {
                    (void)range, (void)stop;
                    if (value) [found addObject:value];
                  }];
    return found;
}

// The laid-out block behind a drawn-block attachment, or nil for any other attachment.
static SPDFMacChatBlock* ChatBlockOf(NSTextAttachment* attachment) {
    id cell = attachment.attachmentCell;
    return [cell respondsToSelector:NSSelectorFromString(@"block")] ? [cell valueForKey:@"block"] : nil;
}

static NSArray<SPDFMacChatBlock*>* ChatBlocks(NSAttributedString* text) {
    NSMutableArray* blocks = [NSMutableArray array];
    for (NSTextAttachment* attachment in ChatAttachments(text))
        if (ChatBlockOf(attachment)) [blocks addObject:ChatBlockOf(attachment)];
    return blocks;
}

// Where a character's attachment is drawn in a text view, in the view's coordinates.
static NSRect ChatAttachmentFrame(NSTextView* view, NSUInteger index) {
    NSLayoutManager* layout = view.layoutManager;
    [layout ensureLayoutForTextContainer:view.textContainer];
    NSUInteger glyph = [layout glyphIndexForCharacterAtIndex:index];
    NSRect line = [layout lineFragmentRectForGlyphAtIndex:glyph effectiveRange:NULL];
    NSPoint location = [layout locationForGlyphAtIndex:glyph];
    NSSize size = [layout attachmentSizeForGlyphAtIndex:glyph];
    NSPoint origin = view.textContainerOrigin;
    return NSMakeRect(origin.x + NSMinX(line) + location.x, origin.y + NSMinY(line) + location.y - size.height,
                      size.width, size.height);
}

static NSUInteger ChatIndexOfAttachment(NSAttributedString* text, NSTextAttachment* attachment) {
    __block NSUInteger index = NSNotFound;
    [text enumerateAttribute:NSAttachmentAttributeName inRange:NSMakeRange(0, text.length) options:0
                  usingBlock:^(id value, NSRange range, BOOL* stop) {
                    if (value == attachment) {
                        index = range.location;
                        *stop = YES;
                    }
                  }];
    return index;
}

static NSWindow* ChatWindow(NSRect frame) {
    NSWindow* window = [[NSWindow alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed = NO;
    return window;
}
