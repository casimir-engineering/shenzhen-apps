// The card the person approves, as the AI chat draws it (SPDFMacAIChatActivityView.h): a friend's planted
// instruction has the model hide document text in Markdown, through the real session and tool layer, and the row
// drawn from the resulting entry shows every character Friends will deliver as plain wrapping text, at the dock's
// narrowest width and its usual one. What Send then queues is that same text. Headless: no helper, no network.

#import <AppKit/AppKit.h>
#import "SPDFMacAIChatActivityView.h"
#import "SPDFMacFriendsSendRig.h"

static NSView* Find(NSView* root, NSString* identifier) {
    if ([root.identifier isEqual:identifier]) return root;
    for (NSView* child in root.subviews) {
        NSView* found = Find(child, identifier);
        if (found) return found;
    }
    return nil;
}

static void Settle(NSView* view) {
    for (int round = 0; round < 3; round++) {
        [view layoutSubtreeIfNeeded];
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
    }
    [view layoutSubtreeIfNeeded];
}

// Every character of `delivered` is in the body as the person sees it: the whole string, laid out in full, wrapping
// inside the card, nothing drawn in its place (no link, no attachment), nothing scrolled sideways or clipped.
static void CheckCardShowsEveryCharacter(NSDictionary* card, NSArray* actions, NSString* delivered, CGFloat width) {
    NSString* at = [NSString stringWithFormat:@"(%.0f pt)", width];
    SPDFMacAIChatActivityRow* row = [[SPDFMacAIChatActivityRow alloc] initWithUnit:@{@"entry" : card,
        @"actions" : actions} expanded:[NSSet set] width:width];
    NSView* host = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, 4000)];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:row];
    [NSLayoutConstraint activateConstraints:@[[row.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [row.topAnchor constraintEqualToAnchor:host.topAnchor], [row.widthAnchor constraintEqualToConstant:width]]];
    Settle(host);
    NSTextView* body = (NSTextView*)Find(row, [@"activityBody:" stringByAppendingString:card[SPDFMacAIActivityIDKey]]);
    Expect([body isKindOfClass:NSTextView.class] && [body.string isEqual:delivered],
           @"%@ the card's text must be exactly what Friends delivers:\n%@", at, body.string);
    __block BOOL drawnAway = NO;
    [body.textStorage enumerateAttributesInRange:NSMakeRange(0, body.textStorage.length) options:0
                                      usingBlock:^(NSDictionary* attributes, NSRange range, BOOL* stop) {
        (void)range; (void)stop;
        if (attributes[NSLinkAttributeName] || attributes[NSAttachmentAttributeName]) drawnAway = YES;
    }];
    Expect(!drawnAway, @"%@ a part of the text is drawn as a link or a picture instead of its characters", at);
    NSScrollView* scroll = body.enclosingScrollView;
    Expect(!scroll || !scroll.hasHorizontalScroller, @"%@ the text must wrap, not scroll sideways", at);
    [body.layoutManager ensureLayoutForTextContainer:body.textContainer];
    NSRange glyphs = [body.layoutManager glyphRangeForTextContainer:body.textContainer];
    NSRange laid = [body.layoutManager characterRangeForGlyphRange:glyphs actualGlyphRange:NULL];
    NSRect used = [body.layoutManager usedRectForTextContainer:body.textContainer];
    NSRect inRow = [body convertRect:body.bounds toView:row];
    Expect(laid.length == delivered.length && NSWidth(used) <= NSWidth(body.bounds) + 1 &&
           NSHeight(used) <= NSHeight(body.bounds) + 1 && !body.hiddenOrHasHiddenAncestor && body.alphaValue > 0 &&
           NSMinX(inRow) >= -0.5 && NSMaxX(inRow) <= width + 0.5 && NSMaxY(inRow) <= NSHeight(row.bounds) + 0.5,
           @"%@ every line must be laid out and inside the card: %lu of %lu characters, %@ used in %@", at,
           (unsigned long)laid.length, (unsigned long)delivered.length, NSStringFromRect(used),
           NSStringFromRect(body.bounds));
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSString* state = SPDFMacFriendsTestTemporaryDirectory(@"send-card");
        SPDFMacFriendsTestUseReaderStateDirectory(state);
        SendRig* rig = [[SendRig alloc] initWithSender:[FakeSender new]];
        NSDictionary* card = CardAfterInjection(rig, kHiddenConstructsMessage);
        NSArray* actions = [rig.session liveActivityActionsForEntry:card[SPDFMacAIActivityIDKey]];
        Expect(card && [[actions valueForKey:@"id"] isEqual:(@[@"send", @"discard"])] &&
               ![rig.sender intentsOfType:@"send_message"].count, @"the message must wait on a card: %@", card);
        for (NSNumber* width in @[@320, @400])
            CheckCardShowsEveryCharacter(card, actions, kHiddenConstructsMessage, width.doubleValue);
        [rig.session performActivityAction:@"send" forEntry:card[SPDFMacAIActivityIDKey]];
        NSDictionary* fields = [rig.sender intentsOfType:@"send_message"].firstObject[@"fields"];
        Expect([fields[@"text"] isEqual:kHiddenConstructsMessage], @"Send must queue what the card showed: %@",
               fields[@"text"]);
        [NSFileManager.defaultManager removeItemAtPath:state error:nil];
    }
    puts("SPDFMacFriendsSendCardTests passed");
    return 0;
}
