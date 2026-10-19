// Shenzhen Friends helper link: the AppKit views' Objective-C face of the C client library.
//
// Wraps client/szfriends_client.h on the main run loop (a dispatch source on the client's descriptor and a
// timer for its ticks), parses frames with NSJSONSerialization, routes snapshots to the handler of the
// subscription they belong to, and matches replies to intents. After a reconnect it re-sends every active
// subscription itself, so a view keeps its handler across helper restarts and handovers.
//
// Views use only this link to reach the helper; they never include anything under service/.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol SZFriendsHost;

typedef NS_ENUM(NSInteger, SZFriendsLinkState) {
    SZFriendsLinkStateIdle = 0,
    SZFriendsLinkStateConnecting = 1,
    SZFriendsLinkStateReady = 2,
    SZFriendsLinkStateWaiting = 3,      // reconnecting; views keep their last snapshot and show the status line
    SZFriendsLinkStateIncompatible = 4,
};

// Reply error: PROTOCOL.md error object. `message` is display-ready or nil.
@interface SZFriendsLinkError : NSObject
@property(nonatomic, readonly, copy) NSString *code;
@property(nonatomic, readonly, copy, nullable) NSString *message;
@property(nonatomic, readonly) BOOL retryable;
@property(nonatomic, readonly, copy) NSDictionary<NSString *, id> *details;
@end

typedef void (^SZFriendsSnapshotHandler)(NSDictionary<NSString *, id> *data, NSInteger rev);
typedef void (^SZFriendsReplyHandler)(NSDictionary<NSString *, id> *_Nullable result,
                                      SZFriendsLinkError *_Nullable error);

@interface SZFriendsHelperLink : NSObject
// The launch path: one dispatch to a utility-QoS queue that runs szfriends_spawn_helper() (connect-or-spawn) for
// the host's embedded helper, and returns at once. The reader's first window never waits for it (brief § Product
// contract: reception starts at launch); the host calls this only while Friends is enabled.
+ (void)spawnHelperInBackgroundForHost:(id<SZFriendsHost>)host;

- (instancetype)initWithHost:(id<SZFriendsHost>)host NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (void)start;
// Friends turned off in this app: sends `disable`, then disconnects. Other apps keep their helper.
- (void)stopDisablingFriends:(BOOL)disabling;

@property(nonatomic, readonly) SZFriendsLinkState state;
// The status line for non-Ready states, from szfriends_connection_state_text(); nil when Ready.
@property(nonatomic, readonly, copy, nullable) NSString *statusText;
@property(nonatomic, copy, nullable) void (^onStateChange)(SZFriendsLinkState state);

// welcome.strings: the static labels (PROTOCOL.md § Static strings). Empty before the first welcome; views show
// nothing rather than invent text.
- (nullable NSString *)staticStringForKey:(NSString *)key;
// welcome.capabilities of the helper ("nearby.bluetooth", "online" from M2...).
@property(nonatomic, readonly, copy) NSSet<NSString *> *helperCapabilities;

// Returns a local token that stays valid across reconnects; `handler` receives every snapshot.
- (NSString *)subscribeToView:(NSString *)view
                       params:(nullable NSDictionary<NSString *, id> *)params
                      handler:(SZFriendsSnapshotHandler)handler;
// open_conversation: a conversation subscription that also marks it read while it exists. Hold it only while
// the conversation is on screen; release it when the dropdown closes.
- (NSString *)openConversation:(NSString *)conversationID
                     messageID:(nullable NSString *)messageID
                       handler:(SZFriendsSnapshotHandler)handler;
- (void)setFilter:(NSString *)query forSubscription:(NSString *)token;
- (void)loadEarlierForSubscription:(NSString *)token;
- (void)unsubscribe:(NSString *)token;

// Any other intent (PROTOCOL.md § Intents). `reply` runs on the main thread exactly once. When the link is
// not Ready it fails at once with the client-side code "not_ready" instead of queueing, since the helper owns
// every queue and a send must not happen later behind the person's back. When the connection drops before the
// reply arrives it fails with the client-side code "connection_lost": the intent may or may not have taken effect,
// and send_message / send_files are safe to retry with the same client_token. Client-side errors carry the
// status text as their message.
- (void)sendIntent:(NSString *)type
            fields:(nullable NSDictionary<NSString *, id> *)fields
             reply:(nullable SZFriendsReplyHandler)reply;
@end

NS_ASSUME_NONNULL_END
