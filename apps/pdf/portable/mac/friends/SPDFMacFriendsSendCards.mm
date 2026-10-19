#import "SPDFMacFriendsSendCards.h"
#import "SPDFMacFriendsComposerText.h"
#import "SPDFMacFriendsRevision.h"

static NSString* const kSendAction = @"send";
static NSString* const kDiscardAction = @"discard";
static NSString* const kShowAction = @"show";
// Enough for every message a long session leaves waiting or on its way; the oldest settled ones go first.
static const NSUInteger kCardsKept = 64;

NSString* SPDFMacFriendsQueuedCondition(id<SPDFMacFriendsIntentSender> sender, NSString* name) {
    NSString* note = [sender respondsToSelector:@selector(staticStringForKey:)]
        ? [sender staticStringForKey:@"queued_note"] : nil;
    if (![note isKindOfClass:NSString.class] || !note.length) return nil;
    return [note stringByReplacingOccurrencesOfString:@"{first}" withString:name ?: @""];
}

NSString* SPDFMacFriendsQueuedStatus(NSString* name, NSString* condition, BOOL show) {
    NSString* where = show ? [NSString stringWithFormat:@"Show opens your chat with %@, where you can see when it "
                                                         "arrives.", name]
                           : [NSString stringWithFormat:@"Your chat with %@ in Friends shows when it arrives.", name];
    // Without Friends' own condition the card names none rather than guess one Friends might not share.
    return [NSString stringWithFormat:@"%@ %@", condition.length ? condition : @"Friends has it.", where];
}

// A cancelled message, cancelled from the card or in the Friends conversation: Friends' word for it when it has one
// ("Cancelled"), then who won't get it.
static NSString* CancelledStatus(NSString* label, NSString* name) {
    NSString* word = label.length ? label : @"Cancelled";
    if ([word hasSuffix:@"."]) word = [word substringToIndex:word.length - 1];
    return [NSString stringWithFormat:@"%@. %@ won’t get it.", word, name];
}

typedef NS_ENUM(NSInteger, SPDFMacFriendsCardPhase) {
    SPDFMacFriendsCardWaiting, // for the person's Send or Discard
    SPDFMacFriendsCardSending, // Friends has not answered yet
    SPDFMacFriendsCardQueued,  // Friends has it; watched until it reports delivery
    SPDFMacFriendsCardFinal,   // delivered, not delivered or partly withdrawn: only Show remains
};

@interface SPDFMacFriendsSendCard : NSObject
@property(nonatomic, copy) NSString* cardID;
@property(nonatomic) SPDFMacFriendsSendPlan* plan;
@property(nonatomic, nullable) SPDFMacFriendsSendRecord* record;
@property(nonatomic) SPDFMacFriendsCardPhase phase;
@property(nonatomic, weak) id<SPDFMacAIActivityReporting> activity;
// What the card shows in this phase (title, status, state, actions, interruptedStatus), applied again on reopen.
@property(nonatomic, copy) NSDictionary* shown;
// Friends refused to cancel the text (it may already be on the friend's Mac): Cancel is not offered again, even when
// the message waits again after its connection dropped.
@property(nonatomic) BOOL cancelRefused;
@end

@implementation SPDFMacFriendsSendCard
@end

static NSString* ClientToken(void) {
    // 32 random lowercase hex characters, fresh per press of Send, so a retry after a reconnect never sends twice
    // (PROTOCOL.md § Idempotency).
    uint8_t bytes[16];
    arc4random_buf(bytes, sizeof bytes);
    NSMutableString* token = [NSMutableString stringWithCapacity:32];
    for (size_t index = 0; index < sizeof bytes; index++) [token appendFormat:@"%02x", bytes[index]];
    return token;
}

