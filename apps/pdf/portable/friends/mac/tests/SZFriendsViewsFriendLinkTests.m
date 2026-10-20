// Shenzhen Friends views tests: links (PROTOCOL.md § Links). The link page asks the helper and acts only on the
// card's own buttons; the profile's "Your links" copies, resets and revokes through the actions it was given; the drop
// panel offers "Copy link instead" for one file when the host copies links; Copy Download Link puts the helper's URL
// on the pasteboard; and the two views render in light and dark.

#import "SZFriendsViewsTestSupport.h"

#import "mac/SZFriendsDetailsPage.h"
#import "mac/SZFriendsLinkPage.h"

// A host that copies download links (SZFriendsHost.h, Download links) and records each offer.
@interface SZFLinkHost : SZFTestHost
@property(nonatomic, strong) NSMutableArray<SZFriendsAttachableItem *> *offers;
@end

@implementation SZFLinkHost
- (NSString *)friendsCopyLinkInsteadLabel {
    return @"Copy link instead";
}
- (void)friendsOfferDownloadLinkForItem:(SZFriendsAttachableItem *)item fromView:(NSView *)view {
    SZFExpect(view.window != nil, @"the expiry choice shows from a button still on screen");
    if (!self.offers) self.offers = [NSMutableArray array];
    [self.offers addObject:item];
}
@end

// A Ready link whose welcome announces `links`, unless `links` is NO (a helper from before links).
static SZFriendsHelperLink *SZFLinksLink(SZFTestTransport **transportOut, BOOL links) {
    SZFTestTransport *transport = nil;
    SZFriendsHelperLink *link = SZFTestReadyLink(&transport);
    NSMutableDictionary *welcome = [SZFTestFrame(@"frames/welcome") mutableCopy];
    if (links) welcome[@"capabilities"] = [welcome[@"capabilities"] arrayByAddingObject:@"links"];
    [transport deliver:welcome];
    *transportOut = transport;
    return link;
}

static NSDictionary *SZFLastOfType(SZFTestTransport *transport, NSString *type) {
    for (NSDictionary *frame in transport.sent.reverseObjectEnumerator)
        if ([frame[@"type"] isEqualToString:type]) return frame;
    return nil;
}

static NSUInteger SZFCountOfType(SZFTestTransport *transport, NSString *type) {
    NSUInteger count = 0;
    for (NSDictionary *frame in transport.sent) count += [frame[@"type"] isEqualToString:type];
    return count;
}

static void SZFAnswer(SZFTestTransport *transport, NSDictionary *intent, NSString *fixture) {
    NSMutableDictionary *reply = [SZFTestFrame(fixture) mutableCopy];
    reply[@"re"] = intent[@"id"] ?: @"";
    [transport deliver:reply];
}

static SZFriendsAttachableItem *SZFLinkItem(NSString *name) {
    SZFriendsAttachableItem *item = [SZFriendsAttachableItem new];
    item.title = name;
    item.kindLabel = @"PDF";
    item.fileURL = [NSURL fileURLWithPath:[@"/Users/raph/Documents" stringByAppendingPathComponent:name]];
    return item;
}

static NSString *const SZFFriendPayload = @"f.AbTdSXSAjDJSLILKcnTFnJ61gwHnPY127KX0X8oI-0OqyMnKy8zNzs_Q0dLT1NXW1w1ib25"
                                          @"maXJlLW90dGVyCExlbyBQYXJr";

