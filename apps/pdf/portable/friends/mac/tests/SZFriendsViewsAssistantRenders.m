// Shenzhen Friends views tests: offscreen renders of Markdown bubbles (headings, lists, code, a table, math, a
// diagram), "Via the assistant" with a queued send's Cancel, and the `/` states (the command with the host's note,
// running, a draft, a proposal waiting, sending, failed, long), in light and dark at 2x (<name>-dark.png) and 1x
// (<name>-dark@1x.png), under assistant/. The Markdown is drawn by the test host's stand-in
// renderer (SZFriendsViewsTestMarkdown.m): these show how bubbles lay out what a host returns, not the app's engine.

#import "SZFriendsViewsTestSupport.h"

#import "mac/SZFriendsComposerInternal.h"
#import "mac/SZFriendsItemViewsInternal.h"

typedef NSView *_Nonnull (^SZFAssistantViewBuilder)(SZFriendsContext *context, SZFTestAssistantHost *host);

static NSMutableArray *SZFAssistantRenderOwners;

static NSUInteger SZFDistinctColours(NSString *path) {
    NSBitmapImageRep *rep = (NSBitmapImageRep *)[NSBitmapImageRep imageRepWithContentsOfFile:path];
    if (![rep isKindOfClass:NSBitmapImageRep.class]) return 0;
    NSMutableSet *colours = [NSMutableSet set];
    for (NSInteger y = 0; y < rep.pixelsHigh; y += 5)
        for (NSInteger x = 0; x < rep.pixelsWide; x += 5) {
            NSUInteger pixel[4] = {0};
            [rep getPixel:pixel atX:x y:y];
            [colours addObject:@((pixel[0] << 16) | (pixel[1] << 8) | pixel[2])];
        }
    return colours.count;
}

static void SZFRenderAssistant(NSString *name, NSSize size, SZFAssistantViewBuilder build) {
    for (NSAppearanceName appearance in @[ NSAppearanceNameDarkAqua, NSAppearanceNameAqua ]) {
        SZFTestAssistantHost *host = [SZFTestAssistantHost new];
        host.assistant = [SZFTestAssistant new];
        SZFriendsContext *context = SZFTestContext(host, SZFTestReadyLink(NULL));
        [SZFAssistantRenderOwners addObjectsFromArray:@[ host, context ]];
        NSView *view = build(context, host);
        NSWindow *window = SZFTestHostWindow(view, size, appearance);
        [window.contentView layoutSubtreeIfNeeded];
        NSString *file = [NSString stringWithFormat:@"assistant/%@-%@", name,
                                                    [appearance isEqualToString:NSAppearanceNameDarkAqua] ? @"dark"
                                                                                                          : @"light"];
        NSString *path = SZFTestRender(window.contentView, file, 2);
        SZFExpect(path != nil && SZFDistinctColours(path) > 12, @"render %@ written and not blank", file);
        SZFExpect(SZFTestRender(window.contentView, [file stringByAppendingString:@"@1x"], 1) != nil,
                  @"render %@@1x written", file);
    }
}

static NSDictionary *SZFItem(NSString *itemID, NSString *direction, NSString *text, NSDictionary *extra) {
    NSMutableDictionary *item = [@{@"kind" : @"message", @"item_id" : itemID, @"direction" : direction,
                                   @"text" : text, @"text_format" : @"markdown", @"segments" : @[ @{@"text" : text} ],
                                   @"time_label" : NSNull.null, @"status" : NSNull.null, @"actions" : @[],
                                   @"assistant_label" : NSNull.null, @"highlighted" : @NO,
                                   @"accessibility_label" : text} mutableCopy];
    [item addEntriesFromDictionary:extra ?: @{}];
    return item;
}

static SZFriendsConversationPage *SZFConversationWith(SZFriendsContext *context, NSArray *items, CGFloat height) {
    NSMutableDictionary *data = [SZFTestSnapshot(@"conversation-mei") mutableCopy];
    data[@"items"] = items;
    data[@"has_earlier"] = @NO;
    SZFriendsConversationPage *page = [[SZFriendsConversationPage alloc] initWithContext:context
                                                                          conversationID:@"c_mei"
                                                                        highlightMessage:nil];
    page.frame = NSMakeRect(0, 0, 400, height);
    [page applySnapshot:data];
    return page;
}

static NSArray *SZFTextItems(void) {
    return @[
        @{@"kind" : @"day", @"item_id" : @"d_1", @"label" : @"Today", @"highlighted" : @NO,
          @"accessibility_label" : @"Today"},
        SZFItem(@"m_1", @"in", @"# Site visit\n## Thursday\n### Before we go\n- Bring the **bracket** drawing\n"
                               @"- Check pages *3–5*\n1. Measure the opening\n2. Photograph the anchors",
                @{@"time_label" : @"09:20"}),
        SZFItem(@"m_2", @"out", @"Here is the check I ran:\n```python\nfor page in range(3, 6):\n"
                                @"    print(page, check_dimensions(page, tolerance_mm=0.5, report=True))\n```",
                @{@"time_label" : @"09:24", @"status" : @{@"state" : @"delivered", @"label" : @"Delivered"}}),
    ];
}

