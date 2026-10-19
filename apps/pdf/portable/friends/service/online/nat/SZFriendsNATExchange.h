// One UDP request/answer exchange with one server, for PCP and NAT-PMP (internal to service/online/nat/).
//
// The socket is connected to the server, so the kernel drops datagrams from anyone else and an ICMP "port
// unreachable" surfaces as ECONNREFUSED: the gateway's own "no" (ADR 0011: it ends the exchange at once). Answers
// longer than SZFriendsPCPMessageMax are dropped unread.

#import "service/online/nat/SZFriendsNAT.h"

NS_ASSUME_NONNULL_BEGIN

typedef BOOL (^SZFriendsNATExchangeAccept)(NSData *answer);
typedef void (^SZFriendsNATExchangeCompletion)(NSData *_Nullable answer, NSError *_Nullable error);

@interface SZFriendsNATExchange : NSObject
// Nil when no socket could be made, bound to `bindAddress` (when given) or connected to `server`.
- (nullable instancetype)initWithServer:(SZFriendsNATEndpoint *)server
                            bindAddress:(nullable SZFriendsNATEndpoint *)bindAddress
                                  queue:(dispatch_queue_t)queue NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// The socket's own address after connecting: the client address PCP puts in its header.
@property(nonatomic, readonly) SZFriendsNATEndpoint *localEndpoint;

// Sends `request` now and again at each of `retransmits` (seconds after the first send), until `accept` takes an
// answer, the socket reports the port unreachable (SZFriendsNATErrorRefused), or `budget` passes
// (SZFriendsNATErrorTimedOut). One exchange at a time; the completion runs once, on the queue.
- (void)sendRequest:(NSData *)request
        retransmits:(NSArray<NSNumber *> *)retransmits
             budget:(NSTimeInterval)budget
             accept:(SZFriendsNATExchangeAccept)accept
         completion:(SZFriendsNATExchangeCompletion)completion;
// Sends without waiting for anything (a delete on close). Cancels a running exchange first.
- (void)sendOnly:(NSData *)request;
// Stops the running exchange without calling its completion, and closes the socket. Idempotent.
- (void)close;
@end

NS_ASSUME_NONNULL_END