static void SZFTestLinkPage(void) {
    SZFTestTransport *transport = nil;
    SZFriendsHelperLink *link = SZFLinksLink(&transport, YES);
    SZFLinkHost *host = [SZFLinkHost new];
    SZFriendsDropdownController *controller =
        [[SZFriendsDropdownController alloc] initWithHost:host link:link presenter:[SZFTestPresenter new]];
    [controller install];
    SZFExpect(controller.offersLinks, @"a Ready helper that announces links offers them");
    [controller showLinkPayload:SZFFriendPayload];
    SZFExpect(controller.shown && controller.currentView == SZFriendsDropdownViewLink, @"opens on the link page");
    NSDictionary *open = SZFLastOfType(transport, @"open_link");
    SZFExpect([open[@"fields"][@"payload"] isEqualToString:SZFFriendPayload], @"open_link with the payload: %@", open);
    SZFriendsLinkPage *page = (SZFriendsLinkPage *)controller.content.topPage;
    SZFExpect(page.actionButtons.count == 0, @"no button before the helper's card");
    SZFAnswer(transport, open, @"replies/open_link");
    SZFExpect([page.titleLabel.stringValue isEqualToString:@"Add Leo Park?"], @"card title: %@",
              page.titleLabel.stringValue);
    SZFExpect([page.subtitleLabel.stringValue containsString:@"bonfire"], @"card subtitle");
    SZFExpect(page.actionButtons.count == 1 && [page.actionButtons[0].title isEqualToString:@"Add"], @"Add only");
    // The scheme handler never acts by itself: nothing but the question went to the helper.
    SZFExpect(SZFCountOfType(transport, @"add_from_link") == 0, @"nothing added before Add");
    [page.actionButtons[0] performClick:nil];
    NSDictionary *add = SZFLastOfType(transport, @"add_from_link");
    SZFExpect([add[@"fields"][@"payload"] isEqualToString:SZFFriendPayload] && [add[@"fields"] count] == 1,
              @"Add sends the action's payload as it is: %@", add);
    SZFExpect(!page.actionButtons[0].enabled, @"Add rests until the reply, so a double click asks once");
    SZFAnswer(transport, add, @"replies/add_from_link");
    SZFExpect(controller.currentView == SZFriendsDropdownViewConversation, @"the request's conversation opens");

    // A link the helper refuses shows its words and nothing to press.
    [controller showLinkPayload:@"d.AAAA"];
    page = (SZFriendsLinkPage *)controller.content.topPage;
    open = SZFLastOfType(transport, @"open_link");
    [transport deliver:@{@"type" : @"reply", @"re" : open[@"id"], @"ok" : @NO,
                         @"error" : @{@"code" : @"not_found", @"message" : @"Mei revoked this link.",
                                      @"retryable" : @NO, @"details" : @{}}}];
    SZFExpect([page.messageLabel.stringValue isEqualToString:@"Mei revoked this link."] &&
                  page.actionButtons.count == 0,
              @"refusal shown: %@", page.messageLabel.stringValue);

    // While the helper is not answering, the page asks again once it does.
    [transport setLinkState:SZFriendsLinkStateWaiting];
    [controller showLinkPayload:SZFFriendPayload];
    NSUInteger before = SZFCountOfType(transport, @"open_link");
    [transport setLinkState:SZFriendsLinkStateReady];
    SZFExpect(SZFTestWaitUntil(2, ^BOOL { return SZFCountOfType(transport, @"open_link") == before + 1; }),
              @"asked again once Ready");
    [controller uninstall];
}

