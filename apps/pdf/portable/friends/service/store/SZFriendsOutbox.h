// Shenzhen Friends outbox: everything waiting to reach a friend, and the state machine it moves through.
//
// Helper-only; persisted in friends.sqlite beside SZFriendsStore. Requests, messages and offers share one queue
// per recipient (brief § Outbox and delivery). Delivered means the recipient's helper acknowledged after its own
// transaction committed, not that a socket write succeeded and not that anyone read it. Retries are idempotent:
// each entry keeps its random 128-bit id, and the recipient deduplicates by sender key and id.
//
// Nothing waits forever without saying so: an entry still unsent 30 days after it was queued (or last retried)
// becomes Failed with SZFriendsOutboxFailureNotDelivered30Days, which the presentation shows as "Not delivered in
// 30 days" with Try again. Removing or blocking someone tells them nothing; their entries expire the same way.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// PROTOCOL.md message.status.state uses the same names in lowercase.
typedef NS_ENUM(NSInteger, SZFriendsOutboxState) {
    SZFriendsOutboxStateQueued = 0,     // no route to the recipient right now
    SZFriendsOutboxStateConnecting = 1, // a route is being dialed
    SZFriendsOutboxStateSending = 2,    // written to a session; waiting for the durable acknowledgement
    SZFriendsOutboxStateDelivered = 3,  // terminal: acknowledged by the recipient's Mac
    SZFriendsOutboxStateFailed = 4,     // terminal until retried: refused or impossible (source gone, blocked)
};

typedef NS_ENUM(NSInteger, SZFriendsOutboxKind) {
    SZFriendsOutboxKindRequest = 0,        // nearby request (XX) or Add by ID (NN, ADR 0004)
    SZFriendsOutboxKindMessage = 1,
    SZFriendsOutboxKindOffer = 2,          // itemID is the transfer id; the entry moves its transfer (below)
    SZFriendsOutboxKindAnswer = 3,         // request answers and offer answers also need to arrive
    SZFriendsOutboxKindPresenceSecret = 4, // our new secret after a remove or block, queued to every friend left
};

// What happened, as the state machine sees it.
typedef NS_ENUM(NSInteger, SZFriendsOutboxEvent) {
    SZFriendsOutboxEventRouteAvailable = 0,
    SZFriendsOutboxEventSessionEstablished = 1,
    SZFriendsOutboxEventWritten = 2,
    SZFriendsOutboxEventAcknowledged = 3,
    SZFriendsOutboxEventSessionLost = 4,   // back to Queued; the same id is resent later
    SZFriendsOutboxEventRefused = 5,       // the recipient refused permanently (blocked, unknown offer)
    SZFriendsOutboxEventSourceMissing = 6, // an attachment's bound revision is gone
    SZFriendsOutboxEventRetry = 7,         // the user pressed Try again on a Failed entry
    SZFriendsOutboxEventExpired = 8,       // unsent for SZFriendsOutboxExpiryInterval; -expireEntriesAtDate: sends it
};

// Pure transition function; the whole policy in one place so it is tested exhaustively. Returns the next state,
// or `state` unchanged when the event does not apply (a late SessionLost, Retry on a live entry). An
// acknowledgement means the recipient's Mac committed the item, so it makes any state Delivered: showing anything
// else would be untrue for the person reading it.
SZFriendsOutboxState SZFriendsOutboxNextState(SZFriendsOutboxState state, SZFriendsOutboxEvent event);

extern const NSTimeInterval SZFriendsOutboxExpiryInterval; // 30 days

// -cancelMessage:...'s *state for an entry waiting again (Queued or Connecting) after it was written to a session that
// dropped before the acknowledgement: outside SZFriendsOutboxState, since the entry's own state is Queued.
extern const NSInteger SZFriendsOutboxCancelStateWritten;

// Why an entry is Failed (SZFriendsOutboxEntry.failureReason): stable keys the presentation catalog words.
extern NSString *const SZFriendsOutboxFailureNotDelivered30Days; // "not_delivered_30_days"
extern NSString *const SZFriendsOutboxFailureRefused;            // "refused"
extern NSString *const SZFriendsOutboxFailureSourceMissing;      // "source_missing"