static NSArray *SZFTableItems(void) {
    return @[
        SZFItem(@"m_3", @"in", @"| Item | Supplier | Delivery date | Status |\n|---|---|---|---|\n"
                               @"| Brackets | Mei Lin Fabrication | Friday 16 October | Confirmed |\n"
                               @"| Panels | Kenji Works | Monday 19 October | Waiting |",
                @{@"time_label" : @"10:02"}),
        SZFItem(@"m_4", @"out", @"The load is $F = m \\cdot a$, so $E=mc^2$ does not apply. Details in "
                                @"[the plan](https://example.com/plan).",
                @{@"time_label" : @"10:05", @"status" : @{@"state" : @"delivered", @"label" : @"Delivered"}}),
    ];
}

static NSArray *SZFAssistantItems(void) {
    NSDictionary *cancel = @{@"action" : @"cancel_message", @"label" : @"Cancel", @"style" : @"link"};
    NSMutableDictionary *transfer = [[SZFTestSnapshot(@"conversation-priya-queued")[@"items"] lastObject] mutableCopy];
    transfer[@"assistant_label"] = @"Via the assistant";
    return @[
        SZFItem(@"m_5", @"in", @"```mermaid\nflowchart LR\nDraft --> Review --> Send\n```",
                @{@"time_label" : @"11:40", @"assistant_label" : @"Via Mei’s assistant"}),
        SZFItem(@"m_6", @"out", @"**Summary of pages 3–5:** the bracket moves 12 mm left; the anchors stay.",
                @{@"time_label" : @"11:42", @"assistant_label" : @"Via the assistant",
                  @"status" : @{@"state" : @"queued", @"label" : @"Sends when Mei is nearby"},
                  @"actions" : @[ cancel ]}),
        transfer,
    ];
}

static SZFriendsConversationPage *SZFCommandPage(SZFriendsContext *context) {
    SZFriendsConversationPage *page = SZFConversationWith(context, SZFTextItems(), 640);
    [page.composer.textView insertText:@"/" replacementRange:NSMakeRange(NSNotFound, 0)];
    return page;
}

// A page whose command proposed `text` with the contract chip; the proposal is the last of the render owners.
static SZFriendsConversationPage *SZFProposalPage(SZFriendsContext *context, SZFTestAssistantHost *host,
                                                  NSString *text) {
    SZFriendsConversationPage *page = SZFCommandPage(context);
    SZFriendsAttachableItem *contract = [SZFriendsAttachableItem new];
    contract.title = @"Supplier contract v3.pdf";
    contract.kindLabel = @"PDF";
    contract.fileURL = [NSURL fileURLWithPath:@"/tmp/Supplier contract v3.pdf"];
    [page.composer addAttachments:@[ contract ]];
    [page.composer.textView insertText:@"send Mei a summary of pages 3–5"
                      replacementRange:NSMakeRange(NSNotFound, 0)];
    [page.composer.command run];
    SZFTestProposal *proposal = SZFTestProposalWithText(text, @[ contract ]);
    host.assistant.completion(proposal.result, nil);
    [SZFAssistantRenderOwners addObject:proposal];
    return page;
}

static NSString *const SZFProposalText = @"**Pages 3–5:** the bracket moves 12 mm left; the anchors stay.\n"
                                         @"<!-- totals: 48,200 -->\u200B\u200B See [the plan][p].\n\n"
                                         @"[p]: https://example.com/plan \"Plan v3\"";

