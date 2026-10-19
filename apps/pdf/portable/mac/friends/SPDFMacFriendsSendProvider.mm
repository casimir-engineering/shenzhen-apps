#import "SPDFMacFriendsSendProvider.h"
#import "SPDFMacAIChatActivity.h"
#import "SPDFMacFriendsComposerText.h"
#import "SPDFMacFriendsSendCards.h"

NSString* const SPDFMacFriendsSendProviderIdentifier = @"friends.send";
NSString* const SPDFMacFriendsSendCardKind = @"friends.send";
NSString* const SPDFMacFriendsCancelMessageCapability = @"messages.cancel";

static NSString* const kNoChip = @"Sending to friends isn't part of this request. The user can name a friend with @ in "
    "AI chat, or type / in that friend's chat, to let you write them a message to send.";

static NSDictionary* Refusal(NSString* message) { return @{@"error" : message, @"sent" : @NO}; }

@implementation SPDFMacFriendsSendRecord
- (instancetype)initWithPlan:(SPDFMacFriendsSendPlan*)plan messageID:(NSString*)messageID
                   transfers:(NSArray*)transfers {
    if (!(self = [super init])) return nil;
    _recipient = plan.recipient;
    _text = [plan.text copy];
    _files = [plan.files copy];
    _messageID = [messageID copy] ?: @"";
    _transferIDs = [transfers copy] ?: @[];
    return self;
}
@end

@implementation SPDFMacFriendsSendProvider {
    id<SPDFMacFriendsIntentSender> (^_sender)(void);
    SPDFMacFriendsSendCards* _cards;
    NSMutableDictionary<NSString*, NSNumber*>* _sends; // request id -> messages put in front of the person
}

- (instancetype)initWithSender:(id<SPDFMacFriendsIntentSender> (^)(void))sender {
    if (!(self = [super init])) return nil;
    _sender = [sender copy];
    _cards = [[SPDFMacFriendsSendCards alloc] initWithSender:sender];
    _sends = [NSMutableDictionary dictionary];
    return self;
}

- (void)setShowMessage:(void (^)(NSString*, NSString*))showMessage {
    _showMessage = [showMessage copy];
    _cards.showMessage = _showMessage;
}

- (NSString*)providerIdentifier { return SPDFMacFriendsSendProviderIdentifier; }
- (BOOL)providesTool:(NSString*)name { return [name isEqual:SPDFMacFriendsSendToolName]; }
// See the header: exempt from the read-only rule only because a call can do no more than put a message in front of
// the person.
- (BOOL)isReadOnlyTool:(NSString*)name { return [name isEqual:SPDFMacFriendsSendToolName]; }
// A message Friends accepted, or one waiting on a card, is the person's to act on now; Stop leaves both.
- (void)cancel {}

- (NSUInteger)sendsLeftForContext:(SPDFMacAIRequestContext*)context {
    NSUInteger used = _sends[context.requestID].unsignedIntegerValue;
    return used >= SPDFMacFriendsSendsPerRequest ? 0 : SPDFMacFriendsSendsPerRequest - used;
}

- (void)restoreCardsInActivity:(SPDFMacAIChatActivity*)activity { [_cards restoreCardsInActivity:activity]; }

- (NSArray<NSDictionary*>*)toolDefinitionsForContext:(SPDFMacAIRequestContext*)context {
    NSDictionary* definition = [[[SPDFMacFriendsSendScope alloc] initWithContext:context]
        toolDefinitionWithSendsLeft:[self sendsLeftForContext:context]];
    return definition ? @[definition] : @[];
}

- (NSString*)unavailableMessageForTool:(NSString*)name context:(SPDFMacAIRequestContext*)context {
    (void)name; (void)context;
    return kNoChip;
}

// The `#` chips and dropped files in AI chat's composer; the Friends chats provider reads the `@` chips.
- (NSArray<SPDFMacAIRequestChip*>*)requestChipsInComposerText:(NSAttributedString*)text {
    return SPDFMacFriendsFileChipsInText(text);
}

- (void)beginRequestWithContext:(SPDFMacAIRequestContext*)context { [_sends removeObjectForKey:context.requestID]; }
- (void)endRequestWithContext:(SPDFMacAIRequestContext*)context { [_sends removeObjectForKey:context.requestID]; }

