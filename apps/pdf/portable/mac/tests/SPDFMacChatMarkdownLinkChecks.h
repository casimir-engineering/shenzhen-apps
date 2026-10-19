// Links inside drawn tables (SPDFMacChatMarkdownLinks.mm): a click never opens by itself. It shows where the link
// goes, warning when the cell's words show another site, or it goes to the host's own link handler (Friends' menu).
#pragma once
#import "SPDFMacChatMarkdownAccessChecks.h"

static NSMenu* ChatShownMenu;
static NSUInteger ChatShownMenus;
@implementation NSMenu (ChatMarkdownTestMenus)
- (BOOL)chatMarkdownPopUp:(NSMenuItem*)item atLocation:(NSPoint)location inView:(NSView*)view {
    (void)item, (void)location, (void)view;
    ChatShownMenu = self;
    ChatShownMenus++;
    return NO;
}
@end

// Runs `body` with menus recorded instead of shown: a real pop-up menu would wait for the person.
static void ChatRecordingMenus(void (^body)(void)) {
    Method original = class_getInstanceMethod(NSMenu.class, @selector(popUpMenuPositioningItem:atLocation:inView:));
    Method recorded = class_getInstanceMethod(NSMenu.class, @selector(chatMarkdownPopUp:atLocation:inView:));
    ChatShownMenu = nil;
    ChatShownMenus = 0;
    method_exchangeImplementations(original, recorded);
    body();
    method_exchangeImplementations(original, recorded);
}

// A point over `words` in the block's drawing (y down from its top), or NSZeroPoint.
static NSPoint ChatPointOverWords(SPDFMacChatBlock* block, NSString* words) {
    NSRange range = [block.rendered.attributedString.string rangeOfString:words];
    for (CGFloat y = 1; y < NSHeight(block.contentRect); y += 1)
        for (CGFloat x = 1; x < NSWidth(block.contentRect); x += 2) {
            NSUInteger index = SPDFMacChatBlockCharacterAtPoint(block, NSMakePoint(x, y));
            if (index != NSNotFound && NSLocationInRange(index, range)) return NSMakePoint(x, y);
        }
    return NSZeroPoint;
}

// Words with a scheme become a link to themselves (an autolink inside the link), so a deceptive cell names its site
// without one.
static NSString* const ChatDeceptiveTable =
    @"| Account |\n|---|\n| [www.apple.com/account](https://appleid-verify.example.net/login) |";

// Clicks the link in a friend's table showing `message`, in a plain text view as Friends' bubbles are.
static void ChatClickTableLink(NSString* message, SPDFMacChatMarkdownOptions* options, NSString* words,
                               NSTextView* __autoreleasing* shownIn) {
    NSWindow* window = ChatWindow(NSMakeRect(0, 0, 500, 400));
    NSTextView* view = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 460, 300)];
    view.editable = NO;
    view.textContainer.lineFragmentPadding = 0;
    [window.contentView addSubview:view];
    NSAttributedString* text = SPDFMacChatMarkdownRender(message, options);
    [view.textStorage setAttributedString:text];
    NSTextAttachment* attachment = ChatAttachments(text).firstObject;
    NSPoint target = ChatPointOverWords(ChatBlockOf(attachment), words);
    Check(!NSEqualPoints(target, NSZeroPoint),
          [@"the table's link is under some point: " stringByAppendingString:words]);
    NSRect frame = ChatAttachmentFrame(view, ChatIndexOfAttachment(text, attachment));
    ChatClick(view, NSMakePoint(NSMinX(frame) + target.x, NSMinY(frame) + target.y));
    if (shownIn) *shownIn = view;
    [window close];
}

// Behaviour only (no new API), so it runs against the earlier engine too: with no handler, a click on a table link
// whose words show another site shows the engine's menu, and its first line warns.
static void RunChatTableLinkMenuChecks(void) {
    ChatFetchRecorder* recorder = [ChatFetchRecorder new];
    SPDFMacChatMarkdownOptions* options = ChatOptions(440, NO, recorder);
    options.links = SPDFMacChatMarkdownLinksFriends;
    options.openLink = nil;
    ChatRecordingMenus(^{
      ChatClickTableLink(ChatDeceptiveTable, options, @"apple.com/account", nil);
    });
    NSArray<NSMenuItem*>* items = ChatShownMenu.itemArray;
    NSMutableArray* titles = [NSMutableArray array];
    for (NSMenuItem* item in items) [titles addObject:item.title];
    Check(ChatShownMenus == 1 && items.count == 3, [@"a click on a friend's table link shows one menu of three lines: "
                                                       stringByAppendingString:titles.description]);
    Check([items[0].title isEqualToString:@"Goes to appleid-verify.example.net, not www.apple.com"] &&
              !items[0].enabled,
          [@"its first line warns where the link really goes: " stringByAppendingString:items[0].title]);
    Check([items[1].title isEqualToString:@"https://appleid-verify.example.net/login"] && !items[1].enabled,
          @"then the address, which informs and does not act");
    Check([items[2].title isEqualToString:@"Open in Browser"] && items[2].enabled &&
              [[items[2].representedObject absoluteString] isEqualToString:@"https://appleid-verify.example.net/login"],
          @"and only Open in Browser opens it, at the real address");
}