static void SZFTestYourLinks(void) {
    SZFTestTransport *transport = nil;
    SZFriendsContext *context = SZFTestContext([SZFTestHost new], SZFLinksLink(&transport, YES));
    __block NSDictionary *confirmed = nil;
    context.presentConfirmation = ^(NSDictionary *confirm, void (^onConfirm)(BOOL)) {
        confirmed = confirm;
        onConfirm(NO);
    };
    SZFriendsProfilePage *page = [[SZFriendsProfilePage alloc] initWithContext:context];
    NSWindow *window = SZFTestHostWindow(page, NSMakeSize(400, 640), NSAppearanceNameAqua);
    (void)window;
    [page applySnapshot:SZFTestSnapshot(@"profile-unreserved")];
    [page layoutSubtreeIfNeeded];
    SZFExpect(page.linksView.hidden, @"no Your links without `links` in the snapshot");
    NSDictionary *data = SZFTestSnapshot(@"profile-links");
    [page applySnapshot:data];
    [page layoutSubtreeIfNeeded];
    SZFriendsYourLinksView *links = page.linksView;
    SZFExpect(!links.hidden && NSHeight(links.frame) > 100, @"Your links shown: %@", NSStringFromRect(links.frame));
    SZFExpect(links.fileLabels.count == 2 && [links.fileLabels[0].stringValue isEqualToString:@"Site photos.pdf"],
              @"one row per download link");
    [links.friendCopyButton performClick:nil];
    SZFExpect([[context.pasteboard stringForType:NSPasteboardTypeString]
                  isEqualToString:data[@"links"][@"friend"][@"url"]],
              @"Copy puts the friend link on the pasteboard");
    [links.friendResetButton performClick:nil];
    SZFExpect(confirmed != nil && SZFLastOfType(transport, @"reset_friend_link") != nil,
              @"Reset link asks first, then sends reset_friend_link");
    [links.revokeButtons[1] performClick:nil];
    NSDictionary *revoke = SZFLastOfType(transport, @"revoke_link");
    SZFExpect([revoke[@"fields"][@"link_id"] isEqualToString:@"IiMkJSYnKCkqKywtLi8wMQ"],
              @"Revoke sends that link's id: %@", revoke);
    NSMutableArray *rects = [NSMutableArray array];
    for (NSView *view in [links.revokeButtons arrayByAddingObject:links.friendCopyButton])
        [rects addObject:[NSValue valueWithRect:[view convertRect:view.bounds toView:page]]];
    SZFExpect(!NSIntersectsRect([rects[0] rectValue], [rects[1] rectValue]), @"rows do not overlap");
    for (NSView *target in [links.revokeButtons arrayByAddingObject:links.friendResetButton])
        SZFExpect(SZFTestMissedHits(target, page) == 0, @"%@ is one contiguous hit target", target);
}

static void SZFTestCopyLinkInstead(void) {
    SZFTestTransport *transport = nil;
    SZFLinkHost *host = [SZFLinkHost new];
    SZFriendsDropdownController *controller =
        [[SZFriendsDropdownController alloc] initWithHost:host link:SZFLinksLink(&transport, YES)
                                                presenter:[SZFTestPresenter new]];
    [controller install];
    NSWindow *window = SZFTestHostWindow(controller.content, NSMakeSize(400, 640), NSAppearanceNameAqua);
    (void)window;
    [controller beginSendPickerWithItems:@[ SZFLinkItem(@"Site photos.pdf"), SZFLinkItem(@"Plan.pdf") ]];
    SZFExpect(controller.content.listPage.sendPickerLinkButton == nil, @"two files: no link instead");
    [controller beginSendPickerWithItems:@[ SZFLinkItem(@"Site photos.pdf") ]];
    SZFriendsButton *button = controller.content.listPage.sendPickerLinkButton;
    SZFExpect([button.title isEqualToString:@"Copy link instead"], @"one file: the host's words: %@", button.title);
    [controller.content layoutSubtreeIfNeeded];
    [button performClick:nil];
    SZFExpect(host.offers.count == 1 && [host.offers[0].title isEqualToString:@"Site photos.pdf"],
              @"the host gets the file to offer");
    SZFExpect(controller.content.pendingSendFiles == nil, @"the picker ends");

    // Copy Download Link: the helper's URL on the pasteboard and its words for the host to show.
    controller.context.pasteboard = [NSPasteboard pasteboardWithUniqueName];
    __block NSString *shown = nil;
    __block BOOL copied = NO;
    [controller copyDownloadLinkForItem:SZFLinkItem(@"Site photos.pdf") expiresDays:30
                             completion:^(NSString *message, BOOL ok) {
                                 shown = message;
                                 copied = ok;
                             }];
    NSDictionary *make = SZFLastOfType(transport, @"make_download_link");
    SZFExpect([make[@"fields"][@"expires_days"] isEqual:@30] &&
                  [make[@"fields"][@"file"][@"path"] hasSuffix:@"/Site photos.pdf"],
              @"make_download_link with the file and the expiry: %@", make);
    SZFAnswer(transport, make, @"replies/make_download_link");
    NSString *url = SZFTestFrame(@"replies/make_download_link")[@"result"][@"url"];
    SZFExpect(copied && [[controller.context.pasteboard stringForType:NSPasteboardTypeString] isEqualToString:url] &&
                  [shown hasPrefix:@"Download link copied"],
              @"copied: %@", shown);
    [controller uninstall];

    // A helper from before links: no link instead, and the host is told not to offer links.
    SZFLinkHost *older = [SZFLinkHost new];
    SZFriendsDropdownController *plain =
        [[SZFriendsDropdownController alloc] initWithHost:older link:SZFLinksLink(&transport, NO)
                                                presenter:[SZFTestPresenter new]];
    [plain install];
    SZFExpect(!plain.offersLinks, @"no links without the capability");
    [plain beginSendPickerWithItems:@[ SZFLinkItem(@"Site photos.pdf") ]];
    SZFExpect(plain.content.listPage.sendPickerLinkButton == nil, @"no link instead without the capability");
    [plain uninstall];
}

