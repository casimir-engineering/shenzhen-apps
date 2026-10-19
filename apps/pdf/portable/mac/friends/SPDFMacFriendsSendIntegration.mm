// Sending to friends in the reader: the AI chat's friends_send_message provider (found by its aiToolProvider prefix,
// portable/mac/SPDFMacAIToolProvider.h § 2) and the assistant behind `/` in a friend's composer. Both send through
// this window's helper link, so they exist only while Friends is attached; without it a send is refused, not queued.

#import "SPDFMacFriendsReaderState.h"
#import "SPDFMacAICredentials.h"
#import "SPDFMacAISettings.h"
#import "SPDFMacAITools.h"
#import "SPDFMacAITransport.h"
#import "SPDFMacUnifiedSettings.h"
#import "SPDFMacFriendsAssistant.h"
#import "SPDFMacFriendsLinkSender.h"
#import "SPDFMacFriendsSendProvider.h"
#import <Security/Security.h>

// SPDFMacFriendsAssistantIntegration.mm: the `@` picker's choices, which name each friend by conversation.
@interface ShenzhenMacDelegate (SPDFMacFriendsScopeChoices)
- (void)friendsDeliverScopeChoices:(SPDFMacFriendsChoicesDelivery)deliver;
@end

static NSError* SlashFailure(NSString* message) {
    return [NSError errorWithDomain:@"ShenzhenPDF.Friends.Assistant" code:5
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}

@implementation ShenzhenMacDelegate (SPDFMacFriendsSend)

- (id<SPDFMacFriendsIntentSender>)friendsIntentSender {
    SZFriendsHelperLink* link = [self friendsState].link;
    return link ? [[SPDFMacFriendsLinkSender alloc] initWithLink:link] : nil;
}

- (SPDFMacFriendsSendProvider*)friendsNewSendProvider {
    __weak ShenzhenMacDelegate* weakSelf = self;
    return [[SPDFMacFriendsSendProvider alloc] initWithSender:^id<SPDFMacFriendsIntentSender> {
        return [weakSelf friendsIntentSender];
    }];
}

- (id<SPDFMacAIToolProvider>)aiToolProviderFriendsSend {
    SPDFMacFriendsSendProvider* provider = [self friendsNewSendProvider];
    __weak ShenzhenMacDelegate* weakSelf = self;
    // The card's Show opens the dropdown at the sent message, as a Friends citation does.
    provider.showMessage = ^(NSString* conversationID, NSString* messageID) {
        SPDFMacFriendsReaderState* state = [weakSelf friendsState];
        if (state.services) [state.services showMessage:messageID inConversation:conversationID];
        else [state.dropdown showConversation:conversationID highlightMessage:messageID];
    };
    [self friendsState].chatSendProvider = provider;
    return provider;
}

#pragma mark - `/` in a friend's composer

- (id<SZFriendsAssistant>)friendsBridgeAssistant {
    SPDFMacFriendsReaderState* state = [self friendsState];
    if (state.slashAssistant) return state.slashAssistant;
    __weak ShenzhenMacDelegate* weakSelf = self;
    state.slashAssistant = [[SPDFMacFriendsAssistant alloc] initWithPreparer:^(NSString* conversationID,
        NSArray<SPDFMacAIRequestChip*>* files, SPDFMacFriendsCommandReady ready) {
        ShenzhenMacDelegate* reader = weakSelf;
        if (reader) [reader friendsPrepareCommandFor:conversationID files:files ready:ready];
        else ready(nil, nil, nil, SlashFailure(@"The assistant can’t help in this chat."));
    }];
    return state.slashAssistant;
}

// The same checks as a message sent in AI chat (SPDFMacAIIntegration -aiSendText:), with words for a friend's chat.
- (void)friendsPrepareCommandFor:(NSString*)conversationID files:(NSArray<SPDFMacAIRequestChip*>*)files
                           ready:(SPDFMacFriendsCommandReady)ready {
    SPDFMacAISettings* settings = [[SPDFMacAISettings alloc] initWithURL:SPDFMacAISettings.defaultURL];
    NSError* error = nil;
    if (![settings load:&error] || settings.onboardingRevision < SPDFUnifiedSettingsExperienceVersion ||
        !settings.enabled) {
        ready(nil, nil, nil, SlashFailure(@"Turn on the assistant in Settings to use / here."));
        return;
    }
    error = nil;
    NSString* key = [SPDFMacAICredentials APIKeyWithError:&error];
    if (!key.length) {
        BOOL blocked = error.code == errSecAuthFailed || error.code == errSecInteractionNotAllowed ||
            error.code == errSecNotAvailable;
        ready(nil, nil, nil, SlashFailure(blocked ? @"macOS blocked the saved OpenRouter key. Send a message in AI "
                                                     "chat and allow access, then try / again."
                                                  : @"Connect OpenRouter in Settings to use / here."));
        return;
    }
    __weak ShenzhenMacDelegate* weakSelf = self;
    [self friendsDeliverScopeChoices:^(NSArray<NSDictionary<NSString*, id>*>* choices) {
        ShenzhenMacDelegate* reader = weakSelf;
        if (!reader) { ready(nil, nil, nil, SlashFailure(@"The assistant can’t help in this chat.")); return; }
        NSString* name = @"your friend";
        for (NSDictionary* choice in choices)
            if ([choice[@"id"] isEqual:conversationID] && [choice[@"name"] length]) name = choice[@"name"];
        // Its own gate: a `/` request reads only its conversation and never shares a scope with AI chat.
        SPDFMacFriendsChatScopeGate* gate = [[SPDFMacFriendsChatScopeGate alloc] initWithServices:^{
            return [weakSelf friendsState].services;
        }];
        SPDFMacFriendsSendProvider* send = [reader friendsNewSendProvider];
        SPDFMacAITools* tools = [[SPDFMacAITools alloc] initWithReader:reader];
        SPDFMacAIToolRegistry* registry = SPDFMacFriendsSlashRegistry((id<SPDFMacAIChatTools>)tools,
                                                                      SPDFMacAITools.toolDefinitions, gate, send);
        SPDFMacAITransport* transport = [[SPDFMacAITransport alloc]
            initWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
        SPDFMacAIChatSession* session = [[SPDFMacAIChatSession alloc] initWithTransport:transport registry:registry
                                                                                  store:nil];
        SPDFMacAIRequestChip* friendChip = [SPDFMacAIRequestChip friendsChipWithConversationIDs:@[conversationID]
                                                                                    displayName:name];
        ready([[SPDFMacFriendsSlashCommand alloc] initWithSession:session sendProvider:send friendChip:friendChip
                                                            files:files settings:settings.snapshot],
              settings.model, key, nil);
    }];
}

@end
