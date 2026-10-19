// ShenzhenPDF's Markdown for friend messages (SPDFMacFriendsMarkdown.h): the views' host method answers with the
// chats' renderer under Friends' rules. Headless: no helper, no network.
#import "SPDFMacFriendsMarkdown.h"
#import "SPDFMacChatMarkdownParts.h"
#import "SPDFMacFriendsTestSupport.h"

@interface MarkdownBridge : NSObject <SPDFMacFriendsReaderBridge>
@property(nonatomic, strong) SZFriendsAppearance* appearance;
@end
@implementation MarkdownBridge
- (void)friendsBridgeInstallTitleBarButton:(NSView*)button { (void)button; }
- (void)friendsBridgeRemoveTitleBarButton:(NSView*)button { (void)button; }
- (NSArray<NSDictionary*>*)friendsBridgeOpenDocuments { return @[]; }
- (id<SPDFMacFriendsCollectionLookup>)friendsBridgeCollectionLookup { return nil; }
- (void)friendsBridgeOpenPaths:(NSArray<NSString*>*)paths { (void)paths; }
- (void)friendsBridgeRevealFiles:(NSArray<NSURL*>*)fileURLs { (void)fileURLs; }
- (void)friendsBridgeServicesChanged:(id<SZFriendsServices>)services { (void)services; }
- (SZFriendsAppearance*)friendsBridgeAppearance { return self.appearance; }
@end

static NSColor* Dynamic(NSColor* light, NSColor* dark) {
    return [NSColor colorWithName:nil dynamicProvider:^NSColor*(NSAppearance* appearance) {
      return [[appearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]]
                 isEqualToString:NSAppearanceNameDarkAqua] ? dark : light;
    }];
}

// A friend's 32 KB message of small tables, different from every other one (`seed`), so no layout is reused: the
// security review timed one at 0.46 s against the 0.4 s each message was allowed.
static NSString* HostileMessage(NSUInteger seed) {
    NSMutableString* text = [NSMutableString string];
    for (NSUInteger table = 0; text.length < 32 * 1024; table++)
        [text appendFormat:@"| m%lu | t%lu |\n|---|---|\n| %lu | %lu |\n\n", (unsigned long)seed, (unsigned long)table,
                           (unsigned long)(seed * 1000 + table), (unsigned long)table];
    return text;
}

static NSString* TallTable(NSString* name, NSUInteger rows) {
    NSMutableString* text = [NSMutableString stringWithFormat:@"| %@ | qty | note |\n|---|---|---|\n", name];
    for (NSUInteger row = 0; row < rows; row++)
        [text appendFormat:@"| part %lu | %lu | ships with the %@ order |\n", (unsigned long)row,
                           (unsigned long)(row * 3), name];
    return text;
}

static BOOL HasDrawnTable(NSAttributedString* text, NSString* header) {
    __block BOOL found = NO;
    [text enumerateAttribute:SPDFMacChatMarkdownSourceAttribute inRange:NSMakeRange(0, text.length) options:0
                  usingBlock:^(id source, NSRange range, BOOL* stop) {
                    if ([source isKindOfClass:NSString.class] && [source hasPrefix:header] &&
                        [text attribute:NSAttachmentAttributeName atIndex:range.location effectiveRange:NULL]) {
                        found = YES;
                        *stop = YES;
                    }
                  }];
    return found;
}

