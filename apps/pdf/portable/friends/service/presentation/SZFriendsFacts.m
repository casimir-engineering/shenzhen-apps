// Shenzhen Friends presentation inputs: plain fact objects with defaults that describe "nothing happened yet", so
// the helper fills only what it knows and the builder never meets a nil where the header promises a value.

#import "service/presentation/SZFriendsPresentation.h"

NSString *const SZFriendsEventNowFriends = @"now_friends";
NSString *const SZFriendsEventVerified = @"verified";
NSString *const SZFriendsEventKeyChanged = @"key_changed";
NSString *const SZFriendsEventKeyAccepted = @"key_accepted";
NSString *const SZFriendsEventBlocked = @"blocked";
NSString *const SZFriendsEventUnblocked = @"unblocked";
NSString *const SZFriendsEventRemoved = @"removed";
NSString *const SZFriendsEventReceivedLinkFile = @"received_through_link";
NSString *const SZFriendsEventAddedThroughOurLink = @"added_through_your_link";
NSString *const SZFriendsEventAddedThroughTheirLink = @"added_through_their_link";

// Long enough for the first sighting on a quiet network (Bonjour answers and a Bluetooth scan window), short enough
// that someone alone in a room is not told "looking" for ever.
const NSTimeInterval SZFriendsNearbySearchingSeconds = 8;

@implementation SZFriendsAudience
- (instancetype)init {
    if ((self = [super init])) {
        // Neutral words until a hello names the app: a sentence with "this app" is still true.
        _appName = @"this app";
        _revealIn = @"Finder";
        _locale = @"en";
        _capabilities = [NSSet set];
        _openFormats = [NSSet set];
        _helperCapabilities = [NSSet set];
        _timeZone = [NSTimeZone systemTimeZone];
    }
    return self;
}
@end

@implementation SZFriendsPersonFacts
- (instancetype)init {
    if ((self = [super init])) {
        _conversationID = @"";
        _picture = [SZFriendsPicture placeholder];
        _relation = SZFriendsPersonRelationFriend;
        _routeKind = SZFriendsRouteKindOffline;
        _routeMethod = SZFriendsRouteMethodNone;
        _lastInteractionAt = [NSDate dateWithTimeIntervalSince1970:0];
    }
    return self;
}
@end

@implementation SZFriendsItemFacts
- (instancetype)init {
    if ((self = [super init])) {
        _itemID = @"";
        _sentAt = [NSDate dateWithTimeIntervalSince1970:0];
        _transferRoute = SZFriendsRouteMethodNone;
    }
    return self;
}
@end

@implementation SZFriendsNearbyPersonFacts
- (instancetype)init {
    if ((self = [super init])) {
        _picture = [SZFriendsPicture placeholder];
        _relation = SZFriendsPersonRelationFriend;
        _routeMethod = SZFriendsRouteMethodNone;
    }
    return self;
}
@end

@implementation SZFriendsNearbyFacts
- (instancetype)init {
    if ((self = [super init])) {
        _networkState = SZFriendsAdapterStateNotAsked;
        _bluetoothState = SZFriendsAdapterStateNotAsked;
        _people = @[];
    }
    return self;
}
@end

@implementation SZFriendsDownloadLinkFacts
- (instancetype)init {
    if ((self = [super init])) {
        _linkID = @"";
        _fileName = @"";
        _expiresAt = [NSDate distantFuture];
    }
    return self;
}
@end

@implementation SZFriendsLinksFacts
- (instancetype)init {
    if ((self = [super init])) {
        _downloads = @[];
        _now = [NSDate date];
    }
    return self;
}
@end

@implementation SZFriendsProfileFacts
- (instancetype)init {
    if ((self = [super init])) {
        _friendsID = @"";
        _picture = [SZFriendsPicture placeholder];
        _identityPublicKey = [NSData data];
        _receivedDirectory = @"";
    }
    return self;
}
@end

@implementation SZFriendsSearchHitFacts
- (instancetype)init {
    if ((self = [super init])) {
        _conversationID = @"";
        _itemID = @"";
        _sentAt = [NSDate dateWithTimeIntervalSince1970:0];
        _text = @"";
        _matchRanges = @[];
    }
    return self;
}
@end
