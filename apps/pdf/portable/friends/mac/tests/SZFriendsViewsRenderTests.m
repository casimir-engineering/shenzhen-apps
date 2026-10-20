// Shenzhen Friends views tests: offscreen renders of every view in light and dark, at 2x (<name>-dark.png) and 1x
// (<name>-dark@1x.png), for review against the brief and the mockups; then the same views again with the tokens
// ShenzhenPDF's adapter passes, under reader/. Each render must exist and must not be blank (a page that failed to
// draw is one flat colour).

#import "SZFriendsViewsTestSupport.h"

#import "mac/SZFriendsArming.h"

#import "mac/SZFriendsConversationPage.h"
#import "mac/SZFriendsDetailsPage.h"

// Distinct colours in a sample grid: a blank or failed render has one or two.
static NSUInteger SZFColourCount(NSString *path) {
    NSBitmapImageRep *rep = (NSBitmapImageRep *)[NSBitmapImageRep imageRepWithContentsOfFile:path];
    if (![rep isKindOfClass:NSBitmapImageRep.class]) return 0;
    NSMutableSet *colours = [NSMutableSet set];
    for (NSInteger y = 0; y < rep.pixelsHigh; y += 7)
        for (NSInteger x = 0; x < rep.pixelsWide; x += 7) {
            NSUInteger pixel[4] = {0};
            [rep getPixel:pixel atX:x y:y];
            [colours addObject:@((pixel[0] << 16) | (pixel[1] << 8) | pixel[2])];
        }
    return colours.count;
}

typedef NSView *_Nonnull (^SZFViewBuilder)(SZFriendsContext *context);

// Objects a render's views belong to (a Settings section), kept alive as a host would keep them.
static NSMutableArray *SZFRenderOwners;
// The pass: default tokens, or the reader's (written under reader/).
static BOOL SZFRenderReaderTokens;

static void SZFRenderBoth(NSString *name, NSSize size, SZFViewBuilder build) {
    for (NSAppearanceName appearance in @[ NSAppearanceNameDarkAqua, NSAppearanceNameAqua ]) {
        SZFTestHost *host = [SZFTestHost new];
        host.readerTokens = SZFRenderReaderTokens;
        SZFriendsAttachableItem *item = [SZFriendsAttachableItem new];
        item.title = @"Supplier contract v3.pdf";
        item.detail = @"Open in this window · version saved today, 14:02";
        item.kindLabel = @"PDF";
        SZFriendsAttachableItem *second = [SZFriendsAttachableItem new];
        second.title = @"Supplier pricing.md";
        second.detail = @"Collection · Markdown";
        second.kindLabel = @"MD";
        host.attachableItems = @[ item, second ];
        SZFriendsContext *context = SZFTestContext(host, SZFTestReadyLink(NULL));
        NSView *view = build(context);
        NSWindow *window = SZFTestHostWindow(view, size, appearance);
        SZFTestSpin(0.02); // lets the host's async `#` items arrive
        // File previews load off the main thread; a render shows them, not their places.
        SZFExpect(SZFTestWaitForPreviews(window.contentView), @"previews loaded for %@", name);
        [window.contentView layoutSubtreeIfNeeded];
        NSString *file = [NSString stringWithFormat:@"%@%@-%@", SZFRenderReaderTokens ? @"reader/" : @"", name,
                                                    [appearance isEqualToString:NSAppearanceNameDarkAqua] ? @"dark"
                                                            : @"light"];
        NSString *path = SZFTestRender(window.contentView, file, 2);
        SZFExpect(path != nil, @"render %@ written", file);
        if (path) SZFExpect(SZFColourCount(path) > 12, @"render %@ is not blank", file);
        // 1x too: hairlines, icons and the badge must hold up without Retina's extra pixels.
        if (!SZFRenderReaderTokens)
            SZFExpect(SZFTestRender(window.contentView, [file stringByAppendingString:@"@1x"], 1) != nil,
                      @"render %@@1x written", file);
    }
}