static NSArray* CardAttachments(NSArray<SPDFMacAIRequestChip*>* files) {
    NSMutableArray* rows = [NSMutableArray array];
    for (SPDFMacAIRequestChip* file in files) {
        NSString* kind = SPDFMacFriendsKindLabel(file.fileURL.path ?: @"");
        NSString* label = [file.revision[@"label"] isKindOfClass:NSString.class] ? file.revision[@"label"] : nil;
        [rows addObject:@{@"name" : file.displayName.length ? file.displayName : file.fileURL.lastPathComponent ?: @"",
                          @"detail" : label.length ? [NSString stringWithFormat:@"%@ · %@", kind, label] : kind}];
    }
    return rows;
}

static NSString* Title(NSString* format, SPDFMacFriendsSendPlan* plan) {
    return [NSString stringWithFormat:format, plan.recipient.name];
}

static NSDictionary* Action(NSString* identifier, NSString* title) { return @{@"id" : identifier, @"title" : title}; }

@implementation SPDFMacFriendsSendCards {
    id<SPDFMacFriendsIntentSender> (^_sender)(void);
    NSMutableArray<SPDFMacFriendsSendCard*>* _cards; // oldest first
    id _watch;
    id<SPDFMacFriendsIntentSender> _watchSender; // the link the watch was made on, which must also end it
    NSSet<NSString*>* _watched;
    // Restoring changes entries, and every change of the chat calls restore again; the nested call has nothing to do.
    BOOL _restoring;
}

- (instancetype)initWithSender:(id<SPDFMacFriendsIntentSender> (^)(void))sender {
    if (!(self = [super init])) return nil;
    _sender = [sender copy];
    _cards = [NSMutableArray array];
    return self;
}

- (void)dealloc {
    if (_watch && [_watchSender respondsToSelector:@selector(stopWatching:)]) [_watchSender stopWatching:_watch];
}

- (id<SPDFMacFriendsIntentSender>)sender { return _sender ? _sender() : nil; }

- (SPDFMacFriendsSendCard*)cardWithID:(NSString*)identifier {
    for (SPDFMacFriendsSendCard* card in _cards) if ([card.cardID isEqual:identifier]) return card;
    return nil;
}

- (void)keep:(SPDFMacFriendsSendCard*)card {
    [_cards addObject:card];
    while (_cards.count > kCardsKept) {
        NSUInteger index = [_cards indexOfObjectPassingTest:^BOOL(SPDFMacFriendsSendCard* old, NSUInteger i, BOOL* s) {
            (void)i; (void)s; return old.phase == SPDFMacFriendsCardFinal;
        }];
        [_cards removeObjectAtIndex:index == NSNotFound ? 0 : index];
    }
}

- (NSDictionary*)newCard:(SPDFMacFriendsSendPlan*)plan {
    // Literal: the person approves the characters Friends delivers, and Markdown drawn on the card could hide some
    // (a link's address, a comment, a reference definition, the end of a long code line).
    return @{SPDFMacAIActivityTitleKey : Title(@"Message for %@", plan), SPDFMacAIActivityBodyKey : plan.text,
             SPDFMacAIActivityBodyStyleKey : SPDFMacAIActivityBodyStyleLiteral,
             SPDFMacAIActivityCardKindKey : SPDFMacFriendsSendCardKind,
             SPDFMacAIActivityAttachmentsKey : CardAttachments(plan.files)};
}

