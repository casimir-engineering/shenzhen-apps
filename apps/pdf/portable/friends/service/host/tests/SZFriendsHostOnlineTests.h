// The host suite's protocol 2 groups (SZFriendsHostRendezvous.h): scripted sockets in SZFriendsHostOnlineTests.m and
// the Node service with online Friends on in SZFriendsHostOnlineServerTests.m. Run by SZFriendsHostTests.m.

#import "SZFriendsHostHarness.h"
#import "SZFriendsHostTestSupport.h"
#import "service/host/SZFriendsHostRendezvous.h"

NS_ASSUME_NONNULL_BEGIN

// Records the online side's callbacks; thread-safe. Each incoming signal keeps what arrives on it.
@interface SZFHOnlineRecorder : NSObject <SZFriendsHostOnlineDelegate>
- (NSArray<NSString *> *)events; // "available 1", "incoming <via> <payload as UTF-8>", "ended <reason>"
- (BOOL)saw:(NSString *)event;
- (NSArray<SZFriendsHostSignal *> *)incoming;
- (NSArray<NSData *> *)payloadsOn:(SZFriendsHostSignal *)signal; // after the first, which is in the event
- (void)watch:(SZFriendsHostSignal *)signal; // records an outgoing signal's payloads and end too
@end

// Runs `block` on `queue` and waits for it: the online API is used only on the client's queue.
void SZFHOnQueue(dispatch_queue_t queue, void (^block)(void));
NSData *SZFHUTF8(NSString *text);
// "ended <reason>", as SZFHOnlineRecorder records an end.
NSString *SZFHEnded(SZFriendsHostSignalEnd reason);

// The scripted harness (SZFriendsHostHarness.h) with main-hk also a relay listing TURN URIs, the online side's
// delegate and record provider set.
SZFHHarness *SZFHOnlineHarness(SZFHOnlineRecorder *recorder, NSData *_Nullable (^_Nullable provider)(void));
// The client's latest message of `type` on `socket`.
NSDictionary *_Nullable SZFHLast(SZFHFakeSocket *socket, NSString *type);

void SZFHRunOnlineTests(void);
void SZFHRunOnlineSignalTests(void);
void SZFHRunOnlineServerTests(void);

NS_ASSUME_NONNULL_END