// A context whose welcome also carries the named send-picker strings, as a helper that has them sends.
static SZFriendsContext *SZFNamedStringsContext(SZFriendsContext *context) {
    SZFTestTransport *transport = nil;
    SZFriendsHelperLink *link = SZFTestReadyLink(&transport);
    NSMutableDictionary *welcome = [SZFTestFrame(@"frames/welcome") mutableCopy];
    NSMutableDictionary *strings = [welcome[@"strings"] mutableCopy];
    if (!strings[@"drop_send_file"]) strings[@"drop_send_file"] = @"Send {name} to…";
    if (!strings[@"drop_send_file_and_more"])
        strings[@"drop_send_file_and_more"] = @"Send {name} and {count} more to…";
    welcome[@"strings"] = strings;
    [transport deliver:welcome];
    SZFriendsContext *named = SZFTestContext((SZFTestHost *)context.host, link);
    [SZFRenderOwners addObject:named];
    return named;
}

// Destructive actions as the presentation sends them: Block armed, Remove asking first; a key change to review.
static NSDictionary *SZFDetailsToReview(void) {
    NSMutableDictionary *data = [SZFTestSnapshot(@"details-mei") mutableCopy];
    NSDictionary *arm = @{@"label" : @"Block?", @"accessibility_label" : @"Click again to block Mei", @"seconds" : @4};
    data[@"verification"] = @{@"state" : @"unverified", @"label" : @"Not verified yet",
                              @"body" : @"Compare this code with the one on Mei’s screen.",
                              @"comparison_code" : @"418 270", @"action" : NSNull.null};
    data[@"key_change"] = @{@"title" : @"Mei’s key changed",
                            @"body" : @"This happens when Mei reset Friends or starts over on a new computer. Compare "
                                      @"the code below with Mei before you go on.",
                            @"actions" : @[ @{@"action" : @"accept_key_change", @"label" : @"Codes match",
                                              @"style" : @"primary"},
                                            @{@"action" : @"block", @"label" : @"Block Mei",
                                              @"style" : @"destructive", @"arm" : arm} ]};
    data[@"id_confirmed"] = @YES;
    data[@"id_confirmed_label"] = @"ID confirmed by the Friends server";
    data[@"actions"] = @[
        @{@"action" : @"remove_friend", @"label" : @"Remove friend", @"style" : @"destructive",
          @"note" : @"Keeps your conversation. Mei can send you a new request.",
          @"confirm" : @{@"title" : @"Remove Mei as a friend?",
                         @"body" : @"Mei isn’t told. Your conversation stays.",
                         @"confirm_label" : @"Remove Friend", @"cancel_label" : @"Cancel", @"destructive" : @YES}},
        @{@"action" : @"block", @"label" : @"Block Mei", @"style" : @"destructive",
          @"note" : @"Mei can’t reach you or send requests until you unblock.", @"arm" : arm},
    ];
    return data;
}

