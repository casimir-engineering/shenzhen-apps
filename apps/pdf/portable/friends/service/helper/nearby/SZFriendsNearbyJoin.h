// Joining a profile inside the helper (PROTOCOL.md § Joining; service/identity/SZFriendsJoin.h for the exchange).
// Internal to nearby/: SZFriendsNearbyService+Join.m carries the exchange nearby over NN, +JoinOnline.m through the
// Friends host, and both hand every message to the same code through a pipe, so the two paths cannot disagree.
//
// Everything is in memory. A restart forgets waiting rows and approvals (the new computer repeats its request, and
// the person approves again); the code never reaches a disk or a log.

#import "service/helper/nearby/SZFriendsNearbyInternal.h"
#import "service/identity/SZFriendsJoin.h"
#import "service/presentation/SZFriendsPresentationJoin.h"

NS_ASSUME_NONNULL_BEGIN

// One session carrying join messages, nearby (an NN link) or online (NN signalling over a sid).
@protocol SZFriendsJoinPipe <NSObject>
@property(nonatomic, readonly, nullable) NSData *handshakeHash;
- (BOOL)sendJoinMessages:(NSArray<NSData *> *)messages;
// Nearby: RECEIVED, what every device says; online: nothing (silence is the same answer there).
- (void)sendReceived;
// Lets the session go once what was sent has left.
- (void)finish;
@end

// One sid as joining uses it: the driver's (SZFriendsOnlineDriver+Join.m) or a test's.
typedef void (^SZFriendsJoinOpener)(NSString *friendsID, NSData *payload,
                                    void (^completion)(id<SZFriendsOnlineJoinChannel> _Nullable channel));

@interface SZFriendsJoinState : NSObject
// The person's other computers: requests heard, approvals given (created on first use).
@property(nonatomic, strong, nullable) SZFriendsJoinApprover *approver;
// The new computer.
@property(nonatomic, strong, nullable) SZFriendsJoiner *joiner;
@property(nonatomic) SZFriendsJoiningState phase;
@property(nonatomic, copy, nullable) NSString *code;     // being tried
@property(nonatomic) NSUInteger generation;              // each request and each code is a new one
@property(nonatomic) NSUInteger legsOutstanding;         // code sessions not yet over
@property(nonatomic) BOOL wrongReply;                    // a device answered the code and its tag did not verify
@property(nonatomic, copy, nullable) NSDate *requestSentOnlineAt;
// Sessions carrying a run, by pipe: the new computer's attempts, the approving computer's approvals.
@property(nonatomic, readonly) NSMapTable<id, SZFriendsJoinAttempt *> *attempts;
@property(nonatomic, readonly) NSMapTable<id, SZFriendsJoinApproval *> *approvals;
// Tests only: opens by Friends ID go here instead of to the online driver.
@property(nonatomic, copy, nullable) SZFriendsJoinOpener testOpener;
@property(nonatomic, strong, nullable) SZFriendsReplayCache *replayCache; // online NN message 1s answered
@end

// Wire values of a join open's payload (sig_open to a Friends ID): 'J', then the kind.
extern const uint8_t SZFriendsJoinOpenPrefix;        // 'J'
extern const uint8_t SZFriendsJoinOpenRequest;       // 1: a Request message follows; nobody answers
extern const uint8_t SZFriendsJoinOpenCode;          // 2: NN message 1 follows; only an approving device answers
// How long a code waits for an answer from every session it went out on.
extern const NSTimeInterval SZFriendsJoinCodeWindow; // 10 s
// The new computer repeats its request this often online (the host allows 5 opens by ID an hour) and nearby once per
// presence window per device, while it waits.
extern const NSTimeInterval SZFriendsJoinOnlineRepeat; // 1,200 s

@interface SZFriendsNearbyService (Join)
@property(nonatomic, readonly) SZFriendsJoinState *joinState;

// What snapshots show. Joining is offered while this computer has nobody in Friends and no other computer.
- (BOOL)joinAvailable;
- (SZFriendsJoiningFacts *)joiningFacts;
- (NSArray<SZFriendsJoinRequestFacts *> *)joinRequestFacts;
// A request arrived: a notification for each request the notifier has not heard of (ADR 0017).
- (void)notifyJoinRequests;

// Intents. Each returns nil, or the error code to reply with.
- (nullable NSString *)startJoiningFriendsID:(NSString *)friendsID;
- (nullable NSString *)tryJoinCode:(NSString *)code;
- (void)cancelJoining;
- (nullable NSString *)approveJoinID:(NSString *)joinID;
- (nullable NSString *)denyJoinID:(NSString *)joinID;
// Reset Friends: nothing waits and nothing is being joined.
- (void)forgetJoins;

// Either path: a message on a pipe. `initiator`: this side opened the session (the new computer).
- (void)pipe:(id<SZFriendsJoinPipe>)pipe receivedJoinMessage:(NSData *)message initiator:(BOOL)initiator;
- (void)pipeEnded:(id<SZFriendsJoinPipe>)pipe;
// The new computer: one code session started.
- (void)beginCodeLegOnPipe:(id<SZFriendsJoinPipe>)pipe;
@end

@interface SZFriendsNearbyService (JoinNearby)
// Nearby (+JoinNearby.m): the new computer's NN sessions to every device it cannot recognise, once per presence window
// for the request and once per code; every device's side of a JOIN frame; a session's end.
- (void)offerJoinNearby;
- (void)joinLinkWentLive:(SZFriendsPeerLink *)link;
- (void)link:(SZFriendsPeerLink *)link receivedJoinFrame:(SZFriendsFrame *)frame;
- (void)joinLinkEnded:(SZFriendsPeerLink *)link;
@end

@interface SZFriendsNearbyService (JoinOnline)
// The new computer: its request through the host (first, then every SZFriendsJoinOnlineRepeat), and its code.
- (void)offerJoinOnline;
- (void)sendJoinCodeOnline;
// Every computer of the person: an open by Friends ID that carries a join payload (the driver's delegate).
- (void)receiveJoinOpenPayload:(NSData *)payload channel:(id<SZFriendsOnlineJoinChannel>)channel;
@end

NS_ASSUME_NONNULL_END
