// Controls drawn inside a block (Copy on code, links in a table) as an assistive app reaches them: through the text
// view's accessibility children, with a button role, a label and a press action, like Load image.
#pragma once
#import "SPDFMacChatMarkdownFixtures.h"

// The text view hands an attachment's cell out wrapped in a reparenting proxy, which answers only the attribute API:
// the same calls VoiceOver makes through AXUIElement. That API is deprecated for implementing elements, not for
// reading them, so these checks use it on purpose.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static id ChatAX(id element, NSString* attribute) { return [element accessibilityAttributeValue:attribute]; }

// Every accessibility child of the message's attachments, in order: each block's controls.
static NSArray* ChatAXControls(NSView* view) {
    NSMutableArray* controls = [NSMutableArray array];
    for (id attachment in view.accessibilityChildren)
        for (id control in ChatAX(attachment, NSAccessibilityChildrenAttribute)) [controls addObject:control];
    return controls;
}

static void ChatAXPress(id control) { [control accessibilityPerformAction:NSAccessibilityPressAction]; }
static NSArray* ChatAXActions(id control) { return [control accessibilityActionNames]; }

static NSRect ChatAXFrame(id element) {
    NSPoint position = [ChatAX(element, NSAccessibilityPositionAttribute) pointValue];
    NSSize size = [ChatAX(element, NSAccessibilitySizeAttribute) sizeValue];
    return NSMakeRect(position.x, position.y, size.width, size.height);
}
#pragma clang diagnostic pop

static void RunChatAccessibilityChecks(void) {
    ChatFetchRecorder* recorder = [ChatFetchRecorder new];
    NSWindow* window = ChatWindow(NSMakeRect(0, 0, 460, 600));
    NSPasteboard* pasteboard = [NSPasteboard pasteboardWithUniqueName];
    __block NSMutableArray<NSURL*>* opened = [NSMutableArray array];
    SPDFMacChatMarkdownOptions* options = ChatOptions(0, NO, recorder);
    options.pasteboard = pasteboard;
    options.openLink = ^(NSURL* URL) { [opened addObject:URL]; };
    NSString* message = @"Steps:\n\n```c\nint volts = 5;\n```\n\n| Source | Notes |\n|---|---|\n"
                         "| [page 2](spdf-ai://document?path=a.pdf&page=2) | [the schematic](https://example.com/s) |";
    SPDFMacChatMarkdownView* view = [[SPDFMacChatMarkdownView alloc] initWithMarkdown:message width:440
                                                                              options:options];
    view.translatesAutoresizingMaskIntoConstraints = YES;
    view.frame = NSMakeRect(0, 0, 440, view.contentHeight.constant);
    [window.contentView addSubview:view];
    // Drawn once, as on screen: a control's frame is where its block was last drawn.
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:[view bitmapImageRepForCachingDisplayInRect:view.bounds]];

    NSArray* controls = ChatAXControls(view);
    Check(controls.count == 3, [NSString stringWithFormat:@"Copy and the table's two links are reachable (%lu)",
                                                          (unsigned long)controls.count]);
    NSMutableArray<NSString*>* labels = [NSMutableArray array];
    for (id control in controls) {
        Check([ChatAX(control, NSAccessibilityRoleAttribute) isEqual:NSAccessibilityButtonRole],
              @"a drawn control is a button");
        Check([ChatAXActions(control) containsObject:NSAccessibilityPressAction],
              @"a drawn control can be pressed");
        [labels addObject:ChatAX(control, NSAccessibilityDescriptionAttribute) ?: @""];
    }
    Check([labels[0] isEqualToString:@"Copy code"],
          [@"the code block's control says Copy code: " stringByAppendingString:labels[0]]);
    Check([labels[1] isEqualToString:@"page 2, opens the cited document"],
          [@"a citation says its text and what it opens: " stringByAppendingString:labels[1]]);
    Check([labels[2] isEqualToString:@"the schematic, https://example.com/s"],
          [@"a web link says its text and its address: " stringByAppendingString:labels[2]]);
    // Each control sits where it is drawn: inside the message, Copy at the code block's right edge above the table.
    NSRect screen = [window convertRectToScreen:[view convertRect:view.bounds toView:nil]];
    for (id control in controls) {
        NSRect frame = ChatAXFrame(control);
        Check(NSWidth(frame) > 4 && NSHeight(frame) > 4 && NSMinX(frame) >= NSMinX(screen) &&
                  NSMaxX(frame) <= NSMaxX(screen) + .5,
              @"a control is placed inside its message, at the size it is drawn");
    }
    NSRect copy = ChatAXFrame(controls[0]), link = ChatAXFrame(controls[1]);
    // In this process the attribute API answers in screen coordinates, y up; the system flips them for other apps.
    Check(NSMinX(copy) > NSMidX(screen) && NSMinY(copy) > NSMaxY(link) && NSWidth(copy) == 54,
          [NSString stringWithFormat:@"Copy is where it is drawn: the top right of the code block, above the table "
                                     "(%@, %@)", NSStringFromRect(copy), NSStringFromRect(link)]);

    // Pressing does what clicking does: Copy writes the code to the message's pasteboard, a link opens through the
    // chat's own link handling with its exact address.
    ChatAXPress(controls[0]);
    Check([[pasteboard stringForType:NSPasteboardTypeString] isEqualToString:@"int volts = 5;"],
          @"pressing Copy code puts the code on the pasteboard");
    ChatAXPress(controls[1]);
    ChatAXPress(controls[2]);
    Check(opened.count == 2 && [opened[0].absoluteString isEqualToString:@"spdf-ai://document?path=a.pdf&page=2"] &&
              [opened[1].absoluteString isEqualToString:@"https://example.com/s"],
          [@"pressing a link opens its exact address: " stringByAppendingString:opened.description]);
    // A Friends message keeps https only, so a citation-looking link is never offered there.
    options.links = SPDFMacChatMarkdownLinksFriends;
    SPDFMacChatMarkdownView* friends = [[SPDFMacChatMarkdownView alloc] initWithMarkdown:message width:440
                                                                                options:options];
    friends.translatesAutoresizingMaskIntoConstraints = YES;
    friends.frame = NSMakeRect(0, 0, 440, friends.contentHeight.constant);
    [window.contentView addSubview:friends];
    NSUInteger links = 0;
    for (id control in ChatAXControls(friends))
        if ([ChatAX(control, NSAccessibilityDescriptionAttribute) containsString:@"https://"]) links++;
    Check(ChatAXControls(friends).count == 2 && links == 1, @"a friend's message offers Copy and its https link only");
    Check(recorder.count == 0, @"accessibility fetches nothing");
    [pasteboard releaseGlobally];
    [window close];
}