// One conversation's render pass shares 1 s (SPDFMacFriendsMarkdown.h): fifty hostile messages, asked for newest
// first as the views do, cost about that, and the oldest come back nil for the views to show as plain text. Before,
// each took its own 0.4 s or more, and opening such a conversation froze the window for about 20 s.
static void CheckRenderPassBudget(SPDFMacFriendsHost* host, NSAppearance* light) {
    NSMutableArray<NSString*>* messages = [NSMutableArray array];
    for (NSUInteger index = 0; index < 50; index++) [messages addObject:HostileMessage(index)];
    NSUInteger drawn = 0, plain = 0;
    NSDate* start = [NSDate date];
    [host friendsBeginMarkdownPass];
    for (NSString* message in messages.reverseObjectEnumerator) {
        if ([host friendsRenderMarkdown:message width:300 appearance:light]) drawn++;
        else plain++;
    }
    [host friendsEndMarkdownPass];
    NSTimeInterval took = -start.timeIntervalSinceNow;
    // 1 s shared, plus what the last render may overrun and the nil answers: far below fifty times 0.4 s.
    Expect(took < 3.0 && drawn >= 1 && plain >= 1 && drawn + plain == 50,
           @"fifty hostile messages in one pass took %.2f s (%lu drawn, %lu left to the views as plain text)", took,
           (unsigned long)drawn, (unsigned long)plain);
    // The next pass has its own allowance: the newest message renders again.
    [host friendsBeginMarkdownPass];
    Expect([host friendsRenderMarkdown:messages.lastObject width:300 appearance:light] != nil,
           @"a new pass must start with a fresh allowance");
    [host friendsEndMarkdownPass];
    // Renders the views did not bracket (a bubble asking again) share the main thread's current allowance.
    start = [NSDate date];
    for (NSUInteger index = 50; index < 70; index++)
        [host friendsRenderMarkdown:HostileMessage(index) width:300 appearance:light];
    took = -start.timeIntervalSinceNow;
    Expect(took < 3.0, @"twenty unbracketed hostile renders took %.2f s", took);
}

// A table laid out once is kept, like a diagram: the same message at the same width and appearance (reopening the
// conversation, switching the appearance back) draws it again without laying it out, so it costs the pass little.
static void CheckTablesKept(SPDFMacFriendsHost* host, NSAppearance* light) {
    NSString* message = [@"Here is the list:\n\n" stringByAppendingString:TallTable(@"Kept", 400)];
    [host friendsBeginMarkdownPass];
    NSTimeInterval before = host.friendsMarkdownAllowance.remaining;
    NSAttributedString* first = [host friendsRenderMarkdown:message width:300 appearance:light];
    NSTimeInterval laidOut = before - host.friendsMarkdownAllowance.remaining;
    [host friendsEndMarkdownPass];
    [host friendsBeginMarkdownPass];
    before = host.friendsMarkdownAllowance.remaining;
    NSAttributedString* again = [host friendsRenderMarkdown:message width:300 appearance:light];
    NSTimeInterval kept = before - host.friendsMarkdownAllowance.remaining;
    [host friendsEndMarkdownPass];
    Expect(HasDrawnTable(first, @"| Kept |") && HasDrawnTable(again, @"| Kept |") && kept < laidOut * 0.6,
           @"a table rendered again must come from what was kept: %.3f s laid out, %.3f s again", laidOut, kept);
}

// The suite's private reader state folder, removed however the process ends: Expect() exits at once, and a failed
// run used to leave the folder behind in the temp folder.
static NSString* gState;
static void RemoveState(void) {
    if (gState) [NSFileManager.defaultManager removeItemAtPath:gState error:nil];
}

// Offscreen renders in the Friends bubbles' colours, for checking by eye: written to `folder` when it is set. The
// render itself always runs, in a pass of its own as the views lay out a conversation, so a nil answer fails here
// rather than crashing the renders run (the earlier pass budget checks spend the main thread's allowance).
static void CheckBubbleRenders(SPDFMacFriendsHost* host, NSString* message, NSString* folder) {
    NSString* rich = [message stringByAppendingString:@"\n\n```mermaid\nflowchart LR\n"
                                                       "  A[Parcel] --> B[Depot] --> C[Courier] --> D[Mei]\n"
                                                       "```\n\n- [x] boards\n- [ ] cables"];
    for (NSAppearanceName name in @[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]) {
        BOOL night = name == NSAppearanceNameDarkAqua;
        NSAppearance* appearance = [NSAppearance appearanceNamed:name];
        [host friendsBeginMarkdownPass];
        NSAttributedString* bubble = [host friendsRenderMarkdown:rich width:300 appearance:appearance];
        [host friendsEndMarkdownPass];
        Expect(bubble.length > 0, @"the %@ bubble render came back empty", night ? @"dark" : @"light");
        if (!folder.length) continue;
        NSTextView* view = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 322, 100)];
        view.textContainerInset = NSMakeSize(11, 8);
        view.textContainer.lineFragmentPadding = 0;
        // Friends' incoming bubble (SZFriendsHostValues.m: #efeff1, #34343b).
        view.backgroundColor = night ? [NSColor colorWithSRGBRed:.204 green:.204 blue:.231 alpha:1]
                                     : [NSColor colorWithSRGBRed:.937 green:.937 blue:.945 alpha:1];
        view.appearance = appearance;
        [view.textStorage setAttributedString:bubble];
        [view.layoutManager ensureLayoutForTextContainer:view.textContainer];
        CGFloat height = ceil(NSMaxY([view.layoutManager usedRectForTextContainer:view.textContainer])) + 16;
        view.frame = NSMakeRect(0, 0, 322, height);
        for (NSNumber* scale in @[ @1, @2 ]) {
            NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                pixelsWide:(NSInteger)(322 * scale.doubleValue) pixelsHigh:(NSInteger)(height * scale.doubleValue)
                bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
                bytesPerRow:0 bitsPerPixel:0];
            rep.size = view.bounds.size;
            [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
            NSString* file = [NSString stringWithFormat:@"friends-%@-%@x.png", night ? @"dark" : @"light", scale];
            NSData* png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            Expect([png writeToFile:[folder stringByAppendingPathComponent:file] atomically:YES], @"%@ written", file);
        }
    }
}