@interface SZFriendsOutboxEntry : NSObject <NSCopying>
@property(nonatomic, copy) NSString *entryID;        // random 128-bit, hex; reused on every retry
@property(nonatomic, copy) NSString *conversationID;
@property(nonatomic) SZFriendsOutboxKind kind;
@property(nonatomic) SZFriendsOutboxState state;
@property(nonatomic, copy) NSDate *createdAt;
@property(nonatomic) NSUInteger attempts;            // times written to a session
@property(nonatomic, copy, nullable) NSString *itemID;   // the history item this entry delivers
@property(nonatomic, copy, nullable) NSString *clientToken; // the app's idempotency key for the intent
// When the 30-day clock started: createdAt at enqueue, reset by Try again. Set by the outbox.
@property(nonatomic, copy, nullable) NSDate *queuedAt;
@property(nonatomic, copy, nullable) NSString *failureReason; // set while Failed
// Opaque bytes the helper needs to rebuild the frame later (an answer's verdict); the outbox never reads them.
@property(nonatomic, copy, nullable) NSData *payload;
@end

@class SZFriendsStore;
@class SZFriendsItemRecord;

@interface SZFriendsOutbox : NSObject
// Shares the store's database connection and queue, so an entry and its history item commit together.
- (instancetype)initWithStore:(SZFriendsStore *)store NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// New entries start Queued whatever `state` says; an existing entry id is refused (Constraint).
- (BOOL)enqueue:(SZFriendsOutboxEntry *)entry error:(NSError **)error;
// The entry and the history item it delivers, in one transaction: either both exist afterwards or neither.
- (BOOL)enqueue:(SZFriendsOutboxEntry *)entry item:(nullable SZFriendsItemRecord *)item error:(NSError **)error;
// An intent retried after a reconnect carries the same client token; the existing entry is returned instead of
// a second one being queued.
- (nullable SZFriendsOutboxEntry *)entryWithClientToken:(NSString *)clientToken;
// Every entry one intent created (send_files makes one offer per file under one token), oldest first.
- (NSArray<SZFriendsOutboxEntry *> *)entriesWithClientToken:(NSString *)clientToken;
- (nullable SZFriendsOutboxEntry *)entryWithID:(NSString *)entryID;
// retry_item names the history item; this finds the entry delivering it.
- (nullable SZFriendsOutboxEntry *)entryForItemID:(NSString *)itemID;
// Queued, Connecting and Sending entries, oldest first: what to send when a session to this friend goes live.
- (NSArray<SZFriendsOutboxEntry *> *)pendingEntriesForConversation:(NSString *)conversationID;
- (NSArray<SZFriendsOutboxEntry *> *)allPendingEntries;
// Applies the transition and its bookkeeping in one transaction: Written counts an attempt; Failed records why;
// Retry restarts the 30-day clock. For an Offer entry the transfer follows: delivered offers become Offered, a
// failed one Failed with the same reason, and Try again queues it again. An event that does not apply is not an
// error. Unknown entry: NotFound.
- (BOOL)applyEvent:(SZFriendsOutboxEvent)event toEntry:(NSString *)entryID error:(NSError **)error;
// The same for an event a peer caused (an ACK, a refusal): the entry must be queued to `conversationID`, the
// conversation the frame arrived on, or nothing changes (Invalid, also for an empty conversation). One friend's ACK
// then never marks another friend's message delivered or their offer as offered.
- (BOOL)applyEvent:(SZFriendsOutboxEvent)event
           toEntry:(NSString *)entryID
  fromConversation:(NSString *)conversationID
             error:(NSError **)error;
// cancel_message (PROTOCOL.md § Intents): withdraws this person's outgoing message `itemID` in `conversationID` while
// its entry is Queued or Connecting and was never written to a session (attempts 0), deleting the entry and marking
// the history item cancelled in one transaction. The helper serves intents and delivery on one queue and a write
// marks its entry Sending at once, so a deleted entry can never have been written to a session. Once written it may
// already be on the friend's Mac, so nothing changes: Stale, with *state the entry's state (Sending, Delivered or
// Failed), SZFriendsOutboxCancelStateWritten for one queued again after a session dropped before its acknowledgement
// (the friend's Mac may have stored it), or -1 when no entry records its delivery. A message already cancelled
// succeeds again, so a retry after a lost reply is safe. NotFound when that conversation has no outgoing message with
// that id. Files sent with it are offers of their own and stay as they are.
- (BOOL)cancelMessage:(NSString *)itemID
       inConversation:(NSString *)conversationID
                state:(NSInteger *_Nullable)state
                error:(NSError **)error;
// Fails every entry still unsent SZFriendsOutboxExpiryInterval after its queuedAt, and returns them. The helper
// calls it at start and then periodically (hourly is plenty).
- (nullable NSArray<SZFriendsOutboxEntry *> *)expireEntriesAtDate:(NSDate *)now error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
