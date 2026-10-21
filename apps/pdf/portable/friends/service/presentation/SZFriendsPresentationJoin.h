// Joining a profile from a new computer, as the views show it (PROTOCOL.md § Joining): the rows a request makes at the
// top of the list on the person's other computers, the badge counting them, and the `join` view on the new computer.
//
// Pure, like SZFriendsPresentation.h: facts in, display-ready `data` out, no clock read. Two readers, two sets of
// words. On a computer that already has the profile, the person wonders whether this is them and what pressing
// Approve does; on the new computer, what to type and what happens next.

#import "service/presentation/SZFriendsPresentation.h"

NS_ASSUME_NONNULL_BEGIN

// One request as a device of the person holds it (SZFriendsJoinRequest).
@interface SZFriendsJoinRequestFacts : NSObject
@property(nonatomic, copy) NSString *joinID;       // opaque, sent back in approve_join and deny_join
@property(nonatomic, copy) NSString *deviceName;   // "Mei's MacBook Air", as the new computer calls itself
@property(nonatomic, copy) NSString *system;       // "macOS 26.1"
@property(nonatomic, copy) NSDate *receivedAt;
@property(nonatomic) BOOL approved;
@property(nonatomic, copy, nullable) NSString *code;          // 8 digits, while approved
@property(nonatomic, copy, nullable) NSDate *codeExpiresAt;   // while approved
@end

// Where joining stands on the new computer.
typedef NS_ENUM(NSInteger, SZFriendsJoiningState) {
    SZFriendsJoiningIdle = 0,         // not joining; offered only while this computer has no friends yet
    SZFriendsJoiningWaiting = 1,      // the request went out: approve on another computer, then type its code
    SZFriendsJoiningChecking = 2,     // a code is being tried
    SZFriendsJoiningWrongCode = 3,    // the approving computer did not confirm that code
    SZFriendsJoiningNotReached = 4,   // no computer of the profile answered the code
    SZFriendsJoiningDenied = 5,
    SZFriendsJoiningExpired = 6,
    SZFriendsJoiningTooManyAttempts = 7,
    SZFriendsJoiningJoined = 8,
    SZFriendsJoiningUnavailable = 9,  // this computer already has friends or a profile shared with others
};

@interface SZFriendsJoiningFacts : NSObject
@property(nonatomic) SZFriendsJoiningState state;
@property(nonatomic, copy, nullable) NSString *friendsID; // the ID typed, from Waiting on
// Checking: the session carrying the code (the best one when several do); Joined: the best live session with another
// of the person's computers. None when nothing is connected.
@property(nonatomic) SZFriendsRouteMethod routeMethod;
@end

@interface SZFriendsStrings (SZFriendsJoin)
// error.message of the join intents' errors that have words of their own (not_found, not_allowed, a code that is not
// 8 digits); nil leaves the general message.
- (nullable NSString *)joinMessageForErrorCode:(NSString *)code field:(nullable NSString *)field;
@end

@interface SZFriendsSnapshotBuilder (SZFriendsJoin)
// list.join_requests: oldest first, as given.
- (NSArray<NSDictionary<NSString *, id> *> *)joinRequestRowsWithFacts:(NSArray<SZFriendsJoinRequestFacts *> *)facts
                                                                   now:(NSDate *)now;
// The badge with the rows waiting for an answer, join requests included (approved ones wait for the new computer).
- (NSDictionary<NSString *, id> *)badgeWithPeople:(NSArray<SZFriendsPersonFacts *> *)people
                                     joinRequests:(NSArray<SZFriendsJoinRequestFacts *> *)joinRequests;
// The `join` view's data.
- (NSDictionary<NSString *, id> *)joinWithFacts:(SZFriendsJoiningFacts *)facts;
@end

NS_ASSUME_NONNULL_END