void SZFTestAssistantRenders(void) {
    SZFAssistantRenderOwners = [NSMutableArray array];
    [NSFileManager.defaultManager createDirectoryAtPath:[SZFTestRendersDir stringByAppendingPathComponent:@"assistant"]
                            withIntermediateDirectories:YES attributes:nil error:nil];
    SZFRenderAssistant(@"md-text", NSMakeSize(400, 640), ^NSView *(SZFriendsContext *context, SZFTestAssistantHost *h) {
        (void)h;
        return SZFConversationWith(context, SZFTextItems(), 640);
    });
    SZFRenderAssistant(@"md-table-math", NSMakeSize(400, 640), ^NSView *(SZFriendsContext *context,
                                                                          SZFTestAssistantHost *h) {
        (void)h;
        return SZFConversationWith(context, SZFTableItems(), 640);
    });
    SZFRenderAssistant(@"md-table-scrolled", NSMakeSize(400, 640), ^NSView *(SZFriendsContext *context,
                                                                              SZFTestAssistantHost *h) {
        (void)h;
        SZFriendsConversationPage *page = SZFConversationWith(context, SZFTableItems(), 640);
        [page layoutSubtreeIfNeeded];
        SZFriendsMessageItemView *table = (SZFriendsMessageItemView *)page.itemViews.firstObject;
        [table layoutSubtreeIfNeeded];
        NSScrollView *strip = table.body.wideBlocks.firstObject;
        [strip.contentView scrollToPoint:NSMakePoint(NSWidth(strip.documentView.frame) - NSWidth(strip.frame), 0)];
        [strip reflectScrolledClipView:strip.contentView];
        return page;
    });
    SZFRenderAssistant(@"md-diagram-label", NSMakeSize(400, 640), ^NSView *(SZFriendsContext *context,
                                                                             SZFTestAssistantHost *h) {
        (void)h;
        return SZFConversationWith(context, SZFAssistantItems(), 640);
    });
    SZFRenderAssistant(@"slash-empty", NSMakeSize(400, 640), ^NSView *(SZFriendsContext *context,
                                                                        SZFTestAssistantHost *h) {
        (void)h;
        return SZFCommandPage(context);
    });
    SZFRenderAssistant(@"slash-command", NSMakeSize(400, 640), ^NSView *(SZFriendsContext *context,
                                                                          SZFTestAssistantHost *h) {
        (void)h;
        SZFriendsConversationPage *page = SZFCommandPage(context);
        SZFriendsAttachableItem *contract = [SZFriendsAttachableItem new];
        contract.title = @"Supplier contract v3.pdf";
        contract.kindLabel = @"PDF";
        [page.composer addAttachments:@[ contract ]];
        [page.composer.textView insertText:@"summarize pages 3–5 of the contract and send it to Mei"
                          replacementRange:NSMakeRange(NSNotFound, 0)];
        return page;
    });
    SZFRenderAssistant(@"slash-running", NSMakeSize(400, 640), ^NSView *(SZFriendsContext *context,
                                                                          SZFTestAssistantHost *h) {
        SZFriendsConversationPage *page = SZFCommandPage(context);
        [page.composer.textView insertText:@"summarize pages 3–5" replacementRange:NSMakeRange(NSNotFound, 0)];
        [page.composer.command run];
        h.assistant.progress(@"Reading pages 3–5 of Supplier contract v3.pdf…");
        return page;
    });
    SZFRenderAssistant(@"slash-draft", NSMakeSize(400, 640), ^NSView *(SZFriendsContext *context,
                                                                        SZFTestAssistantHost *h) {
        SZFriendsConversationPage *page = SZFCommandPage(context);
        [page.composer.textView insertText:@"draft a reply" replacementRange:NSMakeRange(NSNotFound, 0)];
        [page.composer.command run];
        SZFriendsAssistantResult *draft = [SZFriendsAssistantResult new];
        draft.text = @"Thanks Mei. Pages 3–5 look right; one question on the bracket position before Friday.";
        draft.note = @"Not sent yet. Check it, then press Send.";
        h.assistant.completion(draft, nil);
        return page;
    });
    SZFRenderAssistant(@"slash-proposal", NSMakeSize(400, 640), ^NSView *(SZFriendsContext *context,
                                                                           SZFTestAssistantHost *h) {
        return SZFProposalPage(context, h, SZFProposalText);
    });
    SZFRenderAssistant(@"slash-proposal-sending", NSMakeSize(400, 640), ^NSView *(SZFriendsContext *context,
                                                                                   SZFTestAssistantHost *h) {
        SZFriendsConversationPage *page = SZFProposalPage(context, h, SZFProposalText);
        [page.composer.command sendProposal];
        return page;
    });
    SZFRenderAssistant(@"slash-proposal-failed", NSMakeSize(400, 640), ^NSView *(SZFriendsContext *context,
                                                                                  SZFTestAssistantHost *h) {
        SZFriendsConversationPage *page = SZFProposalPage(context, h, SZFProposalText);
        [page.composer.command sendProposal];
        SZFTestProposal *proposal = SZFAssistantRenderOwners.lastObject;
        SZFTestAnswerProposal(proposal, [NSError errorWithDomain:@"test" code:1 userInfo:@{
            NSLocalizedDescriptionKey : @"Friends isn’t running. Open the Friends menu, then try again."}]);
        return page;
    });
    SZFRenderAssistant(@"slash-proposal-long", NSMakeSize(400, 640), ^NSView *(SZFriendsContext *context,
                                                                                SZFTestAssistantHost *h) {
        NSMutableString *letter = [NSMutableString string];
        for (int line = 1; line <= 24; line++) [letter appendFormat:@"%d. Item %d of the snag list, checked on site.\n",
                                                                    line, line];
        return SZFProposalPage(context, h, letter);
    });
}
