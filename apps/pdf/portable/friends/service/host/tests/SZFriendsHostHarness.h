// The scripted check-in harness the client suites share: a list cache with two rendezvous hosts (main-hk with
// two URLs, then alt-sg) whose host keys the harness holds, a client whose sockets are SZFHFakeSocket, and helpers
// that play the host's side of the protocol. No network.

#import "SZFriendsHostTestSupport.h"

NS_ASSUME_NONNULL_BEGIN

@interface SZFHHarness : NSObject
@property(nonatomic) dispatch_queue_t queue;
@property(nonatomic) SZFriendsHostListCache *cache;
@property(nonatomic) SZFriendsCheckInClient *client;
@property(nonatomic) SZFHRecorder *recorder;
@property(nonatomic) SZFHTestIdentity *identity;
@property(nonatomic) SZFHSigner *signer;
@property(nonatomic) SZFHSigner *mainHost; // main-hk's host key
@property(nonatomic) SZFHSigner *altHost;  // alt-sg's
@property(nonatomic) NSMutableArray<SZFHFakeSocket *> *sockets;
@property(nonatomic) NSMutableArray<NSString *> *providedIDs;
@end

// The challenge every scripted host sends.
extern NSString *const SZFHNonce;

SZFHHarness *SZFHMakeHarness(void);
// The client's socket number `index`, waiting up to 3 s for it to be opened.
SZFHFakeSocket *_Nullable SZFHSocket(SZFHHarness *h, NSUInteger index);
// Starts the client with an ID provider: maple-river first, then SZFHDrawID(collisions).
void SZFHStart(SZFHHarness *h);
// Delivers the challenge and returns the check-in the client sent in answer.
NSDictionary *SZFHChallenge(SZFHHarness *h, SZFHFakeSocket *socket, NSString *hostID);
// The ID the client's latest message on `socket` asked for: what the host's answer is signed for.
NSString *_Nullable SZFHLastRequested(SZFHFakeSocket *socket);
// Delivers `reply` signed by the host that socket reached, for the client's latest request.
void SZFHReply(SZFHHarness *h, SZFHFakeSocket *socket, NSDictionary *reply);
// A signed welcome with update_required NO unless `fields` says otherwise.
void SZFHWelcome(SZFHHarness *h, SZFHFakeSocket *socket, NSDictionary *fields);

NS_ASSUME_NONNULL_END