- (NSString*)proposePlan:(SPDFMacFriendsSendPlan*)plan activity:(id<SPDFMacAIActivityReporting>)activity {
    // Longer text could not be shown whole, and the person must see every character they approve.
    if ([plan.text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > SPDFMacFriendsCheckedMessageLengthMax) return nil;
    NSString* identifier = [activity addCard:[self newCard:plan] options:SPDFMacAIActivityOptionsNone handler:nil];
    if (!identifier) return nil;
    SPDFMacFriendsSendCard* card = [SPDFMacFriendsSendCard new];
    card.cardID = identifier;
    card.plan = plan;
    card.activity = activity;
    [self keep:card];
    [self waitForPerson:card status:SPDFMacFriendsNotSentYetNote];
    return identifier;
}

- (void)waitForPerson:(SPDFMacFriendsSendCard*)card status:(NSString*)status {
    card.phase = SPDFMacFriendsCardWaiting;
    [self show:card fields:@{SPDFMacAIActivityStateKey : SPDFMacAIActivityStateRunning,
        SPDFMacAIActivityTitleKey : Title(@"Message for %@", card.plan), SPDFMacAIActivityStatusKey : status,
        // Send is the one action the card waits for, so the chat draws it as the primary button.
        SPDFMacAIActivityActionsKey : @[@{@"id" : kSendAction, @"title" : @"Send", @"primary" : @YES},
                                        Action(kDiscardAction, @"Discard")],
        SPDFMacAIActivityInterruptedStatusKey : @"Not sent. Ask the assistant again if you still want to send it."}];
}

- (void)queuePlan:(SPDFMacFriendsSendPlan*)plan sender:(id<SPDFMacFriendsIntentSender>)sender
          outcome:(SPDFMacFriendsSendOutcome)outcome {
    // A card with no entry: the same send, nothing shown here and nothing kept.
    SPDFMacFriendsSendCard* card = [SPDFMacFriendsSendCard new];
    card.plan = plan;
    card.cardID = @"";
    [self queue:card sender:sender outcome:outcome];
}

// Shows `fields` and remembers them for a reopened chat; actions get this object's handler.
- (void)show:(SPDFMacFriendsSendCard*)card fields:(NSDictionary*)fields {
    card.shown = fields;
    [self apply:card];
}

- (void)apply:(SPDFMacFriendsSendCard*)card {
    id<SPDFMacAIActivityReporting> activity = card.activity;
    if (!card.cardID.length || !activity) return;
    [activity updateEntry:card.cardID changes:card.shown];
    if (![card.shown[SPDFMacAIActivityActionsKey] count]) return;
    __weak SPDFMacFriendsSendCards* weakSelf = self;
    NSString* identifier = card.cardID;
    [activity setHandler:^(NSString* action) { [weakSelf perform:action onCard:identifier]; } forEntry:identifier];
}

- (void)forget:(SPDFMacFriendsSendCard*)card { [_cards removeObject:card]; }

// The card's body, as the chat holds it now, is exactly the text Send queues.
- (BOOL)cardShowsItsPlan:(SPDFMacFriendsSendCard*)card {
    id<SPDFMacAIActivityReporting> activity = card.activity;
    if (![activity isKindOfClass:SPDFMacAIChatActivity.class]) return NO; // nothing to read back, so nothing goes
    for (NSDictionary* entry in [(SPDFMacAIChatActivity*)activity entries])
        if ([entry[SPDFMacAIActivityIDKey] isEqual:card.cardID])
            return [entry[SPDFMacAIActivityBodyKey] isEqual:card.plan.text] && SPDFMacAIActivityBodyIsLiteral(entry);
    return NO;
}

- (void)perform:(NSString*)action onCard:(NSString*)identifier {
    SPDFMacFriendsSendCard* card = [self cardWithID:identifier];
    if (!card) return;
    if ([action isEqual:kShowAction] && self.showMessage && card.record.messageID.length) {
        self.showMessage(card.record.recipient.conversationID, card.record.messageID);
    } else if ([action isEqual:kSendAction] && card.phase == SPDFMacFriendsCardWaiting) {
        if (![self cardShowsItsPlan:card]) {
            // What Send would queue is no longer what the card shows (a chat file changed behind the chat): the
            // person approves only text they can read, so nothing goes.
            [self show:card fields:@{SPDFMacAIActivityStateKey : SPDFMacAIActivityStateFailed,
                SPDFMacAIActivityTitleKey : Title(@"Not sent to %@", card.plan),
                SPDFMacAIActivityStatusKey : @"This message changed after the assistant wrote it, so it wasn’t sent. "
                                              "Ask the assistant again.", SPDFMacAIActivityActionsKey : @[]}];
            [self forget:card];
            return;
        }
        id<SPDFMacFriendsIntentSender> sender = [self sender];
        if (!sender.friendsReady) {
            [self waitForPerson:card status:@"Friends isn’t connected, so nothing was sent. Open Friends, then press "
                                             "Send again."];
            return;
        }
        [self queue:card sender:sender outcome:nil];
    } else if ([action isEqual:kDiscardAction] && card.phase == SPDFMacFriendsCardWaiting) {
        [self show:card fields:@{SPDFMacAIActivityStateKey : SPDFMacAIActivityStateStopped,
            SPDFMacAIActivityTitleKey : Title(@"Not sent to %@", card.plan),
            SPDFMacAIActivityStatusKey : @"You discarded this message.", SPDFMacAIActivityActionsKey : @[]}];
        [self forget:card];
    } else if ([action isEqual:SPDFMacAIActivityActionCancel] && card.phase == SPDFMacFriendsCardQueued) {
        [self withdraw:card];
    }
}

- (void)queue:(SPDFMacFriendsSendCard*)card sender:(id<SPDFMacFriendsIntentSender>)sender
      outcome:(SPDFMacFriendsSendOutcome)outcome {
    SPDFMacFriendsSendPlan* plan = card.plan;
    card.phase = SPDFMacFriendsCardSending;
    [self show:card fields:@{SPDFMacAIActivityStateKey : SPDFMacAIActivityStateRunning,
        SPDFMacAIActivityTitleKey : Title(@"Message for %@", plan), SPDFMacAIActivityStatusKey : @"Sending…",
        SPDFMacAIActivityActionsKey : @[], SPDFMacAIActivityInterruptedStatusKey :
            Title(@"This chat closed while sending. Check your chat with %@.", plan)}];
    NSMutableArray* files = [NSMutableArray array];
    for (SPDFMacAIRequestChip* file in plan.files) [files addObject:SPDFMacFriendsFileObject(file)];
    // The card's own text: exactly what the person read on it.
    NSMutableDictionary* fields = [@{@"conversation_id" : plan.recipient.conversationID, @"text" : plan.text,
                                     @"client_token" : ClientToken(), @"via_assistant" : @YES} mutableCopy];
    if (files.count) fields[@"attachments"] = files;
    SPDFMacFriendsSendOutcome done = [outcome copy];
    // Held until Friends answers (the sender keeps the block only that long), so the outcome always runs once.
    SPDFMacFriendsSendCards* cards = self;
    [sender sendIntent:@"send_message" fields:fields reply:^(NSDictionary* result, NSString* code, NSString* message) {
        SPDFMacFriendsSendRecord* record = nil;
        if (code) {
            [cards card:card failed:code message:message];
        } else {
            id messageID = result[@"message_id"], transfers = result[@"transfer_ids"];
            record = [[SPDFMacFriendsSendRecord alloc] initWithPlan:plan
                messageID:[messageID isKindOfClass:NSString.class] ? messageID : nil
                transfers:[transfers isKindOfClass:NSArray.class] ? transfers : nil];
            [cards card:card queued:record sender:sender];
        }
        if (done) done(record, code, message);
    }];
}

- (void)card:(SPDFMacFriendsSendCard*)card failed:(NSString*)code message:(NSString*)message {
    NSString* status = nil;
    if ([code isEqual:@"connection_lost"]) {
        // The helper may have queued it before the connection dropped: nothing is retried behind the person's back.
        status = Title(@"Friends stopped responding, so this may not have been sent. Check your chat with %@.",
                       card.plan);
    } else {
        status = message.length ? message : @"Friends couldn’t send it.";
    }
    NSString* title = [code isEqual:@"connection_lost"] ? @"Message for %@" : @"Not sent to %@";
    [self show:card fields:@{SPDFMacAIActivityStateKey : SPDFMacAIActivityStateFailed,
        SPDFMacAIActivityTitleKey : Title(title, card.plan), SPDFMacAIActivityStatusKey : status,
        SPDFMacAIActivityActionsKey : @[]}];
    [self forget:card];
}

- (NSArray*)showActions:(SPDFMacFriendsSendCard*)card {
    return self.showMessage && card.record.messageID.length ? @[Action(kShowAction, @"Show")] : @[];
}

// Show, and Cancel while Friends can still take all of it back: offers always can be withdrawn, a message's text
// only while it is queued or connecting (`waiting`) and only when the helper says so (messages.cancel, the
// cancel_message intent). A Cancel that left the text on its way would tell the person something false.
- (NSArray*)queuedActions:(SPDFMacFriendsSendCard*)card sender:(id<SPDFMacFriendsIntentSender>)sender
                  waiting:(BOOL)waiting {
    NSMutableArray* actions = [[self showActions:card] mutableCopy];
    SPDFMacFriendsSendRecord* record = card.record;
    BOOL textCancels = !record.text.length || (waiting && !card.cancelRefused &&
        [sender.helperCapabilities containsObject:SPDFMacFriendsCancelMessageCapability]);
    if (textCancels && (record.messageID.length || record.transferIDs.count))
        [actions addObject:Action(SPDFMacAIActivityActionCancel, @"Cancel")];
    return actions;
}

- (void)card:(SPDFMacFriendsSendCard*)card queued:(SPDFMacFriendsSendRecord*)record
      sender:(id<SPDFMacFriendsIntentSender>)sender {
    card.record = record;
    card.phase = SPDFMacFriendsCardQueued;
    // Not "Sent": Friends delivers when the friend can be reached, and only its status may say it arrived. When it
    // goes is Friends' own sentence, the one under its composer.
    NSString* who = record.recipient.name, *condition = SPDFMacFriendsQueuedCondition(sender, who);
    [self show:card fields:@{SPDFMacAIActivityStateKey : SPDFMacAIActivityStateRunning,
        SPDFMacAIActivityTitleKey : Title(@"Message for %@", card.plan),
        SPDFMacAIActivityStatusKey : SPDFMacFriendsQueuedStatus(who, condition, [self showActions:card].count > 0),
        SPDFMacAIActivityActionsKey : [self queuedActions:card sender:sender waiting:YES],
        SPDFMacAIActivityInterruptedStatusKey : SPDFMacFriendsQueuedStatus(who, condition, NO)}];
}

// Friends' delivery status for queued messages in the open chat: on its way in Friends' words ("Connecting to
// Mei…"), back to the condition when it waits again, and "Sent to Mei" once delivered.
- (void)statusesArrived:(NSDictionary<NSString*, NSDictionary*>*)statuses {
    for (SPDFMacFriendsSendCard* card in [_cards copy]) {
        NSDictionary* status = card.phase == SPDFMacFriendsCardQueued ? statuses[card.record.messageID] : nil;
        if (![status isKindOfClass:NSDictionary.class]) continue;
        NSString* state = status[@"state"], *label = status[@"label"];
        BOOL delivered = [state isEqual:@"delivered"], failed = [state isEqual:@"failed"];
        // Withdrawn with Cancel in the Friends conversation: nothing more will go.
        BOOL cancelled = [state isEqual:@"cancelled"];
        if (!delivered && !failed && !cancelled) {
            [self card:card movingAs:state label:[label isKindOfClass:NSString.class] ? label : nil];
            continue;
        }
        card.phase = SPDFMacFriendsCardFinal;
        // A message cancelled in the conversation reads as one cancelled here: the same words, and no Show, since
        // nothing went that the chat could show.
        NSMutableDictionary* fields = [@{SPDFMacAIActivityActionsKey : cancelled ? @[] : [self showActions:card],
            SPDFMacAIActivityStateKey : delivered ? SPDFMacAIActivityStateDone
                : cancelled ? SPDFMacAIActivityStateStopped : SPDFMacAIActivityStateFailed,
            SPDFMacAIActivityTitleKey : Title(delivered ? @"Sent to %@" : @"Not sent to %@", card.plan)} mutableCopy];
        // Friends' words for the person ("Delivered", "Not delivered. Stopped trying after 30 days.").
        BOOL worded = [label isKindOfClass:NSString.class] && label.length;
        fields[SPDFMacAIActivityStatusKey] = cancelled
            ? CancelledStatus(worded ? label : nil, card.record.recipient.name)
            : worded ? label : delivered ? @"Delivered"
            : Title(@"Friends couldn’t deliver it. Your chat with %@ says why.", card.plan);
        [self show:card fields:fields];
    }
}

// A queued message Friends is still working on. Connecting and sending say so in Friends' words; queued (again)
// shows the condition. Cancel stays while it is queued or connecting and goes once Friends is sending it. Unchanged
// words and actions change nothing, so a snapshot that only repeats them costs nothing.
- (void)card:(SPDFMacFriendsSendCard*)card movingAs:(NSString*)state label:(NSString*)label {
    NSString* who = card.record.recipient.name;
    id<SPDFMacFriendsIntentSender> sender = [self sender];
    BOOL moving = ([state isEqual:@"connecting"] || [state isEqual:@"sending"]) && label.length;
    NSString* status = moving ? label
        : SPDFMacFriendsQueuedStatus(who, SPDFMacFriendsQueuedCondition(sender, who),
                                     [self showActions:card].count > 0);
    NSArray* actions = [self queuedActions:card sender:sender waiting:![state isEqual:@"sending"]];
    if ([card.shown[SPDFMacAIActivityStatusKey] isEqual:status] &&
        [card.shown[SPDFMacAIActivityActionsKey] isEqual:actions])
        return;
    NSMutableDictionary* fields = [card.shown mutableCopy];
    fields[SPDFMacAIActivityStatusKey] = status;
    fields[SPDFMacAIActivityActionsKey] = actions;
    [self show:card fields:fields];
}

- (void)restoreCardsInActivity:(SPDFMacAIChatActivity*)activity {
    if (_restoring) return;
    _restoring = YES;
    NSMutableSet<NSString*>* present = [NSMutableSet set];
    if (_cards.count) {
        NSMutableDictionary<NSString*, NSDictionary*>* entries = [NSMutableDictionary dictionary];
        for (NSDictionary* entry in activity.entries)
            if ([entry[SPDFMacAIActivityCardKindKey] isEqual:SPDFMacFriendsSendCardKind])
                entries[entry[SPDFMacAIActivityIDKey]] = entry;
        for (SPDFMacFriendsSendCard* card in [_cards copy]) {
            NSDictionary* entry = entries[card.cardID];
            if (!entry) continue;
            [present addObject:card.cardID];
            card.activity = activity;
            // Reopening reloads the entry without handlers, and turns a running one into its interrupted status.
            BOOL reloaded = ![entry[SPDFMacAIActivityStateKey] isEqual:card.shown[SPDFMacAIActivityStateKey]];
            BOOL lostActions = [card.shown[SPDFMacAIActivityActionsKey] count] &&
                ![activity liveActionsForEntry:card.cardID].count;
            if (reloaded || lostActions) [self apply:card];
        }
    }
    [self watchQueuedCards:present];
    _restoring = NO;
}

// Watches exactly the queued messages whose cards the open chat shows; the first status arrives at once, so a chat
// reopened after delivery says so straight away.
- (void)watchQueuedCards:(NSSet<NSString*>*)present {
    NSMutableSet<NSString*>* messages = [NSMutableSet set];
    for (SPDFMacFriendsSendCard* card in _cards)
        if (card.phase == SPDFMacFriendsCardQueued && card.record.messageID.length && [present containsObject:
            card.cardID])
            [messages addObject:card.record.messageID];
    if (_watch && [messages isEqual:_watched]) return;
    if (!_watch && !messages.count) return;
    if (_watch && [_watchSender respondsToSelector:@selector(stopWatching:)]) [_watchSender stopWatching:_watch];
    _watch = nil;
    _watchSender = nil;
    _watched = nil;
    id<SPDFMacFriendsIntentSender> sender = messages.count ? [self sender] : nil;
    if (![sender respondsToSelector:@selector(watchMessages:handler:)]) return;
    __weak SPDFMacFriendsSendCards* weakSelf = self;
    // Sorted so the same messages always make the same request.
    NSArray* identifiers = [messages.allObjects sortedArrayUsingSelector:@selector(compare:)];
    _watch = [sender watchMessages:identifiers handler:^(NSDictionary<NSString*, NSDictionary*>* statuses) {
        [weakSelf statusesArrived:statuses];
    }];
    if (!_watch) return; // the helper cannot report it: the card keeps saying where to look
    _watchSender = sender;
    _watched = [messages copy];
}

// Cancel: withdraws the message (when the helper can) and every offer; what already arrived stays.
- (void)withdraw:(SPDFMacFriendsSendCard*)card {
    id<SPDFMacFriendsIntentSender> sender = [self sender];
    SPDFMacFriendsSendRecord* record = card.record;
    NSString* who = record.recipient.name;
    if (!sender.friendsReady) {
        NSString* status = @"Friends isn’t connected, so it can’t be cancelled right now.";
        [card.activity updateEntry:card.cardID changes:@{SPDFMacAIActivityStatusKey : status}];
        return;
    }
    NSMutableArray* intents = [NSMutableArray array];
    if (record.text.length && record.messageID.length)
        [intents addObject:@[@"cancel_message", @{@"message_id" : record.messageID}]];
    for (NSString* transfer in record.transferIDs)
        [intents addObject:@[@"cancel_transfer", @{@"transfer_id" : transfer}]];
    card.phase = SPDFMacFriendsCardSending;
    NSMutableDictionary* cancelling = [card.shown mutableCopy];
    cancelling[SPDFMacAIActivityStatusKey] = @"Cancelling…";
    cancelling[SPDFMacAIActivityActionsKey] = @[];
    [self show:card fields:cancelling];
    __block NSUInteger pending = intents.count, cancelled = 0;
    __block NSString* refusal = nil;
    SPDFMacFriendsSendCards* cards = self;
    for (NSArray* intent in intents) {
        [sender sendIntent:intent[0] fields:intent[1] reply:^(NSDictionary* result, NSString* code, NSString* message) {
            (void)result;
            if (code) refusal = refusal ?: message; else cancelled++;
            if (code && [intent[0] isEqual:@"cancel_message"]) card.cancelRefused = YES;
            if (--pending) return;
            if (cancelled == intents.count) {
                // As Discard says it: nothing went, so the title says so too.
                [cards show:card fields:@{SPDFMacAIActivityStateKey : SPDFMacAIActivityStateStopped,
                    SPDFMacAIActivityTitleKey : Title(@"Not sent to %@", card.plan),
                    SPDFMacAIActivityStatusKey : CancelledStatus(nil, who), SPDFMacAIActivityActionsKey : @[]}];
                [cards forget:card];
                return;
            }
            NSMutableDictionary* fields = [card.shown mutableCopy];
            fields[SPDFMacAIActivityActionsKey] = [cards showActions:card];
            if (cancelled) {
                card.phase = SPDFMacFriendsCardFinal;
                fields[SPDFMacAIActivityStateKey] = SPDFMacAIActivityStateDone;
                fields[SPDFMacAIActivityStatusKey] = [NSString stringWithFormat:@"Partly cancelled: some of it had "
                                                                                 "already gone out to %@.", who];
            } else {
                // Too late can mean on its way or delivered; the helper's own words say which when it has them.
                card.phase = SPDFMacFriendsCardQueued;
                fields[SPDFMacAIActivityStatusKey] = refusal.length ? refusal
                    : [NSString stringWithFormat:@"Too late to cancel: it had already gone out to %@.", who];
            }
            [cards show:card fields:fields];
        }];
    }
}

@end
