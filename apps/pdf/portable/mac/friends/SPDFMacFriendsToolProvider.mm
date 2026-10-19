#import "SPDFMacFriendsToolProvider.h"
#import "SPDFMacAIChatStore.h"
#import "SPDFMacFriendsChatHistory.h"
#import "SPDFMacFriendsComposerText.h"

NSString* const SPDFMacFriendsToolProviderIdentifier = @"friends";

// The same words the model read from SPDFMacFriendsScopedChatTools and the gate, so the change of plumbing changes
// nothing it sees.
static NSString* const kReadOnlyAfterChats = @"This request includes Friends messages, so it can only read: nothing "
    "in a friend's message can make changes. Tell the user to ask again in a new message, without @, to make this "
    "change.";

SPDFMacFriendsScopeRequest* SPDFMacFriendsScopeForContext(SPDFMacAIRequestContext* context) {
    NSMutableArray<SPDFMacFriendsScopeRequest*>* scopes = [NSMutableArray array];
    for (SPDFMacAIRequestChip* chip in [context chipsOfKind:SPDFMacAIChipKindFriends]) {
        if ([chip isKindOfClass:SPDFMacFriendsGrantChip.class]) continue;
        [scopes addObject:chip.scopeIDs ? [SPDFMacFriendsScopeRequest conversationIDs:chip.scopeIDs
                                                                              labels:@[chip.displayName]]
                                        : SPDFMacFriendsScopeRequest.allChats];
    }
    // `/` may read the conversation it was typed in (brief § AI boundaries); other chats still need an `@` chip.
    SPDFMacAIRequestChip* friendChip = context.friendConversation;
    if (context.origin == SPDFMacAIRequestOriginFriendComposer && friendChip.scopeIDs.count)
        [scopes addObject:[SPDFMacFriendsScopeRequest conversationIDs:friendChip.scopeIDs
                                                               labels:@[friendChip.displayName]]];
    return [SPDFMacFriendsScopeRequest union:scopes];
}

uint64_t SPDFMacFriendsGrantTokenForContext(SPDFMacAIRequestContext* context) {
    // Only the AI chat's own requests read under a time grant; `/` in a friend's chat reads its conversation alone.
    if (context.origin != SPDFMacAIRequestOriginChat) return 0;
    for (SPDFMacAIRequestChip* chip in [context chipsOfKind:SPDFMacAIChipKindFriends])
        if ([chip isKindOfClass:SPDFMacFriendsGrantChip.class]) return ((SPDFMacFriendsGrantChip*)chip).grantToken;
    return 0;
}

NSArray<SPDFMacAIRequestChip*>* SPDFMacFriendsChipsInText(NSAttributedString* text) {
    NSMutableArray* chips = [NSMutableArray array];
    if (!text.length) return chips;
    [text enumerateAttribute:NSAttachmentAttributeName inRange:NSMakeRange(0, text.length) options:0
                  usingBlock:^(id value, NSRange range, BOOL* stop) {
        (void)range; (void)stop;
        if (![value isKindOfClass:SPDFMacFriendsScopeToken.class]) return;
        SPDFMacFriendsScopeToken* token = value;
        [chips addObject:[SPDFMacAIRequestChip friendsChipWithConversationIDs:token.scope.conversationIDs
                                                                  displayName:token.label]];
    }];
    return chips;
}

@implementation SPDFMacFriendsToolProvider

- (instancetype)initWithGate:(SPDFMacFriendsChatScopeGate*)gate {
    if (!(self = [super init])) return nil;
    _gate = gate;
    return self;
}

- (NSString*)providerIdentifier { return SPDFMacFriendsToolProviderIdentifier; }
- (BOOL)providesTool:(NSString*)name { return SPDFMacFriendsIsChatTool(name); }
- (BOOL)isReadOnlyTool:(NSString*)name { return SPDFMacFriendsIsChatTool(name); }

- (NSArray<NSDictionary*>*)toolDefinitionsForContext:(SPDFMacAIRequestContext*)context {
    (void)context;
    return self.gate.toolDefinitionsForCurrentRequest;
}

