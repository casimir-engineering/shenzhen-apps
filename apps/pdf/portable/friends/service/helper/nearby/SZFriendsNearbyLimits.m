// The numbers of SZFriendsNearbyLimits.h.

#import "service/helper/nearby/SZFriendsNearbyLimits.h"

const NSUInteger SZFriendsAdmissionXXPerMinute = 20;
const NSUInteger SZFriendsAdmissionXXPerAddressPerMinute = 3;
const NSUInteger SZFriendsAdmissionNNPerMinute = 60;
// An honest device sends one Add by ID request per device it sees and retries after minutes, so 6 a minute from one
// address leaves room for several people on one Mac or behind one NAT, and none for a flood.
const NSUInteger SZFriendsAdmissionNNPerAddressPerMinute = 6;
const NSUInteger SZFriendsStrangerSessionsMax = 64;
const NSTimeInterval SZFriendsStrangerIdleTimeout = 60;
// Three minutes: long enough to deliver a request, compare codes and answer, too short to camp in a slot.
const NSTimeInterval SZFriendsStrangerSessionLife = 180;
// Six hours: a requester who found us nearby and withdraws soon after asking can still reach us with CANCEL; after
// that only our answer travels, over the IK we dial. A request by Friends ID gets no window (+KeyPolicy).
const NSTimeInterval SZFriendsIncomingRequestIKWindow = 6 * 60 * 60;
const NSTimeInterval SZFriendsByIDReplyLinger = 2;
const NSTimeInterval SZFriendsByIDSessionLife = 10;

SZFriendsAdmissionLimits *SZFriendsNearbyAdmissionLimits(void) {
    SZFriendsAdmissionLimits *limits = [SZFriendsAdmissionLimits defaultLimits];
    limits.xxPerMinutePerListener = SZFriendsAdmissionXXPerMinute;
    limits.xxPerMinutePerAddress = SZFriendsAdmissionXXPerAddressPerMinute;
    limits.nnPerMinutePerListener = SZFriendsAdmissionNNPerMinute;
    limits.nnPerMinutePerAddress = SZFriendsAdmissionNNPerAddressPerMinute;
    // IK stays unlimited: friends dial it, the session area refuses replayed message 1s, and the caps on connections
    // not yet authenticated still hold.
    return limits;
}
