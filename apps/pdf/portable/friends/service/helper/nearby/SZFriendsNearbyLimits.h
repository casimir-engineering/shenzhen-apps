// What someone who is not a friend may cost this helper, and for how long (ADR 0001 review item 4, ADR 0004
// § Hidden listeners, § Public visibility, § Add by ID nearby). Internal to the helper's nearby/.
//
// Three layers, cheapest first:
//   1. Admission rates, which the adapters apply per listener and per remote address when a connection's preamble
//      names its pattern, before any Diffie-Hellman (SZFriendsAdmissionLimits; the helper only chooses the numbers):
//      XX on the public entry 20 a minute and 3 a minute per address, NN 60 a minute and 6 a minute per address (one
//      host opening 60 NN sessions a minute kept everyone else's Add by ID out; wave-4 re-check). WHY XX at all: each
//      XX session that reaches a request is one comparison-code attempt, so the rate bounds code grinding together
//      with the rule that a code is exchanged only once the request is recorded (ADR 0001 § Comparison codes).
//   2. At most SZFriendsStrangerSessionsMax sessions with people who are not friends at once, checked by the key
//      policy; friends are never refused for it. When the cap is full the newcomer takes the place of the stranger
//      session that has been idle longest, so whoever opened the sessions first cannot keep everyone else out.
//   3. Lifetimes: a session with someone who is not a friend closes SZFriendsStrangerIdleTimeout after the last frame
//      that moved their request forward (the first PROFILE, REQUEST and answer, an ACK of something we sent), and
//      SZFriendsStrangerSessionLife after it went live whatever it carries; an NN session closes
//      SZFriendsByIDReplyLinger after its RECEIVED, the same on every device, so nothing about the close tells who
//      holds the ID.
//   4. Pending requests (ADR 0004 § Hidden listeners, wave-3 review): someone whose request we have not answered may
//      open IK to our hidden listener only within SZFriendsIncomingRequestIKWindow of asking, because their request
//      taught them our static key and IK answered by us alone would let them find our device in every window. A
//      request nobody answers lapses after the store's SZFriendsIncomingRequestLifetime (14 days). Our own requests
//      are bounded the same way (+KeyPolicy, the store's SZFriendsOutgoingRequestLifetime), and a request that came
//      by Friends ID never opens IK at all.

#import <Foundation/Foundation.h>

#import "service/discovery/SZFriendsDiscovery.h"

NS_ASSUME_NONNULL_BEGIN

extern const NSUInteger SZFriendsAdmissionXXPerMinute;           // 20 per listener
extern const NSUInteger SZFriendsAdmissionXXPerAddressPerMinute; // 3
extern const NSUInteger SZFriendsAdmissionNNPerMinute;           // 60 per listener (ADR 0004 step 2)
extern const NSUInteger SZFriendsAdmissionNNPerAddressPerMinute; // 6
extern const NSUInteger SZFriendsStrangerSessionsMax;            // 64
extern const NSTimeInterval SZFriendsStrangerIdleTimeout;        // 60 s
extern const NSTimeInterval SZFriendsStrangerSessionLife;        // 180 s
extern const NSTimeInterval SZFriendsIncomingRequestIKWindow;    // 6 hours after their request
extern const NSTimeInterval SZFriendsByIDReplyLinger;            // 2 s
extern const NSTimeInterval SZFriendsByIDSessionLife;            // 10 s: an NN session carries one request, briefly

// The adapters' defaults (the caps on connections not yet authenticated) with the rates above.
SZFriendsAdmissionLimits *SZFriendsNearbyAdmissionLimits(void);

NS_ASSUME_NONNULL_END
