// Time-limited access to all Friends chats for the AI chat (brief § AI boundaries, Grants).
//
// The assistant reads a Friends chat only under a grant the person gave. Two kinds exist:
//   - for one request: an `@` chip naming a friend or All Friends chats ("This request"), or `/` inside a
//     conversation (SPDFMacFriendsChatScope.h). It ends with that request;
//   - for a while: choosing All Friends chats in AI chat's `@` picker and then "1 hour" or "Until tomorrow"
//     (midnight, local time) makes the grant this object holds. Every AI chat request sent while it is active may
//     read any chat; it ends at expiry, on Stop now, when Friends is turned off or reset or stops running, and on
//     quit. It is held in memory only: nothing saves it, so a new launch never starts with one.
// There is no other way in: no setting, no tool and no text in a message makes one.
//
// Enforcement is in the tool layer, never the prompt. A request made while the grant is active carries its token
// (SPDFMacFriendsGrantChip); SPDFMacFriendsChatScopeGate checks the token at every Friends tool call and refuses once
// the grant has ended, so expiry or Stop now in the middle of a request stops further reads. A grant made later has
// a new token: it never reopens a request made under an earlier one, and a subagent never gets more than its parent
// request had. The `/` assistant in a friend's conversation never uses this grant: its gate has none.

#import <Foundation/Foundation.h>
#import "SPDFMacAIRequestContext.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SPDFMacFriendsGrantLength) {
    SPDFMacFriendsGrantLengthRequest = 0,   // "This request": an All Friends chats chip on the message, no grant here
    SPDFMacFriendsGrantLengthHour = 1,      // "1 hour"
    SPDFMacFriendsGrantLengthUntilTomorrow, // "Until tomorrow": the next local midnight
};

// Posted (object: the grant) when a grant starts, ends or its minute count changes.
FOUNDATION_EXPORT NSNotificationName const SPDFMacFriendsChatGrantDidChangeNotification;

// When a grant of `length` made at `now` ends; nil for SPDFMacFriendsGrantLengthRequest.
NSDate* _Nullable SPDFMacFriendsGrantExpiry(SPDFMacFriendsGrantLength length, NSDate* now, NSCalendar* calendar);
// The `@` picker's second step after All Friends chats: {"id": "all", "name": "This request", "length": @0}, then
// "1 hour" and "Until tomorrow".
NSArray<NSDictionary<NSString*, id>*>* SPDFMacFriendsGrantLengthChoices(void);

@interface SPDFMacFriendsChatGrant : NSObject
// `clock` and `calendar` default to the real time and the current calendar; tests pass their own.
- (instancetype)initWithClock:(NSDate* (^_Nullable)(void))clock
                     calendar:(nullable NSCalendar*)calendar NS_DESIGNATED_INITIALIZER;
- (instancetype)init;
// Starts a grant for all Friends chats, replacing a running one (with a new token). NO, and nothing changes, for
// SPDFMacFriendsGrantLengthRequest or while Friends is unavailable.
- (BOOL)grantAllChatsFor:(SPDFMacFriendsGrantLength)length;
// Stop now; also Friends turned off, reset or not running.
- (void)stop;
// The Friends chats the assistant could read (helper connected, assistant scopes supported) or not. NO ends the
// grant: reset, turning Friends off and a helper restart all pass through here. No grant starts while NO.
- (void)friendsAvailabilityChanged:(BOOL)available;
@property(nonatomic, readonly) BOOL active;
// The running grant's token, 0 without one. Tokens are never reused.
@property(nonatomic, readonly) uint64_t activeToken;
- (BOOL)isActiveToken:(uint64_t)token;
@property(nonatomic, readonly, nullable) NSDate* expiry;
@property(nonatomic, readonly) SPDFMacFriendsGrantLength length;
// Seconds left by the grant's clock; 0 without a running grant.
@property(nonatomic, readonly) NSTimeInterval remaining;
// Ends an expired grant and tells observers; while one runs a timer calls it every 20 seconds.
- (void)tick;
@end

// What the bar in AI chat says while the grant runs; nil without one.
// "The assistant can read all your Friends chats · 52 min left"
NSString* _Nullable SPDFMacFriendsGrantBarText(SPDFMacFriendsChatGrant* grant);
// The same in a narrow chat (320 to 400 points), where the sentence would cut off the time left:
// "All Friends chats · 52 min left". The bar keeps the sentence for its tooltip and VoiceOver.
NSString* _Nullable SPDFMacFriendsGrantBarShortText(SPDFMacFriendsChatGrant* grant);

// The Friends chip a request carries while a grant is active: All Friends chats, good only while the grant with
// this token runs. Its kind is Friends, so the request counts as one that includes Friends chats
// (SPDFMacAIRequestContext includesFriendsChats): no web tools, and Python and helper work kept for the request only.
// It names no friend, so the assistant can write to no one through it.
@interface SPDFMacFriendsGrantChip : SPDFMacAIRequestChip
@property(nonatomic, readonly) uint64_t grantToken;
+ (instancetype)chipForGrantToken:(uint64_t)token;
@end

NS_ASSUME_NONNULL_END
