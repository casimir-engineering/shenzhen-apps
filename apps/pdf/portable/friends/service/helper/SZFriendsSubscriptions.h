// Subscriptions and snapshot publishing: which views each client watches and sending them only when they change.
//
// Internal to the helper. PROTOCOL.md § Snapshots: a full snapshot per change, `rev` from 1 per subscription,
// nothing when the data did not change, at most 10 per second per subscription for background changes. Changes
// an intent caused are sent at once, before its reply, so a view that clears its composer on the reply already
// shows the sent message.

#import <Foundation/Foundation.h>

#import "service/helper/SZFriendsHelperFacts.h"
#import "service/helper/SZFriendsHelperInternal.h"

NS_ASSUME_NONNULL_BEGIN

extern const NSUInteger SZFriendsMaxSubscriptions;    // 32 per connection
extern const NSUInteger SZFriendsConversationWindow;  // 200 items, and load_earlier adds as many

@interface SZFriendsSubscription : NSObject
@property(nonatomic, copy) NSString *subscriptionID;
// badge, list, nearby, details, profile, settings, message_status, conversation
@property(nonatomic, copy) NSString *view;
@property(nonatomic, copy, nullable) NSString *conversationID;
@property(nonatomic, copy, nullable) NSArray<NSString *> *messageIDs; // message_status only
@property(nonatomic, copy) NSString *query;
@property(nonatomic) NSUInteger window;
@property(nonatomic, copy, nullable) NSString *highlightItemID;
@property(nonatomic) NSInteger rev;
@property(nonatomic, copy, nullable) NSDictionary<NSString *, id> *lastData;
@property(nonatomic) CFAbsoluteTime lastSentAt;
@property(nonatomic) BOOL deferred;
@end

// The connection's dispatchState: strings and builder written for this client's app, and its subscriptions.
@interface SZFriendsClientState : NSObject
@property(nonatomic, readonly) SZFriendsAudience *audience;
@property(nonatomic, readonly) SZFriendsStrings *strings;
@property(nonatomic, readonly) SZFriendsSnapshotBuilder *builder;
@property(nonatomic, readonly) NSMutableDictionary<NSString *, SZFriendsSubscription *> *subscriptions;
// set_focus: the conversation this client's focused window shows (PROTOCOL.md § Notifications); gone with the
// connection, since the state is.
@property(nonatomic, copy, nullable) NSString *focusedConversationID;
@end

@interface SZFriendsPublisher : NSObject
- (instancetype)initWithServices:(SZFriendsHelperServices *)services
                          server:(SZFriendsIPCServer *)server
                           queue:(dispatch_queue_t)queue NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// Created on first use from the connection's hello; nil before the hello.
- (nullable SZFriendsClientState *)stateForConnection:(SZFriendsIPCConnection *)connection;
// A new subscription (not yet sent), or nil when the connection already has the maximum.
- (nullable SZFriendsSubscription *)addSubscriptionWithView:(NSString *)view
                                             conversationID:(nullable NSString *)conversationID
                                               toConnection:(SZFriendsIPCConnection *)connection;
// Builds and sends one subscription's snapshot; the first is always sent. NO when its subject no longer exists.
- (BOOL)sendSubscription:(SZFriendsSubscription *)subscription
            toConnection:(SZFriendsIPCConnection *)connection
                    pass:(nullable SZFriendsFactsPass *)pass;
// Everything that changed, to every client: now (after an intent) or within the rate limit (background).
- (void)publishAllImmediately;
- (void)publishAllCoalesced;
// The conversations no notification is posted for now: each focus a client declared with set_focus, and every open
// conversation of a client that does not send it (notifications.focus), so older apps stay quiet rather than noisy.
- (NSSet<NSString *> *)focusedConversations;
// The helper is going away: no more timers.
- (void)stop;
@end

NS_ASSUME_NONNULL_END