extern NSMutableArray<NSArray*>* SPDFMacFriendsFakeLinkMenus; // SPDFMacFriendsViewFakes.mm

// A link in a drawn table opens through Friends' own link menu (SZFriendsShowLinkMenuInView) with the view, the
// cell's words and the click, never the engine's menu: the security review found table links bypassing it.
static void CheckTableLinksUseFriendsMenu(SZFriendsAppearance* theme, NSAppearance* light) {
    SPDFMacChatMarkdownOptions* options = SPDFMacFriendsMarkdownOptions(@"| Parcel |\n|---|\n| [apple.com](https://"
                                                                        "parcel.example/t/1) |", 300, light, theme, nil,
                                                                        nil);
    NSView* view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 40)];
    NSURL* url = [NSURL URLWithString:@"https://parcel.example/t/1"];
    // Without a handler the engine would pop its own menu up, which needs a window: fail here instead.
    Expect(options.linkHandler != nil, @"table links would open through the engine's menu");
    [SPDFMacFriendsFakeLinkMenus removeAllObjects];
    Expect(SPDFMacChatOpenBlockLink(url, @"apple.com", options, view, NSMakePoint(12, 9)) &&
           ([SPDFMacFriendsFakeLinkMenus isEqual:@[@[view, url, @"apple.com",
                                                    [NSValue valueWithPoint:NSMakePoint(12, 9)]]]]),
           @"a table link must open through Friends' link menu: %@", SPDFMacFriendsFakeLinkMenus);
}

static NSSet<NSString*>* Links(NSAttributedString* text) {
    NSMutableSet* links = [NSMutableSet set];
    [text enumerateAttribute:NSLinkAttributeName inRange:NSMakeRange(0, text.length) options:0
                  usingBlock:^(id value, NSRange range, BOOL* stop) {
                    (void)range, (void)stop;
                    if (value) [links addObject:[value absoluteString]];
                  }];
    return links;
}

