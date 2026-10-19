// The helper's glue for links (SZFriendsLinks.h): the service made on first use, the host's link opens routed to it,
// and the page origin links are made for. Internal to the helper.

#import <Foundation/Foundation.h>

#import "service/helper/SZFriendsHelperServices.h"
#import "service/links/SZFriendsLinks.h"

NS_ASSUME_NONNULL_BEGIN

@class SZFriendsHostList;
@class SZFriendsHostOnline;

// The web origin link pages are served from: the signed list's "links" entry (an https origin) when it names one,
// otherwise the main host's own (its first rendezvous URL, wss becoming https, ws becoming http). Nil for a list with
// neither, and for a "links" entry that is anything but an origin.
NSString *_Nullable SZFriendsLinkOriginForList(SZFriendsHostList *_Nullable list);

// The profile's "Your links": the friend link (its standing invite made on first use) and every live download link.
// Nil while no link can be made (no Friends host to make them for).
SZFriendsLinksFacts *_Nullable SZFriendsHelperLinksFacts(SZFriendsHelperServices *services, NSDate *now);

@interface SZFriendsHelperServices (Links)
// Made on first use (an intent, or the host taking online messages); nil without a store and an identity.
- (nullable SZFriendsLinkService *)linkService;
// The check-in client's online side is attached: opens via a link id reach the link service, everything else the
// online driver as before, and live links are registered whenever the host takes online messages.
- (void)attachLinksToHostOnline:(SZFriendsHostOnline *)online;
@end

NS_ASSUME_NONNULL_END