static void RunChatLinkMenuChecks(void) {
    RunChatTableLinkMenuChecks();
    NSURL* phishing = [NSURL URLWithString:@"https://appleid-verify.example.net/login"];
    NSURL* support = [NSURL URLWithString:@"https://support.apple.com/kb"];
    NSArray<NSArray*>* cases = @[
        @[ @"https://www.apple.com/account", phishing, @"www.apple.com" ], @[ @"apple.com", phishing, @"apple.com" ],
        @[ @"mei@apple.com", phishing, @"mei@apple.com" ], @[ @"(www.apple.com)", phishing, @"www.apple.com" ],
        @[ @"apple.com", support, @"" ], @[ @"www.apple.com", support, @"" ], @[ @"the plan", phishing, @"" ],
        @[ @"report.pdf", phishing, @"" ], @[ @"README.md", phishing, @"" ],
        @[ @"https://apple.com.example.net", support, @"apple.com.example.net" ],
        @[ @"https://appleid-verify.example.net/other", phishing, @"" ],
    ];
    for (NSArray* each in cases) {
        NSString* shown = SPDFMacChatLinkShownElsewhere(each[0], each[1]) ?: @"";
        Check([shown isEqualToString:each[2]], [NSString stringWithFormat:@"'%@' going to %@ shows '%@' elsewhere, "
                                                                          "not '%@'", each[0], [each[1] host], each[2],
                                                                          shown]);
    }
    NSMenu* plain = SPDFMacChatLinkMenu(support, @"apple.com");
    Check(plain.itemArray.count == 2 && [plain.itemArray.lastObject.title isEqualToString:@"Open in Browser"],
          @"a link whose words name its own site shows no warning");
    NSString* longAddress = [@"https://example.com/" stringByPaddingToLength:200 withString:@"a" startingAtIndex:0];
    NSString* title = SPDFMacChatLinkMenu([NSURL URLWithString:longAddress], @"").itemArray.firstObject.title;
    Check(title.length == 80 && [title hasPrefix:@"https://example.com/"] && [title hasSuffix:@"…"],
          @"a long address is cut in its path");

    // A host with its own menu gets the click with the cell's words, instead of the engine's menu or openLink.
    ChatFetchRecorder* recorder = [ChatFetchRecorder new];
    SPDFMacChatMarkdownOptions* options = ChatOptions(440, NO, recorder);
    options.links = SPDFMacChatMarkdownLinksFriends;
    __block NSMutableArray<NSArray*>* handled = [NSMutableArray array];
    options.linkHandler = ^(NSURL* URL, NSString* shownText, NSView* view, NSPoint point) {
      [handled addObject:@[ URL, shownText, view, [NSValue valueWithPoint:point] ]];
    };
    __block NSTextView* clicked = nil;
    ChatRecordingMenus(^{
      NSTextView* view = nil;
      ChatClickTableLink(ChatDeceptiveTable, options, @"apple.com/account", &view);
      clicked = view;
    });
    Check(ChatShownMenus == 0 && handled.count == 1, @"with a link handler the engine shows no menu of its own");
    NSArray* call = handled.firstObject;
    Check([[call[0] absoluteString] isEqualToString:@"https://appleid-verify.example.net/login"] &&
              [call[1] isEqualToString:@"www.apple.com/account"] && call[2] == clicked &&
              NSPointInRect([call[3] pointValue], clicked.bounds),
          [@"the handler gets the address, the cell's words, the view and the click: " stringByAppendingString:
              [call description]]);

    // Pressed through accessibility, the handler gets the same.
    NSWindow* window = ChatWindow(NSMakeRect(0, 0, 460, 300));
    SPDFMacChatMarkdownView* view = [[SPDFMacChatMarkdownView alloc] initWithMarkdown:ChatDeceptiveTable width:440
                                                                              options:options];
    view.translatesAutoresizingMaskIntoConstraints = YES;
    view.frame = NSMakeRect(0, 0, 440, view.contentHeight.constant);
    [window.contentView addSubview:view];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:[view bitmapImageRepForCachingDisplayInRect:view.bounds]];
    NSArray* controls = ChatAXControls(view);
    Check(controls.count == 1, @"the table's link is one button");
    ChatRecordingMenus(^{
      ChatAXPress(controls.firstObject);
    });
    Check(ChatShownMenus == 0 && handled.count == 2 && [handled[1][1] isEqualToString:@"www.apple.com/account"] &&
              handled[1][2] == view,
          @"pressing the link's button goes to the handler with its words");
    [window close];
    Check(recorder.count == 0, @"link clicks fetch nothing");
}
