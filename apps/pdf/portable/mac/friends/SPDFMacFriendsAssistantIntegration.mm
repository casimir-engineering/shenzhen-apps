// Friends chats in ShenzhenPDF's AI chat: the session's transport and tools wrapped per request, the `@` picker and
// note in the composer, and Friends citations opening the dropdown at the cited message.

#import "SPDFMacFriendsReaderState.h"
#import "SPDFMacAIChatView.h"
#import "SPDFMacFriendsAttachItems.h"
#import "SPDFMacFriendsChatTools.h"

// A helper announces "assistant.scopes" once it implements assistant_open_scope (PROTOCOL.md § Capabilities); until
// then the `@` picker does not appear, because every scope would fail.
static NSString* const kScopesCapability = @"assistant.scopes";
// The picker shows All Friends chats at once if the list takes longer than this to arrive.
static const NSTimeInterval kChoicesWait = 1.0;

@implementation ShenzhenMacDelegate (SPDFMacFriendsAssistantState)

- (SPDFMacFriendsChatScopeGate*)friendsGate {
    SPDFMacFriendsReaderState* state = [self friendsState];
    if (!state.gate) {
        __weak ShenzhenMacDelegate* weakSelf = self;
        state.gate = [[SPDFMacFriendsChatScopeGate alloc] initWithServices:^id<SZFriendsServices> {
            return [weakSelf friendsState].services;
        }];
        // The AI chat's time grant for all chats: made with the chat, never at launch, and held in memory only.
        state.gate.grant = [SPDFMacFriendsChatGrant new];
        [self friendsAssistantAvailabilityDidChange];
    }
    return state.gate;
}

- (void)friendsAssistantAvailabilityDidChange {
    SPDFMacFriendsReaderState* state = [self friendsState];
    BOOL available = state.services && state.link.state == SZFriendsLinkStateReady &&
        [state.link.helperCapabilities containsObject:kScopesCapability];
    state.composerScope.available = available;
    // Friends turned off, reset (every client reconnects) or not running: a time grant ends and needs giving again.
    [state.gate.grant friendsAvailabilityChanged:available];
}

@end

@implementation ShenzhenMacDelegate (SPDFMacFriendsAssistant)

- (SPDFMacAITransport*)friendsChatTransport:(SPDFMacAITransport*)transport {
    return [[SPDFMacFriendsScopedTransport alloc] initWithTransport:transport gate:[self friendsGate]];
}

- (id<SPDFMacAIChatTools>)friendsChatTools:(id<SPDFMacAIChatTools>)tools {
    return [[SPDFMacFriendsScopedChatTools alloc] initWithTools:tools gate:[self friendsGate]];
}

// One subscription to the `list` view per opened picker, released as soon as the first snapshot arrives.
- (void)friendsDeliverScopeChoices:(SPDFMacFriendsChoicesDelivery)deliver {
    SZFriendsHelperLink* link = [self friendsState].link;
    NSArray* fallback = SPDFMacFriendsScopeChoices(@[]);
    if (!link || link.state != SZFriendsLinkStateReady) { deliver(fallback); return; }
    __block BOOL delivered = NO;
    __block NSString* token = nil;
    __weak SZFriendsHelperLink* weakLink = link;
    token = [link subscribeToView:@"list" params:nil handler:^(NSDictionary* data, NSInteger rev) {
        (void)rev;
        if (delivered) return;
        delivered = YES;
        deliver(SPDFMacFriendsScopeChoices(data[@"rows"]));
        dispatch_async(dispatch_get_main_queue(), ^{ if (token) [weakLink unsubscribe:token]; });
    }];
    dispatch_time_t wait = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kChoicesWait * NSEC_PER_SEC));
    dispatch_after(wait, dispatch_get_main_queue(), ^{
        if (delivered) return;
        delivered = YES;
        [weakLink unsubscribe:token];
        deliver(fallback);
    });
}