static void SZFTestExtraRenders(NSSize dropdown) {
    SZFRenderBoth(@"x-list-hover", dropdown, ^NSView *(SZFriendsContext *context) {
        // A hovered row beside the waiting rows: the hover colour, never the waiting bar or the selection.
        SZFriendsListPage *page = [[SZFriendsListPage alloc] initWithContext:context];
        [page applySnapshot:SZFTestSnapshot(@"list")];
        page.rows[3].hovered = YES;
        return page;
    });
    SZFRenderBoth(@"x-list-send-picker-named", dropdown, ^NSView *(SZFriendsContext *context) {
        SZFriendsDropdownContent *content = [[SZFriendsDropdownContent alloc]
            initWithContext:SZFNamedStringsContext(context)];
        NSMutableDictionary *data = [SZFTestSnapshot(@"list") mutableCopy];
        NSMutableArray *rows = [data[@"rows"] mutableCopy];
        NSMutableDictionary *lena = [rows[0] mutableCopy];
        if (!lena[@"drop_refusal"]) lena[@"drop_refusal"] = @"Lena isn’t your friend yet";
        rows[0] = lena;
        data[@"rows"] = rows;
        [content.listPage applySnapshot:data];
        [content beginSendPickerWithFiles:@[ @{@"path" : @"/tmp/a.pdf", @"display_name" : @"Site photos.pdf"},
                                             @{@"path" : @"/tmp/Delivery dates.md"} ]];
        content.listPage.rows[0].hovered = YES; // the refusal under the pointer
        return content;
    });
    SZFRenderBoth(@"x-details-review", NSMakeSize(400, 640), ^NSView *(SZFriendsContext *context) {
        SZFriendsDetailsPage *page = [[SZFriendsDetailsPage alloc] initWithContext:context conversationID:@"c_mei"];
        [page applySnapshot:SZFDetailsToReview()];
        return page;
    });
    SZFRenderBoth(@"x-details-block-armed", NSMakeSize(400, 640), ^NSView *(SZFriendsContext *context) {
        SZFriendsDetailsPage *page = [[SZFriendsDetailsPage alloc] initWithContext:context conversationID:@"c_mei"];
        [page applySnapshot:SZFDetailsToReview()];
        [page.actionButtons.lastObject performClick:nil];
        return page;
    });
    SZFRenderBoth(@"x-confirm-remove", dropdown, ^NSView *(SZFriendsContext *context) {
        SZFriendsDropdownContent *content = [[SZFriendsDropdownContent alloc] initWithContext:context];
        [content openDetails:@"c_mei"];
        [content.topPage applySnapshot:SZFDetailsToReview()];
        [((SZFriendsDetailsPage *)content.topPage).actionButtons.firstObject performClick:nil];
        return content;
    });
    SZFRenderBoth(@"x-request-lena-armed", dropdown, ^NSView *(SZFriendsContext *context) {
        NSMutableDictionary *data = [SZFTestSnapshot(@"conversation-request-lena") mutableCopy];
        NSMutableDictionary *request = [data[@"request"] mutableCopy];
        NSMutableArray *actions = [request[@"actions"] mutableCopy];
        NSMutableDictionary *block = [actions.lastObject mutableCopy];
        block[@"style"] = @"destructive";
        if (!block[@"arm"] || block[@"arm"] == NSNull.null)
            block[@"arm"] = @{@"label" : @"Block?", @"accessibility_label" : @"Click again to block Lena",
                              @"seconds" : @4};
        actions[actions.count - 1] = block;
        request[@"actions"] = actions;
        data[@"request"] = request;
        SZFriendsConversationPage *page = [[SZFriendsConversationPage alloc] initWithContext:context
                                                                              conversationID:@"c_lena"
                                                                            highlightMessage:nil];
        page.frame = NSMakeRect(0, 0, 400, 640);
        [page applySnapshot:data];
        [page.requestCard.actionButtons.lastObject performClick:nil];
        return page;
    });
    SZFRenderBoth(@"x-conversation-blocked", dropdown, ^NSView *(SZFriendsContext *context) {
        NSMutableDictionary *data = [SZFTestSnapshot(@"conversation-priya-queued") mutableCopy];
        NSMutableDictionary *composer = [data[@"composer"] mutableCopy];
        composer[@"enabled"] = @NO;
        composer[@"note"] = @"You blocked Priya. Unblock her in her details to send messages again.";
        data[@"composer"] = composer;
        SZFriendsConversationPage *page = [[SZFriendsConversationPage alloc] initWithContext:context
                                                                              conversationID:@"c_priya"
                                                                            highlightMessage:nil];
        page.frame = NSMakeRect(0, 0, 400, 640);
        [page applySnapshot:data];
        return page;
    });
}

static SZFriendsConversationPage *SZFConversation(SZFriendsContext *context, NSString *fixture) {
    NSDictionary *data = SZFTestSnapshot(fixture);
    SZFriendsConversationPage *page = [[SZFriendsConversationPage alloc] initWithContext:context
                                                                          conversationID:data[@"conversation_id"]
                                                                        highlightMessage:nil];
    page.frame = NSMakeRect(0, 0, 400, 640);
    [page applySnapshot:data];
    return page;
}