// Each view in light and dark: written, not blank, and drawn on each appearance's own background.
static void SZFTestLinkRenders(void) {
    NSDictionary *card = SZFTestFrame(@"replies/open_link")[@"result"][@"card"];
    NSArray *builders = @[
        @[ @"link-friend", ^NSView *(SZFriendsContext *context) {
              SZFriendsLinkPage *page = [[SZFriendsLinkPage alloc] initWithContext:context payload:SZFFriendPayload];
              [page applyCard:card];
              return page;
          } ],
        @[ @"link-refused", ^NSView *(SZFriendsContext *context) {
              SZFriendsLinkPage *page = [[SZFriendsLinkPage alloc] initWithContext:context payload:SZFFriendPayload];
              [page applyError:@"This link no longer works. Ask Mei for a new one."];
              return page;
          } ],
        @[ @"profile-links", ^NSView *(SZFriendsContext *context) {
              SZFriendsProfilePage *page = [[SZFriendsProfilePage alloc] initWithContext:context];
              [page applySnapshot:SZFTestSnapshot(@"profile-links")];
              return page;
          } ],
    ];
    for (NSArray *entry in builders) {
        uint32_t backgrounds[2] = {0, 0};
        int index = 0;
        for (NSAppearanceName appearance in @[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]) {
            SZFTestTransport *transport = nil;
            SZFriendsContext *context = SZFTestContext([SZFTestHost new], SZFLinksLink(&transport, YES));
            NSView *(^build)(SZFriendsContext *) = entry[1];
            NSView *view = build(context);
            NSWindow *window = SZFTestHostWindow(view, NSMakeSize(400, 640), appearance);
            [window.contentView layoutSubtreeIfNeeded];
            BOOL dark = [appearance isEqualToString:NSAppearanceNameDarkAqua];
            NSString *name = [NSString stringWithFormat:@"%@-%@", entry[0], dark ? @"dark" : @"light"];
            NSString *path = SZFTestRender(window.contentView, name, 2);
            NSBitmapImageRep *rep = path ? (NSBitmapImageRep *)[NSBitmapImageRep imageRepWithContentsOfFile:path] : nil;
            NSMutableSet *colours = [NSMutableSet set];
            for (NSInteger y = 0; y < rep.pixelsHigh; y += 7)
                for (NSInteger x = 0; x < rep.pixelsWide; x += 7) [colours addObject:@(SZFTestBitmapPixel(rep, x, y))];
            SZFExpect(colours.count > 8, @"%@ is drawn (%lu colours)", name, (unsigned long)colours.count);
            backgrounds[index++] = SZFTestPixelAt(window.contentView, NSMakePoint(NSWidth(view.frame) - 3, 600));
        }
        SZFExpect(!SZFTestSameColor(backgrounds[0], backgrounds[1], 40), @"%@ follows the appearance (%06x, %06x)",
                  entry[0], backgrounds[0], backgrounds[1]);
    }
}

void SZFTestFriendLinks(void) {
    SZFTestLinkPage();
    SZFTestYourLinks();
    SZFTestCopyLinkInstead();
    SZFTestLinkRenders();
}