- (void)performTool:(NSString*)name arguments:(NSDictionary*)arguments context:(SPDFMacAIRequestContext*)context
         completion:(SPDFMacAIToolCompletion)completion {
    (void)context;
    [self.gate performTool:name arguments:arguments completion:completion];
}

// The session cancels its providers when a request is stopped, a chat is replaced or saving fails: each ends the
// request, so the scope closes with it.
- (void)cancel { [self.gate endRequest]; }

- (void)beginRequestWithContext:(SPDFMacAIRequestContext*)context {
    SPDFMacFriendsScopeRequest* scope = SPDFMacFriendsScopeForContext(context);
    uint64_t token = SPDFMacFriendsGrantTokenForContext(context);
    SPDFMacFriendsChatScopeGate* gate = self.gate;
    if (!scope && !token) {
        if (gate.requestHasScope) [gate endRequest];
        return;
    }
    // In AI chat the composer's scoper opened this scope from the same chips and grant a moment ago; opening it
    // again would only cost the helper a second scope. Anything else (another origin, another scope) opens anew.
    BOOL opened = context.origin == SPDFMacAIRequestOriginChat && [gate requestMatchesScope:scope grantToken:token];
    if (!opened) [gate beginRequestWithScope:scope grantToken:token];
}

- (void)endRequestWithContext:(SPDFMacAIRequestContext*)context {
    (void)context;
    [self.gate endRequest];
}

- (NSString*)readOnlyReasonForContext:(SPDFMacAIRequestContext*)context {
    (void)context;
    return self.gate.requestIsReadOnly ? kReadOnlyAfterChats : nil;
}

- (NSString*)unavailableMessageForTool:(NSString*)name context:(SPDFMacAIRequestContext*)context {
    (void)name; (void)context;
    return self.gate.unavailableMessage;
}

- (NSArray<NSDictionary*>*)messagesForRequest:(NSArray<NSDictionary*>*)messages
                                      context:(SPDFMacAIRequestContext*)context {
    (void)context;
    SPDFMacFriendsChatScopeGate* gate = self.gate;
    BOOL holdsChats = NO;
    NSArray* sent = SPDFMacFriendsRedactChatHistory(messages, ^BOOL(NSSet<NSString*>* conversations) {
        return [gate scopeCoversConversations:conversations];
    }, &holdsChats);
    // Recorded before the turn goes out, so a tool call in its reply already finds the request read-only.
    if (holdsChats) [gate noteRequestContextHoldsChats];
    return sent;
}

// The chips the person put in the message, and, while the AI chat's time grant runs, its chip: the request then
// includes Friends chats in every sense (no web tools, work kept for the request only), for as long as it runs.
- (NSArray<SPDFMacAIRequestChip*>*)requestChipsInComposerText:(NSAttributedString*)text {
    NSArray<SPDFMacAIRequestChip*>* chips = SPDFMacFriendsChipsInText(text);
    uint64_t token = self.gate.grant.activeToken;
    return token ? [chips arrayByAddingObject:[SPDFMacFriendsGrantChip chipForGrantToken:token]] : chips;
}

// Friends excerpts never reach the chat file (SPDFMacFriendsChatHistory.h § What is kept).
- (NSDictionary*)chatForStorage:(NSDictionary*)chat {
    NSArray* messages = chat[@"messages"];
    if (![messages isKindOfClass:NSArray.class] || !SPDFMacFriendsChatHoldsFriendsResults(messages)) return chat;
    NSMutableDictionary* stored = [chat mutableCopy];
    stored[@"messages"] = SPDFMacFriendsStoredChatHistory(messages);
    stored[SPDFMacAIChatTitleSearchOnlyKey] = @YES;
    return stored;
}

- (NSArray<NSDictionary*>*)messagesForTitle:(NSArray<NSDictionary*>*)messages {
    return SPDFMacFriendsTitleChatHistory(messages);
}

@end
