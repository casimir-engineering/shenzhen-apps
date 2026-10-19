// friends-links-check, end to end: real helpers through the local Node host and coturn (friends/tests/e2e's
// SZFE2EOnlineHost), and a browser stand-in that opens download links as the link page does, as a guest of the host.
// Everything stays on this Mac (127.0.0.1, and en0's address for coturn's relayed side), never the production host.
//   L1  a guest downloads directly and through the relay; a changed original, a revoked and an expired link are
//       refused; "Your links" counts the downloads;
//   L2  an app receives a download link into the sender's conversation; a friend link adds its maker, whose Mac
//       accepts at once and says so.

#import "SZFriendsE2EOnline.h"

#import "service/links/SZFriendsLinkOpening.h"
#import "service/online/transport/SZFriendsOnlineTransportInternal.h"

NS_ASSUME_NONNULL_BEGIN

@interface SZFLGuestSink : NSObject <SZFriendsLinkSink>
@property(nonatomic, strong, nullable) SZFriendsLinkMetadata *metadata;
@property(nonatomic, readonly) NSMutableData *bytes;
@end

// Opens `payloadString` ("d.<...>") as a guest at `guestURL` (ws://127.0.0.1:<port>/v1?guest=1) and downloads it;
// with `blockDirect` only relay candidates are sent or applied. Returns how it ended; `attempt` is the connection
// that carried the file (1 direct, 2 relayed).
SZFriendsLinkOutcome SZFLGuestOpen(NSURL *guestURL, NSString *_Nullable stunURI, NSString *payloadString,
                                   BOOL blockDirect, SZFLGuestSink *sink, uint8_t *_Nullable attempt);

BOOL SZFLScenarioGuests(SZFE2EWorld *world);
BOOL SZFLScenarioApps(SZFE2EWorld *world);

NS_ASSUME_NONNULL_END