- (void)friendsAttachChatView:(SPDFMacAIChatView*)view session:(SPDFMacAIChatSession*)session {
    SPDFMacFriendsReaderState* state = [self friendsState];
    __weak SPDFMacAIChatSession* weakSession = session;
    __weak SPDFMacAIChatView* weakView = view;
    SPDFMacFriendsChatRequestScoper* scoper = [[SPDFMacFriendsChatRequestScoper alloc] initWithGate:[self friendsGate]
        running:^BOOL { return weakSession.running; }
        composerText:^NSAttributedString* { return weakView.composer.textStorage; }];
    state.scoper = scoper;
    if (view.sendText) view.sendText = [scoper sendTextWrapping:view.sendText];
    void (^changed)(void) = session.changed;
    // Discovered with the chat's tool providers a moment ago (SPDFMacFriendsSendIntegration.mm).
    SPDFMacFriendsSendProvider* sendProvider = state.chatSendProvider;
    session.changed = ^{
        if (changed) changed();
        [scoper sessionDidChange];
        // Opening a chat drops every card's buttons (SPDFMacAIChatActivity.h); a message still waiting for Send, or
        // on its way, gets them back here, and the open chat's queued messages are watched for delivery.
        [sendProvider restoreCardsInActivity:weakSession.activity];
    };
    __weak ShenzhenMacDelegate* weakSelf = self;
    [state.composerScope uninstall];
    state.composerScope = [[SPDFMacFriendsComposerScope alloc] initWithComposer:view.composer
        choices:^(SPDFMacFriendsChoicesDelivery deliver) {
            ShenzhenMacDelegate* reader = weakSelf;
            if (reader) [reader friendsDeliverScopeChoices:deliver]; else deliver(@[]);
        }];
    // All Friends chats asks how long; a time grant shows as a bar over the chat until it ends.
    SPDFMacFriendsChatGrant* grant = [self friendsGate].grant;
    state.composerScope.grantAllChats = ^BOOL(SPDFMacFriendsGrantLength length) {
        return [grant grantAllChatsFor:length];
    };
    [state.grantBar uninstall];
    state.grantBar = [[SPDFMacFriendsGrantBar alloc] initWithGrant:grant show:^(SPDFMacFriendsGrantBar* bar) {
        weakView.banner = bar;
    }];
    // `#`: the same open and Collection documents the Friends composer offers, each bound to the revision on screen,
    // so a file sent from AI chat is exactly the one the person picked (SPDFMacFriendsAttachItems.h).
    state.composerScope.filePlaceholder = SPDFMacFriendsAttachPlaceholder;
    state.composerScope.fileChoices = ^(SPDFMacFriendsChoicesDelivery deliver) {
        SPDFMacFriendsHost* host = [weakSelf friendsState].host;
        if (!host) { deliver(@[]); return; }
        [host friendsAttachableItemsMatching:@"" completion:^(NSArray<SZFriendsAttachableItem*>* items) {
            deliver(SPDFMacFriendsFileChoices(items));
        }];
    };
    [self friendsAssistantAvailabilityDidChange];
}

- (BOOL)friendsSendDraft:(NSString*)draft using:(BOOL (^)(NSString* text))send {
    SPDFMacFriendsChatRequestScoper* scoper = [self friendsState].scoper;
    return scoper ? [scoper sendTextWrapping:send](draft) : send(draft);
}

- (BOOL)friendsOpenCitation:(NSURL*)url chat:(NSDictionary*)chat {
    NSString* conversationID = nil, *messageID = nil;
    if (!SPDFMacFriendsParseMessageCitationURL(url, &conversationID, &messageID)) return NO;
    if (!SPDFMacFriendsChatContainsCitation(chat, url)) {
        // Like a document citation (SPDFMacAIIntegration.mm -aiOpenCitation): a link the model wrote itself is not
        // evidence, so it opens nothing.
        NSAlert* alert = [NSAlert new];
        alert.messageText = @"This link has no retrieved message";
        alert.informativeText = @"Ask the assistant to search the chat again before opening its citation.";
        [alert addButtonWithTitle:@"OK"];
        // Friends interface, so the assistant's app_controls leaves it alone (SPDFMacAIAppControls.h).
        alert.window.identifier = @"szfriends.alert.citation";
        [alert beginSheetModalForWindow:_window completionHandler:nil];
        return YES;
    }
    SPDFMacFriendsReaderState* state = [self friendsState];
    if (state.services) [state.services showMessage:messageID inConversation:conversationID];
    else [state.dropdown showConversation:conversationID highlightMessage:messageID];
    return YES;
}

@end