- (void)performTool:(NSString*)name arguments:(NSDictionary*)arguments context:(SPDFMacAIRequestContext*)context
         completion:(SPDFMacAIToolCompletion)completion {
    SPDFMacFriendsSendScope* scope = [[SPDFMacFriendsSendScope alloc] initWithContext:context];
    if (![self providesTool:name] || !scope.recipients.count) { completion(Refusal(kNoChip)); return; }
    if (![self sendsLeftForContext:context]) {
        completion(Refusal([NSString stringWithFormat:@"This request already prepared %lu messages, the most one "
            "request may. Nothing more was prepared; tell the user.", (unsigned long)SPDFMacFriendsSendsPerRequest]));
        return;
    }
    NSString* error = nil;
    SPDFMacFriendsSendPlan* plan = [scope planForArguments:arguments error:&error];
    if (!plan) { completion(Refusal(error)); return; }
    if (context.cancellation.cancelled) {
        completion(Refusal(@"The request was stopped, so nothing was sent."));
        return;
    }
    if (self.proposal) { [self propose:plan context:context completion:completion]; return; }
    id<SPDFMacFriendsIntentSender> sender = _sender ? _sender() : nil;
    if (!sender.friendsReady) {
        completion(Refusal(@"Shenzhen Friends isn't connected right now, so nothing was sent. Tell the user to open "
                            "Friends and ask again."));
        return;
    }
    [self showCard:plan context:context completion:completion];
}

static NSDictionary* Waiting(SPDFMacFriendsSendPlan* plan, NSUInteger left, NSString* note) {
    return @{@"sent" : @NO, @"status" : @"waiting for the person", @"to" : plan.recipient.label,
             @"attachments" : plan.fileLabels, @"sends_left" : @(left), @"note" : note};
}

- (void)showCard:(SPDFMacFriendsSendPlan*)plan context:(SPDFMacAIRequestContext*)context
      completion:(SPDFMacAIToolCompletion)completion {
    if ([plan.text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > SPDFMacFriendsCheckedMessageLengthMax) {
        completion(Refusal([NSString stringWithFormat:@"The user has to check this message before it goes, and the "
            "card shows at most %lu bytes. Shorten it. Nothing was sent.",
            (unsigned long)SPDFMacFriendsCheckedMessageLengthMax]));
        return;
    }
    if (![_cards proposePlan:plan activity:context.activity]) {
        completion(Refusal(@"The chat can't show the message for the user to check, so nothing was sent. Tell the "
                            "user to start a new chat and ask again."));
        return;
    }
    _sends[context.requestID] = @(_sends[context.requestID].unsignedIntegerValue + 1);
    completion(Waiting(plan, [self sendsLeftForContext:context], [NSString stringWithFormat:@"Not sent. The user sees "
        "the message in AI chat with Send and Discard, and it goes to %@ only if they press Send. Don't call "
        "friends_send_message again for it, and don't say it was sent.", plan.recipient.name]));
}

- (void)propose:(SPDFMacFriendsSendPlan*)plan context:(SPDFMacAIRequestContext*)context
     completion:(SPDFMacAIToolCompletion)completion {
    _sends[context.requestID] = @(_sends[context.requestID].unsignedIntegerValue + 1);
    self.proposal(context, plan);
    completion(Waiting(plan, [self sendsLeftForContext:context], [NSString stringWithFormat:@"Not sent. The user sees "
        "the message above their message box with Send and Edit, and it goes to %@ only if they press Send. Don't "
        "call friends_send_message again unless the message must change.", plan.recipient.name]));
}

static NSError* SendFailure(NSString* message) {
    return [NSError errorWithDomain:@"ShenzhenPDF.Friends.Send" code:1 userInfo:@{NSLocalizedDescriptionKey : message}];
}

- (void)sendProposal:(SPDFMacFriendsSendPlan*)plan done:(void (^)(NSError*))done {
    void (^finish)(NSError*) = [done copy];
    id<SPDFMacFriendsIntentSender> sender = _sender ? _sender() : nil;
    // The person reads these above the friend's composer, where Friends shows the message once it has it, so they
    // name nothing but what to do next.
    if (!sender.friendsReady) {
        dispatch_async(dispatch_get_main_queue(), ^{
            finish(SendFailure(@"Friends isn’t connected, so nothing was sent. Press Send again once it’s back."));
        });
        return;
    }
    [_cards queuePlan:plan sender:sender outcome:^(SPDFMacFriendsSendRecord* record, NSString* code,
                                                    NSString* message) {
        if (record) { finish(nil); return; }
        if ([code isEqual:@"connection_lost"]) {
            finish(SendFailure(@"Friends stopped responding, so this may not have been sent. Check this chat before "
                                "you send it again."));
            return;
        }
        finish(SendFailure(message.length ? message : @"Friends couldn’t send it."));
    }];
}

@end