int main(int argc, char** argv) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSString* state = SPDFMacFriendsTestTemporaryDirectory(@"markdown");
        gState = state;
        atexit(RemoveState);
        SPDFMacFriendsTestUseReaderStateDirectory(state);
        SZFriendsAppearance* theme = [SZFriendsAppearance new];
        theme.primaryTextColor = Dynamic([NSColor colorWithSRGBRed:.1 green:.2 blue:.3 alpha:1],
                                         [NSColor colorWithSRGBRed:.9 green:.8 blue:.7 alpha:1]);
        theme.secondaryTextColor = Dynamic(NSColor.grayColor, NSColor.lightGrayColor);
        theme.accentColor = Dynamic(NSColor.blueColor, NSColor.cyanColor);
        MarkdownBridge* bridge = [MarkdownBridge new];
        bridge.appearance = theme;
        SPDFMacFriendsHost* host = [[SPDFMacFriendsHost alloc] initWithBridge:bridge bundle:NSBundle.mainBundle
                                                                      formats:[NSSet setWithObject:@"md"]];
        Expect([host respondsToSelector:@selector(friendsRenderMarkdown:width:appearance:)],
               @"the host answers the views' Markdown method");

        // The key the views copy drawn blocks by is the one the renderer marks them with.
        NSString* header = argc > 1 ? [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding
                                                                   error:nil] : nil;
        NSString* declared = [NSString stringWithFormat:@"// \"%@\"", SPDFMacChatMarkdownSourceAttribute];
        Expect([header containsString:@"SZFriendsMarkdownSourceAttributeName"] && [header containsString:declared],
               @"SZFriendsHost.h declares the same copy key the renderer uses (%@)",
               SPDFMacChatMarkdownSourceAttribute);

        NSString* message = @"**Delivery** is Friday: [tracking](https://parcel.example/t/1), "
                             "[doc](spdf-ai://document?path=a.pdf), [mail](mailto:mei@example.com), "
                             "[web](http://plain.example).\n\n| Item | Qty |\n|---|---|\n| Boards | 5 |\n\n"
                             "![photo](https://tracker.example/pixel.gif?id=7)";
        NSAppearance* light = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
        NSAppearance* dark = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        NSAttributedString* text = [host friendsRenderMarkdown:message width:300 appearance:light];
        Expect([Links(text) isEqualToSet:[NSSet setWithObject:@"https://parcel.example/t/1"]],
               @"a friend's message links only to https: %@", Links(text));
        NSRange tracking = [text.string rangeOfString:@"tracking"];
        Expect([[text attribute:NSToolTipAttributeName atIndex:tracking.location effectiveRange:NULL]
                   isEqualToString:@"https://parcel.example/t/1"],
               @"a link shows where it goes before it is opened");
        NSColor* ink = [text attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL];
        Expect(fabs(ink.redComponent - .1) < .01 && fabs(ink.blueComponent - .3) < .01,
               @"text takes the bubble's light text colour, concrete");
        NSAttributedString* night = [host friendsRenderMarkdown:message width:300 appearance:dark];
        ink = [night attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL];
        Expect(fabs(ink.redComponent - .9) < .01, @"and its dark text colour in dark mode");

        // The table is one attachment marked with its Markdown; the image is a placeholder, not a fetch.
        __block NSUInteger blocks = 0, placeholders = 0;
        [text enumerateAttribute:NSAttachmentAttributeName inRange:NSMakeRange(0, text.length) options:0
                      usingBlock:^(NSTextAttachment* attachment, NSRange range, BOOL* stop) {
                        (void)stop;
                        if (!attachment) return;
                        NSString* source = [text attribute:SPDFMacChatMarkdownSourceAttribute atIndex:range.location
                                            effectiveRange:NULL];
                        if ([source hasPrefix:@"| Item | Qty |"]) blocks++;
                        if ([source hasPrefix:@"![photo]("]) placeholders++;
                        // The views size a strip by bounds, then the image, then the cell: one of them must answer.
                        NSSize size = attachment.attachmentCell.cellSize;
                        NSImage* image = [attachment imageForBounds:NSMakeRect(0, 0, size.width, size.height)
                                                      textContainer:nil characterIndex:range.location];
                        Expect(size.width > 0 && NSEqualSizes(image.size, size),
                               @"a drawn block offers its picture at its own size for a sideways strip");
                      }];
        Expect(blocks == 1 && placeholders == 1, @"the table is drawn and the image waits for Load image");
        Expect(!SPDFMacChatLoadedImage(message, [NSURL URLWithString:@"https://tracker.example/pixel.gif?id=7"]) &&
                   !SPDFMacChatImageIsLoading(message, [NSURL URLWithString:@"https://tracker.example/pixel.gif?id=7"]),
               @"rendering a friend's message never starts an image fetch");
        Expect([SPDFMacChatMarkdownCopyText(text, NSMakeRange(0, text.length)) containsString:@"| Boards | 5 |"],
               @"copying the message gives the table's Markdown");
        CheckTableLinksUseFriendsMenu(theme, light);
        CheckTablesKept(host, light);
        CheckRenderPassBudget(host, light);
        CheckBubbleRenders(host, message, NSProcessInfo.processInfo.environment[@"SPDF_CHAT_MARKDOWN_RENDERS"]);
        [NSFileManager.defaultManager removeItemAtPath:state error:nil];
        printf("SPDFMacFriendsMarkdownTests passed\n");
    }
    return 0;
}