static void SZFTestRenderPass(void) {
    NSSize dropdown = NSMakeSize(400, 640);
    SZFTestExtraRenders(dropdown);
    SZFRenderBoth(@"list", dropdown, ^NSView *(SZFriendsContext *context) {
        SZFriendsDropdownContent *content = [[SZFriendsDropdownContent alloc] initWithContext:context];
        [content.listPage applySnapshot:SZFTestSnapshot(@"list")];
        return content;
    });
    SZFRenderBoth(@"list-reconnecting", dropdown, ^NSView *(SZFriendsContext *context) {
        // The helper stopped answering: the last snapshot stays, with the client library's line above it.
        SZFTestTransport *transport = nil;
        SZFriendsContext *waiting = SZFTestContext((SZFTestHost *)context.host, SZFTestReadyLink(&transport));
        SZFriendsDropdownContent *content = [[SZFriendsDropdownContent alloc] initWithContext:waiting];
        [content.listPage applySnapshot:SZFTestSnapshot(@"list")];
        [transport setLinkState:SZFriendsLinkStateWaiting];
        [SZFRenderOwners addObject:waiting];
        return content;
    });
    SZFRenderBoth(@"list-id-changed", dropdown, ^NSView *(SZFriendsContext *context) {
        SZFriendsListPage *page = [[SZFriendsListPage alloc] initWithContext:context];
        [page applySnapshot:SZFTestSnapshot(@"list-id-changed")];
        return page;
    });
    SZFRenderBoth(@"list-send-picker", dropdown, ^NSView *(SZFriendsContext *context) {
        SZFriendsDropdownContent *content = [[SZFriendsDropdownContent alloc] initWithContext:context];
        [content.listPage applySnapshot:SZFTestSnapshot(@"list")];
        [content beginSendPickerWithFiles:@[ @{@"path" : @"/tmp/a.pdf"}, @{@"path" : @"/tmp/b.pdf"} ]];
        return content;
    });
    SZFRenderBoth(@"list-drop-hint", dropdown, ^NSView *(SZFriendsContext *context) {
        SZFriendsListPage *page = [[SZFriendsListPage alloc] initWithContext:context];
        [page applySnapshot:SZFTestSnapshot(@"list")];
        [page setDropHint:[context string:@"drop_hint"]];
        return page;
    });
    SZFRenderBoth(@"nearby-visible", dropdown, ^NSView *(SZFriendsContext *context) {
        SZFriendsListPage *page = [[SZFriendsListPage alloc] initWithContext:context];
        [page showNearby:YES];
        [page applyNearbySnapshot:SZFTestSnapshot(@"nearby-visible-bluetooth-off")];
        return page;
    });
    SZFRenderBoth(@"nearby-denied", dropdown, ^NSView *(SZFriendsContext *context) {
        SZFriendsListPage *page = [[SZFriendsListPage alloc] initWithContext:context];
        [page showNearby:YES];
        [page applyNearbySnapshot:SZFTestSnapshot(@"nearby-local-network-denied")];
        return page;
    });
    SZFRenderBoth(@"conversation-mei", dropdown, ^NSView *(SZFriendsContext *context) {
        return SZFConversation(context, @"conversation-mei");
    });
    SZFRenderBoth(@"conversation-kenji-offer", dropdown, ^NSView *(SZFriendsContext *context) {
        return SZFConversation(context, @"conversation-kenji-offer");
    });
    SZFRenderBoth(@"conversation-priya-queued", dropdown, ^NSView *(SZFriendsContext *context) {
        return SZFConversation(context, @"conversation-priya-queued");
    });
    SZFRenderBoth(@"conversation-attach-picker", dropdown, ^NSView *(SZFriendsContext *context) {
        SZFriendsConversationPage *page = SZFConversation(context, @"conversation-mei");
        [page.composer.textView insertText:@"Yes, this one has your comments " replacementRange:NSMakeRange(0, 0)];
        [page openAttachPicker];
        return page;
    });
    SZFRenderBoth(@"conversation-chips", dropdown, ^NSView *(SZFriendsContext *context) {
        SZFriendsConversationPage *page = SZFConversation(context, @"conversation-mei");
        [page.composer.textView insertText:@"On it. I'll send my notes tonight." replacementRange:NSMakeRange(0, 0)];
        [page.composer addAttachments:@[ context.host ? ((SZFTestHost *)context.host).attachableItems[0]
                                                      : [SZFriendsAttachableItem new] ]];
        return page;
    });
    SZFRenderBoth(@"request-lena", dropdown, ^NSView *(SZFriendsContext *context) {
        return SZFConversation(context, @"conversation-request-lena");
    });
    SZFRenderBoth(@"details-mei", NSMakeSize(400, 560), ^NSView *(SZFriendsContext *context) {
        SZFriendsDetailsPage *page = [[SZFriendsDetailsPage alloc] initWithContext:context conversationID:@"c_mei"];
        [page applySnapshot:SZFTestSnapshot(@"details-mei")];
        return page;
    });
    SZFRenderBoth(@"profile", dropdown, ^NSView *(SZFriendsContext *context) {
        SZFriendsProfilePage *page = [[SZFriendsProfilePage alloc] initWithContext:context];
        [page applySnapshot:SZFTestSnapshot(@"profile-unreserved")];
        return page;
    });
    SZFRenderBoth(@"profile-animals", dropdown, ^NSView *(SZFriendsContext *context) {
        SZFriendsProfilePage *page = [[SZFriendsProfilePage alloc] initWithContext:context];
        [page applySnapshot:SZFTestSnapshot(@"profile-unreserved")];
        [page toggleAnimals];
        return page;
    });
    SZFRenderBoth(@"confirm", dropdown, ^NSView *(SZFriendsContext *context) {
        SZFriendsDropdownContent *content = [[SZFriendsDropdownContent alloc] initWithContext:context];
        [content.listPage applySnapshot:SZFTestSnapshot(@"list")];
        context.presentConfirmation(SZFTestSnapshot(@"settings")[@"reset"][@"confirm"], ^(BOOL ticked) { (void)ticked; });
        return content;
    });
    // Remove from a row's menu: the question with "Also delete chat history", unticked.
    SZFRenderBoth(@"confirm-remove", dropdown, ^NSView *(SZFriendsContext *context) {
        SZFriendsDropdownContent *content = [[SZFriendsDropdownContent alloc] initWithContext:context];
        [content.listPage applySnapshot:SZFTestSnapshot(@"list")];
        context.presentConfirmation(SZFTestRemoveConfirm(@"Mei", YES), ^(BOOL ticked) { (void)ticked; });
        return content;
    });
    SZFRenderBoth(@"settings", NSMakeSize(560, 560), ^NSView *(SZFriendsContext *context) {
        SZFriendsSettingsSection *section = [[SZFriendsSettingsSection alloc] initWithHost:context.host
                                                                                       link:context.link];
        [section applySnapshot:SZFTestSnapshot(@"settings")];
        [section.buttons[2] performClick:nil];
        [SZFRenderOwners addObject:section];
        SZFriendsFlippedView *pane = [[SZFriendsFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 560, 560)];
        pane.fillColor = context.appearance.backgroundColor;
        section.view.frame = NSMakeRect(24, 20, 512, 520);
        [pane addSubview:section.view];
        return pane;
    });
    SZFRenderBoth(@"title-button", NSMakeSize(120, 40), ^NSView *(SZFriendsContext *context) {
        SZFriendsFlippedView *bar = [[SZFriendsFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 120, 40)];
        bar.fillColor = SZFriendsDynamicColor(0xe8e8eb, 0x202125);
        SZFriendsTitleButton *plain = [[SZFriendsTitleButton alloc] initWithContext:context];
        plain.frame = NSMakeRect(16, 6, 28, 28);
        SZFriendsTitleButton *badged = [[SZFriendsTitleButton alloc] initWithContext:context];
        badged.frame = NSMakeRect(60, 6, 28, 28);
        badged.badgeLabel = @"2";
        badged.selectedLook = YES;
        [bar addSubview:plain];
        [bar addSubview:badged];
        return bar;
    });
}

void SZFTestRenders(void) {
    SZFRenderOwners = [NSMutableArray array];
    SZFRenderReaderTokens = NO;
    SZFTestRenderPass();
    // The same views with the tokens the reader's host adapter actually passes.
    [NSFileManager.defaultManager createDirectoryAtPath:[SZFTestRendersDir stringByAppendingPathComponent:@"reader"]
                            withIntermediateDirectories:YES attributes:nil error:nil];
    SZFRenderReaderTokens = YES;
    SZFTestRenderPass();
    SZFRenderReaderTokens = NO;
}
